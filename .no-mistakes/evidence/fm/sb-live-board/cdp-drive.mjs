// Drive the real board page in headless Chromium over CDP: click real buttons, screenshot.
import { writeFileSync } from "node:fs";
const [port, outDir, phase = "answer"] = process.argv.slice(2);
const url = `http://127.0.0.1:${port}/`;
const targets = await (await fetch("http://127.0.0.1:9333/json")).json();
const page = targets.find((t) => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let n = 0; const pending = new Map();
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise((r) => { const id = ++n; pending.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ev = async (expr) => (await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true })).result.result.value;
const shot = async (name) => { const r = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true }); writeFileSync(`${outDir}/${name}.png`, Buffer.from(r.result.data, "base64")); console.log("screenshot", name); };
const click = async (sel) => { const ok = await ev(`(() => { const b = document.querySelector(${JSON.stringify(sel)}); if (!b) return false; b.click(); return true; })()`); console.log("click", sel, ok); if (!ok) throw new Error("missing " + sel); };
const state = async (label) => console.log(label, JSON.stringify(await ev(`({title: document.title, you: document.getElementById("c-you")?.textContent, cards: [...document.querySelectorAll("[data-card]")].map(c => c.dataset.card), feedback: [...document.querySelectorAll(".feedback")].map(f => f.textContent), body: document.body.innerText.slice(0, 1500)})`)));
await send("Page.enable"); await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 1000, height: 1300, deviceScaleFactor: 1, mobile: false });
if (phase === "answer") {
  await send("Page.navigate", { url }); await sleep(2500);
  await state("INITIAL"); await shot("01-waiting-on-you-initial");
  await click('button[data-act="choice"][data-id="call-yes"][data-choice="yes"]'); await sleep(1500);
  await state("AFTER-YES"); await shot("02-after-yes-click");
  await click('button[data-act="choice"][data-id="sample-ship"][data-choice="no"]'); await sleep(1500);
  await click('button[data-act="panel"][data-id="sample-plain"][data-panel="reply"]'); await sleep(300);
  await ev(`(() => { const t = document.querySelector('textarea[data-draft="sample-plain"]'); t.value = "Not yet, wait for the docs"; t.dispatchEvent(new Event("input", {bubbles: true})); })()`);
  await shot("03-reply-panel-typed");
  await click('button[data-act="reply"][data-id="sample-plain"]'); await sleep(1500);
  await click('button[data-act="choice"][data-id="call-option"][data-choice="opt-2"]'); await sleep(1500);
  await shot("04-after-all-clicks");
  await send("Page.reload"); await sleep(3500);
  await state("AFTER-RELOAD"); await shot("05-after-reload-answered-with-lead");
} else if (phase === "stale") {
  await sleep(8000);
  await state("STALE"); await shot("06-stale-after-server-stopped");
}
ws.close();
