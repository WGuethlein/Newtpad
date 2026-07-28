; Newtpad installer (Inno Setup 6).
;
; This is what a stranger gets. install.ps1 stays as the developer loop -- it is
; faster and it is what the dev cycle uses. Everything this script registers is
; a mirror of install.ps1's tested list; if the two ever disagree, install.ps1
; wins and this file is the bug. build-installer.ps1 enforces the extension half
; of that mirror mechanically (see the [Registry] note below).
;
; Like install.ps1 it writes only under HKCU, installs only under
; %LOCALAPPDATA%, and needs no elevation. It deliberately does NOT try to seize
; the default .txt handler: Windows 10/11 protect that with a tamper-checked
; UserChoice hash, so the honest path is to appear in "Open with" and let the
; user pick "Always use this app" once.
;
; Build it with build-installer.ps1 -- do not invoke ISCC by hand. The script
; supplies the version, checks the extension list against text_exts.txt, and
; re-encodes LICENSE.txt so the license page is not mojibake (see LicenseFile).
;
; Requires Inno Setup 6. Not compiled or run on the authoring machine: Inno
; Setup is deliberately not installed there.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
  #pragma message "newtpad.iss: no /DMyAppVersion given -- defaulting to 0.0.0. Build with build-installer.ps1."
#endif

; The license page and the copy installed next to the exe. Inno reads a
; plain-text LicenseFile as ANSI unless it carries a UTF-8 BOM, and
; LICENSE.txt is BOM-less UTF-8 containing em dashes -- pointed at directly it
; renders as "a-EUR-quote" garbage on the first page a stranger ever sees.
; build-installer.ps1 writes a BOM'd CRLF copy and passes it here.
#ifndef LicenseFile
  #define LicenseFile "..\LICENSE.txt"
  #pragma message "newtpad.iss: no /DLicenseFile given -- using ..\LICENSE.txt, whose non-ASCII characters will render wrong. Build with build-installer.ps1."
#endif

#define MyAppName "Newtpad"
#define MyAppPublisher "Wyatt Guethlein"
#define MyAppURL "https://github.com/WGuethlein/Newtpad"
#define MyAppExeName "newtpad.exe"

[Setup]
; Never change AppId: it is the identity Windows uses to recognise an upgrade
; and to find the Add/Remove Programs entry. A new GUID here means the next
; version installs alongside the old one instead of over it.
AppId={{CB1E9F26-70CC-4798-84BB-53631ED6BBDB}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
VersionInfoVersion={#MyAppVersion}

; Per-user, no elevation. This is not a preference -- every registration below
; lives in HKCU, and an elevated install would write them into the
; administrator's hive where the real user never sees them. install.ps1 has the
; same property by virtue of being a plain user script.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
LicenseFile={#LicenseFile}

Uninstallable=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}

OutputDir=..\build
OutputBaseFilename=newtpad-{#MyAppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0
SetupMutex=NewtpadSetupMutex

; The exe is x64. ArchitecturesAllowed is left off on purpose: the spelling
; changed in Inno 6.3 (x64 -> x64compatible) and this file cannot be compiled
; on the authoring machine to find out which one the local compiler accepts.
; 32-bit Windows 10 is the only affected case. Add whichever your Inno accepts:
;   ArchitecturesAllowed=x64compatible

; Broadcasts WM_SETTINGCHANGE / SHChangeNotify so a running Explorer picks up
; the PATH entry and the "Open with" registrations without a logoff.
ChangesEnvironment=yes
ChangesAssociations=yes

; --- THE IMPORTANT TWO LINES IN THIS FILE ------------------------------------
;
; Inno's default (CloseApplications=yes) hands a running Newtpad to the Restart
; Manager, which asks via WM_QUERYENDSESSION/WM_ENDSESSION and then FORCE
; TERMINATES anything that does not comply. Newtpad's window proc handles
; WM_CLOSE but not WM_ENDSESSION, so the Restart Manager would kill it -- and a
; hard kill skips the hot-exit session write in main.odin, which loses every
; unsaved tab. That is the exact failure this installer exists to prevent.
;
; So: no Restart Manager. PrepareToInstall below posts a real WM_CLOSE instead,
; which is what the title-bar X does, waits for the process to actually go, and
; aborts the install if it does not. A failed install is recoverable; lost tabs
; are not.
;
; AppMutex is deliberately NOT set either. It would make Setup block on its own
; "please close the application" dialog before PrepareToInstall ever runs, so
; the graceful close could never happen.
CloseApplications=no
RestartApplications=no

; No SetupIconFile: the tree has no .ico yet (src/platform/newtpad.rc embeds
; only the DPI manifest), which is also why DefaultIcon below resolves to
; nothing. Add an icon and both this and Explorer improve at once.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\build\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#LicenseFile}"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
; {autoprograms} resolves to the per-user Start Menu because
; PrivilegesRequired=lowest.
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Only if empty -- never blanket-delete {app}, which is a directory the user can
; put things in.
Type: dirifempty; Name: "{app}"

[Registry]
; ---------------------------------------------------------------------------
; Mirror of install.ps1's registration block, in the same order.
;
; The extension list below is a literal copy of text_exts.txt. It could have
; been read at compile time with an ISPP file loop, and that would have removed
; the drift by construction -- but that idiom is syntax-fragile and cannot be
; compile-checked on the authoring machine, and a broken .iss is worse than a
; checked duplicate. build-installer.ps1 diffs this list against text_exts.txt
; and refuses to build on any mismatch, which is verifiable without ISCC.
;
; uninsdeletekey on the first entry removes the whole Applications\newtpad.exe
; subtree (shell, DefaultIcon, SupportedTypes) at uninstall, matching
; install.ps1 -Uninstall's `Remove-Item $AppKey -Recurse`.
; ---------------------------------------------------------------------------

Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Newtpad"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"",0"

; SupportedTypes drives which files offer Newtpad in "Open with"; the
; per-extension OpenWithList keys make it show up without "Choose another app".
; Empty REG_SZ values, exactly as Set-ItemProperty -Value '' writes them.
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".txt"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".log"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".md"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".markdown"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".json"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".csv"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".tsv"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".xml"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".yaml"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".yml"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".toml"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".ini"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".cfg"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".conf"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".env"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".c"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".h"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".cpp"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".hpp"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".cs"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".odin"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".py"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".js"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".ts"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".go"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".rs"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".java"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".sql"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".sh"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".bat"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".ps1"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".html"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".css"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\newtpad.exe\SupportedTypes"; ValueType: string; ValueName: ".gitignore"; ValueData: ""

; Key only, no values -- the same shape as `New-Item ...\OpenWithList\newtpad.exe`.
; uninsdeletekey removes just the newtpad.exe leaf, leaving the user's other
; OpenWithList entries alone, matching install.ps1 -Uninstall.
Root: HKCU; Subkey: "Software\Classes\.txt\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.log\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.md\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.markdown\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.json\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.csv\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.tsv\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.xml\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.yaml\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.yml\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.toml\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.ini\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.cfg\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.conf\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.env\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.c\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.h\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.cpp\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.hpp\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.cs\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.odin\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.py\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.js\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.go\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.rs\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.java\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.sql\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.sh\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.bat\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.ps1\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.html\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.css\OpenWithList\newtpad.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.gitignore\OpenWithList\newtpad.exe"; Flags: uninsdeletekey

[Code]

const
  { Named with a prefix so this can never collide with anything Pascal Script
    already defines -- a redefinition is a compile error, and this file cannot
    be compiled here to find out. }
  NP_WM_CLOSE = $0010;

  { src/platform/window.odin:98 and src/platform/instance.odin:34. If either is
    renamed, the graceful-close path silently turns into "nothing is running"
    and the install replaces the exe underneath a live editor. }
  NP_WINDOW_CLASS = 'NewtpadWindowClass';
  NP_MUTEX        = 'Local\NewtpadSingleInstance';

  { Newtpad never prompts on close -- File>Exit and the X both just post
    WM_CLOSE and the session is written on the way out (commands.odin:1394,
    main.odin:901) -- so a normal shutdown is well under a second. The generous
    ceiling is for a big unsaved buffer being flushed, or for a modal dialog
    that is holding the message loop and needs a human. }
  NP_CLOSE_TIMEOUT_MS = 60000;
  NP_POLL_MS          = 250;

  NP_ENV_KEY = 'Environment';

{ True while any trace of Newtpad is still live. Both signals matter: the window
  goes away as soon as the message loop exits, but the process lives on for the
  hot-exit session write, and it is the process that holds newtpad.exe open. The
  mutex (created in instance_claim, released by Windows on process exit) is the
  one that answers "has it actually gone". }
function NewtpadIsRunning(): Boolean;
begin
  Result := (FindWindowByClassName(NP_WINDOW_CLASS) <> 0) or CheckForMutexes(NP_MUTEX);
end;

{ Ask a running Newtpad to close the way its own title-bar X does, and wait for
  the process to go. Never TerminateProcess, never Restart Manager: a hard kill
  skips the hot-exit session write and loses unsaved tabs.

  Returns False with a human-readable Reason if it is still there afterwards.
  The caller aborts on False -- a failed install is recoverable, lost tabs are
  not. ShowStatus is False in the uninstaller, where WizardForm does not exist. }
function CloseNewtpadGracefully(ShowStatus: Boolean; var Reason: String): Boolean;
var
  Wnd: HWND;
  Waited: Integer;
begin
  Reason := '';
  Result := True;
  if not NewtpadIsRunning() then
    exit;

  Wnd := FindWindowByClassName(NP_WINDOW_CLASS);
  if Wnd = 0 then
  begin
    { Mutex held but no window: Newtpad is starting up, already shutting down,
      or wedged. There is nothing safe to post a WM_CLOSE to. }
    Result := False;
    Reason := 'Newtpad appears to be running but has no window yet, so Setup cannot ask it'
            + ' to close safely.' + #13#10#13#10
            + 'Nothing has been changed. Wait for Newtpad to finish starting or close it'
            + ' yourself, then run Setup again.';
    exit;
  end;

  { Best effort only: Sleep below does not pump messages, so this may not repaint
    until the wait ends. Deliberately no Refresh/Update call -- the wait is under
    a second in every normal case, and a cosmetic repaint is not worth a method
    name this file cannot be compiled here to verify. }
  if ShowStatus and not WizardSilent() then
    WizardForm.PreparingLabel.Caption :=
      'Newtpad is running. Asking it to close so it can save your open tabs...';

  { PostMessage, not SendMessage: SendMessage would block Setup for as long as
    Newtpad takes to handle it, and would deadlock outright against a modal. }
  PostMessage(Wnd, NP_WM_CLOSE, 0, 0);

  Waited := 0;
  while (Waited < NP_CLOSE_TIMEOUT_MS) and NewtpadIsRunning() do
  begin
    Sleep(NP_POLL_MS);
    Waited := Waited + NP_POLL_MS;
  end;

  if NewtpadIsRunning() then
  begin
    Result := False;
    Reason := 'Newtpad did not close within ' + IntToStr(NP_CLOSE_TIMEOUT_MS div 1000)
            + ' seconds. It may be showing a dialog that needs an answer.' + #13#10#13#10
            + 'Setup has stopped and changed nothing. Close Newtpad yourself and run Setup'
            + ' again.' + #13#10#13#10
            + 'Setup will not force it closed: that would skip the shutdown step that saves'
            + ' your unsaved tabs.';
    exit;
  end;

  { The mutex is gone, so the process is gone, but give the loader a moment to
    drop its handle on newtpad.exe before we overwrite it. }
  Sleep(500);
end;

{ install.ps1 compares PATH entries case-insensitively with trailing
  backslashes trimmed. Same here: wrap both sides in separators and look for an
  exact segment. }
function UserPathHasDir(const PathValue, Dir: String): Boolean;
var
  Hay, Needle: String;
begin
  Hay := ';' + Lowercase(PathValue) + ';';
  while Pos('\;', Hay) > 0 do
    StringChangeEx(Hay, '\;', ';', True);
  Needle := ';' + Lowercase(RemoveBackslashUnlessRoot(Dir)) + ';';
  Result := Pos(Needle, Hay) > 0;
end;

{ Mirrors install.ps1's PATH block. Done in code rather than a [Registry] entry
  because the olddata constant would append a duplicate on every reinstall
  (written without braces on purpose: Pascal brace comments do NOT nest, so an
  inner brace closes the comment early and the rest parses as code -- this
  exact line failed the very first compile with "BEGIN expected"), and because
  uninsdeletevalue on HKCU\Environment\Path would delete the user's entire PATH
  at uninstall. }
procedure AddDirToUserPath(const Dir: String);
var
  Cur: String;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, NP_ENV_KEY, 'Path', Cur) then
    Cur := '';
  if UserPathHasDir(Cur, Dir) then
    exit;
  if Cur = '' then
    Cur := Dir
  else if Copy(Cur, Length(Cur), 1) = ';' then
    Cur := Cur + Dir
  else
    Cur := Cur + ';' + Dir;
  { Always REG_EXPAND_SZ. Rewriting an existing expandable PATH as a plain
    string would break any %USERPROFILE%-style entry already in it; the reverse
    is harmless. }
  RegWriteExpandStringValue(HKEY_CURRENT_USER, NP_ENV_KEY, 'Path', Cur);
end;

procedure RemoveDirFromUserPath(const Dir: String);
var
  Cur, Rest, Seg, Kept, Target: String;
  P: Integer;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, NP_ENV_KEY, 'Path', Cur) then
    exit;
  Target := Lowercase(RemoveBackslashUnlessRoot(Dir));
  Kept := '';
  Rest := Cur + ';';
  while Rest <> '' do
  begin
    P := Pos(';', Rest);
    if P = 0 then
    begin
      Seg := Rest;
      Rest := '';
    end
    else
    begin
      Seg := Copy(Rest, 1, P - 1);
      Rest := Copy(Rest, P + 1, Length(Rest));
    end;
    { Empty segments are dropped, as install.ps1's Where-Object does. }
    if (Seg <> '') and (Lowercase(RemoveBackslashUnlessRoot(Seg)) <> Target) then
    begin
      if Kept <> '' then
        Kept := Kept + ';';
      Kept := Kept + Seg;
    end;
  end;
  if Kept = Cur then
    exit;
  if Kept = '' then
    RegDeleteValue(HKEY_CURRENT_USER, NP_ENV_KEY, 'Path')
  else
    RegWriteExpandStringValue(HKEY_CURRENT_USER, NP_ENV_KEY, 'Path', Kept);
end;

{ Runs after the wizard and before a single file is touched, so returning a
  message here aborts with nothing written. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Reason: String;
begin
  Result := '';
  if not CloseNewtpadGracefully(True, Reason) then
    Result := Reason;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    AddDirToUserPath(ExpandConstant('{app}'));
end;

function InitializeUninstall(): Boolean;
var
  Reason: String;
begin
  Result := CloseNewtpadGracefully(False, Reason);
  if not Result and not UninstallSilent() then
    MsgBox(Reason, mbError, MB_OK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemoveDirFromUserPath(ExpandConstant('{app}'));
end;
