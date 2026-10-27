#if !FileExists("{{SOURCE_DIR}}\piliaurora-runtime.sha256")
  #error "Run tool/packaging/prepare_windows_package.py before packaging."
#endif

[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UsePreviousAppDir=yes
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no
SetupMutex=PiliAurora.Setup
ChangesAssociations=yes

[Code]
const
  RuntimeManifest = 'piliaurora-runtime.sha256';
  ManifestHeader = '# PiliAurora runtime manifest v1';

var
  PreviousFiles: TArrayOfString;

function GetFileAttributesW(Filename: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function FollowsLink(Filename, AppRoot: String): Boolean;
begin
  Result := True;
  while CompareText(AddBackslash(Filename), AppRoot) <> 0 do begin
    if (GetFileAttributesW(Filename) and $400) <> 0 then Exit;
    Filename := ExtractFileDir(Filename);
  end;
  Result := False;
end;

function ReadEntry(Line: String; var Digest, RelativePath: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Pos(#9, Line) <> 65 then Exit;
  Digest := Copy(Line, 1, 64);
  for I := 1 to Length(Digest) do
    if Pos(Lowercase(Digest[I]), '0123456789abcdef') = 0 then Exit;
  RelativePath := Copy(Line, 66, Length(Line));
  StringChangeEx(RelativePath, '/', '\', True);
  if (RelativePath = '') or (Copy(RelativePath, 1, 1) = '\') or
     (Pos(':', RelativePath) > 0) or (Pos(#9, RelativePath) > 0) or
     (Pos('\..\', '\' + RelativePath + '\') > 0) or
     (Pos('\.\', '\' + RelativePath + '\') > 0) then Exit;
  Result := True;
end;

procedure RemoveRetiredFiles;
var
  CurrentFiles: TArrayOfString;
  CurrentPaths: TStringList;
  I: Integer;
  Digest, RelativePath, Filename, AppRoot: String;
begin
  if (GetArrayLength(PreviousFiles) = 0) or
     (PreviousFiles[0] <> ManifestHeader) then Exit;
  if not LoadStringsFromFile(ExpandConstant('{app}\') + RuntimeManifest, CurrentFiles) then Exit;
  if (GetArrayLength(CurrentFiles) = 0) or
     (CurrentFiles[0] <> ManifestHeader) then Exit;
  AppRoot := AddBackslash(ExpandFileName(ExpandConstant('{app}')));
  CurrentPaths := TStringList.Create;
  try
    for I := 1 to GetArrayLength(CurrentFiles) - 1 do
      if ReadEntry(CurrentFiles[I], Digest, RelativePath) then
        CurrentPaths.Add(Lowercase(RelativePath));
    CurrentPaths.Sorted := True;
    for I := 1 to GetArrayLength(PreviousFiles) - 1 do begin
      if not ReadEntry(PreviousFiles[I], Digest, RelativePath) then Continue;
      if CurrentPaths.IndexOf(Lowercase(RelativePath)) >= 0 then Continue;
      Filename := ExpandFileName(AppRoot + RelativePath);
      if CompareText(Copy(Filename, 1, Length(AppRoot)), AppRoot) <> 0 then Continue;
      if not FileExists(Filename) then Continue;
      if FollowsLink(Filename, AppRoot) then Continue;
      try
        { 旧清单证明文件归属；用户修改过的文件继续保留。 }
        if CompareText(GetSHA256OfFile(Filename), Digest) = 0 then begin
          if DeleteFile(Filename) then
            Log('Removed retired runtime file: ' + RelativePath)
          else
            Log('Unable to remove retired runtime file: ' + RelativePath);
        end else
          Log('Preserved modified file: ' + RelativePath);
      except
        Log('Preserved unreadable file: ' + RelativePath);
      end;
    end;
  finally
    CurrentPaths.Free;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    LoadStringsFromFile(ExpandConstant('{app}\') + RuntimeManifest, PreviousFiles)
  else if CurStep = ssPostInstall then
    RemoveRetiredFiles;
end;

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "launchAtStartup"; Description: "{cm:AutoStartProgram,{{DISPLAY_NAME}}}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; WorkingDir: "{app}"; AppUserModelID: "PiliAurora.Desktop"
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; WorkingDir: "{app}"; AppUserModelID: "PiliAurora.Desktop"; Tasks: desktopicon
Name: "{commonstartup}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; WorkingDir: "{app}"; AppUserModelID: "PiliAurora.Desktop"; Tasks: launchAtStartup

[Registry]
Root: HKLM; Subkey: "Software\\Classes\\bilibili"; ValueType: string; ValueData: "URL:Bilibili Protocol"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\\Classes\\bilibili"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKLM; Subkey: "Software\\Classes\\bilibili\\DefaultIcon"; ValueType: string; ValueData: "{app}\\{{EXECUTABLE_NAME}},0"
Root: HKLM; Subkey: "Software\\Classes\\bilibili\\shell\\open\\command"; ValueType: string; ValueData: """{app}\\{{EXECUTABLE_NAME}}"" ""%1"""

[Run]
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: runascurrentuser nowait postinstall skipifsilent
