# 使用说明（通用版）

## 桌面版

1. 双击 `my_notes.exe`（Release 目录内）启动。
2. 首次启动设置 4–6 位数字启动密码，需输入两次确认。
3. 之后每次启动输入该密码解锁；连续输错 5 次会冷却 30 秒。
4. 「设置 → 安全」可修改密码、关闭启动锁、立即锁定。
5. 关闭窗口会最小化到托盘；托盘右键菜单可新建笔记、搜索、设置、退出。
   全局热键 `Ctrl+Shift+Alt+N` 呼出窗口。

### 忘记密码

关闭程序，编辑 `notes-data/settings.txt`，删除 `lockHash`、`lockSalt`、`lockLen` 三行，
加入一行 `lockDisabled=1`，保存后重启即可关闭启动锁。**笔记数据不会丢失**。

## 网页版

```bash
cd web
docker compose up -d --build
```

打开 `http://<服务器IP>:8000`。默认无需令牌；需要访问控制时设置 `SYNC_TOKEN`。

## 双端同步

桌面版 `notes-data/settings.txt`：

```text
syncUrl=http://<服务器IP>:8000
syncToken=
```

与网页版 `SYNC_TOKEN` 保持一致即可。两端都留空 = 免令牌。
桌面版状态栏会显示「实时同步 · 已同步 N 条」。

## 数据位置

- 桌面版：`notes-data/notes.db` + `notes-data/attachments/`
- 网页版：`web/data/state.json` + `web/data/md/` + `web/data/attachments/`

请自行定期备份这两个目录。
