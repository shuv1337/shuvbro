// Phase-driven CDP helper for the guard drive.
import { writeFileSync } from "node:fs";
const [port, outDir, phase] = process.argv.slice(2);
const page = (await (await fetch("http://127.0.0.1:9333/json")).json()).find((t) => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl); await new Promise((r) => ws.addEventListener("open", r));
let n = 0; const p = new Map(); ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); p.get(m.id)?.(m); });
const send = (method, params = {}) => new Promise((r) => { const id = ++n; p.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ev = async (x) => (await send("Runtime.evaluate", { expression: x, awaitPromise: true, returnByValue: true })).result.result.value;
const shot = async (name) => { const r = await send("Page.captureScreenshot", { format: "png" }); writeFileSync(`${outDir}/${name}.png`, Buffer.from(r.result.data, "base64")); console.log("screenshot", name); };
const click = async (sel) => console.log("click", sel, await ev(`(() => { const b = document.querySelector(${JSON.stringify(sel)}); if (!b) return false; b.click(); return true; })()`));
const body = async (l) => console.log(l, JSON.stringify(await ev(`({title: document.title, text: document.body.innerText.slice(0, 1200)})`)));
await send("Emulation.setDeviceMetricsOverride", { width: 1000, height: 1100, deviceScaleFactor: 1, mobile: false });
if (phase === "load") { await send("Page.navigate", { url: `http://127.0.0.1:${port}/` }); await sleep(2500); await body("LOADED"); }
if (phase === "stale-click") {
  await click('button[data-act="choice"][data-id="call-a"][data-choice="yes"]'); await sleep(2500);
  await body("AFTER-STALE-CLICK"); await shot("07-stale-card-click-refused");
}
if (phase === "later") {
  await send("Page.reload"); await sleep(2500);
  await click('button[data-act="panel"][data-id="sample-ship"][data-panel="later"]'); await sleep(300);
  await shot("08-later-panel");
  await click('button[data-act="later"][data-id="sample-ship"]'); await sleep(2500);
  await send("Page.reload"); await sleep(2500);
  await body("AFTER-LATER"); await shot("09-after-later");
}
ws.close();
