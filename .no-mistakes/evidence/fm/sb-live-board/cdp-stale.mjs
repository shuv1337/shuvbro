// Poll the open board page's "updated" indicator over CDP while the server is stopped.
import { writeFileSync } from "node:fs";
const [outDir] = process.argv.slice(2);
const page = (await (await fetch("http://127.0.0.1:9333/json")).json()).find((t) => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl); await new Promise((r) => ws.addEventListener("open", r));
let n = 0; const p = new Map(); ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); p.get(m.id)?.(m); });
const send = (method, params = {}) => new Promise((r) => { const id = ++n; p.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
await send("Emulation.setFocusEmulationEnabled", { enabled: true });
for (let i = 0; i < 4; i++) {
  const v = (await send("Runtime.evaluate", { expression: `[document.getElementById("updated").textContent, document.getElementById("updated").className, document.visibilityState]`, returnByValue: true })).result.result.value;
  console.log(new Date().toISOString(), JSON.stringify(v));
  await new Promise((r) => setTimeout(r, 2000));
}
const r = await send("Page.captureScreenshot", { format: "png" }); writeFileSync(`${outDir}/06-stale-after-server-stopped.png`, Buffer.from(r.result.data, "base64"));
ws.close();
