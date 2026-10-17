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
    [ValidateSet('inspect','tokens','accounts','enable-uac','gl','broker-host','broker-peer','direct-target','drop-source','install','upgrade','seed-foreign-before','expect-install-refused','seed-foreign-after','uninstall','check-preserved','cleanup-foreign')]
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
    [ValidateRange(15,120)][int]$CloseWaitSeconds = 15,
    [ValidateSet('text','multiline','files')][string]$DropCase = 'text',
    [string]$OleSourceSha256,
    [ValidateRange(1000,30000)][int]$DropTimeoutMs = 30000,
    [switch]$AutoDrag,
    [ValidateSet('broker','medium-medium','high-medium','high-high')][string]$DropDirection = 'broker',
    [ValidateSet('medium','high')][string]$TargetIntegrity = 'medium',
    [ValidateRange(0,2147483647)][int]$TargetPid = 0,
    [ValidateRange(0,9223372036854775807)][long]$TargetBirth = 0,
    [ValidatePattern('^(0x[0-9a-fA-F]{1,16})?$')][string]$TargetWindow = '',
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
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);

    public static string[] Arguments(string command) {
        if (String.IsNullOrEmpty(command)) return new string[0];
        int count;
        IntPtr memory = CommandLineToArgvW(command, out count);
        if (memory == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            string[] result = new string[count];
            for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
            return result;
        } finally { LocalFree(memory); }
    }
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

# Window facts and explicitly requested fixture input. GetWindowText does not
# send messages across processes; WM_NULL uses SMTO_ABORTIFHUNG and a bound.
$script:WindowSource = @'
using System;
using System.Collections;
using System.Runtime.InteropServices;
using System.Text;
public static class GxVmWindows {
    delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lparam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hwnd, EnumProc proc, IntPtr lparam);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll", SetLastError = true)] static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mouse; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION value; }
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder image, ref uint size);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

    sealed class ProcessLease : IDisposable {
        public IntPtr Handle;
        public ProcessLease(uint pid, long birth, string exe) {
            Handle = OpenProcess(0x101000, false, pid); // SYNCHRONIZE | QUERY_LIMITED_INFORMATION
            if (Handle == IntPtr.Zero) throw new Exception("OpenProcess failed: " + Marshal.GetLastWin32Error());
            try {
                long created, exited, kernel, user;
                uint length = 32768;
                StringBuilder image = new StringBuilder((int)length);
                if (!GetProcessTimes(Handle, out created, out exited, out kernel, out user) || created != birth ||
                    !QueryFullProcessImageName(Handle, 0, image, ref length) ||
                    !String.Equals(image.ToString(), exe, StringComparison.OrdinalIgnoreCase)) throw new Exception("Process identity mismatch");
                Alive();
            } catch { Dispose(); throw; }
        }
        public void Alive() { if (WaitForSingleObject(Handle, 0) != 258) throw new Exception("Owned process exited"); }
        public void Dispose() { if (Handle != IntPtr.Zero) { CloseHandle(Handle); Handle = IntPtr.Zero; } }
    }

    static void RequireWindow(IntPtr hwnd, uint pid, string cls) {
        uint actual;
        StringBuilder name = new StringBuilder(128);
        GetClassNameW(hwnd, name, name.Capacity);
        if (GetWindowThreadProcessId(hwnd, out actual) == 0 || actual != pid || name.ToString() != cls ||
            !IsWindowVisible(hwnd) || !IsWindowEnabled(hwnd) || IsIconic(hwnd)) throw new Exception("Window ownership or visibility mismatch");
    }
    public static ArrayList Terminals(IntPtr parent, uint pid) {
        RequireWindow(parent, pid, "GhosttyWindow");
        ArrayList list = new ArrayList();
        EnumChildWindows(parent, delegate (IntPtr hwnd, IntPtr unused) {
            Hashtable item = Describe(hwnd);
            if (!(bool)item["exists"]) return true;
            if ((long)item["pid"] == pid && (string)item["class"] == "GhosttyTerminal" &&
                (bool)item["visible"] && (bool)item["enabled"] && GetAncestor(hwnd, 2) == parent) list.Add(item);
            return true;
        }, IntPtr.Zero);
        return list;
    }
    static RECT ClientRect(IntPtr hwnd) {
        RECT rect; POINT origin = new POINT(0, 0);
        if (!GetClientRect(hwnd, out rect) || !ClientToScreen(hwnd, ref origin)) throw new Exception("Client rectangle unavailable");
        rect.Left += origin.X; rect.Right += origin.X; rect.Top += origin.Y; rect.Bottom += origin.Y;
        return rect;
    }
    static void MoveCursor(POINT point) {
        POINT actual;
        if (!SetCursorPos(point.X, point.Y) || !GetCursorPos(out actual) || actual.X != point.X || actual.Y != point.Y)
            throw new Exception("Cursor position was not observed at the requested point");
    }
    static void MouseButton(uint flags) {
        INPUT[] input = new INPUT[1]; input[0].value.mouse.flags = flags;
        if (SendInput(1, input, Marshal.SizeOf(typeof(INPUT))) != 1) throw new Exception("SendInput failed: " + Marshal.GetLastWin32Error());
    }
    public static void ReleaseAfterSourceExit(IntPtr sourceProcess) {
        if (WaitForSingleObject(sourceProcess, 0) != 0) throw new Exception("Cannot release without proven source exit");
        MouseButton(4);
    }

    // The caller has verified hashes, source lineage and the real split-token pair.
    // Retained process handles bind all mouse input to those exact process lives.
    public static Hashtable DragOwned(uint sourcePid, long sourceBirth, string sourceExe, IntPtr sourceWindow,
        uint receiverPid, long receiverBirth, string appExe, IntPtr receiverWindow, uint hostPid, long hostBirth) {
        return DragCore(sourcePid, sourceBirth, sourceExe, sourceWindow, receiverPid, receiverBirth, appExe,
            receiverWindow, hostPid, hostBirth, "GhosttyDropCompanion", IntPtr.Zero);
    }
    public static Hashtable DragDirect(uint sourcePid, long sourceBirth, string sourceExe, IntPtr sourceWindow,
        uint targetPid, long targetBirth, string appExe, IntPtr terminalWindow, IntPtr mainWindow) {
        return DragCore(sourcePid, sourceBirth, sourceExe, sourceWindow, targetPid, targetBirth, appExe,
            terminalWindow, targetPid, targetBirth, "GhosttyTerminal", mainWindow);
    }
    static Hashtable DragCore(uint sourcePid, long sourceBirth, string sourceExe, IntPtr sourceWindow,
        uint receiverPid, long receiverBirth, string appExe, IntPtr receiverWindow, uint hostPid, long hostBirth,
        string receiverClass, IntPtr mainWindow) {
        Hashtable result = new Hashtable(); result["status"] = "FAIL";
        result["clipboard_access"] = false; result["enter_injected"] = false;
        bool down = false;
        POINT start = new POINT(), end = new POINT(); bool haveEnd = false;
        IntPtr previousDpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            using (ProcessLease source = new ProcessLease(sourcePid, sourceBirth, sourceExe))
            using (ProcessLease receiver = new ProcessLease(receiverPid, receiverBirth, appExe))
            using (ProcessLease host = new ProcessLease(hostPid, hostBirth, appExe)) {
                Action guard = delegate {
                    source.Alive(); receiver.Alive(); host.Alive();
                    RequireWindow(sourceWindow, sourcePid, "GxOwnedOleDragSource");
                    RequireWindow(receiverWindow, receiverPid, receiverClass);
                    if (mainWindow != IntPtr.Zero) {
                        RequireWindow(mainWindow, receiverPid, "GhosttyWindow");
                        if (GetAncestor(receiverWindow, 2) != mainWindow) throw new Exception("Terminal was reparented");
                    }
                };
                try {
                    guard();
                    if (previousDpi == IntPtr.Zero) throw new Exception("DPI context unavailable");
                    RECT sourceOuter;
                    if (!GetWindowRect(sourceWindow, out sourceOuter)) throw new Exception("Source rectangle unavailable");
                    // Move only this source, leaving the receiver's client exposed.
                    int x = GetSystemMetrics(76) + 20;
                    int y = GetSystemMetrics(77) + GetSystemMetrics(79) - (sourceOuter.Bottom - sourceOuter.Top) - 80;
                    if (!SetWindowPos(sourceWindow, IntPtr.Zero, x, y, 0, 0, 0x41)) throw new Exception("Source placement failed");
                    SetForegroundWindow(sourceWindow);
                    System.Threading.Thread.Sleep(100);
                    guard();
                    if (GetForegroundWindow() != sourceWindow) throw new Exception("Source foreground not established");
                    RECT s = ClientRect(sourceWindow), r = ClientRect(receiverWindow);
                    start = new POINT((s.Left + s.Right) / 2, (s.Top + s.Bottom) / 2);
                    if (WindowFromPoint(start) != sourceWindow) throw new Exception("Source point is occluded");
                    foreach (int ey in new int[] { r.Top + 30, r.Bottom - 30 }) {
                        foreach (int ex in new int[] { r.Right - 30, r.Left + 30 }) {
                            POINT candidate = new POINT(ex, ey);
                            if (ex > r.Left && ex < r.Right && ey > r.Top && ey < r.Bottom && WindowFromPoint(candidate) == receiverWindow) {
                                end = candidate; haveEnd = true; break;
                            }
                        }
                        if (haveEnd) break;
                    }
                    if (!haveEnd) throw new Exception("No exposed receiver point");
                    result["source_point"] = new int[] { start.X, start.Y };
                    result["receiver_point"] = new int[] { end.X, end.Y };
                    result["source_window"] = Describe(sourceWindow); result["receiver_window"] = Describe(receiverWindow);
                    guard(); MoveCursor(start); MouseButton(2); down = true;
                    for (int step = 1; step <= 20; step++) {
                        guard(); MoveCursor(new POINT(start.X + (end.X - start.X) * step / 20, start.Y + (end.Y - start.Y) * step / 20));
                        System.Threading.Thread.Sleep(30);
                    }
                    guard();
                    if (WindowFromPoint(end) != receiverWindow) throw new Exception("Receiver point became occluded");
                    MouseButton(4); down = false;
                    result["status"] = "REAL_DRAG_SENT";
                } finally {
                    if (down) {
                        // Never emit mouse-up unless this invocation emitted mouse-down.
                        // The pinned source's WM_CLOSE sets cancelled before returning.
                        // Acknowledging it before mouse-up prevents an accidental drop.
                        try {
                            if (WaitForSingleObject(source.Handle, 0) != 0) {
                                RequireWindow(sourceWindow, sourcePid, "GxOwnedOleDragSource");
                                IntPtr unused;
                                if (SendMessageTimeoutW(sourceWindow, 0x0010, IntPtr.Zero, IntPtr.Zero, 2, 1000, out unused) == IntPtr.Zero)
                                    throw new Exception("Source cancellation was not acknowledged");
                            }
                            MouseButton(4); down = false;
                            result["cleanup"] = "released owned mouse-down after source cancellation or exit";
                        } catch (Exception error) { result["cleanup"] = "BLOCKED: " + error.Message; }
                    }
                }
            }
        } catch (Exception error) { result["error"] = error.Message; }
        finally { if (previousDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(previousDpi); }
        result["mouse_down_unreleased"] = down;
        return result;
    }

    public static string Hex(IntPtr hwnd) { return "0x" + hwnd.ToInt64().ToString("x"); }

    public static Hashtable Describe(IntPtr hwnd) {
        Hashtable facts = new Hashtable();
        facts["hwnd"] = Hex(hwnd);
        bool alive = hwnd != IntPtr.Zero && IsWindow(hwnd);
        facts["exists"] = alive;
        if (!alive) return facts;
        uint pid;
        facts["thread"] = (long)GetWindowThreadProcessId(hwnd, out pid);
        facts["pid"] = (long)pid;
        StringBuilder text = new StringBuilder(512);
        GetClassNameW(hwnd, text, text.Capacity);
        facts["class"] = text.ToString();
        text.Length = 0;
        GetWindowTextW(hwnd, text, text.Capacity);
        facts["title"] = text.ToString();
        facts["visible"] = IsWindowVisible(hwnd);
        facts["enabled"] = IsWindowEnabled(hwnd);
        facts["iconic"] = IsIconic(hwnd);
        facts["owner"] = Hex(GetWindow(hwnd, 4));
        facts["style"] = "0x" + GetWindowLongPtr(hwnd, -16).ToInt64().ToString("x");
        facts["ex_style"] = "0x" + GetWindowLongPtr(hwnd, -20).ToInt64().ToString("x");
        RECT rect;
        if (GetWindowRect(hwnd, out rect)) facts["rect"] = new int[] { rect.Left, rect.Top, rect.Right, rect.Bottom };
        int cloaked;
        facts["cloaked"] = DwmGetWindowAttribute(hwnd, 14, out cloaked, 4) == 0 ? (object)cloaked : null;
        return facts;
    }

    public static ArrayList TopLevel(int pid) {
        ArrayList list = new ArrayList();
        EnumWindows(delegate (IntPtr hwnd, IntPtr unused) {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner == (uint)pid) list.Add(Describe(hwnd));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // WM_NULL with SMTO_ABORTIFHUNG: whether the window's thread still pumps messages.
    public static Hashtable Responds(IntPtr hwnd, uint ms) {
        Hashtable facts = new Hashtable();
        facts["hwnd"] = Hex(hwnd);
        facts["timeout_ms"] = (long)ms;
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) { facts["responds"] = null; facts["note"] = "no window"; return facts; }
        IntPtr unused;
        bool ok = SendMessageTimeoutW(hwnd, 0, IntPtr.Zero, IntPtr.Zero, 2, ms, out unused) != IntPtr.Zero;
        facts["responds"] = ok;
        facts["error"] = ok ? 0 : Marshal.GetLastWin32Error();
        return facts;
    }

    public static Hashtable PostClose(IntPtr hwnd) {
        Hashtable facts = new Hashtable();
        facts["hwnd"] = Hex(hwnd);
        bool ok = PostMessageW(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero);
        facts["posted"] = ok;
        facts["error"] = ok ? 0 : Marshal.GetLastWin32Error();
        return facts;
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

function Get-WindowSnapshot([int]$ProcessId, [IntPtr]$Main, [string]$Label) {
    if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }
    $top = @([GxVmWindows]::TopLevel($ProcessId))
    $ghostty = @($top | Where-Object { $_['class'] -ceq 'GhosttyWindow' })
    $responds = @($ghostty | ForEach-Object { [GxVmWindows]::Responds([IntPtr][Convert]::ToInt64($_['hwnd'].Substring(2), 16), 2000) })
    return [ordered]@{ label=$Label; utc=[DateTime]::UtcNow.ToString('o'); main=[GxVmWindows]::Describe($Main);
        main_is_ghostty_window=(@($ghostty | Where-Object { $_['hwnd'] -eq [GxVmWindows]::Hex($Main) }).Count -eq 1);
        ghostty_windows=$ghostty; ghostty_wm_null=$responds; top_level=$top }
}

function Get-ProcessScene([Diagnostics.Process]$Process) {
    $Process.Refresh()
    $threads = @($Process.Threads | Group-Object { if ($_.ThreadState -eq 'Wait') { 'Wait/' + $_.WaitReason } else { [string]$_.ThreadState } } |
        ForEach-Object { [ordered]@{ state=$_.Name; count=$_.Count } })
    $children = @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $Process.Id) |
        ForEach-Object { [ordered]@{ pid=[int]$_.ProcessId; name=$_.Name; created=$_.CreationDate.ToUniversalTime().ToString('o') } })
    return [ordered]@{ utc=[DateTime]::UtcNow.ToString('o'); exited=$Process.HasExited; threads=$threads; children=$children }
}

function Assert-DirectTokenPair($Source, $Target, [string]$Direction) {
    if ($Direction -notin @('medium-medium','high-medium','high-high')) { throw 'Unsupported direct direction.' }
    $levels = $Direction.Split('-')
    foreach ($entry in @(@{ facts=$Source; level=$levels[0] }, @{ facts=$Target; level=$levels[1] })) {
        $facts = $entry.facts
        $high = $entry.level -eq 'high'
        $kind = if ($high) { 'Full' } else { 'Limited' }
        if ($facts.integrity -cne $entry.level -or [bool]$facts.elevated -ne $high -or $facts.elevation_type -cne $kind) {
            throw 'Direct source/target token does not match the explicit direction.'
        }
    }
    if ($Source.sid -ne $Target.sid -or $Source.session_id -ne $Target.session_id) { throw 'Direct participants differ in user or session.' }
    if ($levels[0] -eq $levels[1]) {
        if ($Source.logon_id -eq 0 -or $Source.logon_id -ne $Target.logon_id) { throw 'Same-integrity direct participants must share one logon.' }
    } else {
        $pair = Compare-SplitTokens $Target $Source
        if (-not $pair.paired) { throw ('Direct participants are not linked split tokens: ' + ($pair.failures -join '; ')) }
    }
}

function Get-DirectTarget {
    if ($TargetPid -le 0 -or $TargetBirth -le 0 -or -not $TargetWindow) {
        throw 'Direct drop requires -TargetPid, -TargetBirth and -TargetWindow (the recorded main HWND).'
    }
    $app = Resolve-GlApp
    if ($app.class -cne 'INSTALLED') { throw 'Direct permission cases require the installed, hash-verified application.' }
    $process = Get-Process -Id $TargetPid -ErrorAction Stop
    try {
        if ($process.StartTime.ToFileTimeUtc() -ne $TargetBirth -or $process.Path -ine $app.exe) { throw 'Direct target PID/birth/image mismatch.' }
        $self = Get-TokenFacts $PID
        $targetToken = Get-TokenFacts $TargetPid
        Assert-DirectTokenPair $self $targetToken $DropDirection
        if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }
        $main = [IntPtr][Convert]::ToInt64($TargetWindow.Substring(2), 16)
        $terminals = @([GxVmWindows]::Terminals($main, [uint32]$TargetPid))
        if ($terminals.Count -ne 1) { throw 'Direct target must have exactly one visible, enabled terminal child; no implicit pane selection.' }
        return [ordered]@{ pid=$TargetPid; birth_filetime=$TargetBirth; exe=$app.exe; app_sha256=$AppSha256;
            main_window=([GxVmWindows]::Describe($main)); terminal_window=$terminals[0]; token=$targetToken; source_console_token=$self }
    } finally { $process.Dispose() }
}

function Start-DropSource {
    # Broker is the original medium-only route. Direct cases explicitly name
    # their integrity direction and installed target; neither route elevates.
    # Start the pinned OLE source in --source-window mode, not a private drop API.
    # Default: the host drives the real drag. -AutoDrag explicitly requests
    # same-guest native mouse input after process/window validation; never Enter.
    if ($OleSourceSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'drop-source requires -OleSourceSha256.' }
    if (-not $ExportDir) { throw 'drop-source runs through gx-run.cmd so the staged tool and export folder are known.' }
    $peer = $null; $direct = $null
    if ($DropDirection -eq 'broker') {
        $peer = Find-BrokerPeer
        $receiverPid = [int]$peer.receiver.pid
        $receiverExe = $peer.receiver.exe
    } else {
        $direct = Get-DirectTarget
        $receiverPid = [int]$direct.pid
        $receiverExe = $direct.exe
    }
    $receiverProcess = Get-Process -Id $receiverPid
    $receiverBirth = $receiverProcess.StartTime.ToFileTimeUtc()
    $receiverHwnd = if ($direct) { [IntPtr][Convert]::ToInt64($direct.terminal_window.hwnd.Substring(2), 16) } else { $receiverProcess.MainWindowHandle }
    if ($direct -and $receiverBirth -ne $TargetBirth) { throw 'Direct target changed before source launch.' }
    if ($receiverHwnd -eq [IntPtr]::Zero) { throw 'The drop receiver has no visible window.' }
    $toolShare = Join-Path (Split-Path -Parent $ExportDir) 'tools\gx_ole_source_window.exe'
    $toolDir = Join-Path $script:RunRoot ($script:Step + '-ole')
    [IO.Directory]::CreateDirectory($toolDir) | Out-Null
    $tool = Join-Path $toolDir 'gx_ole_source_window.exe'
    Copy-Item -LiteralPath $toolShare -Destination $tool
    Assert-Hash $tool $OleSourceSha256
    $work = Join-Path $toolDir 'work'
    [IO.Directory]::CreateDirectory($work) | Out-Null
    if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }
    $arguments = @('--run', '--source-window', ('--hwnd=0x{0:x}' -f $receiverHwnd.ToInt64()), "--pid=$receiverPid", "--birth=$receiverBirth",
        ('--exe="' + $receiverExe + '"'), ('--sha256=' + $AppSha256.ToLowerInvariant()), ('--work-dir="' + $work + '"'),
        "--case=$DropCase", "--timeout-ms=$DropTimeoutMs")
    $start = [Diagnostics.ProcessStartInfo]::new($tool, ($arguments -join ' '))
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $toolDir
    $source = [Diagnostics.Process]::Start($start)
    $null = $source.Handle
    $result = [ordered]@{ peer=$peer; direct_target=$direct; direction=$DropDirection; source_token=$null;
        receiver_birth_filetime=$receiverBirth; tool_sha256=$OleSourceSha256.ToLowerInvariant();
        source_pid=$source.Id; source_birth_filetime=$source.StartTime.ToFileTimeUtc(); case=$DropCase;
        timeout_ms=$DropTimeoutMs; ready=$null; auto_drag_requested=[bool]$AutoDrag; auto_drag=$null; exit_code=$null; evidence=$null }
    try {
        if ($direct) {
            $result.source_token = Get-TokenFacts $source.Id
            Assert-DirectTokenPair $result.source_token $direct.token $DropDirection
            if ($result.source_token.logon_id -ne $direct.source_console_token.logon_id) { throw 'Source did not inherit the selected console logon.' }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        $readyFile = $null
        while (-not $readyFile -and [DateTime]::UtcNow -lt $deadline -and -not $source.HasExited) {
            $readyFile = Get-ChildItem -LiteralPath $work -Recurse -Filter 'ready.json' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $readyFile) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $readyFile) { throw "OLE source did not become ready (exited=$($source.HasExited))." }
        $ready = Get-Content -LiteralPath $readyFile.FullName -Raw | ConvertFrom-Json
        if (($AutoDrag -or $direct) -and ($ready.source_pid -ne $source.Id -or $ready.target_pid -ne $receiverPid -or
            [long]$ready.target_birth -ne $receiverBirth -or [long]$ready.target_hwnd -ne $receiverHwnd.ToInt64() -or
            $ready.app_sha256 -ine $AppSha256 -or $ready.case -cne $DropCase)) { throw 'OLE source ready identity mismatch.' }
        $result.ready = $ready
        $sourceWindow = [GxVmWindows]::Describe([IntPtr][int64]$ready.source_hwnd)
        $receiverWindow = [GxVmWindows]::Describe($receiverHwnd)
        $result.source_window = $sourceWindow
        $result.receiver_window = $receiverWindow
        $s = $sourceWindow['rect']; $r = $receiverWindow['rect']
        # Drag from the source's client middle to the receiver's lower-right area, clear of the source window.
        $result.drag = [ordered]@{ x=[int](($s[0] + $s[2]) / 2); y=[int](($s[1] + $s[3]) / 2) + 12;
            to_x=[int]($r[0] + ($r[2] - $r[0]) * 0.65); to_y=[int]($r[1] + ($r[3] - $r[1]) * 0.65) }
        Write-Json (Join-Path $script:ExportRoot ($script:ExportPrefix + $script:Step + '-drop-ready.json')) $result
        if ($AutoDrag) {
            # All participants are freshly verified by their selected route.
            # The source is the exact child we launched, with a pinned image.
            Assert-Hash $tool $OleSourceSha256
            Assert-Hash $receiverExe $AppSha256
            if ($direct) {
                $main = [IntPtr][Convert]::ToInt64($direct.main_window.hwnd.Substring(2), 16)
                $result.auto_drag = [GxVmWindows]::DragDirect([uint32]$source.Id, $source.StartTime.ToFileTimeUtc(), $tool,
                    [IntPtr][long]$ready.source_hwnd, [uint32]$receiverPid, $receiverBirth, $receiverExe, $receiverHwnd, $main)
            } else {
                $result.auto_drag = [GxVmWindows]::DragOwned([uint32]$source.Id, $source.StartTime.ToFileTimeUtc(), $tool,
                    [IntPtr][long]$ready.source_hwnd, [uint32]$receiverPid, $receiverBirth, $receiverExe,
                    $receiverHwnd, [uint32]$peer.host.pid, [long]$peer.host.birth_filetime)
            }
            if ($result.auto_drag['status'] -cne 'REAL_DRAG_SENT') { throw ('Automatic owned drag failed: ' + $result.auto_drag['error']) }
            Write-Json (Join-Path $script:ExportRoot ($script:ExportPrefix + $script:Step + '-auto-drag.json')) $result.auto_drag
        }
        $closed = $source.WaitForExit($DropTimeoutMs + 15000)
        if (-not $closed) { $source.Kill(); $null = $source.WaitForExit(5000); throw 'OLE source did not finish within its deadline.' }
        $result.exit_code = $source.ExitCode
        $evidence = Get-ChildItem -LiteralPath $work -Recurse -File | Where-Object { $_.Name -in 'evidence.json','result.json','trace.jsonl' }
        foreach ($item in $evidence) { $script:ExportExtra.Add($item.FullName) }
        $finished = $evidence | Where-Object { $_.Name -ne 'trace.jsonl' } | Select-Object -First 1
        if ($finished) { $result.evidence = Get-Content -LiteralPath $finished.FullName -Raw | ConvertFrom-Json }
        $result.meaning = @{ 0='COPY accepted (OLE admission only; inspect the elevated preview)'; 3='cancelled'; 4='drop rejected/NONE'; 2='invalid invocation/identity/error' }[[int]$source.ExitCode]
        if ($source.ExitCode -ne 0) { throw ('OLE source exited ' + $source.ExitCode + ': ' + $result.meaning) }
        if ($direct) {
            $result.meaning = 'COPY accepted (OLE admission only; inspect the target terminal and any protection dialog)'
            if (-not $result.evidence -or $result.evidence.effect -ne 1 -or $result.evidence.get_data -lt 1 -or
                $result.evidence.get_data -ne $result.evidence.medium_releases) { throw 'Direct OLE data acquisition/release evidence did not pass.' }
        }
    } finally {
        if (-not $source.HasExited) { $source.Kill(); $null = $source.WaitForExit(5000) }
        if ($result.auto_drag -and $result.auto_drag['mouse_down_unreleased']) {
            try {
                [GxVmWindows]::ReleaseAfterSourceExit($source.Handle)
                $result.auto_drag['mouse_down_unreleased'] = $false
                $result.auto_drag['cleanup'] = 'released owned mouse-down after verified source process exit'
            } catch { $result.auto_drag['cleanup'] = 'BLOCKED: ' + $_.Exception.Message }
        }
        $source.Dispose()
        if ($result.auto_drag) {
            # Cleanup must finish before any potentially blocking share export.
            Write-Json (Join-Path $toolDir 'auto-drag.json') $result.auto_drag
            $script:ExportExtra.Add((Join-Path $toolDir 'auto-drag.json'))
        }
        Write-Json (Join-Path $toolDir 'drop-source.json') $result
        $script:ExportExtra.Add((Join-Path $toolDir 'drop-source.json'))
    }
    return $result
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
    # Compile the window helper before the launch so the close evidence adds no
    # delay between the observed window and CloseMainWindow (hold 0 timing).
    if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    $pidOwned = $process.Id
    $birth = $process.StartTime.ToUniversalTime().ToString('o')
    $log = Join-Path $private 'ghostty\logs\ghostty.log'
    $script:ExportExtra.Add($log)
    $renderer = $null
    $closed = $false
    $held = 0
    $outcome = $null
    # Close evidence is always exported, also when the close fails and the
    # finally block replaces the result with the shutdown failure.
    $closePath = Join-Path $script:RunRoot ($script:Step + '-gl-close.json')
    $script:ExportExtra.Add($closePath)
    $close = [ordered]@{ pid=$pidOwned; birth=$birth; birth_filetime=$process.StartTime.ToFileTimeUtc(); hold_seconds=$HoldSeconds;
        close_wait_seconds=$CloseWaitSeconds; probe_error=$null; probe_outcome=$null }
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
        $close.renderer_seen_utc = [DateTime]::UtcNow.ToString('o')
        $windowDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do { $process.Refresh(); if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $windowDeadline)
        if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Renderer started without an observable application window.' }
        $close.window_seen_utc = [DateTime]::UtcNow.ToString('o')
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
        $outcome = @{ status=$(if ($app.class -eq 'INSTALLED') { 'PASS_NATIVE_GL_ONLY' } else { 'REHEARSAL_NATIVE_GL_ONLY_NOT_FINAL' });
                  app_class=$app.class; pid=$pidOwned; birth=$birth; app_sha256=$AppSha256; exe=$exe; window_title=$title;
                  renderer=$renderer; software_renderer=$software; held_seconds=$held; log=$log;
                  visual_review='PENDING'; software_requested=[bool]$SoftwareGL }
    } catch {
        $close.probe_error = $_.Exception.Message
        throw
    } finally {
        $close.probe_outcome = $outcome
        if (-not $process.HasExited) {
            # CloseMainWindow targets the handle cached by the window wait above
            # (no Refresh here), exactly as before; record which window that is.
            $main = $process.MainWindowHandle
            $close.before = Get-WindowSnapshot $pidOwned $main 'before-close'
            $close.close_main_window_utc = [DateTime]::UtcNow.ToString('o')
            $close.close_main_window = $process.CloseMainWindow()
            if ($ExportDir -and $script:ExportRoot) {
                Write-Json (Join-Path $script:ExportRoot ($script:ExportPrefix + $script:Step + '-gl-closing.json')) @{ pid=$pidOwned;
                    utc=$close.close_main_window_utc; close_main_window=$close.close_main_window; wait_seconds=$CloseWaitSeconds }
            }
            $closed = $process.WaitForExit(1000)
            $close.children_after_1s = @()
            if (-not $closed) {
                $close.after_1s = Get-WindowSnapshot $pidOwned $main 'after-1s'
                $close.children_after_1s = @((Get-ProcessScene $process).children)
                $closed = $process.WaitForExit($CloseWaitSeconds * 1000 - 1000)
            }
            if (-not $closed) {
                $close.before_kill = Get-WindowSnapshot $pidOwned $main 'before-kill'
                $close.scene = Get-ProcessScene $process
                # Diagnostic only, never a pass: when CloseMainWindow did not reach a
                # GhosttyWindow, post WM_CLOSE to the top-level GhosttyWindow itself.
                if (-not $close.close_main_window -or -not $close.before.main_is_ghostty_window) {
                    $close.followup = @($close.before_kill.ghostty_windows | ForEach-Object {
                        [GxVmWindows]::PostClose([IntPtr][Convert]::ToInt64($_['hwnd'].Substring(2), 16)) })
                    $close.followup_exited = $process.WaitForExit(15000)
                    if (-not $close.followup_exited) { $close.after_followup = Get-WindowSnapshot $pidOwned $main 'after-followup' }
                }
                if (-not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(5000) }
                $close.killed = $true
            }
        } else { $closed = $true }
        $exitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
        $close.exit_code = $exitCode
        $close.exit_code_hex = if ($null -ne $exitCode) { '0x{0:X8}' -f $exitCode } else { $null }
        $close.exit_utc = if ($process.HasExited) { $process.ExitTime.ToUniversalTime().ToString('o') } else { $null }
        # Direct children started by this app that outlived it (ParentProcessId
        # stays recorded after the parent exits; creation time rules out reuse).
        $close.orphans_after_exit = if ($process.HasExited) {
            $bornUtc = $process.StartTime.ToUniversalTime()
            @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $pidOwned) |
                Where-Object { $_.CreationDate.ToUniversalTime() -ge $bornUtc } |
                ForEach-Object { [ordered]@{ pid=[int]$_.ProcessId; name=$_.Name; created=$_.CreationDate.ToUniversalTime().ToString('o') } })
        } else { $null }
        $close.closed_normally = $closed -and $exitCode -eq 0
        if ($closed -and $exitCode -ne 0) {
            # A crash during shutdown: keep the Windows Error Reporting facts.
            $since = $process.StartTime.AddSeconds(-1)
            $close.application_errors = @(Get-WinEvent -FilterHashtable @{ LogName='Application'; Id=@(1000,1001); StartTime=$since } -MaxEvents 20 -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match 'ghostty\.exe' } |
                ForEach-Object { [ordered]@{ id=$_.Id; provider=$_.ProviderName; utc=$_.TimeCreated.ToUniversalTime().ToString('o'); message=$_.Message } })
        }
        $process.Dispose()
        Write-Json $closePath $close
        if (-not $closed) { throw 'Owned GL probe required termination; normal shutdown did not pass.' }
        if ($exitCode -ne 0) { throw ('Owned GL probe exited with ' + $close.exit_code_hex + ' after the close request; normal shutdown did not pass.') }
    }
    return $outcome
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

function Start-IsolatedApp([string]$Exe, [string]$Private, [string[]]$ConfigLines) {
    $config = Join-Path $Private 'ghostty\config.ghostty'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($config)) | Out-Null
    [IO.File]::WriteAllText($config, (($ConfigLines -join $script:LF) + $script:LF), [Text.UTF8Encoding]::new($false))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Exe
    $start.Arguments = '--gx-single-instance=false'
    $start.WorkingDirectory = $Private
    $start.UseShellExecute = $false
    foreach ($key in @($start.EnvironmentVariables.Keys)) {
        if ($key -match '^(?i:GHOSTTY_|XDG_)' -or $key -in @('NO_COLOR','TERM','LOCALAPPDATA','APPDATA')) { $start.EnvironmentVariables.Remove($key) }
    }
    $start.EnvironmentVariables['LOCALAPPDATA'] = $Private
    $start.EnvironmentVariables['APPDATA'] = Join-Path $Private 'appdata'
    $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $Private
    $start.EnvironmentVariables['XDG_STATE_HOME'] = Join-Path $Private 'state'
    $start.EnvironmentVariables['XDG_CACHE_HOME'] = Join-Path $Private 'cache'
    return [Diagnostics.Process]::Start($start)
}

function Start-DirectTarget {
    # Launch under the caller's existing token. Repeated calls get distinct
    # profiles and ownership records, never overwrite an earlier target record.
    $self = Get-TokenFacts $PID
    Assert-DirectTokenPair $self $self ($TargetIntegrity + '-' + $TargetIntegrity)
    $app = Resolve-GlApp
    if ($app.class -cne 'INSTALLED') { throw 'Direct targets require the installed, hash-verified application.' }
    $private = Join-Path $script:RunRoot ($script:Step + '-direct-profile')
    Assert-NoReparse $private
    if (Test-Path -LiteralPath $private) { throw 'Direct target profile already exists.' }
    if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }
    $prompt = 'command = cmd.exe /d /k prompt GX_DIRECT_' + $TargetIntegrity.ToUpperInvariant() + '$G$S'
    $process = Start-IsolatedApp $app.exe $private @('language = en', 'confirm-close-surface = false', 'gx-session-restore = false',
        'clipboard-paste-protection = true', $prompt)
    $null = $process.Handle
    $record = Join-Path $script:RunRoot ($script:Step + '-direct-target.json')
    $facts = [ordered]@{ status='STARTING'; pid=$process.Id; birth_filetime=$process.StartTime.ToFileTimeUtc();
        exe=$app.exe; app_sha256=$AppSha256; integrity=$TargetIntegrity; profile=$private;
        log=(Join-Path $private 'ghostty\logs\ghostty.log'); token=$null; main_window=$null; terminal_window=$null }
    Write-Json $record $facts
    $script:ExportExtra.Add($record)
    try {
        $facts.token = Get-TokenFacts $process.Id
        Assert-DirectTokenPair $self $facts.token ($TargetIntegrity + '-' + $TargetIntegrity)
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        do {
            $process.Refresh()
            if ($process.HasExited) { throw "Direct target exited $($process.ExitCode) during startup." }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                $terminals = @([GxVmWindows]::Terminals($process.MainWindowHandle, [uint32]$process.Id))
                if ($terminals.Count -gt 1) { throw 'Unexpected multiple terminal children in the isolated target.' }
                if ($terminals.Count -eq 1) {
                    $facts.main_window = [GxVmWindows]::Describe($process.MainWindowHandle)
                    $facts.terminal_window = $terminals[0]
                    $facts.status = 'TARGET_READY'
                    return $facts
                }
            }
            Start-Sleep -Milliseconds 100
        } while ($deadline.Elapsed.TotalSeconds -lt 45)
        throw 'Direct target showed no terminal child within 45 seconds.'
    } finally {
        # A startup failure still preserves the exact process/profile to inspect;
        # targets are only closed by the subsequent explicitly owned GUI steps.
        Write-Json $record $facts
        $process.Dispose()
    }
}

function Start-BrokerHost {
    # Elevated, isolated candidate terminal that stays running for the manual
    # menu/drop steps. Only -Rehearsal payloads are accepted before the final package.
    if (-not (Test-Elevated)) { throw 'broker-host must run in the elevated (high) console of the split-token user.' }
    $app = Resolve-GlApp
    $private = Join-Path $script:RunRoot ($script:Step + '-broker-profile')
    $process = Start-IsolatedApp $app.exe $private @('language = en', 'confirm-close-surface = false', 'gx-session-restore = false',
        'clipboard-paste-protection = true', 'command = cmd.exe /d /k prompt GX_BROKER_HIGH$G$S')
    $null = $process.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do { $process.Refresh(); if ($process.HasExited) { throw "Broker host exited $($process.ExitCode) during startup." }
         if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 200 } while ([DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Broker host showed no window within 45 seconds.' }
    $host_record = [ordered]@{ pid=$process.Id; birth_filetime=$process.StartTime.ToFileTimeUtc(); birth=$process.StartTime.ToUniversalTime().ToString('o');
        exe=$app.exe; app_class=$app.class; app_sha256=$AppSha256; hwnd=('0x{0:x}' -f $process.MainWindowHandle.ToInt64());
        token=(Get-TokenFacts $process.Id); log=(Join-Path $private 'ghostty\logs\ghostty.log') }
    $record = Join-Path $script:RunRoot 'broker-host.json'
    Write-Json $record $host_record
    $script:ExportExtra.Add($record)
    $process.Dispose()
    return $host_record
}

function Find-BrokerPeer {
    if (Test-Elevated) { throw 'broker-peer must run in the normal (medium) console.' }
    $hostPath = Join-Path $script:RunRoot 'broker-host.json'
    $hostRecord = Get-Content -LiteralPath $hostPath -Raw | ConvertFrom-Json
    $hostProcess = Get-Process -Id $hostRecord.pid -ErrorAction Stop
    if ($hostProcess.StartTime.ToFileTimeUtc() -ne [int64]$hostRecord.birth_filetime) { throw 'Broker host PID was reused.' }
    $hostFacts = Get-TokenFacts $hostRecord.pid
    $self = Get-TokenFacts $PID
    $expectedPid = '--gx-drop-target-pid=' + $hostRecord.pid
    $expectedBirth = '--gx-drop-target-birth=' + $hostRecord.birth_filetime
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name = 'ghostty.exe'" | Where-Object {
        $arguments = [GxVmToken]::Arguments($_.CommandLine)
        $arguments -ccontains '--gx-shell-action=drop-companion' -and $arguments -ccontains $expectedPid })
    if ($candidates.Count -ne 1) { throw "Expected exactly one drop receiver for host $($hostRecord.pid), found $($candidates.Count)." }
    $peer = $candidates[0]
    if ($peer.ExecutablePath -ine $hostRecord.exe) { throw 'Drop receiver image path differs from the elevated host.' }
    Assert-Hash $peer.ExecutablePath $AppSha256
    $peerArguments = [GxVmToken]::Arguments($peer.CommandLine)
    if ($peerArguments -cnotcontains $expectedBirth) { throw 'Drop receiver birth argument differs from the host process.' }
    $peerFacts = Get-TokenFacts ([int]$peer.ProcessId)
    $pair = Compare-SplitTokens $peerFacts $hostFacts
    if (-not $pair.paired) { throw ('Receiver/host split-token pairing failed: ' + ($pair.failures -join '; ')) }
    if ($peerFacts.sid -ne $self.sid -or $peerFacts.logon_id -ne $self.logon_id) { throw 'Receiver is not in this medium console logon.' }
    $windows = @(Get-Process -Id $peer.ProcessId | ForEach-Object { @{ title=$_.MainWindowTitle; hwnd=('0x{0:x}' -f $_.MainWindowHandle.ToInt64()) } })
    return [ordered]@{ host=$hostRecord; host_token_now=$hostFacts; receiver=@{ pid=[int]$peer.ProcessId; command_line=$peer.CommandLine;
        exe=$peer.ExecutablePath; created=$peer.CreationDate.ToUniversalTime().ToString('o'); token=$peerFacts; window=$windows }; pairing=$pair }
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
        'broker-host' { $report.result = Start-BrokerHost }
        'broker-peer' { $report.result = Find-BrokerPeer }
        'direct-target' { $report.result = Start-DirectTarget }
        'drop-source' { $report.result = Start-DropSource }
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
