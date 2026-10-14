; Ghostty GX installer (fork file, not used by upstream Ghostty).
; scripts/gx_windows_package.py stages the payload and passes every define below:
;   GxVersion         version string VS (<build.zig.zon X.Y.Z>-gx.<fork X.Y.Z>)
;   GxNumericVersion  X.Y.Z.0 of the Ghostty product version, for the version resource
;   GxApp             portable directory without fonts\, installed into {app}
;   GxFonts           generated [Files] entries that install the bundled fonts into {autofonts}
;                     (the user's fonts, or all users' fonts in an all-users installation)
;   GxIcon, GxOutput, GxFilename
; Uninstalling removes only what this installer wrote: the user's Ghostty configuration is kept,
; and fonts stay installed (uninsneveruninstall) because other GX programs share them.
#if VER < EncodeVer(7, 1, 0) || VER >= EncodeVer(8, 0, 0)
  #error Inno Setup 7.1 is required (python scripts/setup_env.py --innosetup)
#endif
#ifndef GxVersion
  #error GxVersion is required
#endif
#ifndef GxNumericVersion
  #error GxNumericVersion is required
#endif
#ifndef GxApp
  #error GxApp is required
#endif
#ifndef GxFonts
  #error GxFonts is required
#endif
#ifndef GxIcon
  #error GxIcon is required
#endif
#ifndef GxOutput
  #error GxOutput is required
#endif
#ifndef GxFilename
  #error GxFilename is required
#endif
; Kept in sync with shell/Identity.zig by InstallerScriptTests.
#define GxAumid "gx0404.GhosttyGX"
#define GxToastClsid "978ab84b-3cac-4593-95d5-2e04d68eed4f"
#define GxOpenHereEn "Open Ghostty GX here"
#define GxOpenHereZh "在此处打开 Ghostty GX"

[Setup]
AppId={{49341A18-5070-425E-83B9-79E184242ACF}
AppName=Ghostty GX
AppVersion={#GxVersion}
AppVerName=Ghostty GX {#GxVersion}
AppPublisher=gx0404
AppPublisherURL=https://github.com/gx0404/gx_ghostty
AppSupportURL=https://github.com/gx0404/gx_ghostty/issues
AppUpdatesURL=https://github.com/gx0404/gx_ghostty/releases
AppComments=Ghostty GX is an unofficial fork of Ghostty maintained by gx0404. It is not affiliated with or endorsed by the Ghostty project.
VersionInfoVersion={#GxNumericVersion}
VersionInfoProductVersion={#GxNumericVersion}
VersionInfoTextVersion={#GxVersion}
VersionInfoProductTextVersion={#GxVersion}
VersionInfoProductName=Ghostty GX
VersionInfoDescription=Ghostty GX Setup (unofficial fork of Ghostty)
VersionInfoCompany=gx0404
DefaultDirName={autopf}\Ghostty GX
DisableWelcomePage=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#GxOutput}
OutputBaseFilename={#GxFilename}
SetupIconFile={#GxIcon}
UninstallDisplayIcon={app}\ghostty.exe
UninstallDisplayName=Ghostty GX
; Do not inherit legacy uninsdeletekey actions when upgrading. Files removed
; from an older manifest may remain; never guess which old files are safe to delete.
UninstallLogMode=overwrite
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=auto
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
chinesesimplified.WelcomeLabel2=现在将安装 [name/ver] 到您的电脑中。%n%nGhostty GX 是 Ghostty 的非官方分支，由 gx0404 维护，与 Ghostty 团队无关，未获其认可或背书。%n%n推荐您在继续安装前关闭所有其它应用程序。
english.WelcomeLabel2=This will install [name/ver] on your computer.%n%nGhostty GX is an unofficial fork of Ghostty maintained by gx0404. It is not affiliated with or endorsed by the Ghostty project.%n%nIt is recommended that you close all other applications before continuing.

[CustomMessages]
chinesesimplified.IntegrationGroup=系统集成：
english.IntegrationGroup=System integration:
chinesesimplified.ContextMenuTask=在资源管理器右键菜单中添加“在此处打开 Ghostty GX”
english.ContextMenuTask=Add "Open Ghostty GX here" to the Explorer context menu
chinesesimplified.OpenHere={#GxOpenHereZh}
english.OpenHere={#GxOpenHereEn}
chinesesimplified.ShellIdentityInUse=另一个安装目录已占用 Ghostty GX 的通知身份。请先卸载该安装，再重试。
english.ShellIdentityInUse=Another installation owns the Ghostty GX notification identity. Uninstall that installation before retrying.
chinesesimplified.IntegrationInUse=已有 Windows 集成项不属于此安装目录，安装已停止。请先处理冲突后重试。
english.IntegrationInUse=Existing Windows integration entries do not belong to this installation. Resolve the conflicting entries before retrying.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "contextmenu"; Description: "{cm:ContextMenuTask}"; GroupDescription: "{cm:IntegrationGroup}"

[Files]
Source: "{#GxApp}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#include GxFonts

[Icons]
Name: "{autoprograms}\Ghostty GX"; Filename: "{app}\ghostty.exe"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "{#GxAumid}"; AppUserModelToastActivatorCLSID: "{#GxToastClsid}"
Name: "{autodesktop}\Ghostty GX"; Filename: "{app}\ghostty.exe"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "{#GxAumid}"; AppUserModelToastActivatorCLSID: "{#GxToastClsid}"; Tasks: desktopicon

[Registry]
; No automatic uninstall deletion: the guarded code below removes only values
; that still belong to this exact installation. Portable startup never writes these.
Root: HKA; Subkey: "Software\Classes\AppUserModelId\{#GxAumid}"; ValueType: string; ValueName: "GxExecutable"; ValueData: "{app}\ghostty.exe"
Root: HKA; Subkey: "Software\Classes\AppUserModelId\{#GxAumid}"; ValueType: string; ValueName: "CustomActivator"; ValueData: "{{{#GxToastClsid}}"
Root: HKA; Subkey: "Software\Classes\AppUserModelId\{#GxAumid}"; ValueType: string; ValueName: "DisplayName"; ValueData: "Ghostty GX"
Root: HKA; Subkey: "Software\Classes\AppUserModelId\{#GxAumid}"; ValueType: string; ValueName: "IconUri"; ValueData: "{app}\ghostty.exe"
Root: HKA; Subkey: "Software\Classes\CLSID\{{{#GxToastClsid}}\LocalServer32"; ValueType: string; ValueData: """{app}\ghostty.exe"" --gx-shell-action=toast-server"
; For a drive root %V is "C:\", whose closing \" the command-line rules read as an escaped quote,
; so ghostty.exe receives --working-directory=C:" and restores the backslash
; (src/apprt/win32/App.zig::restoreTrailingBackslash). "%V\." would also work but leaves
; non-canonical paths such as C:\Users\me\. as the initial working directory.
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\App Paths\ghostty.exe"; ValueType: string; ValueData: "{app}\ghostty.exe"
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\App Paths\ghostty.exe"; ValueType: string; ValueName: "Path"; ValueData: "{app}"
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\GhosttyGX"; ValueType: string; ValueData: "{cm:OpenHere}"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\GhosttyGX"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\ghostty.exe"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\GhosttyGX\command"; ValueType: string; ValueData: """{app}\ghostty.exe"" --working-directory=""%V"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\GhosttyGX"; ValueType: string; ValueData: "{cm:OpenHere}"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\GhosttyGX"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\ghostty.exe"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\GhosttyGX\command"; ValueType: string; ValueData: """{app}\ghostty.exe"" --working-directory=""%V"""; Tasks: contextmenu

[Run]
Filename: "{app}\ghostty.exe"; Description: "{cm:LaunchProgram,Ghostty GX}"; WorkingDir: "{%USERPROFILE}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
const
  GxAumidKey = 'Software\Classes\AppUserModelId\{#GxAumid}';
  GxClsidKey = 'Software\Classes\CLSID\{{#GxToastClsid}}';
  GxActivator = '{{#GxToastClsid}}';
  GxAppPathKey = 'Software\Microsoft\Windows\CurrentVersion\App Paths\ghostty.exe';
  GxBackgroundKey = 'Software\Classes\Directory\Background\shell\GhosttyGX';
  GxDirectoryKey = 'Software\Classes\Directory\shell\GhosttyGX';

function GxExpectedServer: String;
begin
  Result := '"' + ExpandConstant('{app}\ghostty.exe') + '" --gx-shell-action=toast-server';
end;

function GxRegisteredValueMatches(const Key, Name, Expected: String): Boolean;
var
  Value: String;
begin
  Result := RegQueryStringValue(HKA, Key, Name, Value) and
    (CompareText(Value, Expected) = 0);
end;

function GxOwnsShellRegistration: Boolean;
begin
  Result := GxRegisteredValueMatches(GxAumidKey, 'GxExecutable', ExpandConstant('{app}\ghostty.exe')) and
    GxRegisteredValueMatches(GxAumidKey, 'CustomActivator', GxActivator) and
    GxRegisteredValueMatches(GxClsidKey + '\LocalServer32', '', GxExpectedServer);
end;

{ An unexpected value or subkey makes the entire integration group foreign.
  Enumerate first; do not recursively delete or silently overwrite additions. }
function GxHasExactValues(const Key, OtherName: String): Boolean;
var
  Names: TArrayOfString;
  I, ExpectedCount: Integer;
  HasDefault, HasOther: Boolean;
begin
  Result := False;
  if not RegGetValueNames(HKA, Key, Names) then Exit;
  ExpectedCount := 1;
  if OtherName <> '' then ExpectedCount := 2;
  if GetArrayLength(Names) <> ExpectedCount then Exit;
  HasDefault := False;
  HasOther := OtherName = '';
  for I := 0 to GetArrayLength(Names) - 1 do begin
    if Names[I] = '' then
      HasDefault := True
    else if (OtherName <> '') and (CompareText(Names[I], OtherName) = 0) then
      HasOther := True
    else
      Exit;
  end;
  Result := HasDefault and HasOther;
end;

function GxHasExactSubkeys(const Key, OnlyName: String): Boolean;
var
  Names: TArrayOfString;
begin
  Result := False;
  if not RegGetSubkeyNames(HKA, Key, Names) then Exit;
  if OnlyName = '' then begin
    Result := GetArrayLength(Names) = 0;
    Exit;
  end;
  if GetArrayLength(Names) <> 1 then Exit;
  Result := CompareText(Names[0], OnlyName) = 0;
end;

function GxExpectedIcon: String;
begin
  Result := '"' + ExpandConstant('{app}\ghostty.exe') + '",0';
end;

function GxExpectedOpenHere: String;
begin
  Result := '"' + ExpandConstant('{app}\ghostty.exe') + '" --working-directory="%V"';
end;

function GxOwnsAppPath: Boolean;
begin
  Result := GxHasExactValues(GxAppPathKey, 'Path') and
    GxHasExactSubkeys(GxAppPathKey, '') and
    GxRegisteredValueMatches(GxAppPathKey, '', ExpandConstant('{app}\ghostty.exe')) and
    GxRegisteredValueMatches(GxAppPathKey, 'Path', ExpandConstant('{app}'));
end;

function GxOwnsContextMenu(const Key: String): Boolean;
begin
  { Accept either installed language when upgrading in the other language. }
  Result := GxHasExactValues(Key, 'Icon') and
    GxHasExactSubkeys(Key, 'command') and
    GxHasExactValues(Key + '\command', '') and
    GxHasExactSubkeys(Key + '\command', '') and
    GxRegisteredValueMatches(Key, 'Icon', GxExpectedIcon) and
    GxRegisteredValueMatches(Key + '\command', '', GxExpectedOpenHere) and
    (GxRegisteredValueMatches(Key, '', '{#GxOpenHereEn}') or
     GxRegisteredValueMatches(Key, '', '{#GxOpenHereZh}'));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if (RegKeyExists(HKA, GxAumidKey) or RegKeyExists(HKA, GxClsidKey)) and
    not GxOwnsShellRegistration then
    Result := CustomMessage('ShellIdentityInUse');
  if Result <> '' then Exit;
  if RegKeyExists(HKA, GxAppPathKey) and not GxOwnsAppPath then begin
    Result := CustomMessage('IntegrationInUse');
    Exit;
  end;
  { Unselected Explorer integration is preserved rather than overwritten. }
  if WizardIsTaskSelected('contextmenu') then
    if (RegKeyExists(HKA, GxBackgroundKey) and not GxOwnsContextMenu(GxBackgroundKey)) or
       (RegKeyExists(HKA, GxDirectoryKey) and not GxOwnsContextMenu(GxDirectoryKey)) then
      Result := CustomMessage('IntegrationInUse');
end;

procedure GxDeleteOwnedValue(const Key, Name, Expected: String);
begin
  if GxRegisteredValueMatches(Key, Name, Expected) then
    RegDeleteValue(HKA, Key, Name);
end;

procedure GxDeleteOwnedAppPath;
begin
  if not GxOwnsAppPath then Exit;
  GxDeleteOwnedValue(GxAppPathKey, 'Path', ExpandConstant('{app}'));
  GxDeleteOwnedValue(GxAppPathKey, '', ExpandConstant('{app}\ghostty.exe'));
  RegDeleteKeyIfEmpty(HKA, GxAppPathKey);
end;

procedure GxDeleteOwnedContextMenu(const Key: String);
begin
  if not GxOwnsContextMenu(Key) then Exit;
  GxDeleteOwnedValue(Key + '\command', '', GxExpectedOpenHere);
  RegDeleteKeyIfEmpty(HKA, Key + '\command');
  GxDeleteOwnedValue(Key, 'Icon', GxExpectedIcon);
  GxDeleteOwnedValue(Key, '', '{#GxOpenHereEn}');
  GxDeleteOwnedValue(Key, '', '{#GxOpenHereZh}');
  RegDeleteKeyIfEmpty(HKA, Key);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    GxDeleteOwnedAppPath;
    GxDeleteOwnedContextMenu(GxBackgroundKey);
    GxDeleteOwnedContextMenu(GxDirectoryKey);
  end;
  if (CurUninstallStep = usUninstall) and GxOwnsShellRegistration then begin
    GxDeleteOwnedValue(GxClsidKey + '\LocalServer32', '', GxExpectedServer);
    RegDeleteKeyIfEmpty(HKA, GxClsidKey + '\LocalServer32');
    RegDeleteKeyIfEmpty(HKA, GxClsidKey);
    GxDeleteOwnedValue(GxAumidKey, 'CustomActivator', GxActivator);
    GxDeleteOwnedValue(GxAumidKey, 'DisplayName', 'Ghostty GX');
    GxDeleteOwnedValue(GxAumidKey, 'IconUri', ExpandConstant('{app}\ghostty.exe'));
    GxDeleteOwnedValue(GxAumidKey, 'GxExecutable', ExpandConstant('{app}\ghostty.exe'));
    RegDeleteKeyIfEmpty(HKA, GxAumidKey);
  end;
end;
