; 마디 Windows판 설치 파일 — Inno Setup 6. CI(.github/workflows/windows.yml)가 dotnet publish의 out\Madi를 묶는다.
;
; - 사용자별 설치(관리자 권한 없이): %LOCALAPPDATA%\Programs\Madi. 시작 메뉴에 마디.
; - 파일 연결: .md · .markdown · .mdown · .mkd · .mkdn · .mdx · .txt · .text · .log의 "연결 프로그램"에 마디를 올린다. 기본 앱을
;   바꾸지는 않는다(Windows가 앱이 스스로 바꾸지 못하게 막는다) — 설정 ▸ 기본 앱(마디의 도구 ▸ 기본 앱 설정 열기)에서 사람이 고른다.
; - madi:// 링크(MadiUrl.cs). 마디가 이미 켜져 있으면 두 번째 마디가 넘기고 끝난다(SingleInstance.cs).
; - 서명하지 않았다(인증서가 없다) — 처음 열면 SmartScreen이 묻는다. 지우면 레지스트리의 마디 항목도 지운다(설정 · 최근 문서는 남긴다:
;   %APPDATA%\Madi).

#ifndef AppVersion
  #define AppVersion "0.0.1"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\out\Madi"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\out\installer"
#endif

[Setup]
AppId={{6F0D6A52-3C1B-4E5B-9D7A-2A9E1C4B8F31}
AppName=마디
AppVersion={#AppVersion}
AppVerName=마디 {#AppVersion}
AppPublisher=ddiiwoong
AppPublisherURL=https://github.com/ddiiwoong/madi
AppSupportURL=https://github.com/ddiiwoong/madi/issues
DefaultDirName={autopf}\Madi
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Madi-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
CloseApplications=yes
UninstallDisplayIcon={app}\Madi.exe
UninstallDisplayName=마디

[Languages]
; 한국어 번역은 Inno Setup의 판에 따라 없을 수 있다 — 있으면 쓴다.
#if FileExists(CompilerPath + "Languages\Korean.isl")
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
#endif
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\마디"; Filename: "{app}\Madi.exe"

[Registry]
; 문서 종류(ProgID) 둘 — 마크다운, 글(글 · 로그).
Root: HKA; Subkey: "Software\Classes\Madi.Markdown"; ValueType: string; ValueName: ""; ValueData: "마크다운 문서"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Madi.Markdown\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\Madi.exe"",0"
Root: HKA; Subkey: "Software\Classes\Madi.Markdown\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Madi.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\Madi.Text"; ValueType: string; ValueName: ""; ValueData: "글 문서"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Madi.Text\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\Madi.exe"",0"
Root: HKA; Subkey: "Software\Classes\Madi.Text\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Madi.exe"" ""%1"""
; "연결 프로그램"에 올린다 — 기본 앱은 그대로.
Root: HKA; Subkey: "Software\Classes\.md\OpenWithProgids"; ValueType: string; ValueName: "Madi.Markdown"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.markdown\OpenWithProgids"; ValueType: string; ValueName: "Madi.Markdown"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mdown\OpenWithProgids"; ValueType: string; ValueName: "Madi.Markdown"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mkd\OpenWithProgids"; ValueType: string; ValueName: "Madi.Markdown"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mkdn\OpenWithProgids"; ValueType: string; ValueName: "Madi.Markdown"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mdx\OpenWithProgids"; ValueType: string; ValueName: "Madi.Markdown"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.txt\OpenWithProgids"; ValueType: string; ValueName: "Madi.Text"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.text\OpenWithProgids"; ValueType: string; ValueName: "Madi.Text"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.log\OpenWithProgids"; ValueType: string; ValueName: "Madi.Text"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "마디"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Madi.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\SupportedTypes"; ValueType: string; ValueName: ".md"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\SupportedTypes"; ValueType: string; ValueName: ".markdown"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\SupportedTypes"; ValueType: string; ValueName: ".mdown"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\SupportedTypes"; ValueType: string; ValueName: ".mkd"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\SupportedTypes"; ValueType: string; ValueName: ".mkdn"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\SupportedTypes"; ValueType: string; ValueName: ".mdx"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\SupportedTypes"; ValueType: string; ValueName: ".txt"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\SupportedTypes"; ValueType: string; ValueName: ".text"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\Madi.exe\SupportedTypes"; ValueType: string; ValueName: ".log"; ValueData: ""
; madi:// 링크.
Root: HKA; Subkey: "Software\Classes\madi"; ValueType: string; ValueName: ""; ValueData: "URL:마디"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\madi"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\madi\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\Madi.exe"",0"
Root: HKA; Subkey: "Software\Classes\madi\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Madi.exe"" ""%1"""
; 설정 ▸ 기본 앱에 마디가 보이게(RegisteredApplications — 도구 ▸ 기본 앱 설정 열기가 이 이름으로 연다).
Root: HKA; Subkey: "Software\Madi"; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Madi\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "마디"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Madi\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "마크다운 편집기"
Root: HKA; Subkey: "Software\Madi\Capabilities\FileAssociations"; ValueType: string; ValueName: ".md"; ValueData: "Madi.Markdown"
Root: HKA; Subkey: "Software\Madi\Capabilities\FileAssociations"; ValueType: string; ValueName: ".markdown"; ValueData: "Madi.Markdown"
Root: HKA; Subkey: "Software\Madi\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mdown"; ValueData: "Madi.Markdown"
Root: HKA; Subkey: "Software\Madi\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mkd"; ValueData: "Madi.Markdown"
Root: HKA; Subkey: "Software\Madi\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mkdn"; ValueData: "Madi.Markdown"
Root: HKA; Subkey: "Software\Madi\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mdx"; ValueData: "Madi.Markdown"
Root: HKA; Subkey: "Software\Madi\Capabilities\FileAssociations"; ValueType: string; ValueName: ".txt"; ValueData: "Madi.Text"
Root: HKA; Subkey: "Software\Madi\Capabilities\FileAssociations"; ValueType: string; ValueName: ".text"; ValueData: "Madi.Text"
Root: HKA; Subkey: "Software\Madi\Capabilities\FileAssociations"; ValueType: string; ValueName: ".log"; ValueData: "Madi.Text"
Root: HKA; Subkey: "Software\Madi\Capabilities\URLAssociations"; ValueType: string; ValueName: "madi"; ValueData: "madi"
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Madi"; ValueData: "Software\Madi\Capabilities"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\Madi.exe"; Description: "마디 켜기"; Flags: nowait postinstall skipifsilent
