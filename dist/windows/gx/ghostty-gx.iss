; Ghostty GX installer (fork file, not used by upstream Ghostty).
; scripts/gx_windows_package.py stages the payload and passes every define below:
;   GxVersion         version string VS (<build.zig.zon X.Y.Z>-gx.<fork X.Y.Z>)
;   GxNumericVersion  X.Y.Z.0 of the Ghostty product version, for the version resource
;   GxApp             portable directory without fonts\, installed into {app}
;   GxFonts           generated [Files] entries that install the bundled fonts per user
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

[Setup]
AppId={{49341A18-5070-425E-83B9-79E184242ACF}
AppName=Ghostty GX
AppVersion={#GxVersion}
AppVerName=Ghostty GX {#GxVersion}
AppPublisher=gx0404
AppPublisherURL=https://github.com/gx0404/gx_ghostty
AppSupportURL=https://github.com/gx0404/gx_ghostty/issues
AppUpdatesURL=https://github.com/gx0404/gx_ghostty/releases
VersionInfoVersion={#GxNumericVersion}
VersionInfoProductVersion={#GxNumericVersion}
VersionInfoTextVersion={#GxVersion}
VersionInfoProductTextVersion={#GxVersion}
VersionInfoProductName=Ghostty GX
VersionInfoDescription=Ghostty GX Setup
VersionInfoCompany=gx0404
DefaultDirName={autopf}\Ghostty GX
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
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=auto
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chinesesimplified.IntegrationGroup=系统集成：
english.IntegrationGroup=System integration:
chinesesimplified.ContextMenuTask=在资源管理器右键菜单中添加“在此处打开 Ghostty GX”
english.ContextMenuTask=Add "Open Ghostty GX here" to the Explorer context menu
chinesesimplified.OpenHere=在此处打开 Ghostty GX
english.OpenHere=Open Ghostty GX here

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "contextmenu"; Description: "{cm:ContextMenuTask}"; GroupDescription: "{cm:IntegrationGroup}"

[Files]
Source: "{#GxApp}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#include GxFonts

[Icons]
Name: "{autoprograms}\Ghostty GX"; Filename: "{app}\ghostty.exe"; WorkingDir: "{%USERPROFILE}"
Name: "{autodesktop}\Ghostty GX"; Filename: "{app}\ghostty.exe"; WorkingDir: "{%USERPROFILE}"; Tasks: desktopicon

[Registry]
; For a drive root %V is "C:\", whose closing \" the command-line rules read as an escaped quote,
; so ghostty.exe receives --working-directory=C:" and restores the backslash
; (src/apprt/win32/App.zig::restoreTrailingBackslash). "%V\." would also work but leaves
; non-canonical paths such as C:\Users\me\. as the initial working directory.
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\App Paths\ghostty.exe"; ValueType: string; ValueData: "{app}\ghostty.exe"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\App Paths\ghostty.exe"; ValueType: string; ValueName: "Path"; ValueData: "{app}"
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\GhosttyGX"; ValueType: string; ValueData: "{cm:OpenHere}"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\GhosttyGX"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\ghostty.exe"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\GhosttyGX\command"; ValueType: string; ValueData: """{app}\ghostty.exe"" --working-directory=""%V"""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\GhosttyGX"; ValueType: string; ValueData: "{cm:OpenHere}"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\GhosttyGX"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\ghostty.exe"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\GhosttyGX\command"; ValueType: string; ValueData: """{app}\ghostty.exe"" --working-directory=""%V"""; Tasks: contextmenu

[Run]
Filename: "{app}\ghostty.exe"; Description: "{cm:LaunchProgram,Ghostty GX}"; WorkingDir: "{%USERPROFILE}"; Flags: nowait postinstall skipifsilent runasoriginaluser
