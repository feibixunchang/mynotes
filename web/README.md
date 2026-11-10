# 自托管网页版

仅需 Python 3.13 标准库（Docker 方式无需本机装 Python）。

```bash
docker compose up -d --build
# 或本机直接运行
PORT=8000 DATA_DIR=./data python server.py
```

打开 `http://localhost:8000`。

## 配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `8000` | 监听端口 |
| `DATA_DIR` | `/data` | 数据目录（state.json、md/、attachments/） |
| `SYNC_TOKEN` | 空 | 留空 = 免令牌；非空时页面与接口需要该令牌 |

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/health` | 版本、构建时间、rev、epoch、认证开关 |
| GET | `/api/state` | 全量笔记状态；`deletedIds` / `deletedAt` 下发删除墓碑，客户端据此移除已彻底删除的笔记。带 `since=<rev>` 且 `since == 当前rev` 时返回 `unchanged: true`（`notes` 为空），**v1.3.7 起该响应同样携带 `deletedIds` / `deletedAt` / `epoch`**，避免另一端删除要等下一次笔记变更才同步 |
| POST | `/api/sync` | 推送/合并笔记；可携带 `deletedIds` / `deletedAt` 批量删除，返回 `deletedApplied` |
| POST | `/api/purge` | 彻底删除单条笔记并写入删除墓碑 |
| POST | `/api/clear` | 清空全部笔记并递增 epoch |
| GET | `/api/events` | SSE 实时推送 |
| GET | `/api/export.md` | 导出全部 Markdown |
| POST | `/api/attachment` | 上传附件 |
| GET | `/font.ttf` | 可选自定义字体；未放置时返回 404，前端回退系统字体 |

## 字体（可选）

自备授权字体时，把 `FangZhengSongHei.ttf` 放到本目录，并在 `Dockerfile` 的 `COPY` 行补上文件名，
然后 `docker compose up -d --build`。未放置时页面使用系统字体。

## 安全提示

默认免令牌是**为可信局域网**设计的。部署到公网或不可信网络时，请设置 `SYNC_TOKEN`
并配合反向代理与 HTTPS。数据目录请纳入定期备份。
