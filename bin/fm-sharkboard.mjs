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
const read = (file, fallback) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
};
function save(file, value) {
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
}
function run(executable, args, input = '', allowed = [0], json = true) {
  const result = spawnSync(executable, args, {
    input, encoding: 'utf8', timeout: 90000, maxBuffer: 8 * 1024 * 1024,
    env: { ...process.env, HARK_CONFIG: config },
  });
  if (result.error || !allowed.includes(result.status)) die(`${path.basename(executable)} ${args[0]} failed; no cursor advanced`);
  if (!json) return result.stdout;
  try { return JSON.parse(result.stdout); }
  catch { die(`${path.basename(executable)} returned invalid JSON`); }
}
const shark = (verb, args = [], payload) => run('sharkctl', ['board', verb, '--json', ...args, ...(payload ? ['--stdin'] : [])], payload ? JSON.stringify(payload) : '', verb === 'get' ? [0, 4] : [0]);
const model = () => run(path.join(bin, 'fm-board.sh'), ['model']);
const links = row => [...(row.links ?? []), ...(row.pr ? [row.pr] : [])].filter(url => url.startsWith('https://')).slice(0, 10).map(url => ({ kind: 'other', url }));

async function tick(mode) {
  const dir = path.join(home, 'state/sharkboard');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const lock = path.join(dir, 'lock');
  try { fs.mkdirSync(lock); } catch (error) { if (error.code === 'EEXIST') die('sharkboard lock exists; verify its owner before removing it'); throw error; }
  fs.writeFileSync(path.join(lock, 'pid'), String(process.pid));
  try {
    const file = path.join(dir, 'last.json');
    const state = read(file, { version: 1, binding: hash([fs.realpathSync(home), fs.realpathSync(config)]), rows: {}, events: {}, cursor: '' });
    if (state.version !== 1 || state.binding !== hash([fs.realpathSync(home), fs.realpathSync(config)])) die('sharkboard state/config binding changed');
    const persist = () => save(file, state);
    if (mode !== 'publish') {
      const page = shark('answers', state.cursor ? ['--since', state.cursor] : []);
      if (!Array.isArray(page.events) || typeof page.cursor !== 'string') die('invalid answer page');
      // Snoozes are not terminal events in SHark's cursor feed.
      for (const [key, row] of Object.entries(state.rows)) {
        if (row.type !== 'ask' || !row.card || !row.published) continue;
        const remote = shark('get', ['--key', key]).ask;
        if (remote?.id !== row.askId || remote.revision !== row.revision) die('published ask changed outside adapter');
        if (remote.status === 'open' && remote.snoozeUntil) {
          page.events.unshift({ askKey: key, askId: row.askId, revision: row.revision,
            waitingTaskId: row.task, answeredVia: 'web', status: 'answered',
            eventId: `${row.askId}:snooze:${remote.snoozeUntil}`, until: remote.snoozeUntil.slice(0, 10) });
        }
      }
      for (const event of page.events) {
        const row = state.rows[event.askKey];
        // Another home/token's rows and old revisions never reach the intake.
        if (!row || row.type !== 'ask' || row.askId !== event.askId || row.revision !== event.revision) continue;
        if (state.events[event.eventId] === 'applying') die('answer application was interrupted; reconcile its receipt before retrying');
        if (!state.events[event.eventId]) {
          if (event.status !== 'answered' || !row.card) {
            state.events[event.eventId] = 'applying'; persist();
            run(path.join(bin, 'fm-inbox.sh'), ['note', '-'],
              `SHark board event for ${row.payload.title}: ${event.status}.\nUntrusted captain text: ${event.text ?? event.optionLabel ?? ''}\nNo task was released by this transport; apply the normal authority rules.`, [0], false);
            state.events[event.eventId] = 'applied'; persist();
          } else {
          if (event.waitingTaskId !== row.task || !['web', 'ios_app', 'ios_webview'].includes(event.answeredVia)) die('unexpected answer provenance');
          const current = model().waiting_on_you.find(item => item.answerable && item.id === row.task && item.card === row.card);
          if (!current) { state.events[event.eventId] = 'stale'; persist(); continue; }
          if (event.until && event.until <= new Date().toISOString().slice(0, 10)) event.until = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
          const choice = event.until ? 'later' : event.optionId ?? 'reply';
          if (event.optionId && !current.choices.some(option => option.id === choice)) die('answer option no longer offered');
          state.events[event.eventId] = 'applying'; persist();
          const args = ['answer', row.task, '--card', row.card, '--choice', choice, '--login', `sharkboard:${event.answeredVia}`];
          if (event.until) args.push('--until', event.until);
          else if (!event.optionId) args.push('--text-file', '-');
          const applied = run(path.join(bin, 'fm-board.sh'), args, event.text ?? '');
          if (!applied.ok) die('answer not applied; reconcile receipt');
          state.events[event.eventId] = 'applied'; persist();
          }
        }
        if (state.events[event.eventId] === 'applied' && !event.until) {
          // Keys include the local question digest, so ack cannot target a new question.
          shark('ack', ['--key', event.askKey]);
          state.events[event.eventId] = 'acked'; persist();
        }
      }
      state.cursor = page.cursor; persist();
    }
    if (mode === 'answers') return;
    const view = model();
    if (view.schema !== 'fm-board.v1' || view.errors?.length) die('board model is incomplete; refusing destructive reconciliation');
    const prefix = `shuvbro:${hash(fs.realpathSync(home)).slice(0, 16)}:`;
    const desired = {};
    for (const row of view.waiting_on_you) {
      const identity = row.card ?? hash([row.source, row.from, row.id, row.title, row.reason]);
      const key = `${prefix}ask:${hash([row.source, row.from, row.id, identity]).slice(0, 40)}`;
      desired[key] = { type: 'ask', task: row.answerable ? row.id : null, card: row.answerable ? row.card : null,
        payload: { key, title: row.title.slice(0, 120), body: row.reason ?? '', kind: row.source === 'note' ? 'todo' : 'decision',
          options: row.answerable ? row.choices : [], allowText: row.source !== 'note', allowLater: Boolean(row.answerable),
          priority: 'p2', push: 'none', ...(row.answerable ? { taskId: row.id } : {}), links: links(row) } };
    }
    for (const lane of ['queued', 'in_flight', 'with_lead', 'done']) for (const row of view[lane]) {
      const key = `${prefix}work:${hash(row.id).slice(0, 40)}`;
      const done = lane === 'done';
      desired[key] = { type: done ? 'done' : 'work', payload: { key, title: row.title.slice(0, 120), links: links(row),
        ...(done ? { verb: ['merged', 'shipped', 'done', 'closed', 'reported'].includes(row.verb) ? row.verb : 'done' } : { state: lane === 'with_lead' ? 'blocked' : lane, ...(row.label ? { statusLabel: row.label } : {}) }) } };
    }
    for (const row of view.fyi) {
      const key = `${prefix}note:${hash([row.text, row.link]).slice(0, 40)}`;
      desired[key] = { type: 'note', payload: { key, text: row.text, ...(row.detail ? { detail: row.detail } : {}), ...(row.link ? { link: row.link } : {}) } };
    }
    for (const [key, row] of Object.entries(desired)) {
      const previous = state.rows[key];
      if (previous?.published && hash(previous.payload) === hash(row.payload) && row.payload.state !== 'in_flight') continue;
      // Save intent before transport. A retry uses the same content-addressed key.
      state.rows[key] = { ...previous, ...row, published: false }; persist();
      const result = shark(row.type === 'ask' ? 'ask' : row.type, ['--key', key], row.payload);
      if (row.type === 'ask') {
        if (!result.ask?.id || !Number.isInteger(result.ask.revision)) die('invalid published ask');
        state.rows[key].askId = result.ask.id;
        state.rows[key].revision = result.ask.revision;
      }
      state.rows[key].published = true; persist();
    }
    for (const [key, row] of Object.entries(state.rows)) {
      if (desired[key]) continue;
      if (row.type === 'ask') shark('cancel', ['--key', key, '--reason', 'No longer waiting in source board']);
      else if (row.type === 'note') shark('note', ['--key', key, '--clear']);
      else if (row.type !== 'done') shark('done', ['--key', key, '--verb', 'closed']);
      delete state.rows[key]; persist();
    }
  } finally { fs.rmSync(lock, { recursive: true }); }
}

try {
  if (!['publish', 'answers', 'sync', 'serve'].includes(command)) die('usage: fm-sharkboard.sh publish|answers|sync|serve');
  if (process.env.FM_TASK_ID) die('task workers cannot publish or consume captain board answers');
  if (!home || !path.isAbsolute(home) || !config || !path.isAbsolute(config)) die('FM_HOME and FM_SHARKBOARD_CONFIG must be explicit absolute paths');
  if ((fs.statSync(config).mode & 0o077) !== 0) die('board config must be private (mode 600)');
  do {
    await tick(command === 'serve' ? 'sync' : command);
    if (command === 'serve') {
      const pending = path.join(home, 'state/sharkboard/pending');
      for (let elapsed = 0; elapsed < 120; elapsed++) {
        await new Promise(resolve => setTimeout(resolve, 1000));
        if (fs.existsSync(pending)) { fs.unlinkSync(pending); break; }
      }
    }
  } while (command === 'serve');
} catch (error) { console.error(`sharkboard: ${error.message}`); process.exitCode = 1; }
