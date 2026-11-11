# 我的笔记 (mynotes)

一套**离线优先**的双端笔记应用：Windows 桌面版（Flutter）+ 自托管网页版（Python 标准库，零第三方依赖）。
两端通过同一份 JSON 状态 + SSE 实时同步，笔记数据始终留在你自己的设备或服务器上。

> 本仓库只包含**源代码与构建配置**，不含任何笔记内容、账号、令牌或密码。详见 [PRIVACY.md](PRIVACY.md)。

## 直接下载（Windows，免编译）

**[下载 v1.3.8](https://github.com/feibixunchang/mynotes/releases/latest)** · Windows 安装版：`MyNotes-1.3.8-Windows-x64-Setup.exe` · Windows 便携版：`mynotes-1.3.8-windows-x64-portable-clean.zip` · macOS：`MyNotes-1.3.8-macOS.dmg`

> 使用自托管 NAS 网页版的朋友，请把 `web/server.py` 与 `web/index.html` 一并更新到 v1.3.8
> （容器部署：替换这两个文件后重启容器即可）。**v1.3.8 的删除实时同步依赖新版服务端**：
> 旧的 `server.py` 广播里不带 `deletedIds`，另一端删除的笔记不会即时消失。

Windows 提供两种用法：**安装版**运行 Setup 向导（中文界面，可选桌面快捷方式，卸载保留笔记）；**便携版**解压后双击 `my_notes.exe`，无需安装、不写注册表。从便携版换到安装版，把旧目录的 `notes-data` 整个复制到安装目录即可迁移笔记。
两者都是**全新建的空笔记库**：不含任何笔记、账号、令牌、内网地址、日志或附件，也不捆绑商业字体（网页版统一使用系统默认字体）。
首次启动会要求设置 4–6 位数字启动锁；**同步地址需要自己填一次**：公开版不预置任何地址，全新安装时状态栏会显示红色的「未设置同步地址 · 点此设置」，点它进入「设置 → 同步」填写 NAS 地址与令牌即可。安装版与便携版各有独立数据目录，换用另一种时需重新填一次地址。
完整说明见包内 `使用说明.txt`，发布包的逐项隐私审计结果见 Release 页面。

## 功能

- **自动更新（Windows / macOS）**：启动后自动检查官方 Release，多渠道并发测速选最快下载，
  校验 SHA-256 后自动安装并重启；「设置 → 自动更新」可关闭或手动检查。
  更新请求不含任何本机信息，只读取公开的 GitHub / CDN 地址
- **实时同步 + 手动刷新（Windows / macOS / 网页版）**：内容变更走 SSE 事件拉取；
  **彻底删除走独立事件通道**，服务端广播直接携带 `deletedIds`，另一端收到即删，
  不再依赖 `rev` 增量或 `unchanged` 推断（实测三端 46ms 内到达）；`unchanged`
  下发删除与 30 秒轮询作为断线兜底。主页面 `⟳` 一键全量重取并重载三栏。
  左栏回收站下方还有「打开发布页」直达更新日志
- **回收站防误操作**：点击条目只预览、不改变状态；还原 / 彻底删除 / 清空回收站
  都需要二次确认，彻底删除会明确提示同步影响，操作按钮常显并带说明
- **Windows 安装向导**：中文安装界面、可选桌面快捷方式、开始菜单与卸载入口，
  卸载不删除笔记数据；不使用安装向导也可用零数据便携版
- **桌面版**：三栏布局、Markdown 编辑与预览、笔记本 / 标签 / 回收站、全文搜索、置顶、
  图片查看与插入、导入 Simplenote JSON / Markdown、系统托盘与全局热键 `Ctrl+Shift+Alt+N`
- **启动锁**：首次启动强制设置 4–6 位数字密码，之后每次启动需解锁；
  加盐 SHA-256 存储，连续输错 5 次冷却 30 秒；可在「设置 → 安全」修改 / 关闭 / 立即锁定
- **生物识别解锁**：系统配好 Windows Hello（指纹 / 人脸 / PIN）后，锁屏页会出现
  「Windows Hello 解锁」按钮。验证弹窗由系统自己完成，应用只拿到「通过 / 未通过」，
  不接触指纹模板、人脸数据或 PIN；没配 Hello 的设备该按钮不显示
- **单实例**：同一 Windows 账号下只允许开一个窗口，重复双击图标会把已有窗口唤到前台
  （即使它已经关到托盘），不会再出现两个进程同时改同一个笔记库；点窗口的关闭按钮
  是最小化到托盘而不是退出，真正退出走托盘右键菜单「退出」
- **同步设置界面**：「设置 → 同步」里可直接填服务器地址与令牌，支持「测试连接」和
  「保存并重连」，不必再手改 `settings.txt`；换服务器会做一次完整推送
- **网页版**：三栏布局、编辑 / 预览、看图、插入图片、删除 / 还原 / 彻底删除、
  导入导出 Markdown、中文右键菜单、SSE 实时同步；手机浏览器自动切换成
  单栏 + 抽屉式导航，并支持安卓返回键从正文退回列表
- **跨端一致性**：一端「清空所有笔记」通过 `epoch` 机制同步到另一端，不会把旧笔记推回来
- **版本号**：窗口标题、状态栏、设置页、网页右下角、`/health` 接口五处一致

## 快速开始

### 网页版（最简单，Docker 一键起）

```bash
cd web
docker compose up -d --build
```

浏览器打开 `http://<服务器IP>:8000`。默认 `SYNC_TOKEN` 为空，局域网内**直接打开、不需要输入令牌**。
如需访问控制，在 `docker-compose.yml` 里设置 `SYNC_TOKEN`。

数据保存在 `web/data/`（已被 `.gitignore` 排除），包含 `state.json`、Markdown 镜像和附件。

### 桌面版（Windows）

不想编译的话，直接用上面的 [Release 便携版](#直接下载windows免编译)。自行编译的要求：
Flutter 3.x（Windows 桌面支持）、Visual Studio 2022 Build Tools（C++ 桌面工作负载）、Windows 10/11 SDK。

```bash
cd desktop
flutter pub get
flutter build windows --release
```

产物在 `desktop/build/windows/x64/runner/Release/`。把整个 Release 目录拷到任意位置即可绿色运行；
数据目录为程序目录下的 `notes-data/`。

首次运行会进入「设置启动密码」页，设置 4–6 位数字后进入主界面。

### 让两端同步

桌面版「设置」里配置同步地址，或直接编辑 `notes-data/settings.txt`：

```text
syncUrl=http://<服务器IP>:8000
syncToken=
```

`syncToken` 与网页版的 `SYNC_TOKEN` 保持一致；两边都留空即可免令牌。
配置值按 `\n` 解析，写入时统一 LF，避免 CRLF 残留导致 HTTP 请求头非法。

## 关于字体

原开发版内嵌「方正宋黑」，该字体为**商业授权字体，本仓库和 Release 便携版都不分发**。
公开版默认使用系统自带中文字体（Windows 上为微软雅黑，其他平台自动回退到系统中文字体），
字形与原版略有不同，功能完全不受影响。
自备授权字体的方法见 [desktop/assets/fonts/README.md](desktop/assets/fonts/README.md)；
网页版同理，见 [web/README.md](web/README.md)。

## macOS（想自己编译请看这里）

Flutter **不支持从 Windows 交叉编译 macOS 应用**，`windows/` runner、`flutter_windows.dll`、
`sqlite3.dll`、`app.so` 与 Release 里的 Windows 便携包在 Mac 上都不能用，必须在 Mac 上重新编译全部二进制。
本仓库目前只有 `windows/` 平台目录，所以也不是「拿来源码直接 build」就能出 DMG，需要先生成
macOS 工程并替换平台专属代码：

```bash
# 在 Mac 上：需 Xcode（含命令行工具）、Flutter 3.x macOS 桌面支持、CocoaPods
git clone https://github.com/feibixunchang/mynotes.git
cd mynotes/desktop
flutter create --platforms=macos .     # 生成 macos/ Runner 与 Xcode 工程
flutter pub get
flutter build macos --release          # 产物是 .app，不是 DMG
```

编译前需要处理：

1. **系统托盘**：`windows/runner/main.cpp` 里的 Win32 `Shell_NotifyIconW` 右键菜单不会进入 macOS 工程，
   要在 `macos/Runner/AppDelegate.swift` 用 `NSStatusItem` + `NSMenu` 重写，或改用 `tray_manager` 之类的跨平台插件。
2. **全局热键**：`Ctrl+Shift+Alt+N` 在 macOS 上需用 `NSEvent` 全局监听或 `hotkey_manager`，并申请辅助功能权限。
3. **nativeapi**：插件声明了 macOS 平台且底层带 Objective-C++ 实现，Dart 层窗口/文件对话框/DPI 调用可保留，
   但沙箱与签名下的行为需实测。
4. **SQLite**：Windows 的 `sqlite3.dll` 用不了；macOS 自带 `libsqlite3.dylib`，
   `sqflite_common_ffi` 可直接加载，需确认 `.app` 内的动态库查找路径。
5. **字体与路径**：`FZ_FONT` 为 `Microsoft YaHei`，Mac 上会自动回退到苹方；
   数据目录在程序目录不可写时已改为 `~/Library/Application Support/MyNotes/`（见 `lib/db.dart`）。
   启动锁、笔记逻辑、同步均为纯 Dart，可直接复用。

打 DMG（`flutter build macos --release` 只产出 `.app`）：

```bash
brew install create-dmg
create-dmg --volname "我的笔记" --app-drop-link 480 170 --window-size 660 400 \
  --icon "my_notes.app" 180 170 "我的笔记-1.3.4.dmg" \
  build/macos/Build/Products/Release/my_notes.app
```

未签名未公证的 `.app` / DMG 在别人 Mac 上会被 Gatekeeper 拦截；自用可执行 `xattr -cr my_notes.app`，
公开分发则需要 Apple Developer 账号做 Developer ID 签名 + `xcrun notarytool` 公证。
同步照常在「设置」里填自己的网页版地址即可。

> 说明：**v1.3.5 起已提供经过 Mac 实机编译、签名与验收的 macOS DMG**（当前为 v1.3.8）
> （应用显示名为「我的笔记」，ad-hoc 签名，未做 Developer ID 签名与公证；
> 首次打开若被 Gatekeeper 拦截，执行 `xattr -cr "/Applications/我的笔记.app"`）。
>
> [v1.3.3 Release](https://github.com/feibixunchang/mynotes/releases/tag/v1.3.3) 里另外提供了
> `mynotes-1.3.3-macos-port-handoff.zip`：一份已做好平台适配、解压即可编译的 macOS Flutter 工程
> （已移除 Windows 原生插件，托盘/窗口/文件对话框改用 Cocoa + MethodChannel 实现），
> 附 `README_FIRST.txt` —— 给 Mac 端 AI 的执行指令、常见报错处理和逐项验收清单。
>
> Windows 便携包由 `.github/workflows/build-windows.yml` 在发布 Release 时自动构建，
> 构建产物为全新的空笔记库，不含任何笔记、配置、令牌或日志。

## 目录结构

```text
desktop/    Flutter Windows 应用源码（lib/、assets/、windows/ runner、test/）
web/        自托管网页版（server.py、index.html、Dockerfile、compose）
.github/    GitHub Actions：发布 Release 时自动构建 Windows 便携包
update/     latest.json：自动更新的兜底版本清单（api.github.com 不可达时读取）
docs/       使用说明
scripts/    隐私自查脚本
```

## 常见问题

- **忘记启动密码**：关闭程序，编辑 `notes-data/settings.txt`，删除 `lockHash`、`lockSalt`、
  `lockLen` 三行并加入 `lockDisabled=1`，重启即可关闭启动锁。**笔记数据完全保留**。
  启动锁用于防止他人随手打开软件查看，不等于数据库加密；请勿把它当作强加密方案。
- **状态栏提示同步失败**：确认 `syncUrl` 可达、`syncToken` 与服务端一致，且没有被系统代理拦截。
- **小字不清晰 / 想换字体**：见上面的字体说明。

## 许可证

[MIT](LICENSE)。字体、图标等第三方素材请遵循各自授权。
