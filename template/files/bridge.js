'use strict';
/**
 * Bridge for 9Router -> opencode2api.
 *
 * Listens on BRIDGE_PORT (default 8787) and forwards to 127.0.0.1:API_PORT
 * (default 18080).
 *  - rewrites /inference/* -> /*
 *  - injects the local opencode2api server key
 *  - strips session/affinity request headers
 *  - aliases blocked tool names (anything matching /terminal/i)
 *  - restores the original tool names in the response stream
 *  - rotates WARP exits on upstream 429, retries on local API down
 *
 * Environment:
 *   BRIDGE_PORT, API_PORT, OPENCODE2API_KEY, BRIDGE_LOG, BRIDGE_FAIL_DIR,
 *   ROTATE_SCRIPT
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const { StringDecoder } = require('string_decoder');

const PORT = Number(process.env.BRIDGE_PORT || 8787);
const UPSTREAM = {
  host: '127.0.0.1',
  port: Number(process.env.API_PORT || 18080),
};
const KEY = process.env.OPENCODE2API_KEY || 'change-me-local-key';
const LOG = process.env.BRIDGE_LOG || '/tmp/bridge-requests.log';
const FAIL_DIR = process.env.BRIDGE_FAIL_DIR || '/tmp/bridge-fail';
const ROTATE_SCRIPT = process.env.ROTATE_SCRIPT || path.join(__dirname, 'rotate_wireproxy.py');
const BLOCKED = /terminal/i;
const ALIAS = 'oc2api_t0';
const MAX_ATTEMPTS = 3;
const LOCAL_RETRIES = 10;
const LOCAL_RETRY_MS = 3000;
const ROTATE_TIMEOUT_MS = 180000;

try { fs.mkdirSync(FAIL_DIR, { recursive: true }); } catch (e) { /* ignore */ }

function log(line) {
  try { fs.appendFileSync(LOG, `${new Date().toISOString()} ${line}\n`); }
  catch (e) { /* logging must never kill the proxy */ }
}

function dump(meta, rawBody, body) {
  const id = `${Date.now()}-${meta.model || 'unknown'}`.replace(/[^a-zA-Z0-9.-]/g, '_');
  try {
    fs.writeFileSync(`${FAIL_DIR}/${id}.json`, JSON.stringify(meta, null, 1));
    fs.writeFileSync(`${FAIL_DIR}/${id}.body.json`, rawBody);
    fs.writeFileSync(`${FAIL_DIR}/${id}.resp.txt`, body);
  } catch (e) { /* capture is best-effort */ }
}

function aliasTools(obj, aliases) {
  const note = (orig) => {
    if (orig && orig !== ALIAS) aliases[ALIAS] = orig;
    return ALIAS;
  };
  if (Array.isArray(obj.tools)) {
    for (const t of obj.tools) {
      const fn = t && t.function;
      if (fn && BLOCKED.test(fn.name || '')) { aliases[ALIAS] = fn.name; fn.name = ALIAS; }
    }
  }
  if (obj.tool_choice && obj.tool_choice.function && BLOCKED.test(obj.tool_choice.function.name || '')) {
    note(obj.tool_choice.function.name);
    obj.tool_choice.function.name = ALIAS;
  }
  if (Array.isArray(obj.messages)) {
    for (const m of obj.messages) {
      if (!m || typeof m !== 'object') continue;
      if (typeof m.name === 'string' && BLOCKED.test(m.name)) m.name = note(m.name);
      if (Array.isArray(m.tool_calls)) {
        for (const tc of m.tool_calls) {
          if (tc && tc.function && typeof tc.function.name === 'string' && BLOCKED.test(tc.function.name)) {
            tc.function.name = note(tc.function.name);
          }
        }
      }
    }
  }
  return aliases;
}

function renamer(aliases) {
  const pairs = Object.entries(aliases || {});
  if (!pairs.length) return null;
  const maxLen = Math.max(...pairs.map(([a]) => a.length));
  const keep = Math.max(0, maxLen - 1);
  const dec = new StringDecoder('utf8');
  const restore = (s) => {
    for (const [a, orig] of pairs) s = s.split(a).join(orig);
    return s;
  };
  let tail = '';
  return new require('stream').Transform({
    transform(chunk, enc, cb) {
      const s = tail + dec.write(chunk);
      if (s.length <= keep) { tail = s; cb(); return; }
      // Never emit a partial alias: if the tail boundary falls inside a
      // possible alias prefix, move the boundary back.
      let cut = s.length - keep;
      for (const [a] of pairs) {
        const maxL = Math.min(a.length - 1, cut);
        for (let L = 1; L <= maxL; L++) {
          if (s.slice(cut - L, cut) === a.slice(0, L)) cut -= L;
        }
      }
      if (cut <= 0) { tail = s; cb(); return; }
      tail = s.slice(cut);
      cb(null, Buffer.from(restore(s.slice(0, cut))));
    },
    flush(cb) {
      cb(null, Buffer.from(restore(tail + dec.end())));
    },
  });
}

let rotating = false;
let rotationPromise = null;

function performRotation() {
  if (rotating && rotationPromise) return rotationPromise;
  rotating = true;
  rotationPromise = new Promise((resolve) => {
    exec(`python3 ${JSON.stringify(ROTATE_SCRIPT)}`, { timeout: ROTATE_TIMEOUT_MS }, (err, stdout) => {
      rotating = false;
      rotationPromise = null;
      const out = String(stdout || '').trim().split('\n').filter(Boolean).pop() || '';
      if (err) log(`ROTATE ERR ${String(err.message).slice(0, 200)}`);
      else log(`ROTATE OK ${out.slice(0, 300)}`);
      resolve(!err);
    });
  });
  return rotationPromise;
}

function buildHeaders(req, bodyLength) {
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (/^(host|content-length|connection|authorization)$/i.test(k)) continue;
    if (/session/i.test(k) || /affinity/i.test(k)) continue;
    headers[k] = v;
  }
  headers.authorization = `Bearer ${KEY}`;
  headers['content-length'] = bodyLength;
  return headers;
}

function forward(options, rawBody, clientRes, attempt, meta) {
  if (clientRes.destroyed) return;
  const proxy = http.request({
    host: UPSTREAM.host,
    port: UPSTREAM.port,
    method: options.method,
    path: options.path,
    headers: options.headers,
  }, (targetRes) => {
    if (clientRes.destroyed) { targetRes.destroy(); return; }
    if (targetRes.statusCode === 429 && attempt < MAX_ATTEMPTS) {
      targetRes.resume();
      log(`429 attempt=${attempt + 1} ${meta.model} msgs=${meta.msgs} tools=${meta.tools} after=${Date.now() - meta.started}ms`);
      performRotation().then(() => forward(options, rawBody, clientRes, attempt + 1, meta));
      return;
    }
    if (targetRes.statusCode !== 200) {
      const chunks = [];
      targetRes.on('data', (c) => chunks.push(c));
      targetRes.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        dump({ ...meta, status: targetRes.statusCode, attempt }, rawBody, body.slice(0, 20000));
        if (clientRes.destroyed) return;
        clientRes.writeHead(targetRes.statusCode, targetRes.headers);
        clientRes.end(body);
      });
      return;
    }
    const headers = { ...targetRes.headers };
    const rn = renamer(meta.aliases || {});
    // The alias is shorter/longer than the placeholder, so a fixed
    // content-length would truncate (or hang) the rewritten body.
    if (rn) delete headers['content-length'];
    clientRes.writeHead(targetRes.statusCode, headers);
    if (rn) {
      rn.on('error', () => targetRes.destroy());
      targetRes.pipe(rn).pipe(clientRes, { end: true });
    } else {
      targetRes.pipe(clientRes, { end: true });
    }
  });
  proxy.setTimeout(300000, () => proxy.destroy(new Error('upstream timeout')));
  proxy.on('error', (err) => {
    if (clientRes.destroyed) return;
    const localDown = err.code === 'ECONNREFUSED' || err.code === 'EHOSTUNREACH' || err.code === 'ENOTFOUND';
    if (localDown) {
      meta.localRetries = (meta.localRetries || 0) + 1;
      if (meta.localRetries <= LOCAL_RETRIES) {
        log(`API_DOWN ${err.message} retry#${meta.localRetries} in 3s`);
        setTimeout(() => {
          if (!clientRes.destroyed) forward(options, rawBody, clientRes, attempt, meta);
        }, LOCAL_RETRY_MS);
        return;
      }
    }
    if (attempt < MAX_ATTEMPTS) {
      proxy.destroy();
      log(`ERR ${err.message} ${meta.model} attempt=${attempt}`);
      performRotation().then(() => forward(options, rawBody, clientRes, attempt + 1, meta));
      return;
    }
    log(`FAIL_ERR ${err.message} ${meta.model} attempt=${attempt}`);
    try {
      clientRes.writeHead(502, { 'content-type': 'application/json' });
      clientRes.end(JSON.stringify({ error: err.message }));
    } catch (e) { /* client gone */ }
  });
  proxy.end(rawBody);
}

const server = http.createServer((req, res) => {
  res.on('error', () => {});
  let targetPath = req.url;
  if (targetPath.startsWith('/inference')) targetPath = targetPath.replace(/^\/inference/, '');

  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    let rawBody = Buffer.concat(chunks);
    const meta = {
      model: '', msgs: 0, tools: 0, stream: false, bytes: rawBody.length,
      reasoning: undefined, ua: req.headers['user-agent'] || '', aliases: {}, started: Date.now(),
    };
    try {
      if (rawBody.length && /json/i.test(req.headers['content-type'] || '')) {
        const obj = JSON.parse(rawBody.toString('utf8'));
        meta.model = obj.model || '';
        meta.msgs = Array.isArray(obj.messages) ? obj.messages.length : 0;
        meta.tools = Array.isArray(obj.tools) ? obj.tools.length : 0;
        meta.stream = !!obj.stream;
        meta.reasoning = obj.reasoning_effort || obj.reasoning?.effort;
        aliasTools(obj, meta.aliases);
        rawBody = Buffer.from(JSON.stringify(obj));
      }
    } catch (e) {
      meta.parseError = String(e.message).slice(0, 120);
    }
    log(`REQ ${meta.model || '-'} path=${targetPath} msgs=${meta.msgs} tools=${meta.tools} stream=${meta.stream} bytes=${meta.bytes} reasoning=${JSON.stringify(meta.reasoning)} ua=${meta.ua.slice(0, 40)} ALIAS ${JSON.stringify(meta.aliases)}`);
    const options = { method: req.method, path: targetPath, headers: buildHeaders(req, rawBody.length) };
    forward(options, rawBody, res, 0, meta);
  });
});

server.on('error', (e) => { log(`SERVER ERR ${e.message}`); });

server.listen(PORT, '127.0.0.1', () => {
  log(`START ${PORT} -> ${UPSTREAM.port} rotate=${ROTATE_SCRIPT} exists=${fs.existsSync(ROTATE_SCRIPT)}`);
});

process.on('uncaughtException', (e) => {
  log(`UNCAUGHT ${e && e.stack ? e.stack.split('\n')[0] : e}`);
});
process.on('unhandledRejection', (e) => {
  log(`UNHANDLED ${e && e.stack ? e.stack.split('\n')[0] : e}`);
});
