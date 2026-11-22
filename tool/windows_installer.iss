#ifndef AppVersion
  #error Build using tool/build_windows.bat
#endif
#ifndef NumericVersion
  #define NumericVersion AppVersion
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
Compression=lzma2/ultra64
; The static FFmpeg tools share code across their roughly 95 MiB images.
LZMADictionarySize=131072
LZMANumBlockThreads=1
LZMAUseSeparateProcess=yes
SolidCompression=yes
WizardStyle=modern
VersionInfoVersion={#NumericVersion}.{#BuildNumber}
CloseApplications=yes
RestartApplications=no
LicenseFile=..\LICENSE

[InstallDelete]
Type: filesandordirs; Name: "{app}\data\flutter_assets"
Type: filesandordirs; Name: "{app}\licenses"

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
const
  SYNCHRONIZE = $00100000;
  WAIT_OBJECT_0 = $00000000;
  ERROR_ACCESS_DENIED = 5;
  WM_APP_EXIT = $8000 + 43;

function GetWindowThreadProcessId(hWnd: HWND; var lpdwProcessId: DWORD): DWORD;
  external 'GetWindowThreadProcessId@user32.dll stdcall';
function OpenProcess(dwDesiredAccess: DWORD; bInheritHandle: BOOL; dwProcessId: DWORD): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(hHandle: THandle; dwMilliseconds: DWORD): DWORD;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';
function OpenMutex(dwDesiredAccess: DWORD; bInheritHandle: BOOL; lpName: string): THandle;
  external 'OpenMutexW@kernel32.dll stdcall';

function DesktopMutexExists(): Boolean;
var
  Mutex: THandle;
begin
  Mutex := OpenMutex(SYNCHRONIZE, False, 'Local\DoujinAudio-Desktop');
  if Mutex <> 0 then begin
    CloseHandle(Mutex);
    Result := True;
  end else begin
    Result := DLLGetLastError = ERROR_ACCESS_DENIED;
  end;
end;

function CloseAudioPlayer(): Boolean;
var
  Window: HWND;
  ProcessId: DWORD;
  ProcessHandle: THandle;
  Attempt: Integer;
begin
  Window := FindWindowByClassName('DOUJIN_AUDIO_WIN32_WINDOW');
  if (Window = 0) and (not DesktopMutexExists()) then begin
    Result := True;
    Exit;
  end;

  ProcessHandle := 0;
  if Window <> 0 then begin
    ProcessId := 0;
    GetWindowThreadProcessId(Window, ProcessId);
    if ProcessId <> 0 then
      ProcessHandle := OpenProcess(SYNCHRONIZE, False, ProcessId);
    if not PostMessage(Window, WM_APP_EXIT, 0, 0) then begin
      if (ProcessHandle = 0) and (FindWindowByClassName('DOUJIN_AUDIO_WIN32_WINDOW') = Window) then begin
        Result := False;
        Exit;
      end;
    end;
  end;

  for Attempt := 1 to 200 do begin
    if ProcessHandle <> 0 then begin
      if WaitForSingleObject(ProcessHandle, 100) = WAIT_OBJECT_0 then begin
        CloseHandle(ProcessHandle);
        Result := True;
        Exit;
      end;
      if (Attempt mod 5) = 0 then begin
        Window := FindWindowByClassName('DOUJIN_AUDIO_WIN32_WINDOW');
        if Window <> 0 then
          PostMessage(Window, WM_APP_EXIT, 0, 0);
      end;
    end else begin
      Window := FindWindowByClassName('DOUJIN_AUDIO_WIN32_WINDOW');
      if Window <> 0 then begin
        ProcessId := 0;
        GetWindowThreadProcessId(Window, ProcessId);
        if ProcessId <> 0 then
          ProcessHandle := OpenProcess(SYNCHRONIZE, False, ProcessId);
        if not PostMessage(Window, WM_APP_EXIT, 0, 0) then begin
          if (ProcessHandle = 0) and (FindWindowByClassName('DOUJIN_AUDIO_WIN32_WINDOW') = Window) then begin
            Result := False;
            Exit;
          end;
        end;
      end else if not DesktopMutexExists() then begin
        Sleep(250);
        Result := True;
        Exit;
      end;
      Sleep(100);
    end;
  end;

  if ProcessHandle <> 0 then CloseHandle(ProcessHandle);
  Result := False;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not CloseAudioPlayer() then
    Result := 'Doujin Audio is still running or saving data. Close it using the tray menu and retry.';
end;

function InitializeUninstall(): Boolean;
begin
  while not CloseAudioPlayer() do begin
    if UninstallSilent or
       (MsgBox('Doujin Audio is still running or saving data. Close it using the tray menu and click Retry, or click Cancel to abort uninstall.',
               mbError, MB_RETRYCANCEL) <> IDRETRY) then begin
      Result := False;
      Exit;
    end;
  end;
  Result := True;
end;
