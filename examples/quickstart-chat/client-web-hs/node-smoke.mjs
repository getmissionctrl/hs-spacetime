// Headless load test: instantiate the built chat-web.wasm in Node and exercise
// the four Hybrid exports (no live server needed). Run AFTER build-web-hs.sh.
import { WASI, OpenFile, File, ConsoleStdout } from "./web/vendor/browser_wasi_shim.mjs";
import { readFile } from "node:fs/promises";
import ghc_wasm_jsffi from "./dist/ghc_wasm_jsffi.js";

const fds = [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered((m) => console.log("[wasm]", m)),
  ConsoleStdout.lineBuffered((m) => console.error("[wasm]", m)),
];
const wasi = new WASI([], [], fds);
const bytes = await readFile(new URL("./dist/chat-web.wasm", import.meta.url));
const mod = await WebAssembly.compile(bytes);
const __exports = {};
const inst = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghc_wasm_jsffi(__exports),
});
Object.assign(__exports, inst.exports);
wasi.initialize(inst);

const sub = await inst.exports.hs_subscribe();
const snd = await inst.exports.hs_send_message("hi from node");
const nm = await inst.exports.hs_set_name("nodeuser");
const view = await inst.exports.hs_on_frame(new Uint8Array([1, 2, 3])); // non-zero tag => empty view, must not throw

console.log("hs_subscribe bytes:", sub.length);
console.log("hs_send_message bytes:", snd.length);
console.log("hs_set_name bytes:", nm.length);
console.log("hs_on_frame -> typeof:", typeof view, "len:", view.length);

const ok = sub.length > 0 && snd.length > 0 && nm.length > 0 && typeof view === "string";
console.log(ok ? "NODE SMOKE PASS" : "NODE SMOKE FAIL");
process.exit(ok ? 0 : 1);
