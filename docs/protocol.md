# App 与服务器的通信协议

App 对接的是 DS Bot 插件暴露给网页端的接口。这些**不是公开稳定的 API**，随 DS Bot 版本可能变化；已验证的版本是 `ds-bot 0.2.1`（DSH `0.2.1-rc.2`）。代码入口：`DSBot/Core/APIClient.swift`、`DSBot/Core/TeamStore.swift`、`DSBot/Core/EventsChannel.swift`。

## 登录流程

```
App                              ds-gateway                        dsh web
 │  GET /  (Authorization: Basic)   │                                  │
 │ ───────────────────────────────▶ │  校验基本认证                     │
 │                                  │ ───────────────────────────────▶ │
 │                                  │ ◀─────────────── 401（没有 Cookie）
 │ ◀──── 302 Location: /?token=… ── │
 │  GET /?token=…                   │ ───────────────────────────────▶ │
 │ ◀──── 303 + Set-Cookie dsh-auth-* ──────────────────────────────── │
 │  GET /  → 200                    │                                  │
 │  POST /api/bot …（带 Cookie）     │                                  │
```

- 每个请求都**主动**带 `Authorization: Basic …`（没填账号就不带），所以不会出现浏览器里 WebSocket 反复弹认证框的问题。
- 重定向到同一主机时保留 `Authorization`（`URLSession` 默认可能丢掉）。
- 任何接口返回 401 / 302 / 303，App 会重新走一遍上面的握手并重试一次。
- 直连原版 `dsh web`（没有网关）时，首页返回 401 且没有重定向，App 无法登录；所以需要网关或等价的令牌代办层，见 [server-setup.md](server-setup.md)。

## `POST /api/bot`

请求体 `{"endpoint": "...", "payload": {...}}`，成功返回 `{"ok": true, "value": ...}`，失败 `{"ok": false, "error": {"message": ...}}`。

| 用途 | endpoint |
|---|---|
| 团队状态（按 `revision` 增量；同时带回各 Bot 的工作状态与待审批项） | `state` |
| 聊天记录 / 更早的消息 | `chat` / `earlier` |
| 发消息 | `send` |
| 群聊里的工具审批 | `approval-answer`（`choice`: `allow` / `reject`） |
| 回答 Bot 的提问 | `answer-question` |
| 新建 / 修改 / 复制 / 删除 Bot | `create-bot` / `update-bot` / `duplicate-bot` / `delete-bot` |
| 设为主 Bot | `set-main` |
| 工作文件夹列表 | `folders` |
| 记忆 | `memory-view` / `memory-forget` |
| 定时任务 | `schedules` / `schedule-create` / `schedule-delete` |
| 用量（小时级记录，App 按天 / 周 / 月汇总） | `usage` |

`state` 的返回里没有每个 Bot 的"最后一条消息"，列表页的预览是 App 自己从 `chat` 的结果里取并缓存的。

停止正在工作的 Bot 不走 `/api/bot`，而是 DSH 的 `session/cancel`：`POST /api/session/cancel`，信封见下。

## DSH 自己的 RPC

`POST /api/<method>`，请求体：

```json
{"type": "client-request", "rpcId": "<uuid>", "method": "<method>", "payload": {"args": { … }}}
```

返回 `{"result": {"ok": true, "value": …}}`。App 用它调用 `session/cancel`（参数 `request.sessionId`）和 `$events/result`（见下）。

## 单聊里的审批走另一条通道

Bot 自己聊天里的工具审批（例如只读权限的 Bot 要写文件，需要提权）**不经过 `/api/bot`**：`state.work.approvals` 里这类条目的 `answerable` 是 `false`。网页端用的是 DSH 的事件通道，App 的 `EventsChannel` 实现了同一条：

1. WebSocket 连 `/api/remote.mux`，发 `{"type":"open","streamId":<uuid>,"endpoint":"$events","payload":{"args":{}}}`。
2. 收到 `{"type":"item","value":{"type":"ready","clientId":…}}` 拿到 `clientId`；之后审批以 `{"type":"waterfall","event":"approval/request","eventId":…,"agentId":<botId>,"request":{toolName,reason,displayReason}}` 推下来。
3. 回答：`POST /api/$events/result`，信封里 `method` 为 `$events/result`，`args` 为 `{clientId, eventId, outcome: {kind: "result", value: "allowed-once" | "rejected"}}`。

审批卡片的内容取自 `work.approvals`，按钮用事件里的 `eventId` 回答。事件通道没连上时按钮置灰并提示"正在同步审批请求"。

## 轮询节奏

前台：有 Bot 在工作时每 1.2 秒一次，否则 2.5 秒一次；失败时指数退避到最长 30 秒。`state` 带上次的 `revision`，没变化服务器只回 `unchanged`。当前打开的聊天在有变化、Bot 在工作、或每 4 个周期时重新拉取。进后台后借约 30 秒后台时间继续轮询，用于发本地通知。
