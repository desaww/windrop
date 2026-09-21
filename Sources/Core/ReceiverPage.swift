import Foundation

/// The page the Windows machine keeps open in its browser. It is served by
/// the Mac itself, so it has to work without any network access of its own.
enum ReceiverPage {

    /// The page is built fresh for every request, so a change of language
    /// takes effect as soon as the Windows tab is reloaded.
    static func html(for language: AppLanguage = .current) -> String {
        let german = language == .german
        func t(_ english: String, _ germanText: String) -> String {
            german ? germanText : english
        }

        // Texts the script needs at runtime, handed over as one JSON object.
        let texts: [String: String] = [
            "connecting": t("Connecting…", "Verbindung wird aufgebaut…"),
            "connected": t("Connected", "Verbunden"),
            "connectedTo": t("Connected to ", "Verbunden mit "),
            "connectedFallback": t("Connected (fallback)", "Verbunden (Rückfallebene)"),
            "lost": t("Connection lost – retrying…", "Verbindung verloren – neuer Versuch…"),
            "fallback": t("WebSocket unavailable – using the fallback",
                          "WebSocket nicht verfügbar – Rückfallebene läuft"),
            "transferring": t("transferring", "überträgt"),
            "failed": t("failed", "fehlgeschlagen"),
        ]

        return template
            .replacingOccurrences(of: "__LANG__", with: language.rawValue)
            .replacingOccurrences(of: "__TEXTS__", with: JSONHelper.text(texts) ?? "{}")
            .replacingOccurrences(of: "__SUBTITLE__",
                                  with: t("Receiving page &ndash; keep this tab open.",
                                          "Empfangsseite &ndash; diesen Tab offen lassen."))
            .replacingOccurrences(of: "__EMPTY__",
                                  with: t("Nothing received yet.", "Noch nichts empfangen."))
            .replacingOccurrences(of: "__HINT_ASK__",
                                  with: t("If the browser asks about",
                                          "Falls der Browser nach"))
            .replacingOccurrences(of: "__HINT_MULTI__",
                                  with: t("Download multiple files",
                                          "Mehrere Dateien herunterladen"))
            .replacingOccurrences(of: "__HINT_ALLOW__",
                                  with: t("choose <b>Allow</b> once. It will not ask again.",
                                          "fragt: einmal <b>Zulassen</b> wählen, dann ist Ruhe."))
            .replacingOccurrences(of: "__HINT_PIN__",
                                  with: t("Pin the tab: right-click the tab",
                                          "Tab anheften: Rechtsklick auf den Tab"))
            .replacingOccurrences(of: "__HINT_PIN_ITEM__",
                                  with: t("Pin tab", "Tab anheften"))
    }

    private static let template = #"""
<!doctype html>
<html lang="__LANG__">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WinDrop</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 44px 24px 80px;
    font: 15px/1.5 -apple-system, "Segoe UI", system-ui, sans-serif;
    background: #f7f7f5; color: #1f1f1e; display: flex; justify-content: center;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #191919; color: #e8e8e6; }
    .card, .item { background: #232323 !important; border-color: #333 !important; }
    .muted, .s { color: #8f8f8c !important; }
    .bar { background: #333 !important; }
  }
  main { width: 100%; max-width: 580px; }
  h1 { font-size: 20px; font-weight: 600; margin: 0 0 4px; }
  .muted { color: #6b6b68; font-size: 13px; }
  .card { background: #fff; border: 1px solid #e3e3e0; border-radius: 10px; padding: 14px 18px; margin-top: 20px; }
  .status { display: flex; align-items: center; gap: 9px; font-size: 14px; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: #b8b8b4; flex: none; }
  .dot.on { background: #4a9c5d; } .dot.off { background: #c1543f; } .dot.wait { background: #c99a3d; }
  .item { background: #fff; border: 1px solid #e3e3e0; border-radius: 8px; padding: 11px 14px; margin-top: 8px; }
  .head { display: flex; align-items: baseline; gap: 10px; }
  .n { font-weight: 500; overflow-wrap: anywhere; }
  .s { margin-left: auto; font-size: 12px; color: #6b6b68; white-space: nowrap; }
  .bar { height: 4px; border-radius: 2px; background: #e8e8e4; margin-top: 9px; overflow: hidden; }
  .bar > i { display: block; height: 100%; width: 0; background: #4a9c5d; transition: width .12s linear; }
  .item.done .bar { display: none; }
  .item.failed .bar > i { background: #c1543f; }
  .hint { font-size: 13px; margin-top: 22px; }
  code { background: rgba(128,128,128,.15); padding: 1px 5px; border-radius: 4px; font-size: 12px; }
  #empty { font-size: 13px; color: #6b6b68; margin-top: 12px; }
</style>
</head>
<body>
<main>
  <h1>WinDrop</h1>
  <div class="muted">__SUBTITLE__</div>

  <div class="card">
    <div class="status"><span id="dot" class="dot"></span><span id="txt"></span></div>
  </div>

  <div id="list"></div>
  <div id="empty">__EMPTY__</div>

  <div class="hint muted">
    __HINT_ASK__ <em>&ldquo;__HINT_MULTI__&rdquo;</em>
    __HINT_ALLOW__<br><br>
    __HINT_PIN__ &rarr; <code>__HINT_PIN_ITEM__</code>.
  </div>
</main>

<script>
const TOKEN = "__TOKEN__";
const T = __TEXTS__;
const dot = document.getElementById("dot");
const txt = document.getElementById("txt");
const list = document.getElementById("list");
const empty = document.getElementById("empty");
const rows = {};
let doneCount = 0;

function setStatus(className, text) {
  dot.className = "dot " + className;
  txt.textContent = text;
}

function humanSize(n) {
  const units = ["B","KB","MB","GB"]; let i = 0;
  while (n >= 1024 && i < 3) { n /= 1024; i++; }
  return (i === 0 ? n.toFixed(0) : n.toFixed(1)) + " " + units[i];
}

function row(msg) {
  if (rows[msg.id]) return rows[msg.id];
  const el = document.createElement("div");
  el.className = "item";
  el.innerHTML = '<div class="head"><span class="n"></span><span class="s"></span></div>' +
                 '<div class="bar"><i></i></div>';
  el.querySelector(".n").textContent = msg.name;
  el.querySelector(".s").textContent = T.transferring;
  list.prepend(el);
  empty.style.display = "none";
  rows[msg.id] = { el, name: msg.name, size: msg.size };
  return rows[msg.id];
}

function startDownload(msg) {
  const r = row(msg);
  r.el.querySelector(".s").textContent = humanSize(msg.size);
  const a = document.createElement("a");
  a.href = msg.url; a.download = msg.name; a.rel = "noopener";
  document.body.appendChild(a); a.click(); a.remove();
}

function progress(msg) {
  const r = rows[msg.id]; if (!r) return;
  const fraction = r.size ? msg.sent / r.size : 0;
  r.el.querySelector(".bar > i").style.width = (fraction * 100).toFixed(1) + "%";
  r.el.querySelector(".s").textContent =
    humanSize(msg.sent) + " / " + humanSize(r.size) + "  " + Math.round(fraction * 100) + "%";
}

function done(msg) {
  const r = rows[msg.id]; if (!r) return;
  r.el.classList.add("done");
  r.el.querySelector(".s").textContent = humanSize(r.size) + " \u00b7 " +
    new Date().toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"});
  doneCount++;
  document.title = "(" + doneCount + ") WinDrop";
}

function failed(msg) {
  const r = rows[msg.id]; if (!r) return;
  r.el.classList.add("failed");
  r.el.querySelector(".s").textContent = msg.reason || T.failed;
}

function handle(msg) {
  if (msg.type === "welcome") {
    setStatus("on", T.connectedTo + msg.device);
  } else if (msg.type === "file") {
    startDownload(msg);
  } else if (msg.type === "progress") {
    progress(msg);
  } else if (msg.type === "done") {
    done(msg);
  } else if (msg.type === "error") {
    failed(msg);
  }
}

// --- Connection: WebSocket first, SSE as a fallback after three failures.
// After sleep, a closed lid or a network change the browser often reports the
// drop late. So the line is also checked every 15 seconds and whenever the
// tab becomes visible again.
let ws = null, es = null, wsFailures = 0, backoff = 500, pending = null;

function scheduleWS(ms) {
  if (pending) clearTimeout(pending);
  pending = setTimeout(function () { pending = null; connectWS(); }, ms);
}

function connectWS() {
  if (ws && (ws.readyState === 0 || ws.readyState === 1)) return;
  if (es) { try { es.close(); } catch (e) {} es = null; }
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  const socket = new WebSocket(scheme + "//" + location.host + "/ws?t=" + encodeURIComponent(TOKEN));
  ws = socket;
  socket.onopen = () => { wsFailures = 0; backoff = 500; setStatus("on", T.connected); };
  socket.onmessage = (e) => handle(JSON.parse(e.data));
  socket.onclose = () => {
    // Only react if this is still the current connection, otherwise
    // several lines pile up after a retry.
    if (ws !== socket) return;
    ws = null;
    setStatus("off", T.lost);
    wsFailures++;
    if (wsFailures >= 3) { connectSSE(); return; }
    scheduleWS(backoff);
    backoff = Math.min(backoff * 2, 5000);
  };
  socket.onerror = () => { try { socket.close(); } catch (e) {} };
}

function connectSSE() {
  if (es) return;
  setStatus("wait", T.fallback);
  const stream = new EventSource("/events?t=" + encodeURIComponent(TOKEN));
  es = stream;
  stream.onopen = () => { if (es === stream) setStatus("on", T.connectedFallback); };
  stream.onmessage = (e) => handle(JSON.parse(e.data));
  stream.onerror = () => {
    if (es !== stream) return;
    setStatus("off", T.lost);
  };
}

// Reconnect right away when the line is obviously dead.
function checkConnection(forceWS) {
  if (ws && ws.readyState === 1) return;
  // While the fallback is running, WebSocket is only retried on a real
  // occasion: network back, tab visible again.
  if (es && es.readyState === 1 && !forceWS) return;
  const oldWS = ws, oldSSE = es;
  ws = null; es = null;
  if (oldWS) { try { oldWS.close(); } catch (e) {} }
  if (oldSSE) { try { oldSSE.close(); } catch (e) {} }
  wsFailures = 0;
  backoff = 500;
  scheduleWS(0);
}

window.addEventListener("online", function () { checkConnection(true); });
window.addEventListener("focus", function () { checkConnection(true); });
window.addEventListener("pageshow", function () { checkConnection(true); });
document.addEventListener("visibilitychange", function () {
  if (!document.hidden) checkConnection(true);
});
setInterval(function () { checkConnection(false); }, 15000);

setStatus("", T.connecting);
connectWS();
</script>
</body>
</html>
"""#
}
