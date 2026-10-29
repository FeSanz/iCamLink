; iCamLink - Windows installer (Inno Setup 6.1+). Built by windows\build-installer.ps1, which
; passes AppVersion / StagingDir / OutputDir / CertFile and the "iclsign" signing tool.
; The app is self-contained (.NET runtime + libvlc included), so there are no prerequisites.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef StagingDir
  #error StagingDir must be defined (run build-installer.ps1)
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

#define AppName "iCamLink"
#define AppExe "ICamLink.App.exe"

[Setup]
AppId={{B3A7D2E1-5C48-4F69-9E0A-7D1C2F8B6A35}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=iCamLink
VersionInfoVersion={#AppVersion}
VersionInfoDescription=Instalador de {#AppName}
; Per-user install, no admin prompt.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\{#AppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=iCamLink-Setup-{#AppVersion}
SetupIconFile=..\ICamLink.App\Assets\app.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SignTool=iclsign
SignedUninstaller=yes

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "startup"; Description: "Abrir iCamLink automáticamente al iniciar sesión en Windows"; GroupDescription: "Opciones:"; Flags: unchecked
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Opciones:"
Name: "trustcert"; Description: "Confiar en el certificado de firma de iCamLink (solo si Smart App Control o SmartScreen bloquean la app; Windows pedirá confirmación)"; GroupDescription: "Seguridad:"; Flags: unchecked

[Files]
Source: "{#StagingDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#CertFile}"; DestDir: "{app}"; DestName: "iCamLink-Signing.cer"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: startup

[Run]
; Only adds this one public certificate to the CURRENT USER's trust stores (Windows itself shows
; a confirmation dialog for the Root store) - it never disables Smart App Control.
Filename: "{sys}\certutil.exe"; Parameters: "-user -f -addstore Root ""{app}\iCamLink-Signing.cer"""; Flags: runhidden waituntilterminated; Tasks: trustcert
Filename: "{sys}\certutil.exe"; Parameters: "-user -f -addstore TrustedPublisher ""{app}\iCamLink-Signing.cer"""; Flags: runhidden waituntilterminated; Tasks: trustcert
Filename: "{app}\{#AppExe}"; Description: "Abrir {#AppName} ahora"; Flags: nowait postinstall skipifsilent
