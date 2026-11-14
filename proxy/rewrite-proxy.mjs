#!/usr/bin/env node
/**
 * rewrite-proxy.mjs — DSH Cloud Shell 反向代理 (持久化版本, 位于 ~/dsh-tools/)
 *
 * 监听 127.0.0.1:3081, 转发到 127.0.0.1:3080
 *   - 改 Host = 127.0.0.1:3080
 *   - 改 Origin = http://127.0.0.1:3080   (满足 DSH 信任围栏 Origin === Host)
 *   - 普通请求: /api/* 等全路径转发, 双向流式透传
 *   - WebSocket Upgrade: 保留 Upgrade/Connection/Sec-WebSocket-*, 双向透传
 *   - GET /login: 从 dsh.log 取当前 launch token, 303 跳到 /?token=...
 *     终端链接识别会截掉 "?token=...", 故提供一个不带查询串的入口.
 *     注意: 这不是门禁, 任何能访问本代理的人 (含命名隧道域名) 都能登录.
 * 纯 Node 内置模块 (node:http / node:net / node:fs), 无第三方依赖, 不安装任何软件.
 */
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';

const LISTEN_HOST = '127.0.0.1';
const LISTEN_PORT = Number(process.env.PROXY_PORT ?? 3081);
const TARGET_HOST = '127.0.0.1';
const TARGET_PORT = 3080;
const LOGIN_PATH = '/login';
const DSH_LOG = `${process.env.HOME ?? ''}/.cache/dsh/dsh.log`;

/**
 * ── Cloudflare 302 跳板（方案：CF 只做跳转，流量走 Preview）──
 *
 * 动机：Cloudflare 免费隧道对 SSE/WebSocket 长连接有边缘空闲切断（表现为 1033），
 *       加心跳只能缓解不能根除；而 Cloud Shell Preview 走 Google 自己的链路，
 *       长连接没有这个问题，速度也更快。
 *       但 Preview 域名里的区域段会随 VM 迁移变化（us-east1 -> us-central1），书签会失效。
 *
 * 做法：书签用固定域名 dsh.<domain>（Cloudflare），它只回一个 302 跳到当前 Preview。
 *       浏览器随后直连 Preview，实际流量完全不过 Cloudflare，
 *       因此那条被切断的长连接也不存在了 —— 1033 消失。
 *
 * 判据：本代理只监听 127.0.0.1:3081，所以凡是从公网域名进来的请求，
 *       Host 一定不是 127.0.0.1:3081。用这个区分「外部跳板入口」和「内网直连」。
 */
const JUMP_ENABLED = process.env.PROXY_JUMP !== '0';
const PREVIEW_HOST = process.env.WEB_HOST ?? '';           // 形如 cs-xxx.cs-us-central1-pits.cloudshell.dev
const PREVIEW_PORT = process.env.PREVIEW_PORT ?? '3081';
// 命中跳板时排除的路径：跳板本身要能被探测存活
const JUMP_EXCLUDE = new Set(['/__jump_health']);

function previewBase() {
  if (!PREVIEW_HOST) return '';
  return `https://${PREVIEW_PORT}-${PREVIEW_HOST}`;
}

/** 是否是经公网域名（Cloudflare/Tailscale 等）进来的请求 */
function isExternalEntry(hostHeader) {
  if (!hostHeader) return false;
  const h = String(hostHeader).toLowerCase();
  return !(h === `127.0.0.1:${LISTEN_PORT}` || h === '127.0.0.1' || h === `localhost:${LISTEN_PORT}`);
}

/**
 * 让浏览器端把本页当成 loopback 主机页.
 *
 * 客户端在 dsh-client-connection/lib/client.js 里自己算:
 *   isLoopback = transport?.ownsHost === true || isLoopbackHostname(location.hostname)
 * 而 __DSH_TRANSPORT__ 全仓库只有读取、无任何赋值 (浏览器里恒为 undefined),
 * 所以公网域名下 isLoopback 恒为 false -> 设置走 "memory" 持久化 ->
 * 提供方目录报 "settings are unavailable in this browser".
 * 这里在应用模块脚本之前注入 ownsHost, 是唯一被客户端认可的开关.
 */
const INJECT_PATHS = new Set(['/', '/index.html']);
const TRANSPORT_BOOTSTRAP =
  '<script>globalThis.__DSH_TRANSPORT__={...globalThis.__DSH_TRANSPORT__,"ownsHost":true}</script>';

/** 在 <head> 之后插入 bootstrap, 保证早于任何模块脚本执行. */
function injectBootstrap(html) {
  const match = /<head[^>]*>/i.exec(html);
  if (match === null) return TRANSPORT_BOOTSTRAP + html;
  const at = match.index + match[0].length;
  return html.slice(0, at) + TRANSPORT_BOOTSTRAP + html.slice(at);
}

/**
 * 读取 dsh.log 末尾, 取最后一条 "dsh web: http://.../?token=..." 里的 token.
 * token 每次启动重新随机生成, 所以必须现读, 不能缓存.
 * @returns token 字符串; 找不到返回空串.
 */
function currentToken() {
  let fd;
  try {
    fd = fs.openSync(DSH_LOG, 'r');
    const size = fs.fstatSync(fd).size;
    const length = Math.min(size, 65536);
    const buf = Buffer.alloc(length);
    fs.readSync(fd, buf, 0, length, size - length);
    const matches = [
      ...buf
        .toString('utf8')
        .matchAll(/dsh web: http:\/\/127\.0\.0\.1:\d+\/\?token=([A-Za-z0-9_-]+)/g),
    ];
    return matches.length > 0 ? matches[matches.length - 1][1] : '';
  } catch {
    return '';
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

// 重写后的上游请求头
function rewriteHeaders(headers) {
  const h = { ...headers };
  h.host = `${TARGET_HOST}:${TARGET_PORT}`;
  if (h.origin) h.origin = `http://${TARGET_HOST}:${TARGET_PORT}`;
  return h;
}

// --- 普通 HTTP 请求 (含 /api/* POST/GET) ---
const server = http.createServer((req, res) => {
  // ═══ 第一优先：公网域名进来的一律 302 到 Preview ═══
  // 放在最前面，确保 /login、/api/*、SSE 等都先被跳走，
  // 浏览器随后直连 Preview，长连接不再经过 Cloudflare。
  if (JUMP_ENABLED) {
    const pathOnly = (req.url ?? '/').split('?')[0];
    if (pathOnly === '/__jump_health') {
      const base = previewBase();
      res.writeHead(200, { 'cache-control': 'no-store', 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, jump: !!base, target: base || null }) + '\n');
      return;
    }
    if (!JUMP_EXCLUDE.has(pathOnly) && isExternalEntry(req.headers.host)) {
      const base = previewBase();
      if (base) {
        // 保留原始路径与查询串（含 token），跳到 Preview 的同路径
        const suffix = req.url ?? '/';
        res.writeHead(302, {
          'cache-control': 'no-store',
          location: base + suffix,
          'referrer-policy': 'no-referrer',
        });
        res.end();
        return;
      }
      // 没有 WEB_HOST 时无法跳转，给出明确提示而不是空 500
      res.writeHead(503, { 'cache-control': 'no-store', 'content-type': 'text/plain; charset=utf-8' });
      res.end('rewrite-proxy: 未配置 WEB_HOST，无法生成 Preview 跳转地址\n');
      return;
    }
  }

  // 无查询串的登录入口: 终端点击 https://<域名>/login 即可完成认证
  if (req.method === 'GET' && req.url?.split('?')[0] === LOGIN_PATH) {
    const token = currentToken();
    if (token === '') {
      res.writeHead(503, {
        'cache-control': 'no-store',
        'content-type': 'text/plain; charset=utf-8',
      });
      res.end(`rewrite-proxy: 未在 ${DSH_LOG} 找到 token, 请确认 DSH 已启动\n`);
      return;
    }
    res.writeHead(303, {
      'cache-control': 'no-store',
      location: `/?token=${token}`,
      'referrer-policy': 'no-referrer',
    });
    res.end();
    return;
  }

  // 应用外壳 (/ 或 /index.html): 需要改写 HTML, 故取未压缩体并缓冲
  const path = (req.url ?? '/').split('?')[0];
  const wantsInjection = req.method === 'GET' && INJECT_PATHS.has(path);

  const headers = rewriteHeaders(req.headers);
  if (wantsInjection) delete headers['accept-encoding']; // 拿 identity 编码, 免得解压

  const upstream = http.request(
    {
      host: TARGET_HOST,
      port: TARGET_PORT,
      method: req.method,
      path: req.url,
      headers,
      setHost: false, // 不覆盖我们显式写入的 Host
    },
    (upRes) => {
      const type = String(upRes.headers['content-type'] ?? '');

      // ── SSE 长连接保活（修复 Cloudflare 1033）──
      // 现象: 经命名隧道访问时，每约 128s 断一次，浏览器报 1033。
      // 根因: DSH 的 /plugins/events 是 SSE，只在插件图变化时推数据，
      //       平时完全静默（实测 180s 仅开头一条 : connected + 一条 data）。
      //       Cloudflare 对空闲流有超时，到点切断 → 前端 1033。
      // 做法: 对 event-stream 响应每 15s 写一个 SSE 注释行（": ping"）。
      //       注释行按 SSE 规范会被客户端忽略，不影响协议语义，
      //       但能让流保持“有数据”状态，避免被边缘节点判定空闲。
      if (type.includes('text/event-stream')) {
        res.writeHead(upRes.statusCode, {
          ...upRes.headers,
          'cache-control': 'no-cache, no-transform',
          'x-accel-buffering': 'no',
        });
        // 立刻 flush 头部，让客户端尽早进入事件流状态
        if (typeof res.flushHeaders === 'function') res.flushHeaders();

        const PING_MS = 5000;
        const ping = setInterval(() => {
          if (res.writableEnded) return;
          try {
            res.write(': ping\n\n');
          } catch {
            /* 客户端已断开，交由 close 清理 */
          }
        }, PING_MS);
        // 不阻止进程退出
        if (typeof ping.unref === 'function') ping.unref();

        const cleanup = () => clearInterval(ping);
        upRes.on('end', cleanup);
        upRes.on('error', cleanup);
        res.on('close', cleanup);

        upRes.pipe(res);
        return;
      }

      if (!wantsInjection || upRes.statusCode !== 200 || !type.includes('text/html')) {
        res.writeHead(upRes.statusCode, upRes.headers);
        upRes.pipe(res);
        return;
      }
      const chunks = [];
      upRes.on('data', (chunk) => chunks.push(chunk));
      upRes.on('end', () => {
        const body = Buffer.from(
          injectBootstrap(Buffer.concat(chunks).toString('utf8')),
          'utf8',
        );
        const out = { ...upRes.headers };
        delete out['content-encoding'];
        delete out['transfer-encoding'];
        delete out.etag; // 内容已变, 不能再用上游校验器
        out['content-length'] = String(body.byteLength);
        out['cache-control'] = 'no-store';
        res.writeHead(upRes.statusCode, out);
        res.end(body);
      });
    },
  );
  upstream.on('error', (err) => {
    res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`rewrite-proxy: upstream error: ${err.message}\n`);
  });
  req.pipe(upstream);
});

// --- WebSocket Upgrade (如 /api/events.mux) ---
server.on('upgrade', (req, socket, head) => {
  const upstream = net.connect(TARGET_PORT, TARGET_HOST, () => {
    // 重写 Host/Origin 后, 用原始请求重放 Upgrade 握手
    const reqHead =
      `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n` +
      Object.entries(rewriteHeaders(req.headers))
        .map(([k, v]) => `${k}: ${v}`)
        .join('\r\n') +
      '\r\n\r\n';
    upstream.write(reqHead);
    if (head && head.length) upstream.write(head);
    socket.pipe(upstream);
    upstream.pipe(socket);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(
    `rewrite-proxy: listening ${LISTEN_HOST}:${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT}`,
  );
  if (JUMP_ENABLED) {
    const b = previewBase();
    console.log(b ? `rewrite-proxy: 公网入口 302 跳板 -> ${b}` : 'rewrite-proxy: 跳板已启用但无 WEB_HOST');
  } else {
    console.log('rewrite-proxy: 跳板已禁用 (PROXY_JUMP=0)');
  }
});
