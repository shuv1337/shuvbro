#!/usr/bin/env node
// HTTP layer of the live board. bin/fm-board.sh owns the contract, the view
// model, and answer recording; this file only serves the page and its data and
// guards the one action endpoint. It is started by `fm-board.sh serve` with its
// resolved configuration in FM_BOARD_SERVE_CONFIG and binds 127.0.0.1 only.
//
// Request guard, applied in this order (docs/live-board.md owns the threat model):
//   - a Tailscale Funnel request is refused outright;
//   - the Host header must name a loopback host or one listed in
//     config/board-hosts, which defeats DNS rebinding;
//   - with config/board-logins present, a request must carry an allowlisted
//     Tailscale-User-Login (set, and stripped from clients, by tailscale serve)
//     or be a direct loopback request with no proxy headers at all;
//   - POST /answer additionally requires application/json, an Origin equal to
//     the page's own origin, a same-origin Sec-Fetch-Site when sent, a body of
//     at most 8 KiB with exactly the documented fields, and the per-start
//     random token embedded in the page.
// Request values reach fm-board.sh only as argv elements or stdin; no shell is
// ever involved.

import http from "node:http";
import { execFile } from "node:child_process";
import { randomBytes, timingSafeEqual } from "node:crypto";
import * as fs from "node:fs";
import { dirname, join } from "node:path";

const config = parseConfig(process.env.FM_BOARD_SERVE_CONFIG);
const token = randomBytes(32).toString("hex");
const instance = randomBytes(8).toString("hex");
const pageTemplate = fs.readFileSync(config.page, "utf8");
const loopbackHosts = new Set(["127.0.0.1", "localhost", "[::1]"]);
const allowedHosts = new Set([...loopbackHosts, ...config.hosts]);
const allowedLogins = new Set(config.logins.map((login) => login.toLowerCase()));
const recordDir = join(config.state_dir, "board");
const recordPath = join(recordDir, "serve.json");
const bodyLimit = 8192;
const answerFields = new Set(["token", "task", "card", "choice", "text", "until"]);

let model = null;
let refreshError = null;
let refreshing = null;
let refreshAfterCurrent = null;
let answerChain = Promise.resolve();

function parseConfig(raw) {
  let value;
  try {
    value = JSON.parse(raw || "");
  } catch {
    fatal("start the board through bin/fm-board.sh serve");
  }
  const ok = value && typeof value === "object"
    && typeof value.home === "string" && typeof value.state_dir === "string"
    && typeof value.board_sh === "string" && typeof value.page === "string"
    && Number.isInteger(value.port) && value.port >= 0 && value.port <= 65535
    && Number.isInteger(value.interval) && value.interval >= 2 && value.interval <= 300
    && Array.isArray(value.hosts) && value.hosts.every((h) => typeof h === "string")
    && Array.isArray(value.logins) && value.logins.every((l) => typeof l === "string");
  if (!ok) fatal("invalid board configuration; start the board through bin/fm-board.sh serve");
  return value;
}

function fatal(message) {
  process.stderr.write(`fm-board: ${message}\n`);
  process.exit(1);
}

function runBoard(args, input) {
  return new Promise((resolve) => {
    const child = execFile(config.board_sh, args, {
      env: process.env,
      timeout: 120000,
      maxBuffer: 16 * 1024 * 1024,
    }, (error, stdout, stderr) => {
      resolve({ code: error ? (typeof error.code === "number" ? error.code : 1) : 0, stdout, stderr });
    });
    child.stdin.on("error", () => {});
    child.stdin.end(input ?? "");
  });
}

function refresh() {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    const result = await runBoard(["model"]);
    try {
      if (result.code !== 0) throw new Error(lastLine(result.stderr) || `exit ${result.code}`);
      const next = JSON.parse(result.stdout);
      if (!next || next.schema !== "fm-board.v1") throw new Error("unexpected board data");
      model = next;
      refreshError = null;
    } catch (error) {
      refreshError = `The board could not refresh: ${String(error.message || error).slice(0, 300)}`;
    } finally {
      refreshing = null;
    }
  })();
  return refreshing;
}

// A refresh whose snapshot starts after this call. Joining one already in
// flight could publish records read before an answer was written, so the page
// would keep offering the question it just answered.
function freshRefresh() {
  if (!refreshing) return refresh();
  if (!refreshAfterCurrent) {
    refreshAfterCurrent = refreshing.then(() => {
      refreshAfterCurrent = null;
      return refresh();
    });
  }
  return refreshAfterCurrent;
}

function lastLine(text) {
  return String(text || "").trim().split("\n").pop()?.replace(/^fm-board: /, "") || "";
}

function headerValue(req, name) {
  const value = req.headers[name];
  if (Array.isArray(value)) return value[0];
  return typeof value === "string" ? value : undefined;
}

// Host or X-Forwarded-Host as a lowercase host name without its port, or null.
function hostName(value) {
  if (typeof value !== "string") return null;
  const match = /^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(?::[0-9]{1,5})?$/.exec(value.trim());
  return match ? match[1].toLowerCase() : null;
}

function refuse(res, status, code, message) {
  send(res, status, { ok: false, code, message });
}

function securityHeaders(res, csp) {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("Content-Security-Policy", csp || "default-src 'none'; frame-ancestors 'none'");
}

function send(res, status, body) {
  const text = JSON.stringify(body);
  securityHeaders(res);
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Content-Length": Buffer.byteLength(text) });
  res.end(res.req.method === "HEAD" ? undefined : text);
}

// Returns null when the request may proceed, else {status, code, message}.
function accessDenied(req) {
  if (headerValue(req, "tailscale-funnel-request") !== undefined) {
    return { status: 403, code: "funnel_refused", message: "This board is never served to the public internet." };
  }
  const host = hostName(headerValue(req, "host"));
  if (!host || !allowedHosts.has(host)) {
    return { status: 403, code: "bad_host", message: "This board does not answer to that host name. Add it to config/board-hosts." };
  }
  const forwardedHost = headerValue(req, "x-forwarded-host");
  if (forwardedHost !== undefined) {
    const name = hostName(forwardedHost);
    if (!name || !allowedHosts.has(name)) {
      return { status: 403, code: "bad_host", message: "This board does not answer to that host name. Add it to config/board-hosts." };
    }
  }
  if (allowedLogins.size === 0) return null;
  const login = headerValue(req, "tailscale-user-login");
  if (login !== undefined) {
    return allowedLogins.has(login.toLowerCase())
      ? null
      : { status: 403, code: "login_refused", message: "This board is not shared with your login." };
  }
  const direct = loopbackHosts.has(host)
    && headerValue(req, "x-forwarded-for") === undefined
    && forwardedHost === undefined
    && headerValue(req, "tailscale-user-name") === undefined;
  return direct ? null : { status: 403, code: "login_refused", message: "This board is not shared with your login." };
}

function servePage(req, res) {
  const nonce = randomBytes(16).toString("base64");
  const page = pageTemplate
    .replaceAll("__FM_BOARD_NONCE__", nonce)
    .replaceAll("__FM_BOARD_TOKEN__", token)
    .replaceAll("__FM_BOARD_INSTANCE__", instance)
    .replaceAll("__FM_BOARD_REFRESH__", String(config.interval));
  securityHeaders(res, [
    "default-src 'none'",
    `script-src 'nonce-${nonce}'`,
    `style-src 'nonce-${nonce}'`,
    "connect-src 'self'",
    "img-src 'self' data:",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join("; "));
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Content-Length": Buffer.byteLength(page) });
  res.end(req.method === "HEAD" ? undefined : page);
}

function serveData(res) {
  if (!model) {
    refuse(res, 503, "warming_up", refreshError || "The board is still loading.");
    return;
  }
  const errors = [...(model.errors || [])];
  if (refreshError) errors.push(refreshError);
  send(res, 200, { ...model, errors, instance, refresh_seconds: config.interval });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const declared = Number(headerValue(req, "content-length") || 0);
    if (declared > bodyLimit) {
      reject(Object.assign(new Error("too large"), { status: 413 }));
      req.resume();
      return;
    }
    const chunks = [];
    let size = 0;
    const collect = (chunk) => {
      size += chunk.length;
      if (size > bodyLimit) {
        // Stop keeping the body and discard the rest, so the refusal still
        // reaches the client; the server's request timeout bounds the drain.
        req.off("data", collect);
        req.resume();
        reject(Object.assign(new Error("too large"), { status: 413 }));
        return;
      }
      chunks.push(chunk);
    };
    req.on("data", collect);
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function sameOrigin(req) {
  const origin = headerValue(req, "origin");
  if (!origin || origin === "null") return false;
  let parsed;
  try {
    parsed = new URL(origin);
  } catch {
    return false;
  }
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.origin !== origin) return false;
  const expected = headerValue(req, "x-forwarded-host") ?? headerValue(req, "host");
  if (!hostName(expected)) return false;
  let expectedHost;
  try {
    expectedHost = new URL(`${parsed.protocol}//${expected.trim()}`).host;
  } catch {
    return false;
  }
  if (parsed.host.toLowerCase() !== expectedHost.toLowerCase()) return false;
  const site = headerValue(req, "sec-fetch-site");
  return site === undefined || site === "same-origin";
}

function tokenMatches(candidate) {
  if (typeof candidate !== "string") return false;
  const given = Buffer.from(candidate);
  const expected = Buffer.from(token);
  return given.length === expected.length && timingSafeEqual(given, expected);
}

function validateAnswer(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return "The request must be a JSON object.";
  for (const key of Object.keys(body)) {
    if (!answerFields.has(key)) return "The request carries a field the board does not accept.";
  }
  if (typeof body.task !== "string" || !/^[A-Za-z0-9._-]{1,128}$/.test(body.task)) return "That item is not on the board.";
  if (typeof body.card !== "string" || !/^[0-9a-f]{64}$/.test(body.card)) return "The request did not name the question it answers.";
  if (typeof body.choice !== "string" || !/^(yes|no|later|reply|opt-[1-6])$/.test(body.choice)) return "That answer is not offered for this question.";
  if (body.choice === "reply") {
    if (typeof body.text !== "string" || body.text.trim().length === 0) return "Write a reply of 1 to 500 characters.";
    if ([...body.text].length > 500) return "Write a reply of 1 to 500 characters.";
  } else if (body.text !== undefined) {
    return "Only a typed reply carries text.";
  }
  if (body.choice === "later") {
    if (typeof body.until !== "string" || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(body.until)) return "Pick a date after today and within a year.";
  } else if (body.until !== undefined) {
    return "Only Later carries a date.";
  }
  return null;
}

function validationCode(message) {
  if (message === "That item is not on the board.") return "unknown_task";
  if (message === "That answer is not offered for this question.") return "bad_choice";
  if (message.startsWith("Write a reply")) return "bad_text";
  if (message.startsWith("Pick a date")) return "bad_date";
  return "bad_request";
}

async function handleAnswer(req, res) {
  const type = (headerValue(req, "content-type") || "").split(";")[0].trim().toLowerCase();
  if (type !== "application/json") {
    refuse(res, 415, "bad_request", "The board accepts only its own answer requests.");
    req.resume();
    return;
  }
  if (!sameOrigin(req)) {
    refuse(res, 403, "bad_origin", "Answers are accepted only from the board's own page.");
    req.resume();
    return;
  }
  let raw;
  try {
    raw = await readBody(req);
  } catch (error) {
    refuse(res, error.status || 400, "bad_request", "The answer request is too large.");
    return;
  }
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    refuse(res, 400, "bad_request", "The request must be a JSON object.");
    return;
  }
  if (!body || typeof body !== "object" || Array.isArray(body) || !tokenMatches(body.token)) {
    refuse(res, 403, "bad_token", "This page is out of date. Reload it and answer again.");
    return;
  }
  const invalid = validateAnswer(body);
  if (invalid) {
    refuse(res, 400, validationCode(invalid), invalid);
    return;
  }
  const args = ["answer", body.task, "--card", body.card, "--choice", body.choice];
  if (body.choice === "later") args.push("--until", body.until);
  if (body.choice === "reply") args.push("--text-file", "-");
  const login = headerValue(req, "tailscale-user-login");
  if (login !== undefined && /^[A-Za-z0-9._%+@:-]{1,128}$/.test(login)) args.push("--login", login);
  const run = answerChain.then(() => runBoard(args, body.choice === "reply" ? body.text : ""));
  answerChain = run.catch(() => {});
  const result = await run;
  let outcome;
  try {
    outcome = JSON.parse(lastLine(result.stdout));
  } catch {
    outcome = { ok: false, code: "record_failed", message: "Your answer was not recorded." };
  }
  const status = result.code === 0 ? 200 : result.code === 2 ? 400 : result.code === 3 ? 409 : 500;
  process.stderr.write(`fm-board: answer ${body.task} ${body.choice}: ${outcome.ok ? outcome.outcome : outcome.code}\n`);
  // Refresh before replying, within a bound, so the page's next read already
  // shows the answered item gone or the changed question in place.
  await Promise.race([freshRefresh(), new Promise((resolve) => setTimeout(resolve, 5000))]);
  send(res, status, outcome);
}

async function handle(req, res) {
  const denied = accessDenied(req);
  if (denied) {
    refuse(res, denied.status, denied.code, denied.message);
    req.resume();
    return;
  }
  const path = (req.url || "/").split("?")[0];
  const routes = {
    "/": ["GET", "HEAD"],
    "/index.html": ["GET", "HEAD"],
    "/board.json": ["GET", "HEAD"],
    "/healthz": ["GET", "HEAD"],
    "/answer": ["POST"],
  };
  const methods = routes[path];
  if (!methods) {
    refuse(res, 404, "not_found", "Not found.");
    req.resume();
    return;
  }
  if (!methods.includes(req.method)) {
    res.setHeader("Allow", methods.join(", "));
    refuse(res, 405, "bad_method", "Method not allowed.");
    req.resume();
    return;
  }
  if (path === "/answer") return handleAnswer(req, res);
  if (path === "/board.json") return serveData(res);
  if (path === "/healthz") return send(res, 200, { ok: true, schema: "fm-board-health.v1", instance });
  return servePage(req, res);
}

function existingBoardAlive() {
  let record;
  try {
    record = JSON.parse(fs.readFileSync(recordPath, "utf8"));
  } catch {
    return Promise.resolve(false);
  }
  if (!record || !Number.isInteger(record.pid) || !Number.isInteger(record.port) || record.pid === process.pid) return Promise.resolve(false);
  try {
    process.kill(record.pid, 0);
  } catch {
    return Promise.resolve(false);
  }
  return new Promise((resolve) => {
    const req = http.get({ host: "127.0.0.1", port: record.port, path: "/healthz", timeout: 2000, headers: { Host: `127.0.0.1:${record.port}` } }, (res) => {
      let text = "";
      res.on("data", (chunk) => { text += chunk; });
      res.on("end", () => {
        try {
          const health = JSON.parse(text);
          resolve(res.statusCode === 200 && health.instance === record.instance);
        } catch {
          resolve(false);
        }
      });
    });
    req.on("timeout", () => { req.destroy(); resolve(false); });
    req.on("error", () => resolve(false));
  });
}

function writeRecord(port) {
  fs.mkdirSync(recordDir, { recursive: true, mode: 0o700 });
  const tmp = join(recordDir, `.serve.${process.pid}.tmp`);
  const record = { schema: "fm-board-serve.v1", pid: process.pid, port, instance, home: config.home, started: new Date().toISOString() };
  fs.writeFileSync(tmp, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, recordPath);
}

function removeRecord() {
  try {
    const record = JSON.parse(fs.readFileSync(recordPath, "utf8"));
    if (record.pid === process.pid && record.instance === instance) fs.unlinkSync(recordPath);
  } catch {
    // Nothing of ours to remove.
  }
}

async function main() {
  if (!fs.existsSync(dirname(config.board_sh))) fatal("board script directory is missing");
  if (await existingBoardAlive()) fatal(`a board is already serving ${config.home}; see bin/fm-board.sh status`);
  await refresh();
  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      process.stderr.write(`fm-board: request failed: ${error.message}\n`);
      if (!res.headersSent) refuse(res, 500, "internal", "The board hit an internal error.");
    });
  });
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  server.on("error", (error) => fatal(`cannot listen on 127.0.0.1:${config.port}: ${error.message}`));
  server.listen(config.port, "127.0.0.1", () => {
    const { port } = server.address();
    writeRecord(port);
    process.stderr.write(`fm-board: serving http://127.0.0.1:${port}/ for ${config.home}\n`);
  });
  const timer = setInterval(refresh, config.interval * 1000);
  const stop = () => {
    clearInterval(timer);
    removeRecord();
    server.close();
    process.exit(0);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  process.on("exit", removeRecord);
}

main();
