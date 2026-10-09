// Loopback SHark board API emulator: records every request; events come from events.json.
import http from 'node:http'; import fs from 'node:fs';
const [port, log, expectToken, eventsFile] = process.argv.slice(2);
const asks = {}, work = {}, notes = {}; let n = 0;
const rec = o => fs.appendFileSync(log, JSON.stringify(o) + '\n');
http.createServer((req, res) => {
  let data = ''; req.on('data', c => data += c); req.on('end', () => {
    const url = new URL(req.url, 'http://x'); const p = url.pathname.split('/').slice(4).map(decodeURIComponent);
    const body = data ? JSON.parse(data) : null;
    const auth = req.headers.authorization === `Bearer ${expectToken}` ? 'dedicated-config-token' : 'OTHER-TOKEN';
    rec({ port, method: req.method, path: url.pathname, auth, body });
    const send = (code, o) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
    if (auth !== 'dedicated-config-token') return send(401, { error: 'Unauthorized' });
    const [kind, key, sub] = p;
    if (kind === 'asks' && req.method === 'PUT') {
      const o = asks[body.key]; const content = JSON.stringify(body);
      if (o && o.status === 'open' && o.content === content) return send(200, { ask: o });
      asks[body.key] = { ...body, id: o?.status === 'open' ? o.id : `ask-${++n}`, revision: o?.status === 'open' ? o.revision + 1 : 1, status: 'open', content };
      return send(200, { ask: asks[body.key] });
    }
    if (kind === 'asks' && sub === 'cancel') { if (asks[key]?.status !== 'open') return send(404, { error: 'No open ask with that key' }); asks[key].status = 'cancelled'; return send(200, { ask: asks[key] }); }
    if (kind === 'asks' && sub === 'ack') { if (!asks[key] || asks[key].status !== 'answered' || asks[key].acked) return send(404, { error: 'No unacknowledged resolved ask with that key' }); asks[key].acked = true; return send(200, { ok: true }); }
    if (kind === 'asks' && req.method === 'GET' && key) { if (!asks[key]) return send(404, { error: 'Ask not found' }); return send(200, { ask: asks[key] }); }
    if (kind === 'answers') {
      const evs = fs.existsSync(eventsFile) ? JSON.parse(fs.readFileSync(eventsFile)) : [];
      for (const e of evs) if (asks[e.askKey] && asks[e.askKey].id === e.askId) asks[e.askKey].status = e.status;
      return send(200, { events: evs, cursor: `c${evs.length}` });
    }
    if (kind === 'work' && req.method === 'PUT') { work[body.key] = body; return send(200, { work: body }); }
    if (kind === 'work' && sub === 'done') { work[key] = { ...work[key], done: true }; return send(200, { work: work[key] }); }
    if (kind === 'notes' && req.method === 'PUT') { notes[body.key] = body; return send(200, { note: body }); }
    if (kind === 'notes' && req.method === 'DELETE') { if (!notes[key]) return send(404, { error: 'Note not found' }); delete notes[key]; return send(200, { ok: true }); }
    if (kind === 'state') return send(200, { asks, work, notes });
    send(404, { error: 'unknown route' });
  });
}).listen(Number(port), '127.0.0.1');
