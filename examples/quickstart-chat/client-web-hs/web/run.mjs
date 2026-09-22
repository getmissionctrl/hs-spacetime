import { WASI, OpenFile, File, ConsoleStdout } from "./vendor/browser_wasi_shim.mjs";

const errEl = document.getElementById("err");
const showErr = (m) => { errEl.textContent += m + "\n"; };
window.addEventListener("error", (e) => showErr("error: " + (e.message || e.error)));
window.addEventListener("unhandledrejection", (e) => showErr("rejection: " + (e.reason && (e.reason.stack || e.reason.message || e.reason))));

async function main() {
  const cb = "?cb=" + Date.now();
  const { default: ghc_wasm_jsffi } = await import("./ghc_wasm_jsffi.js" + cb);

  const params = new URLSearchParams(location.search);
  const host = params.get("host") ?? "127.0.0.1:3000";
  const db = params.get("db") ?? "quickstart-chat";

  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((m) => console.log("[wasm]", m)),
    ConsoleStdout.lineBuffered((m) => console.error("[wasm]", m)),
  ];
  const wasi = new WASI([], [], fds);
  const bytes = await (await fetch("./chat-web.wasm" + cb)).arrayBuffer();
  const mod = await WebAssembly.compile(bytes);
  const __exports = {};
  const inst = await WebAssembly.instantiate(mod, {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: ghc_wasm_jsffi(__exports),
  });
  Object.assign(__exports, inst.exports);
  wasi.initialize(inst); // runs _initialize; do NOT call it again

  const logEl = document.getElementById("log");
  const wsUrl = "ws://" + host + "/v1/database/" + db + "/subscribe?compression=None";
  const ws = new WebSocket(wsUrl, "v2.bsatn.spacetimedb");
  ws.binaryType = "arraybuffer";
  ws.onopen = async () => { ws.send(await inst.exports.hs_subscribe()); };
  ws.onmessage = async (e) => { logEl.innerHTML = await inst.exports.hs_on_frame(new Uint8Array(e.data)); };
  ws.onerror = () => showErr("websocket error (is the module published at " + wsUrl + " ?)");
  ws.onclose = () => showErr("websocket closed");

  document.getElementById("nameForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (ws.readyState !== WebSocket.OPEN) { showErr("not connected yet"); return; }
    ws.send(await inst.exports.hs_set_name(document.getElementById("name").value));
  });
  document.getElementById("msgForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (ws.readyState !== WebSocket.OPEN) { showErr("not connected yet"); return; }
    const el = document.getElementById("msg");
    ws.send(await inst.exports.hs_send_message(el.value));
    el.value = "";
  });
}

main().catch((e) => showErr("EXCEPTION: " + (e && (e.stack || e.message || e))));
