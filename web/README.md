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
| POST | `/api/purge` | 彻底删除单条笔记、写入删除墓碑并广播删除事件 |
| POST | `/api/clear` | 清空全部笔记、递增 epoch 并广播全部被删 id |
| GET | `/api/events` | SSE 实时推送。**v1.3.8 起广播与 `hello` 帧都携带 `deletedIds`**：客户端收到即删本地记录，不必反查 `/api/state`；`hello` 带全部当前墓碑用于重连补偿。响应带 `X-Accel-Buffering: no`，反代不会缓冲事件 |
| GET | `/api/export.md` | 导出全部 Markdown |
| POST | `/api/attachment` | 上传附件 |

## 字体

v1.3.7 起网页版不再加载任何自定义字体，统一使用 `system-ui` 系统默认字体栈，
按钮与输入框一律继承。`index.html` 中不存在 `@font-face`，无需附带字体文件。

## 实时同步回归测试

```bash
python3 web/test_realtime_sync.py
```

脚本会起一个隔离的真实 `server.py`（独立临时数据目录 + 随机本地端口），
模拟三个 SSE 订阅者并验证删除广播、purge 广播、移入回收站不误报、
`unchanged` 兜底，且不触碰任何真实笔记数据。

## 安全提示

默认免令牌是**为可信局域网**设计的。部署到公网或不可信网络时，请设置 `SYNC_TOKEN`
并配合反向代理与 HTTPS。数据目录请纳入定期备份。
