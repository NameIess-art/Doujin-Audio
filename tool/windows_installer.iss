#ifndef AppVersion
  #error Build using tool/build_windows.bat
#endif
[Setup]
AppId={{3FCA3145-3760-4C42-9EEC-64CAC470BD12}
AppName=Doujin Audio
AppVersion={#AppVersion}
AppPublisher=Doujin Audio
AppPublisherURL=https://github.com/NameIess-art/Doujin-Audio
DefaultDirName={localappdata}\Programs\Doujin Audio
DefaultGroupName=Doujin Audio
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputPath}
OutputBaseFilename={#OutputName}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\doujin_audio.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
VersionInfoVersion={#AppVersion}.{#BuildNumber}
CloseApplications=yes
RestartApplications=no
LicenseFile=..\LICENSE

[Files]
Source: "{#AppSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Icons]
Name: "{group}\Doujin Audio"; Filename: "{app}\doujin_audio.exe"
Name: "{autodesktop}\Doujin Audio"; Filename: "{app}\doujin_audio.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\doujin_audio.exe"; Description: "Open Doujin Audio"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\doujin_audio.exe"; Parameters: "--remove-timers"; Flags: runhidden; RunOnceId: "RemoveTimer"

[Code]
function CloseAudioPlayer(): Boolean;
var Window: HWND; Attempt: Integer;
begin
  Window := FindWindowByClassName('DOUJIN_AUDIO_WIN32_WINDOW');
  if Window <> 0 then PostMessage(Window, $8000 + 43, 0, 0);
  for Attempt := 1 to 200 do begin
    if FindWindowByClassName('DOUJIN_AUDIO_WIN32_WINDOW') = 0 then begin
      Result := True;
      Exit;
    end;
    Sleep(100);
  end;
  Result := False;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not CloseAudioPlayer() then
    Result := 'Doujin Audio is still saving data. Close it using the tray menu and retry.';
end;

function InitializeUninstall(): Boolean;
begin
  Result := CloseAudioPlayer();
end;
