// Headless harness: run the spike wasm under Node's built-in WASI so we can
// iterate on the JSFFI callback question without a browser.
import { WASI } from "node:wasi";
import { readFile } from "node:fs/promises";
import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";

const log = (...a) => console.log("[node]", ...a);

const wasi = new WASI({ version: "preview1", returnOnExit: false });
const bytes = await readFile(new URL("./spike.wasm", import.meta.url));
const mod = await WebAssembly.compile(bytes);

const __exports = {};
const inst = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghc_wasm_jsffi(__exports),
});
Object.assign(__exports, inst.exports);

log("typeof globalThis.WebSocket =", typeof globalThis.WebSocket);
log("typeof globalThis.setTimeout =", typeof globalThis.setTimeout);

log("wasi.initialize (runs _initialize)…");
wasi.initialize(inst);
log("RTS initialized");

log("calling startSpike…");
const r = inst.exports.startSpike("wss://ws.postman-echo.com/raw");
log("startSpike returned:", r && typeof r.then === "function" ? "Promise" : typeof r);
if (r && typeof r.then === "function") {
  r.then(() => log("startSpike promise resolved")).catch((e) => log("startSpike rejected:", e));
}

// Keep the process alive long enough to observe deferred callbacks.
setTimeout(() => { log("8s elapsed, exiting"); process.exit(0); }, 8000);
