<#
Guest-only validation. Stage with scripts/gx_windows_vm.py stage-validation and run through the
staged gx-run.cmd ("cmd /c \\host.lan\Data\validation\gx-run.cmd -Phase ..."), which copies this file
into the caller's profile and runs it with a per-process execution-policy bypass.
The manifest's UUID MUST be the live QEMU UUID read by the host (HMP info uuid).
No host execution, password parameters, account impersonation, automatic download,
elevation, or unverified installer/application execution is supported.
The clipboard is touched only by the osc52 phase, and only with test content that the
phase itself writes first; nothing reads or backs up clipboard content it did not write.
Phases that change guest settings (toast-matrix, jumplist-matrix, narrator, dpi) record the
before state, change only fixture-owned or explicitly named values, and restore them.
Each r6 phase report carries "before" and "after" guest snapshots and its restore result.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Manifest,
    [Parameter(Mandatory=$true)]
    [ValidateSet('inspect','tokens','accounts','enable-uac','gl','broker-host','broker-peer','direct-target','drop-source','install','upgrade','seed-foreign-before','expect-install-refused','seed-foreign-after','uninstall','check-preserved','cleanup-foreign',
                 'run-config','osc52','toast-matrix','jumplist-matrix','narrator')]
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
    [switch]$SoftwareGL,
    # r6 phases: a sub-step of the phase (each phase validates its own set).
    [ValidatePattern('^([a-z][a-z0-9-]{0,31})?$')][string]$Action = '',
    # Names one owned application record of a phase (several may run at once).
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,23}$')][string]$Label = 'main',
    # run-config: UTF-8 configuration file (verbatim) and its frozen SHA256.
    [string]$ConfigFile,
    [string]$ConfigSha256,
    # Extra application environment as NAME=VALUE pairs separated by ';' (GHOSTTY_* names only).
    [ValidateLength(0,2048)][string]$AppEnv = '',
    [ValidateRange(0,900)][int]$RunHoldSeconds = 0,
    # osc52: clipboard-write policy of the probe terminal (clipboard-read stays at its default, ask).
    [ValidateSet('allow','ask')][string]$ClipboardWritePolicy = 'allow',
    # toast-matrix early: seconds after the probe shell starts at which each OSC 9 is sent.
    [ValidatePattern('^\d{1,3}(,\d{1,3}){0,9}$')][string]$EarlyOffsets = '8,25,45',
    # toast-matrix early: back up, then delete HKCU Notifications\Settings\<AUMID> before the launch.
    [switch]$ResetToastSettings,
    # Installation directory below the run's AppDir: 'space' and 'cjk' put spaces, CJK and an
    # apostrophe into the installed exe path (fixed names; CJK cannot be typed over HMP).
    [ValidateSet('none','space','cjk')][string]$PathPreset = 'none',
    # jumplist-matrix config: profile set written to the real user configuration.
    [ValidateSet('base','deleted','lang-zh','lang-en')][string]$JumpListSet = 'base',
    # jumplist-matrix config: back up and replace a configuration this fixture did not write.
    [switch]$AdoptUserConfig,
    # jumplist-matrix observe: profile key (p1-p6) whose launch is expected, or none.
    [ValidatePattern('^(p[1-6]|none)?$')][string]$ExpectProfile = ''
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

    // Read-only: every descendant window of one class (bounded).
    public static ArrayList ChildrenOfClass(IntPtr parent, string cls) {
        ArrayList list = new ArrayList();
        if (parent == IntPtr.Zero || !IsWindow(parent)) return list;
        EnumChildWindows(parent, delegate (IntPtr hwnd, IntPtr unused) {
            StringBuilder name = new StringBuilder(128);
            GetClassNameW(hwnd, name, name.Capacity);
            if (name.ToString() == cls) list.Add(Describe(hwnd));
            return list.Count < 256;
        }, IntPtr.Zero);
        return list;
    }

    public static Hashtable Foreground() { return Describe(GetForegroundWindow()); }
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

# ---------------------------------------------------------------------------
# r6 phases. An application is "owned" only while this fixture started (or a
# phase explicitly adopted) it and its PID, creation time and image path still
# match the saved record; nothing else is closed or terminated. Multi-step
# phases keep their records under <RunRoot>\records and are driven by -Action.

$script:R6Phases = @('run-config','osc52','toast-matrix','jumplist-matrix','narrator')
$script:Restore = $null
$script:InstalledAumid = 'gx0404.GhosttyGX'
$script:NotificationSettingsKey = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\' + $script:InstalledAumid
# Fixture keybinds shared by the r6 GUI phases (explicit, so no default chord is assumed).
$script:FixtureKeybinds = @('keybind = ctrl+alt+shift+o=new_split:right', 'keybind = ctrl+alt+shift+t=new_tab',
    'keybind = ctrl+alt+shift+n=new_window', 'keybind = ctrl+alt+shift+w=close_surface',
    'keybind = ctrl+alt+shift+r=reload_config', 'keybind = global:ctrl+alt+shift+q=toggle_quick_terminal')

function Get-PathPresetName([string]$Preset) {
    switch ($Preset) {
        'space' { return "GX JL dir 'q'" }
        'cjk' { return 'GX ' + (-join @([char]0x5B89, [char]0x88C5)) + " dir 'q'" }
        default { return '' }
    }
}

function Assert-Action([string[]]$Allowed, [string]$Default) {
    $value = if ($Action) { $Action } else { $Default }
    if ($Allowed -cnotcontains $value) { throw ("Phase $Phase accepts -Action " + ($Allowed -join '|') + "; got '$value'.") }
    return $value
}

function Get-RecordPath([string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9_.-]{1,96}$') { throw "Invalid record name: $Name" }
    $dir = Join-Path $script:RunRoot 'records'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    return Join-Path $dir ($Name + '.json')
}

function Save-Record([string]$Name, $Value) {
    $path = Get-RecordPath $Name
    Write-Json $path $Value
    if (-not $script:ExportExtra.Contains($path)) { $script:ExportExtra.Add($path) }
    return $path
}

function Read-Record([string]$Name) {
    $path = Get-RecordPath $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    if (-not $script:ExportExtra.Contains($path)) { $script:ExportExtra.Add($path) }
    return Read-JsonFile $path
}

# Write-Json emits BOM-less UTF-8, which Windows PowerShell 5.1's Get-Content
# would decode as ANSI; every r6 JSON read (and state.json) goes through here.
function Read-JsonFile([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json }

function Set-RecordField($Record, [string]$Name, $Value) {
    $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-Utf8Bytes([string]$Text) { return [Text.UTF8Encoding]::new($false).GetBytes($Text) }

function Json-Normal($Value) { return (($Value | ConvertTo-Json -Depth 20) | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress) }

function Open-HkcuBase { return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64) }

function Get-MapEntries($Map) {
    # Entries of an ordered dictionary or of the PSCustomObject it became in JSON.
    if ($null -eq $Map) { return @() }
    if ($Map -is [System.Collections.IDictionary]) { return @($Map.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name=[string]$_.Key; Value=$_.Value } }) }
    return @($Map.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Value=$_.Value } })
}

function Read-AnyKeyTree([Microsoft.Win32.RegistryKey]$Base, [string]$Key, [int]$Depth = 0) {
    # Every value kind, bounded; used to back up a key before a phase changes it.
    $handle = $Base.OpenSubKey($Key, $false)
    if ($null -eq $handle) { return [ordered]@{ exists=$false } }
    try {
        $names = @($handle.GetValueNames() | Sort-Object)
        $subkeys = @($handle.GetSubKeyNames() | Sort-Object)
        if ($names.Count -gt 256 -or $subkeys.Count -gt 64 -or $Depth -gt 4) { throw "Registry backup exceeds fixture bounds: $Key" }
        $values = [ordered]@{}
        foreach ($name in $names) {
            $kind = [string]$handle.GetValueKind($name)
            $raw = $handle.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $data = switch ($kind) {
                'Binary' { [Convert]::ToBase64String([byte[]]$raw) }
                'MultiString' { ,@($raw) }
                'DWord' { [long][int]$raw }
                'QWord' { [long]$raw }
                'String' { [string]$raw }
                'ExpandString' { [string]$raw }
                default { throw "Unsupported registry value kind $kind under $Key; nothing was changed." }
            }
            $values['value:' + $name] = [ordered]@{ kind=$kind; data=$data }
        }
        $children = [ordered]@{}
        foreach ($name in $subkeys) { $children[$name] = Read-AnyKeyTree $Base ($Key + '\' + $name) ($Depth + 1) }
        return [ordered]@{ exists=$true; values=$values; children=$children }
    } finally { $handle.Dispose() }
}

function Restore-AnyKeyTree([Microsoft.Win32.RegistryKey]$Base, [string]$Key, $Tree) {
    if (-not $Tree.exists) { $Base.DeleteSubKeyTree($Key, $false); return }
    $handle = $Base.CreateSubKey($Key)
    $children = @(Get-MapEntries $Tree.children)
    try {
        $wanted = @{}
        foreach ($entry in @(Get-MapEntries $Tree.values)) { $wanted[$entry.Name.Substring(6)] = $entry.Value }
        foreach ($name in @($handle.GetValueNames())) { if (-not $wanted.ContainsKey($name)) { $handle.DeleteValue($name, $false) } }
        foreach ($name in @($wanted.Keys)) {
            $value = $wanted[$name]
            $kind = [Microsoft.Win32.RegistryValueKind]$value.kind
            $data = switch ([string]$value.kind) {
                'Binary' { [byte[]][Convert]::FromBase64String([string]$value.data) }
                'MultiString' { [string[]]@($value.data) }
                'DWord' { [int][long]$value.data }
                'QWord' { [long]$value.data }
                default { [string]$value.data }
            }
            $handle.SetValue($name, $data, $kind)
        }
        $keep = @($children | ForEach-Object { $_.Name })
        foreach ($name in @($handle.GetSubKeyNames())) { if ($keep -notcontains $name) { $handle.DeleteSubKeyTree($name, $false) } }
    } finally { $handle.Dispose() }
    foreach ($child in $children) { Restore-AnyKeyTree $Base ($Key + '\' + $child.Name) $child.Value }
}

function Backup-HkcuKey([string]$RecordName, [string]$Key) {
    # The first backup of a run is kept until it has been restored.
    $existing = Read-Record $RecordName
    if ($existing -and -not $existing.restored) {
        if ($existing.key -cne $Key) { throw "Record $RecordName backs up another key." }
        return $existing
    }
    $base = Open-HkcuBase
    try { $tree = Read-AnyKeyTree $base $Key } finally { $base.Dispose() }
    Save-Record $RecordName ([ordered]@{ hive='HKCU'; key=$Key; before=$tree; backed_up_utc=[DateTime]::UtcNow.ToString('o'); restored=$false }) | Out-Null
    return Read-Record $RecordName
}

function Restore-HkcuKey([string]$RecordName) {
    $record = Read-Record $RecordName
    if ($null -eq $record) { return [ordered]@{ record=$RecordName; restored=$true; note='no backup was taken' } }
    if ($record.restored) { return [ordered]@{ record=$RecordName; key=$record.key; restored=$true; note='already restored' } }
    $base = Open-HkcuBase
    try {
        Restore-AnyKeyTree $base $record.key $record.before
        $after = Read-AnyKeyTree $base $record.key
    } finally { $base.Dispose() }
    $equal = (Json-Normal $after) -ceq (Json-Normal $record.before)
    Set-RecordField $record 'restored' $equal
    Set-RecordField $record 'restored_utc' ([DateTime]::UtcNow.ToString('o'))
    Set-RecordField $record 'after_restore' $after
    Save-Record $RecordName $record | Out-Null
    return [ordered]@{ record=$RecordName; key=$record.key; restored=$equal; before_existed=[bool]$record.before.exists }
}

function Read-HkcuTree([string]$Key) {
    $base = Open-HkcuBase
    try { return Read-AnyKeyTree $base $Key } finally { $base.Dispose() }
}

function Initialize-Toast {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    $null = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
}

function Get-ToastFacts([string]$Aumid) {
    # Notification history XML (same read as the r18 evidence) and the notifier setting.
    $facts = [ordered]@{ aumid=$Aumid; setting=$null; setting_value=$null; history_count=$null; history=@(); error=$null }
    try {
        Initialize-Toast
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid)
        $facts.setting = [string]$notifier.Setting
        $facts.setting_value = [int]$notifier.Setting
        $items = @([Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($Aumid))
        $facts.history_count = $items.Count
        $facts.history = @($items | Select-Object -First 50 | ForEach-Object {
            $xml = $_.Content.GetXml(); if ($xml.Length -gt 4096) { $xml.Substring(0, 4096) } else { $xml } })
    } catch { $facts.error = $_.Exception.Message }
    return $facts
}

# Diagnostic only: the shell's quiet-hours (Focus assist / Do not disturb)
# profile from WNF. The authoritative evidence is the notification center
# screenshot; a nonzero status means the state could not be read here.
$script:WnfSource = @'
using System;
using System.Collections;
using System.Runtime.InteropServices;
public static class GxVmWnf {
    [DllImport("ntdll.dll")] static extern int NtQueryWnfStateData(ref ulong stateName, IntPtr typeId, IntPtr explicitScope, out uint changeStamp, [Out] byte[] buffer, ref uint bufferSize);
    public static Hashtable Query(ulong name) {
        Hashtable facts = new Hashtable();
        byte[] buffer = new byte[64]; uint size = (uint)buffer.Length; uint stamp;
        int status = NtQueryWnfStateData(ref name, IntPtr.Zero, IntPtr.Zero, out stamp, buffer, ref size);
        facts["state_name"] = "0x" + name.ToString("x16");
        facts["status"] = "0x" + status.ToString("x8");
        facts["change_stamp"] = (long)stamp;
        facts["size"] = (long)size;
        if (status == 0 && size >= 4) facts["value"] = (long)BitConverter.ToInt32(buffer, 0);
        return facts;
    }
}
'@

function Get-QuietHoursDiagnostic {
    try {
        if (-not ('GxVmWnf' -as [type])) { Add-Type -TypeDefinition $script:WnfSource -Language CSharp }
        # WNF_SHEL_QUIETHOURS_ACTIVE_PROFILE_CHANGED: 0 off, 1 priority only, 2 alarms only.
        return [GxVmWnf]::Query([uint64]'0x0D83063EA3BF1C75')
    } catch { return @{ error=$_.Exception.Message } }
}

function Get-PortableAumid([string]$Exe) {
    # Mirrors src/apprt/win32/shell/Identity.zig::init for an unregistered copy:
    # SHA-256 of the ASCII-lowercased, forward-slash path; first 16 bytes in hex.
    # The app hashes its final (handle-resolved) path; this uses the full path.
    $normalized = [regex]::Replace([IO.Path]::GetFullPath($Exe).Replace('\', '/'), '[A-Z]', { param($m) $m.Value.ToLowerInvariant() })
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash((Get-Utf8Bytes $normalized))
    return $script:InstalledAumid + '.Portable.' + ([BitConverter]::ToString($hash, 0, 16)).Replace('-', '').ToLowerInvariant()
}

function Copy-PortableApp([string]$Destination) {
    # A copy of this run's installed AppDir without the installer-owned uninstaller.
    if (-not $script:State.installed) { throw 'Install the fixture package in this run first.' }
    Assert-Hash (Join-Path $script:AppDir 'ghostty.exe') $AppSha256
    Assert-NoReparse $Destination
    if (Test-Path -LiteralPath $Destination) { throw "Portable copy already exists: $Destination" }
    $prefix = [IO.Path]::GetFullPath($script:AppDir).TrimEnd('\') + '\'
    $files = @(Get-ChildItem -LiteralPath $script:AppDir -Recurse -File -Force | Where-Object { $_.Name -notlike 'unins*' })
    foreach ($file in $files) {
        $target = Join-Path $Destination $file.FullName.Substring($prefix.Length)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
    $exe = Join-Path $Destination 'ghostty.exe'
    Assert-Hash $exe $AppSha256
    return @{ exe=$exe; files=$files.Count; aumid=(Get-PortableAumid $exe) }
}

function Write-ExportMarker([string]$Suffix, $Value) {
    # A small file the host can poll on the share while the guest holds a step.
    if ($script:ExportRoot) { Write-Json (Join-Path $script:ExportRoot ($script:ExportPrefix + $script:Step + '-' + $Suffix + '.json')) $Value }
}

function Get-AppEnvironment {
    $map = [ordered]@{}
    if ($SoftwareGL) { $map['GHOSTTY_GX_OPENGL'] = 'software' }
    foreach ($pair in @($AppEnv.Split(';') | Where-Object { $_ })) {
        $index = $pair.IndexOf('=')
        if ($index -lt 1) { throw "AppEnv entry needs NAME=VALUE: $pair" }
        $name = $pair.Substring(0, $index)
        $value = $pair.Substring($index + 1)
        if ($name -cnotmatch '^GHOSTTY_[A-Z0-9_]{1,48}$') { throw "AppEnv accepts GHOSTTY_* names only: $name" }
        if ($value.Length -gt 512 -or $value -match '[\x00-\x1f]') { throw "AppEnv value for $name is not a short single line." }
        $map[$name] = $value
    }
    return $map
}

function Get-GuestApps {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'ghostty.exe'" | ForEach-Object {
        [ordered]@{ pid=[int]$_.ProcessId; parent=[int]$_.ParentProcessId; session=[int]$_.SessionId; path=$_.ExecutablePath;
            created=$(if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') } else { $null }); command_line=$_.CommandLine } })
}

function Get-OwnedProcess($Record) {
    # The record's exact process life, or $null once it exited or its PID was reused.
    if ($null -eq $Record -or -not $Record.pid) { return $null }
    $process = Get-Process -Id ([int]$Record.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    try {
        if ($process.StartTime.ToFileTimeUtc() -ne [long]$Record.birth_filetime -or $process.Path -ine [string]$Record.exe) { $process.Dispose(); return $null }
        $null = $process.Handle
        return $process
    } catch { $process.Dispose(); return $null }
}

function Get-OwnedRecordSummary([string]$Prefix) {
    $dir = Join-Path $script:RunRoot 'records'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter ($Prefix + '*.json') | ForEach-Object {
        $record = Read-JsonFile $_.FullName
        $alive = $false
        if ($record.PSObject.Properties['pid'] -and $record.pid) { $owned = Get-OwnedProcess $record; if ($owned) { $alive = $true; $owned.Dispose() } }
        [ordered]@{ name=$_.BaseName; status=$(if ($record.PSObject.Properties['status']) { $record.status } else { $null }); alive=$alive } })
}

function Get-PhaseState([string]$When) {
    $state = [ordered]@{ label=$When; utc=[DateTime]::UtcNow.ToString('o'); user=$env:USERNAME; ghostty=(Get-GuestApps) }
    switch ($Phase) {
        'run-config' { $state.records = @(Get-OwnedRecordSummary 'run-config-') }
        'osc52' {
            # Only the clipboard sequence number: never the content of a clipboard this fixture did not write.
            if (-not ('GxVmClipboard' -as [type])) { Add-Type -TypeDefinition $script:ClipboardSource -Language CSharp }
            $state.clipboard_sequence = [GxVmClipboard]::Sequence()
            $state.records = @(Get-OwnedRecordSummary 'osc52-')
        }
        'toast-matrix' {
            $state.records = @(Get-OwnedRecordSummary 'toast-')
            $state.installed_toast = Get-ToastFacts $script:InstalledAumid
            $state.notification_settings = Read-HkcuTree $script:NotificationSettingsKey
            $state.quiet_hours = Get-QuietHoursDiagnostic
        }
        'jumplist-matrix' {
            $state.records = @(Get-OwnedRecordSummary 'jumplist-')
            $state.jump_lists = Get-JumpListFiles
            $state.user_config = @(Get-UserConfigFiles | ForEach-Object { [ordered]@{ path=$_; exists=(Test-Path -LiteralPath $_);
                sha256=$(if (Test-Path -LiteralPath $_) { Get-Sha256 $_ } else { $null }) } })
        }
        'narrator' {
            $state.records = @(Get-OwnedRecordSummary 'narrator')
            $state.narrator_processes = @(Get-NarratorProcesses)
            $state.screen_reader = Get-ScreenReaderFlag
        }
    }
    return $state
}

function Start-OwnedApp {
    # Isolated by default (private LOCALAPPDATA/APPDATA/XDG_* under -Private, like
    # Start-IsolatedApp); -RealProfile keeps the caller's real user environment.
    param([string]$Exe, [string]$Private, [byte[]]$ConfigBytes, $Environment, [string[]]$Arguments = @(), [switch]$RealProfile, $Overrides = $null)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Exe
    $start.Arguments = ($Arguments -join ' ')
    $start.UseShellExecute = $false
    foreach ($key in @($start.EnvironmentVariables.Keys)) { if ($key -match '^(?i:GHOSTTY_)') { $start.EnvironmentVariables.Remove($key) } }
    $config = $null
    if ($RealProfile) {
        $start.WorkingDirectory = $env:USERPROFILE
    } else {
        Assert-NoReparse $Private
        if (Test-Path -LiteralPath $Private) { throw "Application profile already exists: $Private" }
        [IO.Directory]::CreateDirectory($Private) | Out-Null
        if ($null -ne $ConfigBytes) {
            $config = Join-Path $Private 'ghostty\config.ghostty'
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($config)) | Out-Null
            [IO.File]::WriteAllBytes($config, $ConfigBytes)
        }
        $start.WorkingDirectory = $Private
        foreach ($key in @($start.EnvironmentVariables.Keys)) {
            if ($key -match '^(?i:XDG_)' -or $key -in @('NO_COLOR','TERM','LOCALAPPDATA','APPDATA')) { $start.EnvironmentVariables.Remove($key) }
        }
        $start.EnvironmentVariables['LOCALAPPDATA'] = $Private
        $start.EnvironmentVariables['APPDATA'] = Join-Path $Private 'appdata'
        $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $Private
        $start.EnvironmentVariables['XDG_STATE_HOME'] = Join-Path $Private 'state'
        $start.EnvironmentVariables['XDG_CACHE_HOME'] = Join-Path $Private 'cache'
    }
    if ($Overrides) { foreach ($key in @($Overrides.Keys)) { $start.EnvironmentVariables[$key] = [string]$Overrides[$key] } }
    if ($Environment) { foreach ($key in @($Environment.Keys)) { $start.EnvironmentVariables[$key] = [string]$Environment[$key] } }
    if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.Handle
    return @{ process=$process; config=$config }
}

function New-AppRecord($Process, [string]$Exe, [string]$Class, [string]$Private, [string]$Config, $Environment, [string[]]$Arguments) {
    $logRoot = if ($Private) { $Private } else { $env:LOCALAPPDATA }
    return [ordered]@{ phase=$Phase; label=$Label; status='STARTING'; step=$script:Step; pid=$Process.Id;
        birth_filetime=$Process.StartTime.ToFileTimeUtc(); birth=$Process.StartTime.ToUniversalTime().ToString('o');
        exe=$Exe; exe_sha256=(Get-Sha256 $Exe); app_class=$Class; profile=$Private; config=$Config;
        config_sha256=$(if ($Config) { Get-Sha256 $Config } else { $null }); log=(Join-Path $logRoot 'ghostty\logs\ghostty.log');
        environment=$Environment; arguments=@($Arguments); main_window=$null }
}

function Wait-AppWindow($Process, [int]$Seconds = 45) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $Process.Refresh()
        if ($Process.HasExited) { throw "Owned app exited $($Process.ExitCode) before it showed a window." }
        $windows = @([GxVmWindows]::TopLevel($Process.Id) | Where-Object { $_['class'] -ceq 'GhosttyWindow' -and $_['visible'] })
        if ($windows.Count -gt 0) { return $windows[0] }
        Start-Sleep -Milliseconds 100
    } while ($clock.Elapsed.TotalSeconds -lt $Seconds)
    throw "Owned app showed no GhosttyWindow within $Seconds seconds."
}

function Get-TerminalPanes([int]$ProcessId) {
    $panes = New-Object System.Collections.Generic.List[object]
    foreach ($window in @([GxVmWindows]::TopLevel($ProcessId) | Where-Object { $_['class'] -ceq 'GhosttyWindow' })) {
        $hwnd = [IntPtr][Convert]::ToInt64($window['hwnd'].Substring(2), 16)
        foreach ($pane in @([GxVmWindows]::ChildrenOfClass($hwnd, 'GhosttyTerminal'))) { $pane['window'] = $window['hwnd']; $panes.Add($pane) }
    }
    return $panes.ToArray()
}

function Get-AppStatus($Record) {
    if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }
    $process = Get-OwnedProcess $Record
    $status = [ordered]@{ label=$Record.label; pid=[int]$Record.pid; birth_filetime=[long]$Record.birth_filetime; alive=($null -ne $process);
        foreground=[GxVmWindows]::Foreground() }
    if ($process) {
        try {
            $process.Refresh()
            $status.windows = Get-WindowSnapshot $process.Id $process.MainWindowHandle 'status'
            $status.terminal_panes = @(Get-TerminalPanes $process.Id)
            $status.foreground_is_owned = ([long]$status.foreground['pid'] -eq $process.Id)
        } finally { $process.Dispose() }
    }
    return $status
}

function Close-OwnedApp($Record) {
    # CloseMainWindow first (the normal close request); WM_CLOSE to this exact
    # process's remaining GhosttyWindows is recorded as a follow-up; a kill is
    # always a failed close.
    if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }
    $close = [ordered]@{ label=$Record.label; pid=[int]$Record.pid; birth_filetime=[long]$Record.birth_filetime; wait_seconds=$CloseWaitSeconds;
        already_exited=$false; close_main_window=$null; followup=@(); killed=$false; exit_code=$null; exit_code_hex=$null;
        closed_by_close_main_window=$false; closed_normally=$false }
    $process = Get-OwnedProcess $Record
    if ($null -eq $process) {
        $close.already_exited = $true
        $close.note = 'The recorded process had already exited (or its PID was reused); its exit code is not observable now.'
        return $close
    }
    try {
        $process.Refresh()
        $main = $process.MainWindowHandle
        $close.before = Get-WindowSnapshot $process.Id $main 'before-close'
        $close.close_main_window_utc = [DateTime]::UtcNow.ToString('o')
        $close.close_main_window = $process.CloseMainWindow()
        $exited = $process.WaitForExit(2000)
        $close.closed_by_close_main_window = $exited
        if (-not $exited) {
            $close.after_2s = Get-WindowSnapshot $process.Id $main 'after-2s'
            $close.followup = @($close.after_2s.ghostty_windows | ForEach-Object {
                [GxVmWindows]::PostClose([IntPtr][Convert]::ToInt64($_['hwnd'].Substring(2), 16)) })
            $exited = $process.WaitForExit([Math]::Max(1000, $CloseWaitSeconds * 1000 - 2000))
        }
        if (-not $exited) {
            $close.before_kill = Get-WindowSnapshot $process.Id $main 'before-kill'
            $close.scene = Get-ProcessScene $process
            $process.Kill()
            $null = $process.WaitForExit(5000)
            $close.killed = $true
        }
        if ($process.HasExited) {
            $close.exit_code = $process.ExitCode
            $close.exit_code_hex = '0x{0:X8}' -f $process.ExitCode
            $close.exit_utc = $process.ExitTime.ToUniversalTime().ToString('o')
            $born = $process.StartTime.ToUniversalTime()
            $close.orphans_after_exit = @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $process.Id) |
                Where-Object { $_.CreationDate.ToUniversalTime() -ge $born } |
                ForEach-Object { [ordered]@{ pid=[int]$_.ProcessId; name=$_.Name; created=$_.CreationDate.ToUniversalTime().ToString('o') } })
        }
        $close.closed_normally = (-not $close.killed) -and $process.HasExited -and $process.ExitCode -eq 0
    } finally { $process.Dispose() }
    return $close
}

function Get-RunConfigSource {
    if ($ConfigFile) {
        Assert-Hash $ConfigFile $ConfigSha256
        $bytes = [IO.File]::ReadAllBytes($ConfigFile)
        if ($bytes.Length -gt 262144) { throw 'The configuration file exceeds 256 KiB.' }
        # Strict decoding: an invalid UTF-8 file is refused; the bytes are used verbatim.
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        return [ordered]@{ bytes=$bytes; source=$ConfigFile; sha256=$ConfigSha256.ToLowerInvariant(); default=$false; lines=@($text -split "`r?`n").Count }
    }
    if ($ConfigSha256) { throw '-ConfigSha256 needs -ConfigFile.' }
    $text = (@('language = en', 'confirm-close-surface = false', 'gx-session-restore = false') -join $script:LF) + $script:LF
    return [ordered]@{ bytes=(Get-Utf8Bytes $text); source=$null; sha256=$null; default=$true; lines=3 }
}

function Get-RendererLines([string]$Log) {
    if (-not (Test-Path -LiteralPath $Log)) { return @() }
    return @(Get-Content -LiteralPath $Log | Select-String 'loaded OpenGL' | Select-Object -First 4 | ForEach-Object Line)
}

function Invoke-RunConfig {
    # once: start, wait for the window, hold, CloseMainWindow, require exit 0.
    # start/stop/status split the same life across invocations by -Label.
    $step = Assert-Action @('once','start','stop','status') 'once'
    $name = 'run-config-' + $Label
    if ($step -ceq 'status' -or $step -ceq 'stop') {
        $record = Read-Record $name
        if ($null -eq $record) { throw "No run-config record for -Label $Label in this run." }
        if ($step -ceq 'status') { return Get-AppStatus $record }
        $close = Close-OwnedApp $record
        Set-RecordField $record 'close' $close
        Set-RecordField $record 'renderer' (Get-RendererLines $record.log)
        $record.status = if ($close.closed_normally) { 'CLOSED' } else { 'CLOSE_FAILED' }
        Save-Record $name $record | Out-Null
        if (Test-Path -LiteralPath $record.log) { $script:ExportExtra.Add($record.log) }
        return [ordered]@{ record=$record; fixture_verdict=$(if ($close.closed_normally) { 'PASS' } else { 'FAIL' });
            fixture_reason=$(if ($close.closed_normally) { $null } else { 'normal close did not pass (see close)' }) }
    }
    $previous = Read-Record $name
    $alive = Get-OwnedProcess $previous
    if ($alive) { $alive.Dispose(); throw "Label $Label still runs (pid $($previous.pid)); stop it or use another -Label." }
    $app = Resolve-GlApp
    $source = Get-RunConfigSource
    $environment = Get-AppEnvironment
    $arguments = @('--gx-single-instance=false')
    $private = Join-Path $script:RunRoot ($script:Step + '-run-config-' + $Label)
    $started = Start-OwnedApp -Exe $app.exe -Private $private -ConfigBytes $source.bytes -Environment $environment -Arguments $arguments
    $process = $started.process
    $record = New-AppRecord $process $app.exe $app.class $private $started.config $environment $arguments
    $record.config_source = $source.source
    $record.config_default = $source.default
    $record.config_source_sha256 = $source.sha256
    Save-Record $name $record | Out-Null
    $script:ExportExtra.Add($started.config)
    try {
        $record.main_window = Wait-AppWindow $process 45
        $record.window_seen_utc = [DateTime]::UtcNow.ToString('o')
        $record.status = 'RUNNING'
        Save-Record $name $record | Out-Null
        if ($step -ceq 'start') {
            Write-ExportMarker 'run-config-running' @{ label=$Label; pid=$record.pid; hwnd=$record.main_window['hwnd']; utc=$record.window_seen_utc }
            return [ordered]@{ record=$record; fixture_verdict='RUNNING' }
        }
        $hold = [Math]::Max($HoldSeconds, $RunHoldSeconds)
        if ($hold -gt 0) {
            Write-ExportMarker 'run-config-holding' @{ label=$Label; pid=$record.pid; hold_seconds=$hold; utc=[DateTime]::UtcNow.ToString('o') }
            $holdEnd = [DateTime]::UtcNow.AddSeconds($hold)
            while ([DateTime]::UtcNow -lt $holdEnd) {
                if ($process.HasExited) { throw "Owned app exited $($process.ExitCode) during the hold." }
                Start-Sleep -Milliseconds 200
            }
        }
        $record.held_seconds = $hold
    } catch {
        $record.status = 'START_FAILED'
        $record.error = $_.Exception.Message
        if ($step -ceq 'start' -and -not $process.HasExited) { $record.close = Close-OwnedApp $record }
        Save-Record $name $record | Out-Null
        throw
    } finally {
        if ($step -ceq 'once') {
            if (-not $record.Contains('close')) { $record.close = Close-OwnedApp $record }
            $record.renderer = Get-RendererLines $record.log
            if ($record.status -ceq 'RUNNING') { $record.status = if ($record.close.closed_normally) { 'CLOSED' } else { 'CLOSE_FAILED' } }
            Save-Record $name $record | Out-Null
            if (Test-Path -LiteralPath $record.log) { $script:ExportExtra.Add($record.log) }
        }
        $process.Dispose()
    }
    $passed = $record.close.closed_normally
    return [ordered]@{ record=$record; fixture_verdict=$(if ($passed) { 'PASS' } else { 'FAIL' });
        fixture_reason=$(if ($passed) { $null } else { 'normal close did not pass (see record.close)' }); visual_review='PENDING' }
}

# Controller-side clipboard access: the sequence number (no content) and the
# final clean-up of content this fixture itself put on the clipboard.
$script:ClipboardSource = @'
using System;
using System.Runtime.InteropServices;
public static class GxVmClipboard {
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll", SetLastError = true)] static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseClipboard();
    public static long Sequence() { return (long)GetClipboardSequenceNumber(); }
    public static long EmptyIfSequence(long expected) {
        if ((long)GetClipboardSequenceNumber() != expected) return -1;
        for (int i = 0; i < 50; i++) {
            if (OpenClipboard(IntPtr.Zero)) {
                try {
                    if ((long)GetClipboardSequenceNumber() != expected) return -1;
                    if (!EmptyClipboard()) throw new Exception("EmptyClipboard failed: " + Marshal.GetLastWin32Error());
                } finally { CloseClipboard(); }
                return (long)GetClipboardSequenceNumber();
            }
            System.Threading.Thread.Sleep(20);
        }
        throw new Exception("OpenClipboard failed: " + Marshal.GetLastWin32Error());
    }
}
'@

# The OSC 52 probe runs inside the terminal under test (powershell.exe 5.1).
# It seeds the clipboard with fixture-known text itself, sends one request,
# and reads the terminal's reply from console input in raw VT-input mode.
# Placeholders __NAME__ are replaced at generation; the file must stay ASCII.
$script:Osc52ProbeTemplate = @'
# GX OSC 52 probe generated by gx_vm_validation.ps1 (phase osc52). ASCII only.
$GxOscResults = '__RESULTS__'
$GxOscToken = '__TOKEN__'
$GxOscSeed = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SEED_B64__'))
$GxOscBefore = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__BEFORE_B64__'))
$GxOscWrite = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__WRITE_B64__'))
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class GxOsc52 {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FlushConsoleInputBuffer(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool WriteConsoleW(IntPtr h, string s, uint n, out uint written, IntPtr reserved);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint count);
    [StructLayout(LayoutKind.Explicit, Size = 20)] public struct InputRecord {
        [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public int KeyDown; [FieldOffset(8)] public ushort Repeat;
        [FieldOffset(10)] public ushort VirtualKey; [FieldOffset(12)] public ushort ScanCode; [FieldOffset(14)] public ushort Char;
        [FieldOffset(16)] public uint Control;
    }
    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "ReadConsoleInputW")] static extern bool ReadConsoleInput(IntPtr h, [Out] InputRecord[] buffer, uint length, out uint read);
    [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)] static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetClipboardData(uint format, IntPtr data);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GlobalFree(IntPtr h);

    public static IntPtr Input() { return GetStdHandle(-10); }
    public static long Sequence() { return (long)GetClipboardSequenceNumber(); }
    public static void Flush() { FlushConsoleInputBuffer(Input()); }
    public static void Send(string text) {
        uint written;
        if (!WriteConsoleW(GetStdHandle(-11), text, (uint)text.Length, out written, IntPtr.Zero) || written != (uint)text.Length)
            throw new Exception("WriteConsoleW failed: " + Marshal.GetLastWin32Error());
    }
    public static bool Complete(string text) {
        int start = text.IndexOf("\u001b]52;");
        if (start < 0) return false;
        return text.IndexOf('\u0007', start) >= 0 || text.IndexOf("\u001b\\", start + 1) >= 0;
    }
    // Characters of key-down records until a complete OSC 52 reply or the deadline.
    public static string Read(int timeoutMs) {
        IntPtr input = Input();
        StringBuilder text = new StringBuilder();
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        InputRecord[] records = new InputRecord[128];
        while (DateTime.UtcNow < deadline && text.Length < 65536) {
            int left = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
            if (WaitForSingleObject(input, (uint)Math.Max(1, Math.Min(left, 100))) != 0) continue;
            uint count;
            if (!GetNumberOfConsoleInputEvents(input, out count) || count == 0) { System.Threading.Thread.Sleep(10); continue; }
            uint read;
            if (!ReadConsoleInput(input, records, (uint)records.Length, out read)) throw new Exception("ReadConsoleInputW failed: " + Marshal.GetLastWin32Error());
            for (int i = 0; i < read; i++) {
                if (records[i].EventType != 1 || records[i].KeyDown == 0 || records[i].Char == 0) continue;
                for (int r = 0; r < Math.Max((int)records[i].Repeat, 1); r++) text.Append((char)records[i].Char);
            }
            if (Complete(text.ToString())) break;
        }
        return text.ToString();
    }
    static void Open(IntPtr owner) {
        for (int i = 0; i < 50; i++) { if (OpenClipboard(owner)) return; System.Threading.Thread.Sleep(20); }
        throw new Exception("OpenClipboard failed: " + Marshal.GetLastWin32Error());
    }
    // mode "text" leaves CF_UNICODETEXT (possibly empty); "cleared" leaves no format at all.
    public static long Seed(string mode, string text) {
        IntPtr owner = CreateWindowExW(0, "STATIC", "GxOsc52ClipboardOwner", 0, 0, 0, 0, 0, new IntPtr(-3), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (owner == IntPtr.Zero) throw new Exception("CreateWindowExW failed: " + Marshal.GetLastWin32Error());
        try {
            Open(owner);
            try {
                if (!EmptyClipboard()) throw new Exception("EmptyClipboard failed: " + Marshal.GetLastWin32Error());
                if (mode == "text") {
                    byte[] bytes = Encoding.Unicode.GetBytes(text + "\0");
                    IntPtr block = GlobalAlloc(0x0002, new UIntPtr((uint)bytes.Length));
                    if (block == IntPtr.Zero) throw new Exception("GlobalAlloc failed");
                    IntPtr data = GlobalLock(block);
                    Marshal.Copy(bytes, 0, data, bytes.Length);
                    GlobalUnlock(block);
                    if (SetClipboardData(13, block) == IntPtr.Zero) { GlobalFree(block); throw new Exception("SetClipboardData failed: " + Marshal.GetLastWin32Error()); }
                }
            } finally { CloseClipboard(); }
        } finally { DestroyWindow(owner); }
        return Sequence();
    }
    // Null when no CF_UNICODETEXT is present.
    public static string ReadText() {
        Open(IntPtr.Zero);
        try {
            if (!IsClipboardFormatAvailable(13)) return null;
            IntPtr handle = GetClipboardData(13);
            if (handle == IntPtr.Zero) return null;
            IntPtr data = GlobalLock(handle);
            if (data == IntPtr.Zero) return null;
            try { return Marshal.PtrToStringUni(data); } finally { GlobalUnlock(handle); }
        } finally { CloseClipboard(); }
    }
}
"@

function ConvertTo-GxOscVisible([string]$Text) {
    if ($null -eq $Text) { return $null }
    $out = New-Object Text.StringBuilder
    foreach ($c in $Text.ToCharArray()) { if ([int]$c -lt 32 -or [int]$c -eq 127) { [void]$out.AppendFormat('\x{0:x2}', [int]$c) } else { [void]$out.Append($c) } }
    return $out.ToString()
}

function ConvertFrom-GxOscReply([string]$Text) {
    $esc = [string][char]27
    $parsed = [ordered]@{ found=$false; terminator=$null; kind=$null; payload=$null; decoded_b64=$null; decoded_length=$null; outcome='none' }
    if (-not $Text) { return $parsed }
    $start = $Text.IndexOf($esc + ']52;')
    if ($start -lt 0) { $parsed.outcome = 'garbled'; return $parsed }
    $body = $Text.Substring($start + 5)
    $bel = $body.IndexOf([string][char]7)
    $st = $body.IndexOf($esc + '\')
    if ($bel -lt 0 -and $st -lt 0) { $parsed.outcome = 'garbled'; return $parsed }
    if ($bel -ge 0 -and ($st -lt 0 -or $bel -lt $st)) { $end = $bel; $parsed.terminator = 'bel' } else { $end = $st; $parsed.terminator = 'st' }
    $content = $body.Substring(0, $end)
    $semi = $content.IndexOf(';')
    if ($semi -lt 0) { $parsed.outcome = 'garbled'; return $parsed }
    $parsed.found = $true
    $parsed.kind = $content.Substring(0, $semi)
    $parsed.payload = $content.Substring($semi + 1)
    if ($parsed.payload.Length -eq 0) { $parsed.outcome = 'empty'; return $parsed }
    try { $bytes = [Convert]::FromBase64String($parsed.payload) } catch { $parsed.outcome = 'garbled'; return $parsed }
    $parsed.decoded_b64 = [Convert]::ToBase64String($bytes)
    $parsed.decoded_length = $bytes.Length
    $parsed.outcome = if ([Text.Encoding]::UTF8.GetString($bytes) -ceq $GxOscSeed) { 'match' } else { 'mismatch' }
    return $parsed
}

function Get-GxOscExpected([string]$Case, [string]$Expect) {
    $allow = @('allow','allow-remember','auto-allow')
    if ($Expect -eq 'observe' -or $Case -eq 'read-cleared') { return 'observe' }
    if ($Case -eq 'race') { return 'race' }
    if ($Case -like 'write*') {
        if ($Expect -eq 'auto' -or $allow -contains $Expect) { if ($Case -eq 'write') { return 'written' } else { return 'emptied' } }
        return 'unchanged'
    }
    if ($Expect -eq 'auto') { throw 'Expect auto applies to write cases only (no dialog under clipboard-write = allow).' }
    # A remembered deny turns clipboard-read into deny, which the core answers with nothing at all.
    if ($Expect -eq 'auto-deny') { return 'none' }
    if ($Case -eq 'read-empty') { return 'empty' }
    if ($allow -contains $Expect) { return 'match' }
    return 'empty'
}

function gxosc {
    param([Parameter(Mandatory = $true, Position = 0)][ValidateSet('read','read-empty','read-cleared','write','write-empty','race')][string]$Case,
          [Parameter(Position = 1)][ValidateSet('bel','st')][string]$Term = 'bel',
          [Parameter(Position = 2)][ValidateSet('allow','deny','cancel','allow-remember','deny-remember','auto-allow','auto-deny','auto','observe')][string]$Expect = 'observe',
          [Parameter(Position = 3)][ValidateRange(1,600)][int]$Timeout = 90)
    $esc = [string][char]27
    $terminator = if ($Term -eq 'st') { $esc + '\' } else { [string][char]7 }
    $n = @(Get-ChildItem -LiteralPath $GxOscResults -Filter 'osc52-*.json' -ErrorAction SilentlyContinue).Count + 1
    $result = [ordered]@{ schema=1; n=$n; token=$GxOscToken; case=$Case; terminator=$Term; expect=$Expect; timeout_seconds=$Timeout;
        shell_pid=$PID; expected_outcome=(Get-GxOscExpected $Case $Expect); outcome=$null; verdict=$null; errors=@() }
    $conIn = [GxOsc52]::Input()
    $mode = [uint32]0
    [void][GxOsc52]::GetConsoleMode($conIn, [ref]$mode)
    $result.input_mode_before = '0x{0:X}' -f $mode
    try {
        switch ($Case) {
            'read-empty' { $result.seq_seed = [GxOsc52]::Seed('text', '') }
            'read-cleared' { $result.seq_seed = [GxOsc52]::Seed('cleared', '') }
            { $_ -like 'write*' } { $result.seq_seed = [GxOsc52]::Seed('text', $GxOscBefore) }
            default { $result.seq_seed = [GxOsc52]::Seed('text', $GxOscSeed) }
        }
        $request = if ($Case -eq 'write') { $esc + ']52;c;' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($GxOscWrite)) + $terminator }
                   elseif ($Case -eq 'write-empty') { $esc + ']52;c;' + $terminator } else { $esc + ']52;c;?' + $terminator }
        $result.request_visible = ConvertTo-GxOscVisible $request
        Write-Host ("GX-OSC52 #{0} case={1} term={2} expect={3}: request sent, answer any dialog now" -f $n, $Case, $Term, $Expect)
        if ($Case -like 'write*') {
            [GxOsc52]::Send($request)
            $result.sent_utc = [DateTime]::UtcNow.ToString('o')
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while ($clock.Elapsed.TotalSeconds -lt $Timeout -and [GxOsc52]::Sequence() -eq $result.seq_seed) { Start-Sleep -Milliseconds 100 }
            $result.elapsed_ms = [int]$clock.Elapsed.TotalMilliseconds
            $result.seq_after = [GxOsc52]::Sequence()
            $after = [GxOsc52]::ReadText()
            $result.clipboard_after = [ordered]@{ has_text=($null -ne $after); length=$(if ($null -ne $after) { $after.Length } else { $null }) }
            $result.outcome = if ($null -eq $after -or $after.Length -eq 0) { 'emptied' } elseif ($after -ceq $GxOscWrite) { 'written' } elseif ($after -ceq $GxOscBefore) { 'unchanged' } else { 'other' }
        } else {
            # Raw VT input: no line editing or echo, so the reply arrives as typed characters.
            [void][GxOsc52]::SetConsoleMode($conIn, 0x200)
            [GxOsc52]::Flush()
            [GxOsc52]::Send($request)
            $result.sent_utc = [DateTime]::UtcNow.ToString('o')
            if ($Case -eq 'race') {
                Start-Sleep -Seconds $Timeout
                $result.outcome = 'race-exit'
                $result.verdict = 'RACE_SENT'
                $result.exit_utc = [DateTime]::UtcNow.ToString('o')
                [IO.File]::WriteAllText((Join-Path $GxOscResults ('osc52-{0:D3}-{1}.json' -f $n, $Case)), ($result | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
                Write-Host ("GX-OSC52 #{0} race: shell exits now while the request is pending" -f $n)
                [Environment]::Exit(0)
            }
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $reply = [GxOsc52]::Read($Timeout * 1000)
            $result.elapsed_ms = [int]$clock.Elapsed.TotalMilliseconds
            $result.reply_utc = [DateTime]::UtcNow.ToString('o')
            $result.reply_length = $reply.Length
            $result.reply_visible = ConvertTo-GxOscVisible $(if ($reply.Length -gt 4096) { $reply.Substring(0, 4096) } else { $reply })
            $result.reply = ConvertFrom-GxOscReply $reply
            $result.outcome = $result.reply.outcome
            $result.seq_after = [GxOsc52]::Sequence()
        }
    } catch {
        $result.errors += $_.Exception.Message
        if (-not $result.outcome) { $result.outcome = 'error' }
    } finally {
        [void][GxOsc52]::SetConsoleMode($conIn, $mode)
    }
    $result.verdict = if ($result.expected_outcome -eq 'observe') { 'OBSERVED' } elseif ($result.outcome -ceq $result.expected_outcome) { 'PASS' } else { 'FAIL' }
    $path = Join-Path $GxOscResults ('osc52-{0:D3}-{1}.json' -f $n, $Case)
    [IO.File]::WriteAllText($path, ($result | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
    Write-Host ("GX-OSC52 #{0} case={1} term={2} expect={3} outcome={4} expected={5} verdict={6}" -f $n, $Case, $Term, $Expect, $result.outcome, $result.expected_outcome, $result.verdict)
}
Write-Host ('GX-OSC52 probe ready (token ' + $GxOscToken + '). Usage: gxosc <read|read-empty|read-cleared|write|write-empty|race> <bel|st> <expect> [seconds]')
'@

function New-Osc52Probe([string]$Results, [string]$Token) {
    # Fixture-known test strings only; the seed carries non-ASCII text so the
    # UTF-8 and base64 path is exercised. Built from code points: the fixture
    # file itself stays ASCII for Windows PowerShell 5.1.
    $cjk = -join @([char]0x526A, [char]0x8D34, [char]0x677F, [char]0x6D4B, [char]0x8BD5)
    $strings = [ordered]@{
        seed = 'GX-OSC52-SEED ' + $Token + ' ' + $cjk + ' ' + [char]0x2713 + ' end'
        before = 'GX-OSC52-BEFORE ' + $Token
        write = 'GX-OSC52-WRITE ' + $Token + ' ' + $cjk + ' line2'
    }
    if ($Results -match "[\s']") { throw 'The probe results path must not contain whitespace or quotes.' }
    $text = $script:Osc52ProbeTemplate.Replace('__RESULTS__', $Results).Replace('__TOKEN__', $Token)
    foreach ($key in @('seed','before','write')) {
        $text = $text.Replace('__' + $key.ToUpperInvariant() + '_B64__', [Convert]::ToBase64String((Get-Utf8Bytes $strings[$key])))
    }
    if ($text -match '__[A-Z0-9_]+__' -or $text -match '[^\x00-\x7f]') { throw 'Generated probe is incomplete or not ASCII.' }
    return @{ text=$text; strings=$strings }
}

function Get-Osc52Results([string]$Results) {
    if (-not (Test-Path -LiteralPath $Results)) { return @() }
    return @(Get-ChildItem -LiteralPath $Results -Filter 'osc52-*.json' | Sort-Object Name | ForEach-Object {
        $script:ExportExtra.Add($_.FullName)
        Read-JsonFile $_.FullName })
}

function Invoke-Osc52 {
    # start: isolated app whose terminal dot-sources the probe (gxosc ...);
    # status/collect: app state and probe results; stop: CloseMainWindow, then
    # empty the clipboard only if it still holds this fixture's last content.
    $step = Assert-Action @('start','status','collect','stop') 'start'
    $name = 'osc52-' + $Label
    $results = Join-Path $script:RunRoot ('osc52-' + $Label + '-results')
    if ($step -ceq 'start') {
        $previous = Read-Record $name
        if ($previous) { throw "osc52 label $Label already exists in this run; use a new -Label." }
        $app = Resolve-GlApp
        $token = [guid]::NewGuid().ToString('N').Substring(0, 12)
        [IO.Directory]::CreateDirectory($results) | Out-Null
        $probe = New-Osc52Probe $results $token
        $probePath = Join-Path $script:RunRoot ('osc52-' + $Label + '-probe.ps1')
        [IO.File]::WriteAllText($probePath, $probe.text, [Text.Encoding]::ASCII)
        $lines = @('language = en', 'confirm-close-surface = false', 'gx-session-restore = false',
            ('command = powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -Command . ' + $probePath),
            'keybind = ctrl+alt+shift+o=new_split:right', 'keybind = ctrl+alt+shift+w=close_surface')
        if ($ClipboardWritePolicy -ceq 'ask') { $lines += 'clipboard-write = ask' }
        $environment = Get-AppEnvironment
        $arguments = @('--gx-single-instance=false')
        $private = Join-Path $script:RunRoot ($script:Step + '-osc52-' + $Label)
        $started = Start-OwnedApp -Exe $app.exe -Private $private -ConfigBytes (Get-Utf8Bytes ((($lines -join $script:LF)) + $script:LF)) -Environment $environment -Arguments $arguments
        $process = $started.process
        $record = New-AppRecord $process $app.exe $app.class $private $started.config $environment $arguments
        $record.token = $token
        $record.probe = $probePath
        $record.probe_sha256 = Get-Sha256 $probePath
        $record.results = $results
        $record.clipboard_read = 'default (not set; ask)'
        $record.clipboard_write = $ClipboardWritePolicy
        $record.test_strings_sha256 = [ordered]@{}
        foreach ($key in @($probe.strings.Keys)) { $record.test_strings_sha256[$key] = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash((Get-Utf8Bytes $probe.strings[$key])))).Replace('-', '').ToLowerInvariant() }
        Save-Record $name $record | Out-Null
        $script:ExportExtra.Add($started.config)
        $script:ExportExtra.Add($probePath)
        try {
            $record.main_window = Wait-AppWindow $process 45
            $record.status = 'RUNNING'
        } catch {
            $record.status = 'START_FAILED'
            $record.error = $_.Exception.Message
            if (-not $process.HasExited) { $record.close = Close-OwnedApp $record }
            throw
        } finally { Save-Record $name $record | Out-Null; $process.Dispose() }
        Write-ExportMarker 'osc52-running' @{ label=$Label; pid=$record.pid; hwnd=$record.main_window['hwnd']; token=$token }
        return [ordered]@{ record=$record; fixture_verdict='RUNNING'; next='type gxosc <case> <bel|st> <expect> in the terminal' }
    }
    $record = Read-Record $name
    if ($null -eq $record) { throw "No osc52 record for -Label $Label in this run." }
    $items = @(Get-Osc52Results $results)
    $summary = @($items | ForEach-Object { [ordered]@{ n=$_.n; case=$_.case; terminator=$_.terminator; expect=$_.expect;
        outcome=$_.outcome; expected=$_.expected_outcome; verdict=$_.verdict; elapsed_ms=$(if ($_.PSObject.Properties['elapsed_ms']) { $_.elapsed_ms } else { $null }) } })
    $failed = @($items | Where-Object { $_.verdict -ceq 'FAIL' })
    $status = Get-AppStatus $record
    $result = [ordered]@{ record_status=$record.status; app=$status; results=$summary; counts=[ordered]@{
        total=$items.Count; pass=@($items | Where-Object { $_.verdict -ceq 'PASS' }).Count; fail=$failed.Count;
        observed=@($items | Where-Object { $_.verdict -ceq 'OBSERVED' }).Count; race=@($items | Where-Object { $_.verdict -ceq 'RACE_SENT' }).Count } }
    if ($step -ceq 'status') { return $result }
    if ($step -ceq 'stop') {
        $close = Close-OwnedApp $record
        Set-RecordField $record 'close' $close
        $record.status = if ($close.closed_normally) { 'CLOSED' } else { 'CLOSE_FAILED' }
        Save-Record $name $record | Out-Null
        if (Test-Path -LiteralPath $record.log) { $script:ExportExtra.Add($record.log) }
        $result.close = $close
        # Clean up only content this fixture wrote: the last sequence number a probe observed.
        $sequences = @($items | ForEach-Object { foreach ($field in @('seq_seed','seq_after')) { if ($_.PSObject.Properties[$field] -and $null -ne $_.$field) { [long]$_.$field } } })
        if ($sequences.Count -eq 0) {
            $script:Restore = @{ clipboard='nothing to clean: no probe wrote the clipboard' }
        } else {
            if (-not ('GxVmClipboard' -as [type])) { Add-Type -TypeDefinition $script:ClipboardSource -Language CSharp }
            $last = ($sequences | Measure-Object -Maximum).Maximum
            $now = [GxVmClipboard]::Sequence()
            $emptied = [GxVmClipboard]::EmptyIfSequence([long]$last)
            $script:Restore = [ordered]@{ clipboard=$(if ($emptied -ge 0) { 'emptied (held only this fixture''s last content)' } else { 'left untouched: sequence moved past the fixture''s last write' });
                last_fixture_sequence=$last; sequence_before_cleanup=$now; sequence_after_cleanup=[GxVmClipboard]::Sequence() }
        }
        $result.fixture_verdict = if ($failed.Count -gt 0 -or -not $close.closed_normally) { 'FAIL' } else { 'PASS' }
        $result.fixture_reason = if ($failed.Count -gt 0) { 'probe cases failed: ' + (@($failed | ForEach-Object { '#' + $_.n + ' ' + $_.case }) -join ', ') } elseif (-not $close.closed_normally) { 'normal close did not pass' } else { $null }
        return $result
    }
    # collect: a still-running app is required unless the record was stopped.
    $result.fixture_verdict = if ($failed.Count -gt 0 -or -not $status.alive) { 'FAIL' } else { 'PASS' }
    $result.fixture_reason = if ($failed.Count -gt 0) { 'probe cases failed: ' + (@($failed | ForEach-Object { '#' + $_.n + ' ' + $_.case }) -join ', ') } elseif (-not $status.alive) { 'the owned app is no longer running' } else { $null }
    return $result
}

# Runs inside the terminal under test: gxtoast titles its tab, waits, sends one
# OSC 9 (or OSC 777) notification; gxtoast-early replays the early r3 sequence.
$script:ToastProbeTemplate = @'
# GX toast probe generated by gx_vm_validation.ps1 (phase toast-matrix). ASCII only.
$GxToastResults = '__RESULTS__'
$GxToastToken = '__TOKEN__'
function Send-GxToast([string]$Tag, [string]$Kind, [string]$Body, [hashtable]$Extra) {
    $esc = [string][char]27; $bel = [string][char]7
    $sequence = if ($Kind -eq 'osc777') { $esc + ']777;notify;GX toast ' + $Tag + ';' + $Body + $bel } else { $esc + ']9;' + $Body + $bel }
    [Console]::Out.Write($sequence)
    [Console]::Out.Flush()
    $n = @(Get-ChildItem -LiteralPath $GxToastResults -Filter 'toast-*.json' -ErrorAction SilentlyContinue).Count + 1
    $record = [ordered]@{ schema=1; n=$n; token=$GxToastToken; tag=$Tag; kind=$Kind; body=$Body; shell_pid=$PID; sent_utc=[DateTime]::UtcNow.ToString('o') }
    if ($Extra) { foreach ($key in $Extra.Keys) { $record[$key] = $Extra[$key] } }
    [IO.File]::WriteAllText((Join-Path $GxToastResults ('toast-{0:D3}-{1}.json' -f $n, $Tag)), ($record | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    return $record
}
function gxtoast {
    param([Parameter(Mandatory = $true, Position = 0)][ValidatePattern('^[A-Za-z0-9-]{1,16}$')][string]$Tag,
          [Parameter(Position = 1)][ValidateRange(0,600)][int]$Delay = 10,
          [Parameter(Position = 2)][ValidateSet('osc9','osc777')][string]$Kind = 'osc9')
    $esc = [string][char]27; $bel = [string][char]7
    [Console]::Out.Write($esc + ']2;GX-TOAST-' + $Tag + $bel)
    Write-Host ("GX-TOAST {0}: tab titled GX-TOAST-{0}; {1} in {2} s" -f $Tag, $Kind, $Delay)
    Start-Sleep -Seconds $Delay
    $record = Send-GxToast $Tag $Kind ('GX toast ' + $Tag + ' ' + $GxToastToken) @{ delay_seconds=$Delay; title=('GX-TOAST-' + $Tag) }
    Write-Host ("GX-TOAST {0}: SENT #{1} at {2}" -f $Tag, $record.n, $record.sent_utc)
}
function gxtoast-early {
    param([Parameter(Position = 0)][int[]]$Offsets = @(8, 25, 45))
    $esc = [string][char]27; $bel = [string][char]7
    [Console]::Out.Write($esc + ']2;GX-TOAST-EARLY' + $bel)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $i = 0
    foreach ($offset in $Offsets) {
        $i++
        while ($clock.Elapsed.TotalSeconds -lt $offset) { Start-Sleep -Milliseconds 100 }
        $record = Send-GxToast ('early' + $i) 'osc9' ('GX early ' + $i + ' ' + $GxToastToken) @{ offset_seconds=$offset; elapsed_ms=[int]$clock.Elapsed.TotalMilliseconds }
        Write-Host ("==== GX-TOAST-EARLY {0}/{1} SENT at {2} (offset {3} s) ====" -f $i, $Offsets.Count, $record.sent_utc, $offset)
    }
    Write-Host 'GX-TOAST-EARLY sequence complete.'
}
Write-Host ('GX toast probe ready (token ' + $GxToastToken + '). Usage: gxtoast <tag> [delay] [osc9|osc777]; gxtoast-early [offsets]')
'@

function New-ToastProbe([string]$Results, [string]$Token) {
    if ($Results -match "[\s']") { throw 'The probe results path must not contain whitespace or quotes.' }
    $text = $script:ToastProbeTemplate.Replace('__RESULTS__', $Results).Replace('__TOKEN__', $Token)
    if ($text -match '__[A-Z0-9_]+__' -or $text -match '[^\x00-\x7f]') { throw 'Generated probe is incomplete or not ASCII.' }
    return $text
}

function Get-ToastProbeResults {
    return @(Get-ChildItem -LiteralPath $script:RunRoot -Directory -Filter 'toast-*-results' -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Filter 'toast-*.json' | Sort-Object Name | ForEach-Object {
            $script:ExportExtra.Add($_.FullName)
            Read-JsonFile $_.FullName } })
}

function Start-ToastApp([string]$Exe, [string]$Class, [string]$EarlyCommand) {
    $name = 'toast-' + $Label
    $previous = Read-Record $name
    if ($previous) { throw "toast-matrix label $Label already exists in this run; use a new -Label." }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $results = Join-Path $script:RunRoot ('toast-' + $Label + '-results')
    [IO.Directory]::CreateDirectory($results) | Out-Null
    $probePath = Join-Path $script:RunRoot ('toast-' + $Label + '-probe.ps1')
    [IO.File]::WriteAllText($probePath, (New-ToastProbe $results $token), [Text.Encoding]::ASCII)
    $command = 'command = powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -Command . ' + $probePath
    if ($EarlyCommand) { $command += '; ' + $EarlyCommand }
    $lines = @('language = en', 'confirm-close-surface = false', 'gx-session-restore = false', $command) + $script:FixtureKeybinds
    $environment = Get-AppEnvironment
    $arguments = @('--gx-single-instance=false')
    $private = Join-Path $script:RunRoot ($script:Step + '-toast-' + $Label)
    $started = Start-OwnedApp -Exe $Exe -Private $private -ConfigBytes (Get-Utf8Bytes (($lines -join $script:LF) + $script:LF)) -Environment $environment -Arguments $arguments
    $process = $started.process
    $record = New-AppRecord $process $Exe $Class $private $started.config $environment $arguments
    $record.token = $token
    $record.probe = $probePath
    $record.results = $results
    $record.aumid = if ($Class -ceq 'PORTABLE_COPY') { Get-PortableAumid $Exe } else { $script:InstalledAumid }
    Save-Record $name $record | Out-Null
    $script:ExportExtra.Add($started.config)
    try {
        $record.main_window = Wait-AppWindow $process 45
        $record.status = 'RUNNING'
    } catch {
        $record.status = 'START_FAILED'
        $record.error = $_.Exception.Message
        if (-not $process.HasExited) { $record.close = Close-OwnedApp $record }
        throw
    } finally { Save-Record $name $record | Out-Null; $process.Dispose() }
    return $record
}

function Get-ToastRecords {
    $dir = Join-Path $script:RunRoot 'records'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter 'toast-*.json' | ForEach-Object { Read-JsonFile $_.FullName } |
        Where-Object { $_.PSObject.Properties['pid'] })
}

function Invoke-ToastMatrix {
    # start: isolated installed app with the gxtoast probe; portable: the same
    # payload copied outside the installation (portable identity); early: the
    # probe shell replays the early three-OSC sequence; native-probe: a direct
    # WinRT toast for the installed AUMID; disable-app/enable-app: the
    # per-app notification switch (HKCU, backed up and restored);
    # status: windows, foreground, history XML; stop: close and restore.
    $step = Assert-Action @('start','portable','early','native-probe','disable-app','enable-app','status','stop') 'status'
    switch ($step) {
        'start' {
            $app = Resolve-GlApp
            if ($app.class -cne 'INSTALLED') { throw 'toast-matrix needs the installed, registered application (registration_verified).' }
            $record = Start-ToastApp $app.exe $app.class $null
            Write-ExportMarker 'toast-running' @{ label=$Label; pid=$record.pid; hwnd=$record.main_window['hwnd'] }
            return [ordered]@{ record=$record; installed=(Get-ToastFacts $script:InstalledAumid); fixture_verdict='RUNNING' }
        }
        'portable' {
            $copy = Copy-PortableApp (Join-Path $script:RunRoot ('portable-' + $Label))
            $before = Registry-Snapshot
            $record = Start-ToastApp $copy.exe 'PORTABLE_COPY' $null
            Start-Sleep -Seconds 8
            $after = Registry-Snapshot
            $unchanged = (Json-Canonical $before) -ceq (Json-Canonical $after)
            return [ordered]@{ record=$record; copy=$copy; registry_unchanged=$unchanged; registry_before=$before; registry_after=$after;
                installed=(Get-ToastFacts $script:InstalledAumid); portable=(Get-ToastFacts $copy.aumid);
                fixture_verdict=$(if ($unchanged) { 'RUNNING' } else { 'FAIL' }); fixture_reason=$(if ($unchanged) { $null } else { 'starting the portable copy changed the shell registration' }) }
        }
        'early' {
            $app = Resolve-GlApp
            if ($app.class -cne 'INSTALLED') { throw 'The early sequence needs the installed, registered application.' }
            $settingsBefore = Read-HkcuTree $script:NotificationSettingsKey
            $reset = $null
            if ($ResetToastSettings) {
                $backup = Backup-HkcuKey 'toast-notification-settings' $script:NotificationSettingsKey
                $base = Open-HkcuBase
                try { $base.DeleteSubKeyTree($script:NotificationSettingsKey, $false) } finally { $base.Dispose() }
                $reset = [ordered]@{ backed_up_utc=$backup.backed_up_utc; deleted=(-not (Read-HkcuTree $script:NotificationSettingsKey).exists) }
            }
            $exeItem = Get-Item -LiteralPath $app.exe
            $record = Start-ToastApp $app.exe $app.class ('gxtoast-early ' + $EarlyOffsets)
            Write-ExportMarker 'toast-early-running' @{ label=$Label; pid=$record.pid; offsets=$EarlyOffsets; utc=[DateTime]::UtcNow.ToString('o') }
            return [ordered]@{ record=$record; offsets=$EarlyOffsets; notification_settings_before=$settingsBefore; reset=$reset;
                seconds_since_exe_created=[int]([DateTime]::UtcNow - $exeItem.CreationTimeUtc).TotalSeconds;
                installed=(Get-ToastFacts $script:InstalledAumid); fixture_verdict='RUNNING' }
        }
        'native-probe' {
            Initialize-Toast
            $token = [guid]::NewGuid().ToString('N').Substring(0, 12)
            $facts = [ordered]@{ aumid=$script:InstalledAumid; token=$token; phases=@() }
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:InstalledAumid)
            $facts.setting = [string]$notifier.Setting
            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>GX native control</text><text>' + $token + '</text></binding></visual></toast>')
            $notifier.Show([Windows.UI.Notifications.ToastNotification]::new($xml))
            $facts.shown_utc = [DateTime]::UtcNow.ToString('o')
            $facts.note = 'Show returned; presentation needs the screenshot.'
            Save-Record ('toast-native-' + $token) $facts | Out-Null
            return $facts
        }
        'disable-app' {
            $backup = Backup-HkcuKey 'toast-notification-settings' $script:NotificationSettingsKey
            $base = Open-HkcuBase
            try {
                $key = $base.CreateSubKey($script:NotificationSettingsKey)
                try { $key.SetValue('Enabled', 0, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
            } finally { $base.Dispose() }
            return [ordered]@{ backed_up_utc=$backup.backed_up_utc; before=$backup.before; after=(Read-HkcuTree $script:NotificationSettingsKey);
                installed=(Get-ToastFacts $script:InstalledAumid) }
        }
        'enable-app' {
            $script:Restore = Restore-HkcuKey 'toast-notification-settings'
            return [ordered]@{ restore=$script:Restore; installed=(Get-ToastFacts $script:InstalledAumid);
                fixture_verdict=$(if ($script:Restore.restored) { 'PASS' } else { 'FAIL' }) }
        }
        'status' {
            $records = @(Get-ToastRecords)
            $aumids = @(@($script:InstalledAumid) + @($records | ForEach-Object { $_.aumid }) | Select-Object -Unique)
            return [ordered]@{ apps=@($records | ForEach-Object { Get-AppStatus $_ }); toast=@($aumids | ForEach-Object { Get-ToastFacts $_ });
                probe_results=@(Get-ToastProbeResults); notification_settings=(Read-HkcuTree $script:NotificationSettingsKey);
                quiet_hours=(Get-QuietHoursDiagnostic); visual_review='PENDING' }
        }
        'stop' {
            $closes = @(Get-ToastRecords | Where-Object { $_.status -ceq 'RUNNING' } | ForEach-Object {
                $record = $_
                $close = Close-OwnedApp $record
                Set-RecordField $record 'close' $close
                $record.status = if ($close.closed_normally -or $close.already_exited) { 'CLOSED' } else { 'CLOSE_FAILED' }
                Save-Record ('toast-' + $record.label) $record | Out-Null
                if (Test-Path -LiteralPath $record.log) { $script:ExportExtra.Add($record.log) }
                $close })
            $settings = Restore-HkcuKey 'toast-notification-settings'
            $removed = @(Get-ToastRecords | Where-Object { $_.app_class -ceq 'PORTABLE_COPY' -and $_.status -ceq 'CLOSED' } | ForEach-Object {
                $dir = Split-Path -Parent $_.exe
                $root = [IO.Path]::GetFullPath($script:RunRoot).TrimEnd('\') + '\'
                if ([IO.Path]::GetFullPath($dir).StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $dir) -like 'portable-*' -and (Test-Path -LiteralPath $dir)) {
                    Remove-Item -LiteralPath $dir -Recurse -Force
                    $dir
                } })
            $script:Restore = [ordered]@{ notification_settings=$settings; removed_portable_copies=$removed }
            $bad = @($closes | Where-Object { -not $_.closed_normally -and -not $_.already_exited })
            $verdict = if ($bad.Count -gt 0 -or -not $settings.restored) { 'FAIL' } else { 'PASS' }
            return [ordered]@{ closes=$closes; restore=$script:Restore; toast=(Get-ToastFacts $script:InstalledAumid);
                probe_results=@(Get-ToastProbeResults); fixture_verdict=$verdict;
                fixture_reason=$(if ($bad.Count -gt 0) { 'an owned app did not close normally' } elseif (-not $settings.restored) { 'notification settings were not restored' } else { $null }) }
        }
    }
}

# ---- jumplist-matrix: the real user configuration and shell jump lists -----

function Get-UserConfigFiles {
    $dir = Join-Path $env:LOCALAPPDATA 'ghostty'
    return @(@('config.ghostty', 'config', 'gui-settings.ghostty') | ForEach-Object { Join-Path $dir $_ })
}

function Get-FixtureConfigMarker { return '# gx-vm-validation owner ' + $RunId + ' ' + $script:State.token }

function Test-FixtureOwnedFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ([string](Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8)) -ceq (Get-FixtureConfigMarker)
}

function Adopt-UserConfig {
    # JumpList launches use the shell's environment, so these cases need the real
    # configuration. Foreign files are backed up (hash-checked) and moved aside.
    if ($env:XDG_CONFIG_HOME) { throw 'XDG_CONFIG_HOME is set for this user; the jump list cases expect the default configuration directory.' }
    $record = Read-Record 'jumplist-user-config'
    if ($record -and -not $record.restored) { return $record }
    $backupDir = Join-Path $script:RunRoot ('user-config-backup-' + $script:Step)
    $files = @()
    foreach ($path in Get-UserConfigFiles) {
        $entry = [ordered]@{ path=$path; existed=(Test-Path -LiteralPath $path -PathType Leaf); sha256=$null; backup=$null }
        if ($entry.existed) {
            if (-not $AdoptUserConfig) { throw "A configuration this fixture did not write exists ($path); pass -AdoptUserConfig to back it up and replace it." }
            [IO.Directory]::CreateDirectory($backupDir) | Out-Null
            $entry.sha256 = Get-Sha256 $path
            $entry.backup = Join-Path $backupDir ([IO.Path]::GetFileName($path))
            Copy-Item -LiteralPath $path -Destination $entry.backup
            Assert-Hash $entry.backup $entry.sha256
            Remove-Item -LiteralPath $path
        }
        $files += $entry
    }
    Save-Record 'jumplist-user-config' ([ordered]@{ files=$files; adopted_utc=[DateTime]::UtcNow.ToString('o'); restored=$false }) | Out-Null
    return Read-Record 'jumplist-user-config'
}

function Restore-UserConfig {
    $record = Read-Record 'jumplist-user-config'
    if ($null -eq $record) { return [ordered]@{ restored=$true; note='no configuration was adopted' } }
    if ($record.restored) { return [ordered]@{ restored=$true; note='already restored' } }
    $items = @(foreach ($entry in @($record.files)) {
        $item = [ordered]@{ path=$entry.path; action=$null; ok=$false }
        $present = Test-Path -LiteralPath $entry.path -PathType Leaf
        if ($present -and -not (Test-FixtureOwnedFile $entry.path)) {
            $item.action = 'left untouched: the file now present was not written by this fixture'
            $item.sha256_now = Get-Sha256 $entry.path
        } elseif ($entry.existed) {
            Copy-Item -LiteralPath $entry.backup -Destination $entry.path -Force
            $item.ok = (Get-Sha256 $entry.path) -ceq $entry.sha256
            $item.action = 'restored from backup'
        } elseif ($present) {
            Remove-Item -LiteralPath $entry.path
            $item.ok = -not (Test-Path -LiteralPath $entry.path)
            $item.action = 'removed the fixture file'
        } else { $item.ok = $true; $item.action = 'absent, as before' }
        $item })
    $ok = @($items | Where-Object { -not $_.ok }).Count -eq 0
    Set-RecordField $record 'restored' $ok
    Set-RecordField $record 'restore' $items
    Save-Record 'jumplist-user-config' $record | Out-Null
    return [ordered]@{ restored=$ok; files=$items }
}

function Get-JumpListMarkDir { return Join-Path $script:RunRoot ('jl mark ' + (-join @([char]0x4E2D, [char]0x6587)) + " 'q'") }

function Get-JumpListProfiles([string]$MarkDir) {
    $mark = Join-Path $MarkDir 'gx-jl-mark.cmd'
    return @(
        [ordered]@{ key='p1'; name='GX JL Plain'; command='cmd.exe /d /k title GX_JL_P1' },
        [ordered]@{ key='p2'; name='GX JL Space Name'; command='cmd.exe /d /k title GX_JL_P2' },
        [ordered]@{ key='p3'; name=('GX JL ' + (-join @([char]0x4E2D, [char]0x6587))); command='cmd.exe /d /k title GX_JL_P3' },
        [ordered]@{ key='p4'; name='GX JL "Quote"'; command='cmd.exe /d /k title GX_JL_P4' },
        [ordered]@{ key='p5'; name='GX JL Trail\'; command='cmd.exe /d /k title GX_JL_P5' },
        [ordered]@{ key='p6'; name='GX JL Path'; command=('cmd.exe /d /k call "' + $mark + '" "' + $MarkDir + '\"') })
}

function New-JumpListConfig([string]$Set, [string]$MarkDir) {
    $profiles = @(Get-JumpListProfiles $MarkDir)
    if ($Set -ceq 'deleted') { $profiles = @($profiles | Where-Object { $_.key -cne 'p2' }) }
    $language = if ($Set -ceq 'lang-zh') { 'zh-CN' } else { 'en' }
    $lines = @((Get-FixtureConfigMarker), ('language = ' + $language), 'confirm-close-surface = false', 'gx-session-restore = false') +
        $script:FixtureKeybinds + @($profiles | ForEach-Object { 'gx-launch-profile = ' + $_.name + '=' + $_.command })
    return @{ text=(($lines -join $script:LF) + $script:LF); profiles=$profiles; language=$language }
}

function Read-JumpListTasks([byte[]]$Bytes, [string[]]$Titles) {
    # Shell link StringData is UTF-16 with a 16-bit length prefix: read each
    # argument string exactly, then decode it with CommandLineToArgvW.
    if (-not ('GxVmToken' -as [type])) { Add-Type -TypeDefinition $script:TokenSource -Language CSharp }
    $marker = '"--gx-shell-action=profile"'
    $tasks = New-Object System.Collections.Generic.List[object]
    $present = New-Object System.Collections.Generic.List[string]
    foreach ($offset in @(0, 1)) {
        $count = $Bytes.Length - $offset
        if ($count -lt 2) { continue }
        $text = [Text.Encoding]::Unicode.GetString($Bytes, $offset, $count - ($count % 2))
        foreach ($title in $Titles) { if ($text.Contains($title) -and -not $present.Contains($title)) { $present.Add($title) } }
        $index = $text.IndexOf($marker)
        while ($index -ge 0 -and $tasks.Count -lt 128) {
            $length = if ($index -gt 0) { [int]$text[$index - 1] } else { 0 }
            if ($length -ge $marker.Length -and $index + $length -le $text.Length) { $arguments = $text.Substring($index, $length); $method = 'length-prefixed' }
            else {
                $end = $index
                while ($end -lt $text.Length -and [int]$text[$end] -ge 32) { $end++ }
                $arguments = $text.Substring($index, $end - $index); $method = 'printable-run'
            }
            $argv = @([GxVmToken]::Arguments('x ' + $arguments) | Select-Object -Skip 1)
            $profile = if ($argv.Count -ge 2 -and $argv[1].StartsWith('--gx-shell-profile=')) { $argv[1].Substring(19) } else { $null }
            $tasks.Add([ordered]@{ alignment=$offset; method=$method; arguments=$arguments; argv=$argv; profile=$profile;
                shape_ok=($argv.Count -eq 2 -and $argv[0] -ceq '--gx-shell-action=profile' -and $null -ne $profile) })
            $index = $text.IndexOf($marker, $index + $marker.Length)
        }
    }
    return @{ tasks=$tasks.ToArray(); titles_present=$present.ToArray() }
}

function Get-JumpListTitles {
    $titles = @(Get-JumpListProfiles (Get-JumpListMarkDir) | ForEach-Object { $_.name })
    return $titles + @('Command Prompt', 'Windows PowerShell', (-join @([char]0x547D, [char]0x4EE4, [char]0x63D0, [char]0x793A, [char]0x7B26)))
}

function Get-JumpListFiles {
    $dir = Join-Path $env:APPDATA 'Microsoft\Windows\Recent\CustomDestinations'
    $facts = [ordered]@{ dir=$dir; exists=(Test-Path -LiteralPath $dir); dir_sddl=$null; files=@() }
    if (-not $facts.exists) { return $facts }
    $facts.dir_sddl = (Get-Acl -LiteralPath $dir).Sddl
    $titles = Get-JumpListTitles
    $facts.files = @(Get-ChildItem -LiteralPath $dir -File -Force | Sort-Object Name | ForEach-Object {
        $item = [ordered]@{ name=$_.Name; size=$_.Length; modified_utc=$_.LastWriteTimeUtc.ToString('o'); sha256=$null; gx=$false }
        if ($_.Length -le 4194304) {
            $bytes = [IO.File]::ReadAllBytes($_.FullName)
            $item.sha256 = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
            $parsed = Read-JumpListTasks $bytes $titles
            if ($parsed.tasks.Count -gt 0) { $item.gx = $true; $item.tasks = $parsed.tasks; $item.titles_present = $parsed.titles_present }
        }
        $item })
    return $facts
}

function Get-JumpListLogLines {
    $lines = @()
    foreach ($name in @('ghostty.log.1', 'ghostty.log')) {
        $path = Join-Path $env:LOCALAPPDATA ('ghostty\logs\' + $name)
        if (Test-Path -LiteralPath $path) { $lines += @(Get-Content -LiteralPath $path | Select-String -SimpleMatch 'JumpList' | ForEach-Object Line) }
    }
    return @($lines | Select-Object -Last 40)
}

function Test-JumpListState($JumpLists) {
    $gx = @($JumpLists.files | Where-Object { $_.gx })
    $acl = Read-Record 'jumplist-acl'
    if ($acl -and -not $acl.restored) {
        # Commit denied: the list committed before the denial must be byte-identical.
        $changed = @($acl.gx_files | Where-Object { $name = $_.name; $sha = $_.sha256; -not @($gx | Where-Object { $_.name -ceq $name -and $_.sha256 -ceq $sha }) })
        return [ordered]@{ mode='commit-denied'; unchanged=($changed.Count -eq 0); changed=@($changed | ForEach-Object { $_.name });
            verdict=$(if ($changed.Count -eq 0) { 'PASS' } else { 'FAIL' }) }
    }
    $config = Read-Record 'jumplist-user-config'
    if (-not $config -or $config.restored -or -not $config.PSObject.Properties['profiles']) { return [ordered]@{ mode='no-fixture-config'; verdict='OBSERVED' } }
    $expected = @($config.profiles | ForEach-Object { 'custom:' + $_.name })
    $all = @(Get-JumpListProfiles (Get-JumpListMarkDir) | ForEach-Object { 'custom:' + $_.name })
    $listed = @($gx | ForEach-Object { $_.tasks } | ForEach-Object { $_.profile } | Where-Object { $_ } | Select-Object -Unique)
    $missing = @($expected | Where-Object { $listed -cnotcontains $_ })
    $unexpected = @($listed | Where-Object { $all -ccontains $_ -and $expected -cnotcontains $_ })
    $shape = @($gx | ForEach-Object { $_.tasks } | Where-Object { -not $_.shape_ok }).Count -eq 0
    return [ordered]@{ mode='config'; set=$config.set; language=$config.language; expected=$expected; listed=$listed; missing=$missing;
        unexpected=$unexpected; shape_ok=$shape; verdict=$(if ($missing.Count -eq 0 -and $unexpected.Count -eq 0 -and $shape -and $gx.Count -gt 0) { 'PASS' } else { 'FAIL' }) }
}

function Set-JumpListCommitDenied {
    $existing = Read-Record 'jumplist-acl'
    if ($existing -and -not $existing.restored) { throw 'Commits are already denied in this run; run allow-commit first.' }
    $lists = Get-JumpListFiles
    $gx = @($lists.files | Where-Object { $_.gx })
    if (-not $lists.exists -or $gx.Count -eq 0) { throw 'No Ghostty GX jump list is committed yet; publish one before denying commits.' }
    $targets = @($lists.dir) + @($gx | ForEach-Object { Join-Path $lists.dir $_.name })
    $entries = @($targets | ForEach-Object { [ordered]@{ path=$_; sddl=(Get-Acl -LiteralPath $_).Sddl } })
    Save-Record 'jumplist-acl' ([ordered]@{ entries=$entries; gx_files=@($gx | ForEach-Object { [ordered]@{ name=$_.name; sha256=$_.sha256 } });
        denied_utc=[DateTime]::UtcNow.ToString('o'); restored=$false }) | Out-Null
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach ($entry in $entries) {
        $rights = if ($entry.path -ceq $lists.dir) { [Security.AccessControl.FileSystemRights]'CreateFiles, AppendData, DeleteSubdirectoriesAndFiles' }
                  else { [Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete' }
        $acl = Get-Acl -LiteralPath $entry.path
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user, $rights, [Security.AccessControl.AccessControlType]::Deny))
        Set-Acl -LiteralPath $entry.path -AclObject $acl
    }
    return @($entries | ForEach-Object { [ordered]@{ path=$_.path; sddl_before=$_.sddl; sddl_now=(Get-Acl -LiteralPath $_.path).Sddl } })
}

function Restore-JumpListAcl {
    $record = Read-Record 'jumplist-acl'
    if ($null -eq $record) { return [ordered]@{ restored=$true; note='commits were never denied' } }
    if ($record.restored) { return [ordered]@{ restored=$true; note='already restored' } }
    $items = @(foreach ($entry in @($record.entries)) {
        $item = [ordered]@{ path=$entry.path; ok=$false; note=$null }
        if (-not (Test-Path -LiteralPath $entry.path)) { $item.note = 'path no longer exists' }
        else {
            $acl = Get-Acl -LiteralPath $entry.path
            $acl.SetSecurityDescriptorSddlForm($entry.sddl)
            Set-Acl -LiteralPath $entry.path -AclObject $acl
            $item.ok = (Get-Acl -LiteralPath $entry.path).Sddl -ceq $entry.sddl
        }
        $item })
    $ok = @($items | Where-Object { -not $_.ok }).Count -eq 0
    Set-RecordField $record 'restored' $ok
    Set-RecordField $record 'restore' $items
    Save-Record 'jumplist-acl' $record | Out-Null
    return [ordered]@{ restored=$ok; entries=$items }
}

function Get-JumpListAppRecords {
    $dir = Join-Path $script:RunRoot 'records'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter 'jumplist-*.json' | ForEach-Object { Read-JsonFile $_.FullName } |
        Where-Object { $_.PSObject.Properties['pid'] -and $_.PSObject.Properties['record_name'] })
}

function Close-JumpListApp($Record) {
    $close = Close-OwnedApp $Record
    Set-RecordField $Record 'close' $close
    $Record.status = if ($close.closed_normally -or $close.already_exited) { 'CLOSED' } else { 'CLOSE_FAILED' }
    Save-Record $Record.record_name $Record | Out-Null
    return $close
}

function Invoke-JumpListMatrix {
    # config: write a profile set to the real configuration (adopting it once);
    # snapshot: committed lists read from CustomDestinations; start: the
    # installed app in the real environment; observe: what a shell (JumpList)
    # launch produced; deny-commit/allow-commit: make CommitList fail by ACL,
    # then restore the exact descriptors; portable: a copied payload must not
    # publish or register; stop: close owned/adopted apps; restore: config+ACL.
    $step = Assert-Action @('config','snapshot','start','observe','deny-commit','allow-commit','portable','stop','restore') 'snapshot'
    $installedExe = Join-Path $script:AppDir 'ghostty.exe'
    switch ($step) {
        'config' {
            $record = Adopt-UserConfig
            $markDir = Get-JumpListMarkDir
            Assert-NoReparse $markDir
            [IO.Directory]::CreateDirectory($markDir) | Out-Null
            $markScript = (@('@echo off', 'title GX_JL_P6', 'set "GXARG=%~1"',
                '>>"%~dp0gx-jl-marker.txt" echo GX_JL_PATH_OK tail=[%GXARG:~-1%] at %DATE% %TIME%') -join "`r`n") + "`r`n"
            [IO.File]::WriteAllText((Join-Path $markDir 'gx-jl-mark.cmd'), $markScript, [Text.Encoding]::ASCII)
            $config = New-JumpListConfig $JumpListSet $markDir
            $path = (Get-UserConfigFiles)[0]
            if ((Test-Path -LiteralPath $path) -and -not (Test-FixtureOwnedFile $path)) { throw "Refusing to overwrite ${path}: it is not this fixture's file." }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
            [IO.File]::WriteAllBytes($path, (Get-Utf8Bytes $config.text))
            Set-RecordField $record 'set' $JumpListSet
            Set-RecordField $record 'language' $config.language
            Set-RecordField $record 'profiles' @($config.profiles | ForEach-Object { [ordered]@{ key=$_.key; name=$_.name; command=$_.command } })
            Set-RecordField $record 'config_sha256' (Get-Sha256 $path)
            Set-RecordField $record 'written_utc' ([DateTime]::UtcNow.ToString('o'))
            Save-Record 'jumplist-user-config' $record | Out-Null
            $script:ExportExtra.Add($path)
            return [ordered]@{ set=$JumpListSet; language=$config.language; config=$path; config_sha256=$record.config_sha256;
                profiles=@($config.profiles | ForEach-Object { [ordered]@{ key=$_.key; id=('custom:' + $_.name) } }); mark_dir=$markDir;
                next='reload a running app (ctrl+alt+shift+r) or start it, then snapshot' }
        }
        'snapshot' {
            $lists = Get-JumpListFiles
            $check = Test-JumpListState $lists
            return [ordered]@{ jump_lists=$lists; check=$check; log=@(Get-JumpListLogLines); fixture_verdict=$check.verdict; visual_review='PENDING' }
        }
        'start' {
            $config = Read-Record 'jumplist-user-config'
            if (-not $config -or $config.restored) { throw 'Write the fixture configuration first (-Action config).' }
            Assert-Hash $installedExe $AppSha256
            $name = 'jumplist-' + $Label
            $previous = Read-Record $name
            if ($previous -and (Get-OwnedProcess $previous)) { throw "Label $Label still runs." }
            $started = Start-OwnedApp -Exe $installedExe -Private $null -RealProfile -Arguments @()
            $process = $started.process
            $record = New-AppRecord $process $installedExe 'INSTALLED' $null $null $null @()
            $record.record_name = $name
            try { $record.main_window = Wait-AppWindow $process 45; $record.status = 'RUNNING' }
            catch { $record.status = 'START_FAILED'; $record.error = $_.Exception.Message; throw }
            finally { Save-Record $name $record | Out-Null; $process.Dispose() }
            return [ordered]@{ record=$record; fixture_verdict='RUNNING' }
        }
        'observe' {
            if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }
            $apps = @(Get-GuestApps | Where-Object { $_.path -and $_.path -ieq $installedExe })
            $seen = @(foreach ($app in $apps) {
                $name = 'jumplist-pid-' + $app.pid
                $known = @(Get-JumpListAppRecords | Where-Object { [int]$_.pid -eq $app.pid })
                if ($known.Count -eq 0) {
                    # Adopt the shell-launched process so stop can close exactly this life.
                    $process = Get-Process -Id $app.pid -ErrorAction SilentlyContinue
                    if ($process) {
                        Save-Record $name ([ordered]@{ phase=$Phase; label=('pid-' + $app.pid); record_name=$name; status='RUNNING'; adopted=$true;
                            pid=$app.pid; birth_filetime=$process.StartTime.ToFileTimeUtc(); exe=$installedExe; parent=$app.parent;
                            command_line=$app.command_line; adopted_utc=[DateTime]::UtcNow.ToString('o') }) | Out-Null
                        $process.Dispose()
                    }
                }
                [ordered]@{ pid=$app.pid; parent=$app.parent; created=$app.created; command_line=$app.command_line;
                    windows=@([GxVmWindows]::TopLevel($app.pid) | Where-Object { $_['class'] -ceq 'GhosttyWindow' } | ForEach-Object { [ordered]@{ hwnd=$_['hwnd']; title=$_['title']; visible=$_['visible'] } }) }
            })
            $markerFile = Join-Path (Get-JumpListMarkDir) 'gx-jl-marker.txt'
            $markers = if (Test-Path -LiteralPath $markerFile) { @([IO.File]::ReadAllLines($markerFile, [Text.Encoding]::Default)) } else { @() }
            $result = [ordered]@{ expect=$ExpectProfile; apps=$seen; markers=$markers; jump_lists=(Get-JumpListFiles); log=@(Get-JumpListLogLines) }
            if (-not $ExpectProfile -or $ExpectProfile -ceq 'none') { $result.fixture_verdict = 'OBSERVED'; return $result }
            $want = 'GX_JL_' + $ExpectProfile.ToUpperInvariant()
            $titled = @($seen | ForEach-Object { $_.windows } | Where-Object { $_.title -and $_.title.Contains($want) })
            $markerOk = ($ExpectProfile -cne 'p6') -or (@($markers | Where-Object { $_ -match '^GX_JL_PATH_OK tail=\[\\\]' }).Count -gt 0)
            $result.window_with_title = $titled
            $result.marker_ok = $markerOk
            $result.fixture_verdict = if ($titled.Count -gt 0 -and $markerOk) { 'PASS' } else { 'FAIL' }
            $result.fixture_reason = if ($titled.Count -eq 0) { "no Ghostty window titled $want" } elseif (-not $markerOk) { 'p6 marker missing or trailing backslash lost' } else { $null }
            return $result
        }
        'deny-commit' { return [ordered]@{ denied=@(Set-JumpListCommitDenied); next='change the profile set (config), reload the app, then snapshot' } }
        'allow-commit' {
            $script:Restore = [ordered]@{ acl=(Restore-JumpListAcl) }
            return [ordered]@{ restore=$script:Restore; fixture_verdict=$(if ($script:Restore.acl.restored) { 'PASS' } else { 'FAIL' }) }
        }
        'portable' {
            $config = Read-Record 'jumplist-user-config'
            if (-not $config -or $config.restored) { throw 'Write the fixture configuration first (-Action config).' }
            $copy = Copy-PortableApp (Join-Path $script:RunRoot ('portable-jl-' + $Label))
            $listsBefore = Get-JumpListFiles
            $registryBefore = Registry-Snapshot
            $started = Start-OwnedApp -Exe $copy.exe -Private $null -RealProfile -Arguments @()
            $process = $started.process
            $name = 'jumplist-portable-' + $Label
            $record = New-AppRecord $process $copy.exe 'PORTABLE_COPY' $null $null $null @()
            $record.record_name = $name
            $record.aumid = $copy.aumid
            try { $record.main_window = Wait-AppWindow $process 45; $record.status = 'RUNNING' }
            finally { Save-Record $name $record | Out-Null; $process.Dispose() }
            Start-Sleep -Seconds 8
            $listsAfter = Get-JumpListFiles
            $registryAfter = Registry-Snapshot
            $close = Close-JumpListApp (Read-Record $name)
            $before = @($listsBefore.files | Where-Object { $_.gx } | ForEach-Object { $_.name + '=' + $_.sha256 }) -join ';'
            $after = @($listsAfter.files | Where-Object { $_.gx } | ForEach-Object { $_.name + '=' + $_.sha256 }) -join ';'
            $registryUnchanged = (Json-Canonical $registryBefore) -ceq (Json-Canonical $registryAfter)
            if ($close.closed_normally) { Remove-Item -LiteralPath (Split-Path -Parent $copy.exe) -Recurse -Force }
            $ok = ($before -ceq $after) -and $registryUnchanged -and $close.closed_normally
            return [ordered]@{ copy=$copy; jump_lists_unchanged=($before -ceq $after); registry_unchanged=$registryUnchanged; close=$close;
                jump_lists_before=$listsBefore; jump_lists_after=$listsAfter; fixture_verdict=$(if ($ok) { 'PASS' } else { 'FAIL' });
                fixture_reason=$(if ($ok) { $null } else { 'the portable copy changed a jump list or the registration, or did not close normally' }) }
        }
        'stop' {
            $closes = @(Get-JumpListAppRecords | Where-Object { $_.status -ceq 'RUNNING' } | ForEach-Object { Close-JumpListApp $_ })
            $bad = @($closes | Where-Object { -not $_.closed_normally -and -not $_.already_exited })
            return [ordered]@{ closes=$closes; fixture_verdict=$(if ($bad.Count -eq 0) { 'PASS' } else { 'FAIL' }) }
        }
        'restore' {
            $alive = @(Get-JumpListAppRecords | Where-Object { $_.status -ceq 'RUNNING' -and (Get-OwnedProcess $_) })
            if ($alive.Count -gt 0) { throw 'Stop the owned jump list apps before restoring the configuration.' }
            $script:Restore = [ordered]@{ config=(Restore-UserConfig); acl=(Restore-JumpListAcl) }
            $ok = $script:Restore.config.restored -and $script:Restore.acl.restored
            return [ordered]@{ restore=$script:Restore; jump_lists=(Get-JumpListFiles); fixture_verdict=$(if ($ok) { 'PASS' } else { 'FAIL' });
                note='Unpin the taskbar button by hand if it was pinned for the cold start.' }
        }
    }
}

# ---- narrator: Narrator for screenshots of what a screen reader gets -------

$script:NarratorKeys = [ordered]@{ 'narrator-settings'='Software\Microsoft\Narrator';
    'narrator-accessibility'='Software\Microsoft\Windows NT\CurrentVersion\Accessibility' }

$script:ScreenReaderSource = @'
using System;
using System.Runtime.InteropServices;
public static class GxVmScreenReader {
    [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")] static extern bool GetParam(uint action, uint param, out int value, uint flags);
    [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")] static extern bool SetParam(uint action, uint param, IntPtr value, uint flags);
    // SPI_GETSCREENREADER / SPI_SETSCREENREADER; the app picks native dialogs while it is set.
    public static bool Get() { int value; if (!GetParam(0x0046, 0, out value, 0)) throw new Exception("SPI_GETSCREENREADER failed: " + Marshal.GetLastWin32Error()); return value != 0; }
    public static void Set(bool on) { if (!SetParam(0x0047, on ? 1u : 0u, IntPtr.Zero, 0x2)) throw new Exception("SPI_SETSCREENREADER failed: " + Marshal.GetLastWin32Error()); }
}
'@

function Get-ScreenReaderFlag {
    if (-not ('GxVmScreenReader' -as [type])) { Add-Type -TypeDefinition $script:ScreenReaderSource -Language CSharp }
    return [GxVmScreenReader]::Get()
}

function Get-NarratorProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'Narrator.exe'" | ForEach-Object {
        [ordered]@{ pid=[int]$_.ProcessId; parent=[int]$_.ParentProcessId; session=[int]$_.SessionId; path=$_.ExecutablePath;
            created=$(if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') } else { $null }) } })
}

function Invoke-Narrator {
    # start: back up the Narrator and Accessibility keys, start Narrator.exe and
    # own exactly the Narrator processes created by that start; developer mode
    # (Narrator+Shift+F12) and turning Narrator off (Ctrl+Win+Enter) are the
    # coordinator's keyboard input. stop: wait for that exit (close, then end
    # only the owned processes as a recorded failure), restore keys and flag.
    $step = Assert-Action @('start','status','stop') 'status'
    $record = Read-Record 'narrator'
    switch ($step) {
        'start' {
            if ($record -and $record.status -ceq 'RUNNING') { throw 'This run already started Narrator; stop it first.' }
            $foreign = @(Get-NarratorProcesses)
            if ($foreign.Count -gt 0) { throw ('Narrator already runs (pid ' + (@($foreign | ForEach-Object { $_.pid }) -join ',') + '); turn it off first.') }
            $backups = [ordered]@{}
            foreach ($entry in $script:NarratorKeys.GetEnumerator()) { $backups[$entry.Key] = (Backup-HkcuKey $entry.Key $entry.Value).backed_up_utc }
            $flagBefore = Get-ScreenReaderFlag
            $exe = Join-Path $env:SystemRoot 'System32\Narrator.exe'
            $since = [DateTime]::UtcNow.AddSeconds(-1)
            $launcher = Start-Process -FilePath $exe -PassThru
            $owned = @()
            $clock = [Diagnostics.Stopwatch]::StartNew()
            do {
                Start-Sleep -Milliseconds 500
                $owned = @(Get-NarratorProcesses | Where-Object { $_.created -and [DateTime]::Parse($_.created).ToUniversalTime() -ge $since })
            } while ($clock.Elapsed.TotalSeconds -lt 20 -and ($owned.Count -eq 0 -or -not (Get-ScreenReaderFlag)))
            $owned = @($owned | ForEach-Object {
                $process = Get-Process -Id $_.pid -ErrorAction SilentlyContinue
                if ($process) { $_.birth_filetime = $process.StartTime.ToFileTimeUtc(); $_.exe = $process.Path; $process.Dispose() }
                $_ })
            $record = [ordered]@{ status='RUNNING'; started_utc=$since.AddSeconds(1).ToString('o'); launcher_pid=$launcher.Id; owned=$owned;
                screen_reader_before=$flagBefore; screen_reader_after_start=(Get-ScreenReaderFlag); backups=$backups }
            $launcher.Dispose()
            Save-Record 'narrator' $record | Out-Null
            Write-ExportMarker 'narrator-running' @{ owned=@($owned | ForEach-Object { $_.pid }); utc=[DateTime]::UtcNow.ToString('o') }
            return [ordered]@{ record=$record; fixture_verdict=$(if ($owned.Count -gt 0) { 'RUNNING' } else { 'FAIL' });
                fixture_reason=$(if ($owned.Count -gt 0) { $null } else { 'no Narrator process appeared within 20 seconds' });
                next='developer mode: Narrator+Shift+F12; turn Narrator off with Ctrl+Win+Enter, then -Action stop' }
        }
        'status' {
            return [ordered]@{ record=$record; narrator_processes=@(Get-NarratorProcesses); screen_reader=(Get-ScreenReaderFlag);
                foreground=$(if (-not ('GxVmWindows' -as [type])) { Add-Type -TypeDefinition $script:WindowSource -Language CSharp }; [GxVmWindows]::Foreground()) }
        }
        'stop' {
            if ($null -eq $record) { throw 'This run did not start Narrator.' }
            $outcomes = @(foreach ($owned in @($record.owned)) {
                $item = [ordered]@{ pid=$owned.pid; exited_by_itself=$false; close_main_window=$null; killed=$false; exit_code=$null; unverified_alive=$false }
                $process = if ($owned.PSObject.Properties['birth_filetime']) { Get-OwnedProcess ([pscustomobject]@{ pid=$owned.pid; birth_filetime=$owned.birth_filetime; exe=$owned.exe }) } else { $null }
                if ($null -eq $process -and -not $owned.PSObject.Properties['birth_filetime'] -and (Get-Process -Id ([int]$owned.pid) -ErrorAction SilentlyContinue)) {
                    # Its creation time was not readable at start, so this PID is not provably ours: never touch it.
                    $item.unverified_alive = $true
                } elseif ($null -eq $process) { $item.exited_by_itself = $true }
                else {
                    try {
                        $item.exited_by_itself = $process.WaitForExit($CloseWaitSeconds * 1000)
                        if (-not $item.exited_by_itself) {
                            $item.close_main_window = $process.CloseMainWindow()
                            if (-not $process.WaitForExit(5000)) { $process.Kill(); $null = $process.WaitForExit(5000); $item.killed = $true }
                        }
                        if ($process.HasExited) { $item.exit_code = $process.ExitCode }
                    } finally { $process.Dispose() }
                }
                $item })
            $flag = [ordered]@{ before=$record.screen_reader_before; at_stop=(Get-ScreenReaderFlag); reset=$false }
            if (-not $record.screen_reader_before -and $flag.at_stop -and @(Get-NarratorProcesses).Count -eq 0) {
                # Narrator's own flag outlived it (for example after a forced end): put back the recorded value.
                [GxVmScreenReader]::Set($false)
                $flag.reset = $true
            }
            $flag.after = Get-ScreenReaderFlag
            $restores = @(foreach ($name in $script:NarratorKeys.Keys) { Restore-HkcuKey $name })
            $script:Restore = [ordered]@{ registry=$restores; screen_reader=$flag }
            $record.status = 'STOPPED'
            Set-RecordField $record 'stop' ([ordered]@{ outcomes=$outcomes; restore=$script:Restore; utc=[DateTime]::UtcNow.ToString('o') })
            Save-Record 'narrator' $record | Out-Null
            $forced = @($outcomes | Where-Object { $_.killed -or $_.unverified_alive })
            $restored = @($restores | Where-Object { -not $_.restored }).Count -eq 0 -and $flag.after -eq [bool]$record.screen_reader_before
            return [ordered]@{ outcomes=$outcomes; restore=$script:Restore; fixture_verdict=$(if ($forced.Count -eq 0 -and $restored) { 'PASS' } else { 'FAIL' });
                fixture_reason=$(if ($forced.Count -gt 0) { 'Narrator did not exit on its own or on close (ended, or left running when not provably owned)' } elseif (-not $restored) { 'settings were not restored' } else { $null }) }
        }
    }
}

# This must remain before all account/registry mutations and directory creation.
$identity = Assert-GxVm $Manifest
if ($Scope -eq 'Machine' -and -not (Test-Elevated)) { throw 'Machine-scope fixtures require elevation inside the verified VM.' }
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:RunRoot = Join-Path $env:LOCALAPPDATA ('GXVMValidation\Runs\' + $RunId)
$script:AppBase = if ($Scope -eq 'Machine') { Join-Path $env:ProgramFiles ('GXVMValidation\' + $RunId) } else { Join-Path $env:LOCALAPPDATA ('GXVMValidation\Apps\' + $RunId) }
$script:AppDir = $script:AppBase
if (Get-PathPresetName $PathPreset) { $script:AppDir = Join-Path $script:AppBase (Get-PathPresetName $PathPreset) }
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
    # UTF-8: state values (such as app_dir) may hold non-ASCII text.
    $script:State = Read-JsonFile $statePath
    # A run installed below a path preset keeps that AppDir without repeating -PathPreset.
    if ($PathPreset -ceq 'none' -and ([string]$script:State.app_dir).StartsWith($script:AppBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $script:AppDir = [string]$script:State.app_dir
        Assert-NoReparse $script:AppDir
    }
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
    if ($Phase -in $script:R6Phases) { $report.before = Get-PhaseState 'before' }
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
        'run-config' { $report.result = Invoke-RunConfig }
        'osc52' { $report.result = Invoke-Osc52 }
        'toast-matrix' { $report.result = Invoke-ToastMatrix }
        'jumplist-matrix' { $report.result = Invoke-JumpListMatrix }
        'narrator' { $report.result = Invoke-Narrator }
    }
    # r6 phases may report a fixture verdict without throwing, so their evidence stays intact.
    $verdict = $null
    if ($report.result -is [System.Collections.IDictionary] -and $report.result.Contains('fixture_verdict')) { $verdict = $report.result['fixture_verdict'] }
    $report.status = if ($verdict -ceq 'FAIL') { 'FAIL' } elseif ($Rehearsal) { 'REHEARSAL_NOT_FINAL' } else { 'PASS_NATIVE_SCOPED' }
} catch {
    $report.status = 'FAIL'
    $report.result = @{ reason=$_.Exception.Message; position=$_.InvocationInfo.PositionMessage }
} finally {
    if ($Phase -in $script:R6Phases) {
        try { $report.after = Get-PhaseState 'after' } catch { $report.after = @{ error=$_.Exception.Message } }
        $report.restore = $script:Restore
    }
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
