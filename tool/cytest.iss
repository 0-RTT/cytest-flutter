; cytest Windows 安装包（Inno Setup 6.5+）
;
; 用法：
;   本地  ISCC.exe tool\cytest.iss
;   CI    ISCC.exe /DAppVersion=1.0.84 tool\cytest.iss
;
; 默认路径都写成相对本文件的 ..\，所以不带参数也能在仓库根目录直接编译。
; 注意基准是**脚本所在目录**（tool\），不是调用时的 cwd —— 写成 ..\..\ 会掉到 D:\ 上。
;
; 为什么是「每用户安装」而不是 Program Files：
;   cytest 不装服务、不建虚拟网卡，装到 %LOCALAPPDATA%\Programs\cytest
;   全程不弹 UAC，升级也不会因为占用 Program Files 而失败。
;   （对比 Bettbox：它有 wintun 网卡和 helper 服务，只能 PrivilegesRequired=admin。）
;
; 本文件含中文，必须保存为 **UTF-8 with BOM**，否则 Inno Setup 按 ANSI 解码会乱码。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
; AppId 只用来标识「同一个产品」，决定升级/卸载的匹配关系。一经发布就不能改，
; 改了会被当成另一个软件重装一份。这里必须是合法 UUID（Bettbox 那份末尾混进了
; 非十六进制字符，虽然 Inno 不校验，但没必要学）。
AppId={{6D2B7E91-5C4A-4F38-9B62-A1E0C73D5F84}
AppName=cytest
AppVersion={#AppVersion}
AppVerName=cytest {#AppVersion}
AppPublisher=cytest
AppPublisherURL=https://github.com/0-RTT/cytest-flutter
AppSupportURL=https://github.com/0-RTT/cytest-flutter/issues
DefaultDirName={localappdata}\Programs\cytest
DefaultGroupName=cytest
DisableProgramGroupPage=yes
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=cytest-windows-x64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\cytest.exe
UninstallDisplayName=cytest
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 不申请管理员权限：程序只写自己目录和 %APPDATA%\cytest
PrivilegesRequired=lowest
; 升级时如果 cytest 正在跑，先让它关掉再覆盖文件（否则 exe/dll 被占用直接失败）
CloseApplications=yes
CloseApplicationsFilter=cytest.exe
SetupLogging=yes
VersionInfoVersion={#AppVersion}
VersionInfoDescription=cytest 安装程序

[Languages]
Name: "zh"; MessagesFile: "innosetup\ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
; {cm:CreateDesktopIcon} / {cm:AdditionalIcons} / {cm:LaunchProgram} 都来自语言包，不用重复定义

[Tasks]
; 默认勾选：装完桌面直接有图标（用户仍可在向导里取消）。
; 这里不用 checkedonce —— 实测静默安装下 checkedonce 不算「勾选」，
; 桌面不会生成快捷方式；改成无 flags 后静默安装也会创建，行为一致。
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; 整个 Release 目录原样搬进去：cytest.exe + *.dll + data\ + bin\(引擎) + native_assets.json。
; bin\ 里的 xray.exe / pipeline.exe 必须在包里，缺了程序能开但一跑就提示「引擎不可用」。
; Excludes 排除本机跑过程序后 WebView2 落的用户数据目录（40MB+ 且带别人机器的缓存）。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "cytest.exe.WebView2\*"

[Icons]
Name: "{autoprograms}\cytest"; Filename: "{app}\cytest.exe"
Name: "{autodesktop}\cytest"; Filename: "{app}\cytest.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\cytest.exe"; Description: "{cm:LaunchProgram,cytest}"; Flags: nowait postinstall skipifsilent

[Code]
const
  WebView2ClientGuid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

{ WebView2 运行时的已装版本，没装返回空串。
  三种写法都要查：机器级 64 位视图、机器级 WOW6432Node（Evergreen 默认落这里）、
  以及每用户安装（HKCU）。只查一种会在部分机器上误报缺失。 }
function WebView2Version(): String;
var
  V: String;
begin
  V := '';
  if not RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + WebView2ClientGuid, 'pv', V) then
    if not RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\' + WebView2ClientGuid, 'pv', V) then
      RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + WebView2ClientGuid, 'pv', V);
  Result := V;
end;

function InitializeSetup(): Boolean;
var
  ErrorCode: Integer;
begin
  Result := True;
  if WebView2Version() <> '' then
    Exit;

  { 静默安装（CI/脚本）不弹窗，否则自动化会卡在这里 }
  if WizardSilent then
    Exit;

  { 方案 A 没有兜底：缺 WebView2，「获取数据」直接不可用，所以提前说清楚 }
  if MsgBox('未检测到 Microsoft Edge WebView2 运行时。' + #13#10 + #13#10 +
            'cytest 用它抓取 Censys 数据，缺少时「获取数据」不可用，' +
            '其余功能（本地测试、远程测试）不受影响。' + #13#10 + #13#10 +
            '是否现在打开官方下载页？安装完成后重新运行本安装程序即可。',
            mbConfirmation, MB_YESNO) = IDYES then
    ShellExec('open', 'https://go.microsoft.com/fwlink/p/?LinkId=2124703', '', '',
              SW_SHOWNORMAL, ewNoWait, ErrorCode);
end;
