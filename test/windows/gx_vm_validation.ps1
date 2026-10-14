<#
Guest-only validation. Stage with scripts/gx_windows_vm.py stage-validation and run through the
staged gx-run.cmd ("cmd /c \\host.lan\Data\validation\gx-run.cmd -Phase ..."), which copies this file
into the caller's profile and runs it with a per-process execution-policy bypass.
The manifest's UUID MUST be the live QEMU UUID read by the host (HMP info uuid).
No host execution, password parameters, clipboard, account impersonation, automatic download,
elevation, or unverified installer/application execution is supported.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Manifest,
    [Parameter(Mandatory=$true)]
    [ValidateSet('inspect','tokens','accounts','enable-uac','gl','install','upgrade','seed-foreign-before','expect-install-refused','seed-foreign-after','uninstall','check-preserved','cleanup-foreign')]
    [string]$Phase,
    [ValidatePattern('^[A-Za-z0-9_-]{1,48}$')][string]$RunId = 'validation-01',
    [ValidateSet('User','Machine')][string]$Scope = 'User',
    [ValidateSet('All','AppPath','Background','Directory','ShellIdentity')][string]$Group = 'All',
    [ValidateSet('Value','Subkey','Both')][string]$ForeignKind = 'Both',
    [string]$Installer,
    [string]$InstallerSha256,
    [string]$AppSha256,
    [string]$AppRoot,
    [switch]$Rehearsal,
    [ValidateRange(0,120)][int]$HoldSeconds = 0,
    [ValidateRange(0,2147483647)][int]$PeerPid = 0,
    [string]$ExportDir,
    [switch]$SoftwareGL
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Owner = 'gx-ghostty-ui-validation'
$script:Image = 'dockurr/windows@sha256:59f8bed19cfd49cf1701debe34f9df6311e61a4e2ae68aa9f41206e2184e31cc'
$script:LF = [string][char]10
$script:Activator = '{978ab84b-3cac-4593-95d5-2e04d68eed4f}'
$script:Keys = [ordered]@{
    AppPath = 'Software\Microsoft\Windows\CurrentVersion\App Paths\ghostty.exe'
    Background = 'Software\Classes\Directory\Background\shell\GhosttyGX'
    Directory = 'Software\Classes\Directory\shell\GhosttyGX'
    ShellAumid = 'Software\Classes\AppUserModelId\gx0404.GhosttyGX'
    ShellClsid = 'Software\Classes\CLSID\' + $script:Activator
}
# Installer preflight reasons (english.* custom messages of dist/windows/gx/ghostty-gx.iss).
$script:Refusal = @{
    Integration = 'Existing Windows integration entries do not belong to this installation'
    Shell = 'Another installation owns the Ghostty GX notification identity'
}
$script:ExportExtra = New-Object System.Collections.Generic.List[string]

$script:TokenSource = @'
using System;
using System.Collections;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class GxVmToken {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr buffer, int length, out int returned);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);

    static IntPtr Info(IntPtr token, int infoClass) {
        int length;
        GetTokenInformation(token, infoClass, IntPtr.Zero, 0, out length);
        if (length <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr buffer = Marshal.AllocHGlobal(length);
        if (!GetTokenInformation(token, infoClass, buffer, length, out length)) {
            int error = Marshal.GetLastWin32Error();
            Marshal.FreeHGlobal(buffer);
            throw new Win32Exception(error);
        }
        return buffer;
    }

    public static Hashtable Describe(IntPtr token, bool includeLinked) {
        Hashtable result = new Hashtable();
        IntPtr b = Info(token, 1);
        try { result["sid"] = new SecurityIdentifier(Marshal.ReadIntPtr(b)).Value; } finally { Marshal.FreeHGlobal(b); }
        b = Info(token, 10);
        try { result["logon_id"] = Marshal.ReadInt64(b, 8); } finally { Marshal.FreeHGlobal(b); }
        b = Info(token, 12);
        try { result["session_id"] = Marshal.ReadInt32(b); } finally { Marshal.FreeHGlobal(b); }
        int type;
        b = Info(token, 18);
        try { type = Marshal.ReadInt32(b); } finally { Marshal.FreeHGlobal(b); }
        result["elevation_type"] = type == 1 ? "Default" : type == 2 ? "Full" : type == 3 ? "Limited" : "Unknown";
        b = Info(token, 20);
        try { result["elevated"] = Marshal.ReadInt32(b) != 0; } finally { Marshal.FreeHGlobal(b); }
        b = Info(token, 25);
        try {
            IntPtr sid = Marshal.ReadIntPtr(b);
            int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
            long rid = (long)(uint)Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
            result["integrity_rid"] = rid;
            result["integrity"] = rid < 0x2000 ? "low" : rid < 0x3000 ? "medium" : rid < 0x4000 ? "high" : "system";
        } finally { Marshal.FreeHGlobal(b); }
        if (includeLinked && type != 1) {
            IntPtr linked;
            b = Info(token, 19);
            try { linked = Marshal.ReadIntPtr(b); } finally { Marshal.FreeHGlobal(b); }
            try { result["linked"] = Describe(linked, false); } finally { CloseHandle(linked); }
        }
        return result;
    }

    public static Hashtable Process(int pid) {
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr token;
            if (!OpenProcessToken(process, 0x0008, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try { return Describe(token, true); } finally { CloseHandle(token); }
        } finally { CloseHandle(process); }
    }
}
'@

function Assert-GxVm([string]$ManifestPath) {
    $identity = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($identity.owner -ne $script:Owner -or $identity.image -ne $script:Image -or $identity.schema -ne 1) {
        throw 'Unrecognized VM validation manifest.'
    }
    $expectedUuid = [guid]$identity.guest_uuid
    if ($expectedUuid -eq [guid]::Empty) { throw 'A live QEMU guest UUID is required.' }
    $computer = Get-CimInstance Win32_ComputerSystem
    $product = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $virtualDescription = "$($computer.Manufacturer) $($computer.Model) $($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)"
    if ($computer.Name -ine $identity.guest_name -or [guid]$product.UUID -ne $expectedUuid -or
        $virtualDescription -notmatch '(?i)QEMU|Bochs|SeaBIOS|OVMF|EDK II') {
        throw 'VM identity guard refused: name, QEMU UUID, and QEMU/OVMF hardware must all match. No writes performed.'
    }
    if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -ine $identity.fixture_sha256) {
        throw 'Guest fixture differs from the staged manifest.'
    }
    return $identity
}

function Test-Elevated {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($current)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 20) + $script:LF), [Text.UTF8Encoding]::new($false))
}

function Assert-Hash([string]$Path, [string]$Expected) {
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'An existing file and its complete frozen SHA256 are required.'
    }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Expected) { throw "Frozen file hash mismatch: $Path" }
}

function Assert-NoReparse([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Validation directories must not traverse a reparse point.'
            }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
}

function Open-RegistryBase {
    $hive = if ($Scope -eq 'Machine') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function Read-KeyTree([Microsoft.Win32.RegistryKey]$Base, [string]$Key, [int]$Depth = 0) {
    $handle = $Base.OpenSubKey($Key, $false)
    if ($null -eq $handle) { return [ordered]@{ exists=$false } }
    try {
        $values = [ordered]@{}
        $children = [ordered]@{}
        $names = @($handle.GetValueNames() | Sort-Object)
        $subkeys = @($handle.GetSubKeyNames() | Sort-Object)
        if ($names.Count -gt 64 -or $subkeys.Count -gt 16 -or $Depth -gt 2) { throw 'Registry evidence exceeds fixture bounds.' }
        foreach ($name in $names) {
            $kind = $handle.GetValueKind($name)
            if ($kind -ne [Microsoft.Win32.RegistryValueKind]::String) {
                throw 'Unexpected non-string integration value; preserved without mutation.'
            }
            $value = [string]$handle.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($value.Length -gt 32768) { throw 'Registry string exceeds fixture bounds.' }
            # PS5.1 ConvertFrom-Json rejects an empty property name, so every value
            # name (including the unnamed default) carries this prefix in evidence.
            $values['value:' + $name] = $value
        }
        foreach ($name in $subkeys) { $children[$name] = Read-KeyTree $Base ($Key + '\' + $name) ($Depth + 1) }
        return [ordered]@{ exists=$true; values=$values; children=$children }
    } finally { $handle.Dispose() }
}

function Get-RegValue($Tree, [string]$Name) {
    $key = 'value:' + $Name
    if ($Tree.values.Contains($key)) { return $Tree.values[$key] }
    return $null
}

function Registry-Snapshot {
    $base = Open-RegistryBase
    try {
        $result = [ordered]@{}
        foreach ($entry in $script:Keys.GetEnumerator()) { $result[$entry.Key] = Read-KeyTree $base $entry.Value }
        return $result
    } finally { $base.Dispose() }
}

function Json-Canonical($Value) { return ($Value | ConvertTo-Json -Depth 20 -Compress) }

function Read-Accounts {
    $admin = Get-LocalUser -Name gxadmin
    $standard = Get-LocalUser -Name gxtest
    $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | ForEach-Object { $_.SID.Value })
    $users = @(Get-LocalGroupMember -SID 'S-1-5-32-545' | ForEach-Object { $_.SID.Value })
    $rdp = @(Get-LocalGroupMember -SID 'S-1-5-32-555' | ForEach-Object { $_.SID.Value })
    $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    if (-not $admin.Enabled -or -not $standard.Enabled -or $members -notcontains $admin.SID.Value -or
        $members -contains $standard.SID.Value -or $users -notcontains $standard.SID.Value -or
        $rdp -notcontains $standard.SID.Value -or $policy.fDisableClip -ne 1 -or $policy.fDisableCdm -ne 1) {
        throw 'Expected standard/admin memberships and disabled clipboard/drive redirection were not verified.'
    }
    return @{ verified=$true; admin_sid=$admin.SID.Value; standard_sid=$standard.SID.Value; standard_is_admin=$false;
              rdp_clipboard_disabled=$true; rdp_drive_redirection_disabled=$true }
}

function Initialize-GuestAccounts($Identity) {
    if (-not (Test-Elevated)) { throw 'Account bootstrap requires the elevated gxadmin guest session.' }
    if ($env:USERNAME -ine 'gxadmin') { throw 'Bootstrap is limited to the existing gxadmin guest account.' }
    if (Test-Path -LiteralPath 'C:\OEM\guest-user.json') {
        Assert-Hash 'C:\OEM\setup-guest.ps1' $Identity.setup_sha256
        $account = Get-Content -LiteralPath 'C:\OEM\guest-user.json' -Raw | ConvertFrom-Json
        if ($account.username -cne 'gxtest') { throw 'Unexpected OEM account name.' }
        $account = $null
        # Reuse the single generator-owned bootstrap. Never emit the secret or
        # put it into a process command line. The bootstrap removes its JSON.
        & 'C:\OEM\setup-guest.ps1'
    }
    return Read-Accounts
}

function Get-TokenFacts([int]$ProcessId) {
    if (-not ('GxVmToken' -as [type])) { Add-Type -TypeDefinition $script:TokenSource -Language CSharp }
    return [GxVmToken]::Process($ProcessId)
}

function Compare-SplitTokens($Medium, $High) {
    $failures = New-Object System.Collections.Generic.List[string]
    if ($Medium.sid -ne $High.sid) { $failures.Add('different user SID') }
    if ($Medium.session_id -ne $High.session_id) { $failures.Add('different Windows session') }
    if ($Medium.integrity -ne 'medium' -or $Medium.elevated -or $Medium.elevation_type -ne 'Limited') { $failures.Add('medium side is not a limited, non-elevated medium token') }
    if ($High.integrity -ne 'high' -or -not $High.elevated -or $High.elevation_type -ne 'Full') { $failures.Add('high side is not a full, elevated high token') }
    if ($null -eq $Medium.linked -or $null -eq $High.linked) { $failures.Add('a linked token is missing') }
    elseif ($Medium.linked.logon_id -ne $High.logon_id -or $High.linked.logon_id -ne $Medium.logon_id) { $failures.Add('linked logon sessions do not point at each other') }
    if ($Medium.logon_id -eq $High.logon_id) { $failures.Add('both sides share one logon session, not a UAC split pair') }
    return @{ paired=($failures.Count -eq 0); failures=@($failures); sid=$Medium.sid; session_id=$Medium.session_id;
              medium_logon_id=$Medium.logon_id; high_logon_id=$High.logon_id }
}

function Run-Tokens {
    $self = Get-TokenFacts $PID
    $process = Get-Process -Id $PID
    $facts = [ordered]@{ pid=$PID; birth=$process.StartTime.ToUniversalTime().ToString('o'); self=$self }
    if ($PeerPid -gt 0) {
        try { $facts.peer = Get-TokenFacts $PeerPid; $facts.peer_access = 'granted' }
        catch { $facts.peer_access = 'refused: ' + $_.Exception.Message }
    }
    $level = [string]$self.integrity
    if ($level -notin @('medium','high')) { throw "Token phase expects a medium or high console, got $level." }
    $record = Join-Path $script:RunRoot ('token-' + $level + '.json')
    Write-Json $record $facts
    $script:ExportExtra.Add($record)
    $otherLevel = if ($level -eq 'medium') { 'high' } else { 'medium' }
    $otherPath = Join-Path $script:RunRoot ('token-' + $otherLevel + '.json')
    if (Test-Path -LiteralPath $otherPath) {
        $other = (Get-Content -LiteralPath $otherPath -Raw | ConvertFrom-Json).self
        $mine = (Get-Content -LiteralPath $record -Raw | ConvertFrom-Json).self
        $pair = if ($level -eq 'medium') { Compare-SplitTokens $mine $other } else { Compare-SplitTokens $other $mine }
        $facts.pairing = $pair
        if (-not $pair.paired) { throw ('Split-token pairing failed: ' + ($pair.failures -join '; ')) }
    } else {
        $facts.pairing = 'PENDING: run the same RunId from the other integrity level'
    }
    if ($HoldSeconds -gt 0 -and $script:ExportRoot) {
        # Keep this token alive so the other integrity level can test -PeerPid.
        Write-Json (Join-Path $script:ExportRoot ($script:ExportPrefix + $script:Step + '-token-holding.json')) @{ pid=$PID; integrity=$level; hold_seconds=$HoldSeconds }
        Start-Sleep -Seconds $HoldSeconds
        $facts.held_seconds = $HoldSeconds
    }
    return $facts
}

function Run-Installer([bool]$ExpectRefusal, [string]$Reason) {
    Assert-Hash $Installer $InstallerSha256
    $log = Join-Path $script:RunRoot ($script:Step + '-installer.log')
    $mode = if ($Scope -eq 'Machine') { '/ALLUSERS' } else { '/CURRENTUSER' }
    $arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/LANG=english', $mode,
                   ('/DIR="' + $script:AppDir + '"'), ('/LOG="' + $log + '"'), '/TASKS=contextmenu')
    $process = Start-Process -FilePath $Installer -ArgumentList $arguments -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit(180000)) { throw "Installer PID $($process.Id) exceeded 180 seconds; inspect the owned VM installer, do not kill unknown processes." }
        $exitCode = $process.ExitCode
    } finally { $process.Dispose() }
    $text = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' }
    $script:ExportExtra.Add($log)
    if ($ExpectRefusal) {
        # Inno Setup exit code 7: PrepareToInstall refused before any file was installed.
        if ($exitCode -ne 7 -or $text -notmatch [regex]::Escape($Reason)) {
            throw "Install was not rejected by the expected preflight (exit $exitCode)."
        }
    } elseif ($exitCode -ne 0) { throw "Installer exited $exitCode; see the phase log." }
    return @{ exit_code=$exitCode; installer_sha256=$InstallerSha256; log=$log; expected_reason=$Reason }
}

function Assert-OwnedBaseline($Snapshot, [string]$Name) {
    $tree = $Snapshot[$Name]
    $exe = Join-Path $script:AppDir 'ghostty.exe'
    if (-not $tree.exists) { throw "Integration group $Name is missing after installation." }
    switch ($Name) {
        'AppPath' {
            if ($tree.values.Count -ne 2 -or $tree.children.Count -ne 0 -or (Get-RegValue $tree '') -ine $exe -or
                (Get-RegValue $tree 'Path') -ine $script:AppDir) { throw 'App Paths is not the untouched fixture installation.' }
        }
        'ShellAumid' {
            if ($tree.values.Count -ne 4 -or $tree.children.Count -ne 0 -or (Get-RegValue $tree 'GxExecutable') -ine $exe -or
                (Get-RegValue $tree 'CustomActivator') -ine $script:Activator -or (Get-RegValue $tree 'DisplayName') -cne 'Ghostty GX' -or
                (Get-RegValue $tree 'IconUri') -ine $exe) { throw 'The AUMID registration is not the untouched fixture installation.' }
        }
        'ShellClsid' {
            $server = if ($tree.children.Contains('LocalServer32')) { $tree.children['LocalServer32'] } else { $null }
            if ($tree.values.Count -ne 0 -or $tree.children.Count -ne 1 -or $null -eq $server -or $server.values.Count -ne 1 -or
                $server.children.Count -ne 0 -or (Get-RegValue $server '') -ine ('"' + $exe + '" --gx-shell-action=toast-server')) {
                throw 'The toast activator CLSID is not the untouched fixture installation.'
            }
        }
        default {
            $command = '"' + $exe + '" --working-directory="%V"'
            if ($tree.values.Count -ne 2 -or $tree.children.Count -ne 1 -or -not $tree.children.Contains('command') -or
                (Get-RegValue $tree 'Icon') -ine ('"' + $exe + '",0') -or (Get-RegValue $tree '') -cne 'Open Ghostty GX here') {
                throw 'Explorer integration is not the untouched English fixture installation.'
            }
            $child = $tree.children['command']
            if ($child.values.Count -ne 1 -or $child.children.Count -ne 0 -or (Get-RegValue $child '') -ine $command) {
                throw 'Explorer command contains unexpected content.'
            }
        }
    }
}

function Foreign-Groups([bool]$BeforeInstall) {
    if ($Group -eq 'All') { return @('AppPath','Background','Directory') }
    if ($Group -eq 'ShellIdentity') {
        if (-not $BeforeInstall) { throw 'ShellIdentity foreign content is only supported before installation.' }
        return @('ShellAumid')
    }
    return @($Group)
}

function Seed-Foreign([bool]$BeforeInstall) {
    if ($script:State.foreign_active) { throw 'This run already has foreign fixtures; do not overwrite evidence.' }
    $baseline = Registry-Snapshot
    $groups = @(Foreign-Groups $BeforeInstall)
    if ($BeforeInstall) {
        foreach ($name in $script:Keys.Keys) { if ($baseline[$name].exists) { throw 'Foreign-before needs a clean VM/user registry baseline.' } }
        if ($script:State.installed) { throw 'Cannot seed install-time conflicts over an existing installation.' }
    } else {
        if (-not $script:State.installed) { throw 'Install or upgrade the fixture package first.' }
        foreach ($name in $groups) { Assert-OwnedBaseline $baseline $name }
    }
    $base = Open-RegistryBase
    try {
        foreach ($name in $groups) {
            $key = $base.CreateSubKey($script:Keys[$name])
            try {
                if ($BeforeInstall) {
                    $foreignExe = Join-Path $script:RunRoot 'foreign-owner.exe'
                    if ($name -eq 'ShellAumid') {
                        $key.SetValue('GxExecutable', $foreignExe, [Microsoft.Win32.RegistryValueKind]::String)
                    } else {
                        $key.SetValue('', $foreignExe, [Microsoft.Win32.RegistryValueKind]::String)
                    }
                    if ($name -eq 'AppPath') { $key.SetValue('Path', $script:RunRoot, [Microsoft.Win32.RegistryValueKind]::String) }
                }
                if ($ForeignKind -ne 'Subkey') { $key.SetValue('GXFixtureForeign_' + $script:State.token, 'keep-' + $script:State.token, [Microsoft.Win32.RegistryValueKind]::String) }
                if ($ForeignKind -ne 'Value') {
                    $child = $key.CreateSubKey('GXFixtureForeign_' + $script:State.token)
                    try { $child.SetValue('proof', $script:State.token, [Microsoft.Win32.RegistryValueKind]::String) } finally { $child.Dispose() }
                }
            } finally { $key.Dispose() }
        }
    } finally { $base.Dispose() }
    $script:State.foreign_active = $true
    $script:State.foreign_groups = $groups
    $script:State.foreign_before = $BeforeInstall
    $script:State.foreign_expected = Registry-Snapshot
    return $script:State.foreign_expected
}

function Check-Preserved {
    if (-not $script:State.foreign_active) { throw 'No foreign fixture is recorded for this run.' }
    $actual = Registry-Snapshot
    foreach ($name in @($script:State.foreign_groups)) {
        if ((Json-Canonical $actual[$name]) -cne (Json-Canonical $script:State.foreign_expected.$name)) {
            throw "Foreign values/subkeys or their original owned group were changed: $name"
        }
    }
    return $actual
}

function Cleanup-Foreign {
    if ($script:State.installed) { throw 'Uninstall successfully before fixture cleanup.' }
    $actual = Check-Preserved
    # Only the exact fully compared fixture-owned groups are removed. A changed
    # value, new subkey, failed snapshot, or unknown run refuses cleanup.
    $base = Open-RegistryBase
    try { foreach ($name in @($script:State.foreign_groups)) { $base.DeleteSubKeyTree($script:Keys[$name], $false) } }
    finally { $base.Dispose() }
    $script:State.foreign_active = $false
    return @{ cleaned_groups=@($script:State.foreign_groups); snapshot_before=$actual }
}

function Resolve-GlApp {
    if (-not $AppRoot) {
        if ($Rehearsal) { throw '-Rehearsal requires -AppRoot with a REHEARSAL_NOT_FINAL payload.' }
        $installed = Join-Path $script:AppDir 'ghostty.exe'
        Assert-Hash $installed $AppSha256
        return @{ exe=$installed; class='INSTALLED' }
    }
    if (-not $Rehearsal) { throw '-AppRoot is accepted only with -Rehearsal; final GL evidence uses the installed application.' }
    $payload = Get-Content -LiteralPath (Join-Path $AppRoot 'payload-manifest.json') -Raw | ConvertFrom-Json
    if ($payload.class -cne 'REHEARSAL_NOT_FINAL') { throw 'The payload is not marked REHEARSAL_NOT_FINAL.' }
    $local = Join-Path $script:RunRoot ($script:Step + '-app')
    Copy-Item -LiteralPath $AppRoot -Destination $local -Recurse
    $listed = @($payload.files.PSObject.Properties)
    foreach ($entry in $listed) { Assert-Hash (Join-Path $local $entry.Name) $entry.Value }
    $prefix = [IO.Path]::GetFullPath($local).TrimEnd('\') + '\'
    $known = @{ 'payload-manifest.json' = $true }
    foreach ($entry in $listed) { $known[$entry.Name] = $true }
    $extra = @(Get-ChildItem -LiteralPath $local -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($prefix.Length).Replace('\', '/') } |
               Where-Object { -not $known.ContainsKey($_) })
    if ($extra.Count -gt 0) { throw ('The rehearsal payload contains unlisted files: ' + (($extra | Select-Object -First 8) -join ', ')) }
    $exe = Join-Path $local 'ghostty.exe'
    Assert-Hash $exe $AppSha256
    return @{ exe=$exe; class='REHEARSAL_NOT_FINAL'; payload_app_source=$payload.app_source }
}

function Probe-GL {
    $app = Resolve-GlApp
    $exe = $app.exe
    $private = Join-Path $script:RunRoot ($script:Step + '-gl-profile')
    $config = Join-Path $private 'ghostty\config.ghostty'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($config)) | Out-Null
    $configText = (@('language = en', 'confirm-close-surface = false', 'gx-session-restore = false',
                     'command = cmd.exe /d /k echo GX_VM_GL_PROBE') -join $script:LF) + $script:LF
    [IO.File]::WriteAllText($config, $configText, [Text.UTF8Encoding]::new($false))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.Arguments = '--gx-single-instance=false'
    $start.WorkingDirectory = $private
    $start.UseShellExecute = $false
    foreach ($key in @($start.EnvironmentVariables.Keys)) {
        if ($key -match '^(?i:GHOSTTY_|XDG_)' -or $key -in @('NO_COLOR','TERM','LOCALAPPDATA','APPDATA')) { $start.EnvironmentVariables.Remove($key) }
    }
    $start.EnvironmentVariables['LOCALAPPDATA'] = $private
    $start.EnvironmentVariables['APPDATA'] = Join-Path $private 'appdata'
    $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $private
    $start.EnvironmentVariables['XDG_STATE_HOME'] = Join-Path $private 'state'
    $start.EnvironmentVariables['XDG_CACHE_HOME'] = Join-Path $private 'cache'
    if ($SoftwareGL) { $start.EnvironmentVariables['GHOSTTY_GX_OPENGL'] = 'software' }
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    $pidOwned = $process.Id
    $birth = $process.StartTime.ToUniversalTime().ToString('o')
    $log = Join-Path $private 'ghostty\logs\ghostty.log'
    $script:ExportExtra.Add($log)
    $renderer = $null
    $closed = $false
    $held = 0
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($process.HasExited) { throw "Owned app exited $($process.ExitCode) before GL capability was established." }
            if (Test-Path -LiteralPath $log) {
                $renderer = @(Get-Content -LiteralPath $log | Select-String 'loaded OpenGL [4-9].*vendor=.*software=' | ForEach-Object Line)
                if ($renderer.Count -gt 0) { break }
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $renderer) { throw 'No supported actual WGL/Mesa renderer was reported.' }
        $windowDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do { $process.Refresh(); if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $windowDeadline)
        if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Renderer started without an observable application window.' }
        $title = $process.MainWindowTitle
        if ($HoldSeconds -gt 0) {
            if ($ExportDir) {
                $marker = Join-Path $script:ExportRoot ($script:ExportPrefix + $script:Step + '-gl-holding.json')
                Write-Json $marker @{ pid=$pidOwned; hold_seconds=$HoldSeconds; utc=[DateTime]::UtcNow.ToString('o'); class=$app.class }
            }
            $holdEnd = [DateTime]::UtcNow.AddSeconds($HoldSeconds)
            while ([DateTime]::UtcNow -lt $holdEnd) {
                if ($process.HasExited) { throw "Owned app exited $($process.ExitCode) during the screenshot hold." }
                Start-Sleep -Milliseconds 200
            }
            $held = $HoldSeconds
        }
        $software = if ($renderer[-1] -match 'software=(true|false)') { $Matches[1] -eq 'true' } else { $null }
        return @{ status=$(if ($app.class -eq 'INSTALLED') { 'PASS_NATIVE_GL_ONLY' } else { 'REHEARSAL_NATIVE_GL_ONLY_NOT_FINAL' });
                  app_class=$app.class; pid=$pidOwned; birth=$birth; app_sha256=$AppSha256; exe=$exe; window_title=$title;
                  renderer=$renderer; software_renderer=$software; held_seconds=$held; log=$log;
                  visual_review='PENDING'; software_requested=[bool]$SoftwareGL }
    } finally {
        if (-not $process.HasExited) {
            $null = $process.CloseMainWindow()
            $closed = $process.WaitForExit(15000)
            if (-not $closed) { $process.Kill(); $null = $process.WaitForExit(5000) }
        } else { $closed = $true }
        $process.Dispose()
        if (-not $closed) { throw 'Owned GL probe required termination; normal shutdown did not pass.' }
    }
}

function Enable-SplitTokens {
    # dockur's unattend answer sets EnableLUA=0, so administrators get one unsplit
    # high token and no medium/high pair exists. Restore the Windows defaults
    # inside the verified VM only; the guest must restart before tokens runs.
    if (-not (Test-Elevated)) { throw 'enable-uac requires an elevated administrator console in the verified VM.' }
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $before = Get-ItemProperty -LiteralPath $path
    $old = @{ enable_lua=$before.EnableLUA; consent_admin=$before.ConsentPromptBehaviorAdmin; secure_desktop=$before.PromptOnSecureDesktop }
    Set-ItemProperty -LiteralPath $path -Name EnableLUA -Value 1 -Type DWord
    Set-ItemProperty -LiteralPath $path -Name ConsentPromptBehaviorAdmin -Value 5 -Type DWord
    Set-ItemProperty -LiteralPath $path -Name PromptOnSecureDesktop -Value 1 -Type DWord
    $after = Get-ItemProperty -LiteralPath $path
    return @{ before=$old; after=@{ enable_lua=$after.EnableLUA; consent_admin=$after.ConsentPromptBehaviorAdmin; secure_desktop=$after.PromptOnSecureDesktop };
              restart_required=($old.enable_lua -ne 1) }
}

function Run-Inspect {
    $os = Get-CimInstance Win32_OperatingSystem
    $uac = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $accounts = try { Read-Accounts } catch { @{ verified=$false; reason=$_.Exception.Message } }
    $video = @(Get-CimInstance Win32_VideoController | ForEach-Object { @{ name=$_.Name; driver=$_.DriverVersion; status=$_.Status } })
    return [ordered]@{
        os = @{ caption=$os.Caption; version=$os.Version; build=$os.BuildNumber }
        uac = @{ enable_lua=$uac.EnableLUA; consent_admin=$uac.ConsentPromptBehaviorAdmin; secure_desktop=$uac.PromptOnSecureDesktop }
        oem = @{ guest_user_json_present=(Test-Path -LiteralPath 'C:\OEM\guest-user.json'); setup_result_present=(Test-Path -LiteralPath 'C:\OEM\gx-setup-result.txt') }
        accounts = $accounts
        video = $video
        token = (Get-TokenFacts $PID)
        registry = (Registry-Snapshot)
    }
}

# This must remain before all account/registry mutations and directory creation.
$identity = Assert-GxVm $Manifest
if ($Scope -eq 'Machine' -and -not (Test-Elevated)) { throw 'Machine-scope fixtures require elevation inside the verified VM.' }
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:RunRoot = Join-Path $env:LOCALAPPDATA ('GXVMValidation\Runs\' + $RunId)
$script:AppDir = if ($Scope -eq 'Machine') { Join-Path $env:ProgramFiles ('GXVMValidation\' + $RunId) } else { Join-Path $env:LOCALAPPDATA ('GXVMValidation\Apps\' + $RunId) }
Assert-NoReparse $script:RunRoot
Assert-NoReparse $script:AppDir
$script:ExportRoot = $null
$script:ExportPrefix = $RunId + '--' + $env:USERNAME + '--'
$script:ExportError = $null
if ($ExportDir) {
    # The guest share is Samba over a host 9p bind mount where a directory created
    # by the guest cannot reliably hold a new subdirectory (mkdir reports "not
    # found" although it exists). Export flat into the staged out folder instead;
    # export only copies local evidence, so its failure is reported, never fatal.
    if (Test-Path -LiteralPath $ExportDir -PathType Container) { $script:ExportRoot = $ExportDir }
    else { $script:ExportError = 'Export folder is not reachable: ' + $ExportDir }
}
$statePath = Join-Path $script:RunRoot 'state.json'
if (Test-Path -LiteralPath $statePath) {
    $script:State = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($script:State.owner -ne $script:Owner -or $script:State.uuid -ne $identity.guest_uuid -or
        $script:State.sid -ne $sid -or $script:State.scope -ne $Scope -or $script:State.app_dir -ne $script:AppDir) {
        throw 'Existing run belongs to a different VM/user/scope/application.'
    }
} else {
    if (Test-Path -LiteralPath $script:RunRoot) { throw 'Existing directory has no validation ownership record.' }
    [IO.Directory]::CreateDirectory($script:RunRoot) | Out-Null
    $script:State = [pscustomobject]@{ owner=$script:Owner; uuid=$identity.guest_uuid; sid=$sid; scope=$Scope;
        app_dir=$script:AppDir; token=[guid]::NewGuid().ToString('N'); installed=$false; installer_history=@();
        foreign_active=$false; foreign_groups=@(); foreign_before=$false; foreign_expected=$null }
}
$script:Step = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $Phase
$report = [ordered]@{ phase=$Phase; status='PENDING'; run_id=$RunId; vm_uuid=$identity.guest_uuid; computer=$identity.guest_name;
    user=[Security.Principal.WindowsIdentity]::GetCurrent().Name; sid=$sid; elevated=(Test-Elevated);
    scope=$Scope; app_dir=$script:AppDir; rehearsal=[bool]$Rehearsal; visual_review='PENDING';
    export_error=$script:ExportError; result=$null }
try {
    switch ($Phase) {
        'inspect' { $report.result = Run-Inspect }
        'tokens' { $report.result = Run-Tokens }
        'accounts' { $report.result = Initialize-GuestAccounts $identity }
        'enable-uac' { $report.result = Enable-SplitTokens }
        'gl' { $report.result = Probe-GL }
        { $_ -in 'install','upgrade' } {
            if ($script:State.foreign_active) { throw 'Use expect-install-refused for a recorded foreign-before fixture.' }
            if ($Phase -eq 'upgrade' -and -not $script:State.installed) { throw 'Install the old package in this run before upgrading.' }
            if ($Phase -eq 'install' -and $script:State.installed) { throw 'Use upgrade for an existing fixture installation.' }
            if ($Phase -eq 'upgrade' -and @($script:State.installer_history) -contains $InstallerSha256.ToLowerInvariant()) {
                throw 'Upgrade needs a different frozen installer than the one already installed.'
            }
            $installed = Run-Installer $false ''
            if (-not (Test-Path -LiteralPath (Join-Path $script:AppDir 'ghostty.exe'))) { throw 'Successful installer did not produce the app.' }
            $script:State.installed = $true
            $script:State.installer_history = @(@($script:State.installer_history) + $InstallerSha256.ToLowerInvariant())
            $snapshot = Registry-Snapshot
            foreach ($name in $script:Keys.Keys) { Assert-OwnedBaseline $snapshot $name }
            $report.result = @{ installer=$installed; registry=$snapshot;
                                app_sha256=(Get-FileHash -LiteralPath (Join-Path $script:AppDir 'ghostty.exe') -Algorithm SHA256).Hash }
        }
        'seed-foreign-before' { $report.result = Seed-Foreign $true }
        'expect-install-refused' {
            if (-not $script:State.foreign_active -or -not $script:State.foreign_before) { throw 'Seed a clean foreign-before fixture first.' }
            $reason = if (@($script:State.foreign_groups) -contains 'ShellAumid') { $script:Refusal.Shell } else { $script:Refusal.Integration }
            $report.result = Run-Installer $true $reason
            $null = Check-Preserved
            if (Test-Path -LiteralPath (Join-Path $script:AppDir 'ghostty.exe')) { throw 'Refused installation unexpectedly wrote the executable.' }
        }
        'seed-foreign-after' { $report.result = Seed-Foreign $false }
        'uninstall' {
            if (-not $script:State.installed) { throw 'No fixture installation is recorded.' }
            $uninstaller = Join-Path $script:AppDir 'unins000.exe'
            if (-not (Test-Path -LiteralPath $uninstaller)) { throw 'Installer-owned uninstaller is missing.' }
            $uninstallLog = Join-Path $script:RunRoot ($script:Step + '-uninstall.log')
            $script:ExportExtra.Add($uninstallLog)
            $process = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="' + $uninstallLog + '"')) -WindowStyle Hidden -PassThru
            try {
                if (-not $process.WaitForExit(180000) -or $process.ExitCode -ne 0) { throw "Uninstaller PID $($process.Id) did not complete successfully within 180 seconds." }
                $exitCode = $process.ExitCode
            } finally { $process.Dispose() }
            if (Test-Path -LiteralPath (Join-Path $script:AppDir 'ghostty.exe')) { throw 'Uninstall left the current executable installed.' }
            $script:State.installed = $false
            $after = Registry-Snapshot
            $foreign = if ($script:State.foreign_active) { @($script:State.foreign_groups) } else { @() }
            foreach ($name in $script:Keys.Keys) {
                if ($foreign -notcontains $name -and $after[$name].exists) { throw "Uninstall left owned integration group $name." }
            }
            if ($script:State.foreign_active) { $null = Check-Preserved }
            $report.result = @{ exit_code=$exitCode; log=$uninstallLog; registry=$after }
        }
        'check-preserved' { $report.result = Check-Preserved }
        'cleanup-foreign' { $report.result = Cleanup-Foreign }
    }
    $report.status = if ($Rehearsal) { 'REHEARSAL_NOT_FINAL' } else { 'PASS_NATIVE_SCOPED' }
} catch {
    $report.status = 'FAIL'
    $report.result = @{ reason=$_.Exception.Message; position=$_.InvocationInfo.PositionMessage }
} finally {
    Write-Json $statePath $script:State
    $reportPath = Join-Path $script:RunRoot ($script:Step + '.json')
    Write-Json $reportPath $report
    if ($script:ExportRoot) {
        try {
            Copy-Item -LiteralPath $reportPath -Destination (Join-Path $script:ExportRoot ($script:ExportPrefix + [IO.Path]::GetFileName($reportPath))) -Force
            Copy-Item -LiteralPath $statePath -Destination (Join-Path $script:ExportRoot ($script:ExportPrefix + 'state.json')) -Force
            foreach ($extra in $script:ExportExtra) {
                if (Test-Path -LiteralPath $extra -PathType Leaf) {
                    Copy-Item -LiteralPath $extra -Destination (Join-Path $script:ExportRoot ($script:ExportPrefix + $script:Step + '-' + [IO.Path]::GetFileName($extra))) -Force
                }
            }
        } catch { Write-Warning ('Export failed: ' + $_.Exception.Message) }
    }
    [pscustomobject]@{ status=$report.status; evidence=$reportPath; export=$script:ExportRoot } | ConvertTo-Json -Compress
}
if ($report.status -eq 'FAIL') { exit 1 }
