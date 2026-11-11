; 我的笔记 · Windows 安装向导脚本（Inno Setup 6）
;
; 由 .github/workflows/build-windows.yml 调用 ISCC.exe 编译。
; CI 会先把本文件复制成带 UTF-8 BOM 的副本再交给编译器，保证中文不乱码
; （Inno Setup 无 BOM 时按系统 ANSI 代码页读取，英文 runner 上会乱码）。
; 通过 /D 传入：MyAppVersion、MyStage（已清理干净的安装内容目录）、MyIcon。

#define MyAppName "我的笔记"
#define MyAppPublisher "MyNotes"
#define MyAppURL "https://github.com/feibixunchang/mynotes"
#define MyAppExeName "my_notes.exe"

#ifndef MyAppVersion
  #define MyAppVersion "1.3.8"
#endif
#ifndef MyStage
  #define MyStage "."
#endif
#ifndef MyIcon
  #define MyIcon "desktop\windows\runner\resources\app_icon.ico"
#endif

[Setup]
; AppId 固定不变，重复安装会走升级路径而不是产生两份卸载记录
AppId={{A6D1E1F0-3B6C-4C1D-9E8A-7C2F5B4D6E91}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} v{#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
; 装在当前用户可写目录：程序会把笔记库写在安装目录下的 notes-data，
; 放到 Program Files 会需要管理员权限，还会让自动更新覆盖失败。
; 目录名用英文，避免中文路径给 Flutter 运行时带来不必要的不确定性。
DefaultDirName={localappdata}\Programs\MyNotes
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
SetupIconFile={#MyIcon}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
OutputBaseFilename=MyNotes-Setup
; 卸载时只移除本向导登记过的文件；运行时生成的 notes-data（用户笔记）会保留

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MyStage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
