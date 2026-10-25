#!/usr/bin/env node
// DS Bot 网关：给 `dsh web` 加一层认证，并替 App 完成 DSH 的一次性令牌登录。
//
// 为什么需要它：`dsh web` 启动时只在日志里打印一次性登录链接（?token=…），浏览器带着令牌访问一次，
// 换到会话 Cookie 之后才能用。手机 App 没法读服务器日志，所以由网关代劳：
//
//   App ──(HTTP 基本认证)──▶ 网关 ──(回环地址)──▶ dsh web
//
// - 网关自己启动 `dsh web`（命令写在 `--` 后面），从它的标准输出里读出令牌；
// - 请求未带 Cookie、上游回 401 时，网关把客户端 302 到 `/?token=…`，由 DSH 种下会话 Cookie；
// - 配了 DS_GATEWAY_USER / DS_GATEWAY_PASS 时，所有请求（含 WebSocket）都要先通过基本认证，
//   不通过直接 401，请求不会到达 DSH；
// - 没配账号密码时，只给来自内网地址的客户端发令牌（经反向代理转发时看 X-Forwarded-For），
//   公网来源一律 403；
// - 可选直接提供 HTTPS（DS_GATEWAY_TLS_CERT / DS_GATEWAY_TLS_KEY）。
//
// 用法：
//   DS_GATEWAY_USER=me DS_GATEWAY_PASS=secret \
//   node ds-gateway.mjs -- dsh --profile web --no-open --host 127.0.0.1 --port {PORT}
//
// `{PORT}` 会被替换成网关选出的回环端口。无任何第三方依赖，需要 Node.js 20+。
import http from "node:http";
import https from "node:https";
import net from "node:net";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { timingSafeEqual, createHash } from "node:crypto";

const listenHost = process.env.DS_GATEWAY_HOST ?? "0.0.0.0";
const listenPort = Number(process.env.DS_GATEWAY_PORT ?? 8731);
const authUser = process.env.DS_GATEWAY_USER ?? "";
const authPass = process.env.DS_GATEWAY_PASS ?? "";
const tlsCert = process.env.DS_GATEWAY_TLS_CERT;
const tlsKey = process.env.DS_GATEWAY_TLS_KEY;
// 反向代理（Caddy / nginx / NPM）在前面时填 1：此时只信任 X-Forwarded-* 头里的真实客户端地址和协议
const behindProxy = process.env.DS_GATEWAY_BEHIND_PROXY === "1";
const tokenTimeoutMs = 90_000;

function log(message) {
  process.stderr.write(`${new Date().toISOString()} [ds-gateway] ${message}\n`);
}

const separator = process.argv.indexOf("--");
const command = separator >= 0 ? process.argv.slice(separator + 1) : [];
if (command.length === 0) {
  process.stderr.write("用法：node ds-gateway.mjs -- <启动 dsh web 的命令，端口写成 {PORT}>\n");
  process.exit(2);
}
if ((authUser === "") !== (authPass === "")) {
  process.stderr.write("DS_GATEWAY_USER 和 DS_GATEWAY_PASS 必须同时设置\n");
  process.exit(2);
}
if ((tlsCert === undefined) !== (tlsKey === undefined)) {
  process.stderr.write("DS_GATEWAY_TLS_CERT 和 DS_GATEWAY_TLS_KEY 必须同时设置\n");
  process.exit(2);
}

// ---------- 认证 ----------

function digest(value) {
  return createHash("sha256").update(value).digest();
}

/** 常量时间比较：先哈希成等长再比，避免泄露长度和前缀 */
function safeEqual(a, b) {
  return timingSafeEqual(digest(a), digest(b));
}

function passesBasicAuth(req) {
  if (authUser === "") return true;
  const header = String(req.headers.authorization ?? "");
  if (!/^Basic /i.test(header)) return false;
  const decoded = Buffer.from(header.slice(6).trim(), "base64").toString("utf8");
  const colon = decoded.indexOf(":");
  if (colon < 0) return false;
  const userOk = safeEqual(decoded.slice(0, colon), authUser);
  const passOk = safeEqual(decoded.slice(colon + 1), authPass);
  return userOk && passOk;
}

function isPrivateAddress(raw) {
  const ip = String(raw ?? "").replace(/^::ffff:/, "");
  return (
    ip === "127.0.0.1" || ip === "::1" ||
    /^10\./.test(ip) || /^192\.168\./.test(ip) || /^172\.(1[6-9]|2\d|3[01])\./.test(ip) ||
    /^f[cd][0-9a-f]{2}:/i.test(ip) || /^fe80:/i.test(ip)
  );
}

/** 客户端真实地址是否在内网。经反向代理时，socket 对端永远是代理自己，要看转发头 */
function clientIsPrivate(req) {
  if (!behindProxy) return isPrivateAddress(req.socket.remoteAddress);
  const forwarded = String(req.headers["x-forwarded-for"] ?? req.headers["x-real-ip"] ?? "")
    .split(",").map((item) => item.trim()).filter(Boolean);
  // 没有转发头说明请求没经过代理（直连网关），按 socket 对端算
  if (forwarded.length === 0) return isPrivateAddress(req.socket.remoteAddress);
  return isPrivateAddress(req.socket.remoteAddress) && forwarded.every(isPrivateAddress);
}

function deny(res, status, text, extra = {}) {
  res.writeHead(status, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", ...extra });
  res.end(text);
}

function unauthorized(res) {
  deny(res, 401, "需要认证", { "www-authenticate": 'Basic realm="DS Bot", charset="UTF-8"' });
}

// ---------- 上游 dsh web ----------

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

const internalPort = await freePort();
const authority = `127.0.0.1:${internalPort}`;
let token = null;
let child = null;
let restarts = 0;
let shuttingDown = false;

function launch() {
  const args = command.map((part) => part.replaceAll("{PORT}", String(internalPort)));
  log(`启动：${args.join(" ")}`);
  child = spawn(args[0], args.slice(1), { env: process.env, stdio: ["ignore", "pipe", "pipe"] });
  let buffer = "";
  let announced = false;
  const timer = setTimeout(() => {
    if (!announced) log(`${tokenTimeoutMs / 1000} 秒内没有在输出里看到 ?token=…，请检查上面的命令`);
  }, tokenTimeoutMs);
  child.on("error", (error) => log(`启动失败：${error.message}`));
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    process.stdout.write(chunk.replace(/token=[A-Za-z0-9_-]+/g, "token=<hidden>"));
    buffer = (buffer + chunk).slice(-4096);
    const match = buffer.match(/[?&]token=([A-Za-z0-9_-]+)/);
    if (match) {
      token = match[1];
      restarts = 0;
      if (!announced) {
        announced = true;
        clearTimeout(timer);
        log("dsh web 已就绪");
      }
    }
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => process.stderr.write(chunk));
  child.once("exit", (code, signal) => {
    clearTimeout(timer);
    token = null;
    if (shuttingDown) return;
    log(`dsh web 退出（code=${code} signal=${signal}）`);
    restarts += 1;
    if (restarts > 10) {
      log("连续重启 10 次仍失败，放弃；网关保持运行并返回 503");
      return;
    }
    const delay = Math.min(30_000, 2_000 * 2 ** (restarts - 1));
    log(`${delay / 1000} 秒后重启`);
    setTimeout(() => { if (!shuttingDown) launch(); }, delay);
  });
}

// ---------- 代理 ----------

const SKIP_REQUEST_HEADERS = new Set(["authorization", "x-forwarded-for", "x-forwarded-proto", "x-forwarded-host", "x-real-ip", "forwarded"]);

function upstreamHeaders(req) {
  const headers = {};
  for (const [name, value] of Object.entries(req.headers)) {
    if (!SKIP_REQUEST_HEADERS.has(name)) headers[name] = value;   // 基本认证凭据只在网关用，不转给 DSH
  }
  // DSH 有“同源”校验：把对外的 Host/Origin 换成上游自己的回环地址。认证已经在网关做完
  headers.host = authority;
  if (headers.origin) headers.origin = `http://${authority}`;
  if (headers.referer) headers.referer = `http://${authority}/`;
  return headers;
}

function secureRequest(req) {
  if (tlsCert !== undefined) return true;
  return behindProxy && String(req.headers["x-forwarded-proto"] ?? "").split(",")[0].trim() === "https";
}

function handle(req, res) {
  if (!passesBasicAuth(req)) return unauthorized(res);
  const path = req.url ?? "/";
  const upstream = http.request(
    { host: "127.0.0.1", port: internalPort, method: req.method, path, headers: upstreamHeaders(req) },
    (upstreamRes) => {
      const status = upstreamRes.statusCode ?? 502;
      if (status === 401 && req.method === "GET" && path === "/") {
        upstreamRes.resume();
        // 令牌只发给通过认证的人；没配认证时只发给内网
        const allowed = authUser !== "" || clientIsPrivate(req);
        if (!allowed) {
          log(`拒绝给非内网客户端发令牌：${req.socket.remoteAddress}（xff=${req.headers["x-forwarded-for"] ?? "-"}）`);
          return deny(res, 403, "未配置认证时，只允许从局域网访问");
        }
        if (token === null) return deny(res, 503, "dsh web 正在启动，稍后重试");
        res.writeHead(302, { location: `/?token=${token}`, "cache-control": "no-store" });
        res.end();
        return;
      }
      const headers = { ...upstreamRes.headers };
      if (headers["set-cookie"]) {
        // iOS 的重定向链里 SameSite=Strict 会让 Cookie 丢失（登录死循环），放宽到 Lax；HTTPS 下加 Secure
        const secure = secureRequest(req);
        headers["set-cookie"] = [].concat(headers["set-cookie"]).map((cookie) => {
          let next = cookie.replace(/;\s*SameSite=Strict/i, "; SameSite=Lax");
          if (secure && !/;\s*Secure/i.test(next)) next += "; Secure";
          return next;
        });
      }
      const eventStream = String(headers["content-type"] ?? "").includes("text/event-stream");
      if (eventStream) {
        // 实时通道是 SSE：禁止中间层缓冲，否则事件迟迟不到
        headers["x-accel-buffering"] = "no";
        headers["cache-control"] = "no-cache, no-transform";
        delete headers["content-length"];
      }
      res.writeHead(status, headers);
      if (eventStream) res.flushHeaders?.();
      upstreamRes.pipe(res);
    },
  );
  upstream.on("error", (error) => {
    log(`上游错误：${error.message}`);
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end("dsh web 不可用");
  });
  req.pipe(upstream);
}

function handleUpgrade(req, socket, head) {
  if (!passesBasicAuth(req)) {
    socket.end('HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="DS Bot"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
    return;
  }
  const upstream = net.connect(internalPort, "127.0.0.1", () => {
    const lines = Object.entries(upstreamHeaders(req)).map(([name, value]) => `${name}: ${Array.isArray(value) ? value.join(", ") : value}`);
    upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n${lines.join("\r\n")}\r\n\r\n`);
    if (head?.length) upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
}

launch();
const server = tlsCert !== undefined
  ? https.createServer({ cert: readFileSync(tlsCert), key: readFileSync(tlsKey) }, handle)
  : http.createServer(handle);
server.on("upgrade", handleUpgrade);
server.on("error", (error) => {
  log(`监听失败：${error.message}`);
  child?.kill("SIGTERM");
  process.exit(1);
});
server.listen(listenPort, listenHost, () => {
  const scheme = tlsCert !== undefined ? "https" : "http";
  log(`监听 ${scheme}://${listenHost}:${listenPort}（${authUser !== "" ? `基本认证，用户 ${authUser}` : "未配置认证，仅局域网可登录"}）`);
});

function shutdown(signal) {
  shuttingDown = true;
  log(`收到 ${signal}，退出`);
  server.close();
  child?.kill("SIGTERM");
  setTimeout(() => process.exit(0), 3_000).unref();
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("uncaughtException", (error) => {
  log(`未捕获异常：${error?.stack ?? error}`);
  child?.kill("SIGTERM");
  setTimeout(() => process.exit(1), 500).unref();
});
