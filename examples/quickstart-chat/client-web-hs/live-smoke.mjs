// LIVE round-trip check: runs the Hybrid client wasm in Node against a
// PUBLISHED quickstart-chat module. JS owns a real WebSocket; the Haskell
// exports do the protocol/decode/render. Verifies a sent message echoes back
// in the rendered view. Requires: `bash scripts/build-web-hs.sh` first, plus a
// running SpacetimeDB with the module published (see README). Node >= 21.
import { WASI, OpenFile, File, ConsoleStdout } from "./web/vendor/browser_wasi_shim.mjs";
import { readFile } from "node:fs/promises";
import ghc_wasm_jsffi from "./dist/ghc_wasm_jsffi.js";

const HOST = process.env.HOST ?? "127.0.0.1:3000";
const DB = process.env.DB ?? "quickstart-chat";
const MSG = "hello-from-live-node-" + process.pid;

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

let lastView = "";
let sent = false;
const url = `ws://${HOST}/v1/database/${DB}/subscribe?compression=None`;
console.log("connecting", url);
const ws = new WebSocket(url, "v2.bsatn.spacetimedb");
ws.binaryType = "arraybuffer";

ws.onopen = async () => {
  console.log("ws OPEN — sending subscribe");
  ws.send(await inst.exports.hs_subscribe());
};
ws.onmessage = async (e) => {
  const view = await inst.exports.hs_on_frame(new Uint8Array(e.data));
  lastView = view;
  console.log("frame -> view:", JSON.stringify(view.slice(0, 240)));
  if (!sent) {
    sent = true;
    setTimeout(async () => {
      console.log("sending message:", MSG);
      ws.send(await inst.exports.hs_send_message(MSG));
    }, 300);
  }
  if (view.includes(MSG)) {
    console.log("LIVE ROUND-TRIP PASS: sent message rendered by Haskell hs_on_frame");
    process.exit(0);
  }
};
ws.onerror = (e) => console.error("ws ERROR", e?.message ?? e);
ws.onclose = (e) => console.error("ws CLOSE", e?.code, e?.reason);

setTimeout(() => {
  console.error("TIMEOUT (15s). lastView =", JSON.stringify(lastView));
  process.exit(1);
}, 15000);
