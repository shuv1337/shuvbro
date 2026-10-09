// SHark transport. fm-board.sh owns the projection, locked card validation,
// keyed captain intake and wake. This bridge never executes answer text.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const bin = path.dirname(fileURLToPath(import.meta.url));
const home = process.env.FM_HOME;
const config = process.env.FM_SHARKBOARD_CONFIG;
const command = process.argv[2];
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const die = message => { throw new Error(message); };
const fatal = message => { throw Object.assign(new Error(message), { fatal: true }); };
const read = (file, fallback) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
};
function save(file, value) {
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
}
function exec(executable, args, input = '') {
  const env = { ...process.env, HARK_CONFIG: config };
  delete env.HARK_TOKEN;
  delete env.HARK_API_URL;
  const result = spawnSync(executable, args, {
    input, encoding: 'utf8', timeout: 90000, maxBuffer: 8 * 1024 * 1024,
    env,
  });
  if (result.error) die(`${path.basename(executable)} ${args[0]} failed; no cursor advanced`);
  let body = null;
  try { body = JSON.parse(result.stdout.trim().split('\n').pop()); } catch { /* Callers decide. */ }
  return { status: result.status, stdout: result.stdout, stderr: result.stderr, body };
}
function run(executable, args, input = '', json = true) {
  const result = exec(executable, args, input);
  if (result.status !== 0) die(`${path.basename(executable)} ${args[0]} failed; no cursor advanced`);
  if (!json) return result.stdout;
  if (result.body === null) die(`${path.basename(executable)} returned invalid JSON`);
  return result.body;
}
const sharkArgs = (verb, args, payload) => ['board', verb, '--json', ...args, ...(payload ? ['--stdin'] : [])];
// sharkctl exits 1 for every API failure; only the server's own refusal names an absent row.
const absent = (result, error) => result.status === 1 && result.stderr.split('\n')[0].trim() === error;
const shark = (verb, args = [], payload) => run('sharkctl', sharkArgs(verb, args, payload), payload ? JSON.stringify(payload) : '');
const model = () => run(path.join(bin, 'fm-board.sh'), ['model']);
const https = url => typeof url === 'string' && url.startsWith('https://') && url.length <= 2048;
const links = row => [...(row.links ?? []), ...(row.pr ? [row.pr] : [])].filter(https).slice(0, 10).map(url => ({ kind: 'other', url }));
// SHark refuses format characters, control characters in single-line fields, and overlong text.
const clamp = (text, max) => text.length > max ? `${text.slice(0, max - 1).trimEnd()}…` : text;
const block = (text, max) => clamp(String(text ?? '').replace(/\p{Cf}/gu, '').trim(), max);
const line = (text, max, fallback = 'Untitled') => clamp(String(text ?? '').replace(/\p{Cf}/gu, '').replace(/[\s\x00-\x1f\x7f]+/g, ' ').trim(), max) || fallback;

const startOf = pid => {
  try { return fs.readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ').pop().split(' ')[19] ?? null; }
  catch { return null; }
};
function ownerIsGone(owner) {
  if (!Number.isInteger(owner?.pid) || owner.pid <= 0) return false;
  try { process.kill(owner.pid, 0); }
  catch (error) { return error.code === 'ESRCH'; }
  const start = startOf(owner.pid);
  return Boolean(owner.start && start && start !== owner.start);
}
// The lock is renamed into place with its owner, so it never exists without one.
function acquire(lock, depth = 0) {
  if (depth > 8) die('too many abandoned recovery locks; reconcile lock owners');
  const temp = `${lock}.${process.pid}.tmp`;
  fs.rmSync(temp, { recursive: true, force: true });
  fs.mkdirSync(temp);
  fs.writeFileSync(path.join(temp, 'owner'), JSON.stringify({ pid: process.pid, start: startOf(process.pid) }));
  try {
    for (let attempt = 0; ; attempt++) {
      try { fs.renameSync(temp, lock); return; }
      catch (error) { if (!['EEXIST', 'ENOTEMPTY', 'EISDIR'].includes(error.code)) throw error; }
      const owner = read(path.join(lock, 'owner'), null);
      if (attempt || !ownerIsGone(owner)) die('sharkboard lock is held by a live or unknown owner; verify it before removing it');
      const reap = `${lock}.reap`;
      // The recovery mutex has the same atomic owner record and dead-owner
      // recovery as the main lock. Bound nesting if repeated crashes left a chain.
      acquire(reap, depth + 1);
      try {
        if (JSON.stringify(read(path.join(lock, 'owner'), null)) === JSON.stringify(owner)) fs.rmSync(lock, { recursive: true });
      } finally { fs.rmSync(reap, { recursive: true }); }
    }
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
}

async function tick(mode) {
  const dir = path.join(home, 'state/sharkboard');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const lock = path.join(dir, 'lock');
  acquire(lock);
  try {
    const file = path.join(dir, 'last.json');
    const binding = hash([fs.realpathSync(home), fs.realpathSync(config)]);
    const state = read(file, { version: 1, binding, rows: {}, events: {}, cursor: '' });
    if (state.version !== 1 || state.binding !== binding) fatal('sharkboard state/config binding changed');
    const persist = () => save(file, state);
    const publish = (key, row) => {
      // Save intent before transport. A retry uses the same content-addressed key.
      state.rows[key] = { ...state.rows[key], ...row, published: false, retired: false, refresh: false }; persist();
      const result = shark(row.type, ['--key', key], row.payload);
      if (row.type === 'ask') {
        if (!result.ask?.id || !Number.isInteger(result.ask.revision)) die('invalid published ask');
        state.rows[key].askId = result.ask.id;
        state.rows[key].revision = result.ask.revision;
      }
      state.rows[key].published = true; persist();
    };
    const remoteAsk = key => {
      const result = exec('sharkctl', sharkArgs('get', ['--key', key]));
      if ([0, 4].includes(result.status) && result.body?.ask) return result.body.ask;
      if (absent(result, 'Ask not found')) return null;
      die('sharkctl get failed; no cursor advanced');
    };
    // A re-PUT after an answer would open a new ask, so adopt the answered one.
    const reconcile = (key, row, remote) => {
      if (remote) { Object.assign(state.rows[key], { askId: remote.id, revision: remote.revision }); persist(); }
      if (remote?.status === 'answered') { state.rows[key].published = true; persist(); }
      else attempt(key, () => publish(key, row));
    };
    // One refused row must not stop intake or the other rows; it retries next tick.
    let failed = false;
    const attempt = (key, action) => {
      try { action(); }
      catch (error) { if (error.fatal) throw error; failed = true; console.error(`sharkboard: ${key}: ${error.message}`); }
    };
    const answerOf = (row, event) => event.text
      ?? (event.optionId ? `${event.optionLabel ?? row.payload.options.find(option => option.id === event.optionId)?.label ?? ''} [${event.optionId}]`.trim() : null)
      ?? (event.until ? `later, until ${event.until}` : '');
    // Untrusted text goes to the lead under normal authority. A repeated note is harmless.
    const note = (row, event, why) => run(path.join(bin, 'fm-inbox.sh'), ['note', '-'],
      `SHark board event for ${row.payload.title}: ${why}.\nUntrusted captain answer: ${answerOf(row, event)}\nNo task was released by this transport; apply the normal authority rules.`, false);
    const reject = (row, event, why) => {
      delete state.events[event.eventId]; persist();
      note(row, event, `not applied (${why})`);
      state.events[event.eventId] = 'rejected';
      if (event.until) row.resetSnooze = event.askId;
      persist();
    };
    if (mode !== 'publish') {
      const page = shark('answers', state.cursor ? ['--since', state.cursor] : []);
      if (!Array.isArray(page.events) || typeof page.cursor !== 'string') die('invalid answer page');
      for (const event of page.events) delete event.until;
      // A lost publish response must not let its answers pass unmatched.
      // Snoozes are not terminal events in SHark's cursor feed.
      for (const [key, row] of Object.entries(state.rows)) {
        if (row.type !== 'ask' || row.retired) continue;
        const remote = remoteAsk(key);
        if (!row.published || remote?.id !== row.askId || remote.revision !== row.revision) { reconcile(key, row, remote); continue; }
        if (row.card && remote.status === 'open' && remote.snoozeUntil) {
          page.events.unshift({ askKey: key, askId: row.askId, revision: row.revision,
            waitingTaskId: row.task, answeredVia: 'snooze', status: 'answered',
            eventId: `${row.askId}:snooze:${remote.snoozeUntil}`, until: remote.snoozeUntil.slice(0, 10) });
        }
      }
      let retry = false;
      for (const event of page.events) {
        const row = state.rows[event.askKey];
        // Another home/token's rows and retired rows never reach the intake.
        if (!row || row.type !== 'ask') continue;
        if (state.events[event.eventId] === 'applying') die('answer application was interrupted; reconcile its receipt before retrying');
        if (!state.events[event.eventId]) {
          if (row.askId !== event.askId || row.revision !== event.revision) {
            if (event.status === 'answered') reject(row, event, 'answer to an earlier version of this question');
          } else if (event.status !== 'answered' || !row.card) {
            note(row, event, event.status);
            state.events[event.eventId] = event.status === 'answered' || (event.status === 'cancelled' && ['web', 'ios_app', 'ios_webview'].includes(event.answeredVia)) ? 'applied' : 'noted'; persist();
          } else if (event.waitingTaskId !== row.task || !(event.until ? ['snooze'] : ['web', 'ios_app', 'ios_webview']).includes(event.answeredVia)) {
            reject(row, event, 'unexpected answer provenance');
          } else {
            const current = model().waiting_on_you.find(item => item.answerable && item.id === row.task && item.card === row.card);
            if (event.until && event.until <= new Date().toISOString().slice(0, 10)) event.until = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
            const choice = event.until ? 'later' : event.optionId ?? 'reply';
            if (!current) reject(row, event, 'question changed or no longer waiting');
            else if (event.optionId && !current.choices.some(option => option.id === choice)) reject(row, event, 'answer option no longer offered');
            else {
              state.events[event.eventId] = 'applying'; persist();
              const args = ['answer', row.task, '--card', row.card, '--choice', choice, '--login', `sharkboard:${event.answeredVia}`];
              if (event.until) args.push('--until', event.until);
              else if (!event.optionId) args.push('--text-file', '-');
              const { status, body } = exec(path.join(bin, 'fm-board.sh'), args, event.text ?? '');
              if (status === 0 && body?.ok === true) { state.events[event.eventId] = 'applied'; persist(); }
              // fm-board.sh reports these only when nothing was recorded; its card check makes a retry at most once.
              else if (status === 1 && ['record_failed', 'snapshot_failed'].includes(body?.code)) { delete state.events[event.eventId]; persist(); retry = true; }
              else if ([2, 3].includes(status) && body?.ok === false && typeof body.code === 'string') reject(row, event, body.code);
              else die('answer outcome unknown; reconcile receipt');
            }
          }
        }
        if (state.events[event.eventId] === 'applied' && !event.until) {
          // Keys include the local question digest, so ack cannot target a new question.
          const result = exec('sharkctl', sharkArgs('ack', ['--key', event.askKey]));
          if (result.status !== 0 && !absent(result, 'No unacknowledged resolved ask with that key')) die('sharkctl ack failed; no cursor advanced');
          state.events[event.eventId] = 'acked';
          if (event.status === 'cancelled') row.refresh = true;
          persist();
        }
        if (state.events[event.eventId] && event.status === 'answered' && !event.until) { row.seen = event.askId; persist(); }
      }
      // A retryable intake failure keeps the page for the next tick; settled receipts dedupe it.
      if (!retry) { state.cursor = page.cursor; persist(); }
    }
    // A rejected Later must not keep its source question hidden. Persist the
    // repair until cancel is confirmed; a racing answer remains for next intake.
    for (const [key, row] of Object.entries(state.rows)) {
      if (!row.resetSnooze) continue;
      attempt(key, () => {
        let remote = remoteAsk(key);
        if (remote?.id === row.resetSnooze && remote.status === 'open') {
          exec('sharkctl', sharkArgs('cancel', ['--key', key, '--reason', 'Later was not applied by the source board']));
          remote = remoteAsk(key);
          if (remote?.id === row.resetSnooze && remote.status === 'open') die('rejected snooze cancellation not confirmed');
        }
        if (!remote || (remote.id === row.resetSnooze && remote.status !== 'answered')) row.refresh = true;
        delete row.resetSnooze;
        persist();
      });
    }
    if (mode === 'answers') { if (failed) die('some board rows could not be published'); return; }
    const view = model();
    if (view.schema !== 'fm-board.v1' || view.errors?.length) die('board model is incomplete; refusing destructive reconciliation');
    const prefix = `shuvbro:${hash(fs.realpathSync(home)).slice(0, 16)}:`;
    const desired = {};
    for (const row of view.waiting_on_you) {
      const identity = row.card ?? hash([row.source, row.from, row.id, row.title, row.reason]);
      const key = `${prefix}ask:${hash([row.source, row.from, row.id, identity]).slice(0, 40)}`;
      desired[key] = { type: 'ask', task: row.answerable ? row.id : null, card: row.answerable ? row.card : null,
        payload: { key, title: line(row.title, 120), body: block(row.reason, 2000), kind: row.source === 'note' ? 'todo' : 'decision',
          options: row.answerable ? row.choices.map(option => ({ id: option.id, label: line(option.label, 120, option.id) })) : [], allowText: row.source !== 'note', allowLater: Boolean(row.answerable),
          priority: 'p2', push: 'none', ...(row.answerable ? { taskId: row.id } : {}), links: links(row) } };
    }
    for (const lane of ['queued', 'in_flight', 'with_lead', 'done']) for (const row of view[lane]) {
      const key = `${prefix}work:${hash(row.id).slice(0, 40)}`;
      const done = lane === 'done';
      desired[key] = { type: done ? 'done' : 'work', payload: { key, title: line(row.title, 120), links: links(row),
        ...(done ? { verb: ['merged', 'shipped', 'done', 'closed', 'reported'].includes(row.verb) ? row.verb : 'done' } : { state: lane === 'with_lead' ? 'blocked' : lane, ...(row.label ? { statusLabel: line(row.label, 60) } : {}) }) } };
    }
    for (const row of view.fyi) {
      const key = `${prefix}note:${hash([row.text, row.link]).slice(0, 40)}`;
      desired[key] = { type: 'note', payload: { key, text: line(row.text, 300), ...(block(row.detail, 2000) ? { detail: block(row.detail, 2000) } : {}), ...(https(row.link) ? { link: row.link } : {}) } };
    }
    for (const [key, row] of Object.entries(desired)) {
      const previous = state.rows[key];
      // Active work heartbeats every tick so SHark never marks it stale.
      if (previous?.published && !previous.retired && !previous.refresh && hash(previous.payload) === hash(row.payload) && row.type !== 'work') continue;
      attempt(key, () => publish(key, row));
    }
    for (const [key, row] of Object.entries(state.rows)) {
      if (desired[key]) continue;
      attempt(key, () => {
        if (row.type === 'ask') {
          const result = exec('sharkctl', sharkArgs('cancel', ['--key', key, '--reason', 'No longer waiting in source board']));
          const remote = result.status === 0 ? null : remoteAsk(key);
          if (remote?.status === 'open') die('sharkctl cancel failed');
          // An answer that raced retirement must still reach the lead before the row goes.
          if (remote?.status === 'answered' && row.seen !== remote.id) { Object.assign(row, { retired: true, askId: remote.id, revision: remote.revision }); persist(); return; }
        } else if (row.type === 'note') {
          const result = exec('sharkctl', sharkArgs('note', ['--key', key, '--clear']));
          if (result.status !== 0 && !absent(result, 'Note not found')) die('sharkctl note failed');
        } else if (row.type !== 'done') {
          // Without a title SHark closes only an item it has; it names one it never created.
          const result = exec('sharkctl', sharkArgs('done', ['--key', key, '--verb', 'closed']));
          if (result.status !== 0 && !absent(result, 'A new done item needs a title')) die('sharkctl done failed');
        }
        delete state.rows[key]; persist();
      });
    }
    if (failed) die('some board rows could not be published or retired');
  } finally { fs.rmSync(lock, { recursive: true }); }
}

try {
  if (!['publish', 'answers', 'sync', 'serve'].includes(command)) die('usage: fm-sharkboard.sh publish|answers|sync|serve');
  if (process.env.FM_TASK_ID) die('task workers cannot publish or consume captain board answers');
  if (!home || !path.isAbsolute(home) || !config || !path.isAbsolute(config)) die('FM_HOME and FM_SHARKBOARD_CONFIG must be explicit absolute paths');
  if ((fs.statSync(config).mode & 0o077) !== 0) die('board config must be private (mode 600)');
  do {
    try { await tick(command === 'serve' ? 'sync' : command); }
    catch (error) { if (command !== 'serve' || error.fatal) throw error; console.error(`sharkboard: ${error.message}; retrying`); }
    if (command === 'serve') {
      const pending = path.join(home, 'state/sharkboard/pending');
      for (let elapsed = 0; elapsed < 120; elapsed++) {
        await new Promise(resolve => setTimeout(resolve, 1000));
        if (fs.existsSync(pending)) { fs.unlinkSync(pending); break; }
      }
    }
  } while (command === 'serve');
} catch (error) { console.error(`sharkboard: ${error.message}`); process.exitCode = 1; }
