; Standardkonformer Inno-Setup-Installer fuer den Novan Launcher.
; Ersetzt den alten RCDATA-Dropper (FriendTestSetup.exe), der bei Avast/Sophos
; durch Heuristik-Alarme auffiel. Keine eingebetteten Payloads, kein Self-Drop.

#define AppName "Novan Launcher"
#ifndef AppVersion
  #define AppVersion "0.0.27"
#endif
#ifndef SourceDir
  #define SourceDir "..\\..\\artifacts-v0.0.27"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
AppId={{9F2C4A61-7D3B-4E58-B0C1-5A8E6D2F1A73}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=wolfmod
AppPublisherURL=https://github.com/zwerg061/isaac-repentogon-friend-test
AppSupportURL=https://github.com/zwerg061/isaac-repentogon-friend-test/issues
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Novan-Setup-{#AppVersion}
SetupIconFile=
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x86 x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\isaac-mod-launcher.exe
UninstallDisplayName={#AppName} {#AppVersion}
LicenseFile=
PrivilegesRequired=lowest
DirExistsWarning=no

[Files]
Source: "{#SourceDir}\isaac-mod-launcher.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\payload\*"; DestDir: "{app}\payload"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\isaac-mod-launcher.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\isaac-mod-launcher.exe"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Desktop-Verknuepfung erstellen"; GroupDescription: "Zusaetzliche Optionen:"

[Run]
Filename: "{app}\isaac-mod-launcher.exe"; Description: "{#AppName} jetzt starten"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
