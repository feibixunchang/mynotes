# 我的笔记 (mynotes)

一套**离线优先**的双端笔记应用：Windows 桌面版（Flutter）+ 自托管网页版（Python 标准库，零第三方依赖）。
两端通过同一份 JSON 状态 + SSE 实时同步，笔记数据始终留在你自己的设备或服务器上。

> 本仓库只包含**源代码与构建配置**，不含任何笔记内容、账号、令牌或密码。详见 [PRIVACY.md](PRIVACY.md)。

## 功能

- **桌面版**：三栏布局、Markdown 编辑与预览、笔记本 / 标签 / 回收站、全文搜索、置顶、
  图片查看与插入、导入 Simplenote JSON / Markdown、系统托盘与全局热键 `Ctrl+Shift+Alt+N`
- **启动锁**：首次启动强制设置 4–6 位数字密码，之后每次启动需解锁；
  加盐 SHA-256 存储，连续输错 5 次冷却 30 秒；可在「设置 → 安全」修改 / 关闭 / 立即锁定
- **网页版**：三栏布局、编辑 / 预览、看图、插入图片、删除 / 还原 / 彻底删除、
  导入导出 Markdown、中文右键菜单、SSE 实时同步
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

环境要求：Flutter 3.x（Windows 桌面支持）、Visual Studio 2022 Build Tools（C++ 桌面工作负载）、Windows 10/11 SDK。

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

原版界面使用内嵌「方正宋黑」，该字体为**商业授权字体，本仓库不分发**。
未放置字体文件时，Flutter 会自动回退到系统字体，构建与功能都不受影响，只是字形不同。
自备授权字体的方法见 [desktop/assets/fonts/README.md](desktop/assets/fonts/README.md)；
网页版同理，见 [web/README.md](web/README.md)。

## 目录结构

```text
desktop/    Flutter Windows 应用源码（lib/、assets/、windows/ runner）
web/        自托管网页版（server.py、index.html、Dockerfile、compose）
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
