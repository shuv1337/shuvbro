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
//   - a request must carry an allowlisted Tailscale-User-Login (set, and
//     stripped from clients, by tailscale serve) or be a direct loopback
//     request with no proxy headers at all; without config/board-logins only
//     the direct loopback request is served;
//   - POST /answer additionally requires application/json, an Origin equal to
//     the page's own origin, a same-origin Sec-Fetch-Site when sent, a body of
//     at most 8 KiB with exactly the documented fields, and the per-start
//     random token embedded in the page.
// Request values reach fm-board.sh only as argv elements or stdin; no shell is
// ever involved.
// Successful answers keep a private, atomic receipt in state/board/answers,
// keyed by task and card digest. An exact retry (including answer and login)
// returns that result without another mutation or inbox note, even after a
// server restart or a new hold. A different answer to that card is refused.

import http from "node:http";
import { execFile } from "node:child_process";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
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
const answerDir = join(recordDir, "answers");
const bodyLimit = 8192;
const answerFields = new Set(["token", "task", "card", "choice", "text", "until"]);

let model = null;
let refreshError = null;
let refreshing = null;
let refreshEpoch = 0;
let modelEpoch = -1;
let cachedSignature = null;
let lastFullAt = 0;
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
    && Number.isInteger(value.full_interval) && value.full_interval >= value.interval && value.full_interval <= 300
    && typeof value.data_dir === "string"
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

// Cheap identity of the records a rebuild reads. A same-second rewrite that
// keeps the same length is not visible here; an answer invalidates separately.
function inputSignature() {
  const parts = [];
  const statOne = (path) => {
    try {
      const st = fs.statSync(path);
      parts.push(`${path}\t${st.mtimeMs}\t${st.size}`);
    } catch {
      parts.push(`${path}\tmissing`);
    }
  };
  statOne(join(config.data_dir, "backlog.md"));
  statOne(join(config.data_dir, "board-notes.json"));
  statOne(join(config.data_dir, "secondmates.md"));
  let names = [];
  try {
    names = fs.readdirSync(config.state_dir);
  } catch {
    parts.push(`${config.state_dir}\tmissing`);
  }
  for (const name of names) {
    if (name.endsWith(".meta") || name.endsWith(".status")) statOne(join(config.state_dir, name));
  }
  parts.sort();
  return parts.join("\n");
}

function cacheHit() {
  return model
    && modelEpoch === refreshEpoch
    && cachedSignature !== null
    && cachedSignature === inputSignature()
    && (Date.now() - lastFullAt) < config.full_interval * 1000;
}

// A full rebuild. Joining one already in flight is safe for a viewer poll.
// freshRefresh refuses that join, because the in-flight snapshot may have
// started before an answer was written.
function refresh() {
  if (refreshing) return refreshing;
  const myEpoch = refreshEpoch;
  const before = inputSignature();
  refreshing = (async () => {
    const result = await runBoard(["model"]);
    try {
      if (result.code !== 0) throw new Error(lastLine(result.stderr) || `exit ${result.code}`);
      const next = JSON.parse(result.stdout);
      if (!next || next.schema !== "fm-board.v1") throw new Error("unexpected board data");
      model = next;
      refreshError = null;
      const after = inputSignature();
      if (myEpoch === refreshEpoch && before === after) {
        modelEpoch = myEpoch;
        cachedSignature = after;
        lastFullAt = Date.now();
      } else {
        cachedSignature = null;
      }
    } catch (error) {
      refreshError = `The board could not refresh: ${String(error.message || error).slice(0, 300)}`;
      cachedSignature = null;
    } finally {
      refreshing = null;
    }
  })();
  return refreshing;
}

function noteChecked() {
  if (!model) return;
  model = { ...model, generated: new Date().toISOString() };
}

// Rebuild when the viewer needs a snapshot; otherwise mark the cached view checked.
async function ensureFresh() {
  if (cacheHit()) {
    noteChecked();
    return;
  }
  await refresh();
}

// A refresh whose snapshot starts after this call. Joining one already in
// flight could publish records read before an answer was written, so the page
// would keep offering the question it just answered.
function freshRefresh() {
  refreshEpoch += 1;
  cachedSignature = null;
  if (!refreshing) return refresh();
  return refreshing.then(() => refresh());
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
  const login = headerValue(req, "tailscale-user-login");
  const direct = loopbackHosts.has(host)
    && headerValue(req, "x-forwarded-for") === undefined
    && forwardedHost === undefined
    && login === undefined
    && headerValue(req, "tailscale-user-name") === undefined;
  if (direct) return null;
  if (allowedLogins.size === 0) {
    return { status: 403, code: "local_only", message: "This board is served to this computer only. List your Tailscale login in config/board-logins to share it." };
  }
  return login !== undefined && allowedLogins.has(login.toLowerCase())
    ? null
    : { status: 403, code: "login_refused", message: "This board is not shared with your login." };
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

async function serveData(res) {
  await ensureFresh();
  if (!model) {
    refuse(res, 503, "warming_up", refreshError || "The board is still loading.");
    return;
  }
  const errors = [...(model.errors || [])];
  if (refreshError) errors.push(refreshError);
  const age = Math.max(0, Math.round((Date.now() - Date.parse(model.generated)) / 1000));
  send(res, 200, { ...model, errors, instance, refresh_seconds: config.interval, age_seconds: Number.isFinite(age) ? age : null });
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

function digest(value) {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

async function recordedAnswer(body, args, login) {
  const receiptPath = join(answerDir, `${digest([body.task, body.card])}.json`);
  const request = digest([body.choice, body.text ?? null, body.until ?? null, login ?? null]);
  const errorResult = (code, message, exit = 1) => ({
    code: exit, stdout: JSON.stringify({ ok: false, code, message }),
  });
  try {
    const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
    if (receipt.request !== request) {
      return errorResult("answer_conflict", "This question already received a different answer. Refresh to see the current question.", 3);
    }
    if (receipt.outcome?.ok !== true || receipt.outcome.task !== body.task) throw new Error("invalid receipt");
    return { code: 0, stdout: JSON.stringify(receipt.outcome) };
  } catch (error) {
    if (error.code !== "ENOENT") {
      return errorResult("outcome_unknown", "The board could not confirm the previous answer. Refresh or ask the lead before answering again.");
    }
  }
  const result = await runBoard(args, body.choice === "reply" ? body.text : "");
  let outcome;
  try {
    outcome = JSON.parse(lastLine(result.stdout));
  } catch {
    return errorResult("outcome_unknown", "Your answer may have been recorded. Refresh to check before answering again.");
  }
  if (result.code !== 0 || outcome.ok !== true) return result;
  const tmp = `${receiptPath}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(answerDir, { recursive: true, mode: 0o700 });
    fs.writeFileSync(tmp, `${JSON.stringify({ request, outcome })}\n`, { mode: 0o600 });
    fs.renameSync(tmp, receiptPath);
  } catch {
    try { fs.unlinkSync(tmp); } catch { /* Nothing staged. */ }
    return errorResult("outcome_unknown", "Your answer was recorded, but its confirmation could not be saved. Refresh or ask the lead before answering again.");
  }
  return result;
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
  const run = answerChain.then(() => recordedAnswer(body, args, login));
  answerChain = run.catch(() => {});
  const result = await run;
  let outcome;
  try {
    outcome = JSON.parse(lastLine(result.stdout));
  } catch {
    outcome = { ok: false, code: "outcome_unknown", message: "Your answer may have been recorded. Refresh to check before answering again." };
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
  const stop = () => {
    removeRecord();
    server.close();
    process.exit(0);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  process.on("exit", removeRecord);
}

main();
