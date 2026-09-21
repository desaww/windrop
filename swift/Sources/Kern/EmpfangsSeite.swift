import Foundation

/// Die Empfangsseite, die der Windows-Rechner im Browser offen haelt.
/// Zeichengleich mit der Python-Fassung aus M1, damit beide Versionen
/// austauschbar bleiben.
enum EmpfangsSeite {
    static let html = #"""
<!doctype html>
<html lang="de">
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
  .kopf { display: flex; align-items: baseline; gap: 10px; }
  .n { font-weight: 500; overflow-wrap: anywhere; }
  .s { margin-left: auto; font-size: 12px; color: #6b6b68; white-space: nowrap; }
  .bar { height: 4px; border-radius: 2px; background: #e8e8e4; margin-top: 9px; overflow: hidden; }
  .bar > i { display: block; height: 100%; width: 0; background: #4a9c5d; transition: width .12s linear; }
  .item.fertig .bar { display: none; }
  .item.fehler .bar > i { background: #c1543f; }
  .hint { font-size: 13px; margin-top: 22px; }
  code { background: rgba(128,128,128,.15); padding: 1px 5px; border-radius: 4px; font-size: 12px; }
  #leer { font-size: 13px; color: #6b6b68; margin-top: 12px; }
</style>
</head>
<body>
<main>
  <h1>WinDrop</h1>
  <div class="muted">Empfangsseite &ndash; diesen Tab ge&ouml;ffnet lassen.</div>

  <div class="card">
    <div class="status"><span id="dot" class="dot"></span><span id="txt">Verbinde&hellip;</span></div>
  </div>

  <div id="liste"></div>
  <div id="leer">Noch nichts empfangen.</div>

  <div class="hint muted">
    Falls der Browser nach <em>&bdquo;Herunterladen mehrerer Dateien&ldquo;</em> fragt:
    einmal <b>Zulassen</b> w&auml;hlen. Danach kommt die Frage nicht wieder.<br><br>
    Tab anheften: Rechtsklick auf den Tab &rarr; <code>Registerkarte anheften</code>.
  </div>
</main>

<script>
const TOKEN = "__TOKEN__";
const dot = document.getElementById("dot");
const txt = document.getElementById("txt");
const liste = document.getElementById("liste");
const leer = document.getElementById("leer");
const zeilen = {};
let fertigZaehler = 0;

function setStatus(klasse, text) {
  dot.className = "dot " + klasse;
  txt.textContent = text;
}

function kbyte(n) {
  const e = ["B","KB","MB","GB"]; let i = 0;
  while (n >= 1024 && i < 3) { n /= 1024; i++; }
  return (i === 0 ? n.toFixed(0) : n.toFixed(1)) + " " + e[i];
}

function zeile(msg) {
  if (zeilen[msg.id]) return zeilen[msg.id];
  const el = document.createElement("div");
  el.className = "item";
  el.innerHTML = '<div class="kopf"><span class="n"></span><span class="s"></span></div>' +
                 '<div class="bar"><i></i></div>';
  el.querySelector(".n").textContent = msg.name;
  el.querySelector(".s").textContent = "wird &uuml;bertragen";
  liste.prepend(el);
  leer.style.display = "none";
  zeilen[msg.id] = { el, name: msg.name, groesse: msg.groesse };
  return zeilen[msg.id];
}

function starteDownload(msg) {
  const z = zeile(msg);
  z.el.querySelector(".s").textContent = kbyte(msg.groesse);
  const a = document.createElement("a");
  a.href = msg.url; a.download = msg.name; a.rel = "noopener";
  document.body.appendChild(a); a.click(); a.remove();
}

function fortschritt(msg) {
  const z = zeilen[msg.id]; if (!z) return;
  const anteil = z.groesse ? msg.gesendet / z.groesse : 0;
  z.el.querySelector(".bar > i").style.width = (anteil * 100).toFixed(1) + "%";
  z.el.querySelector(".s").textContent =
    kbyte(msg.gesendet) + " / " + kbyte(z.groesse) + "  " + Math.round(anteil * 100) + "%";
}

function fertig(msg) {
  const z = zeilen[msg.id]; if (!z) return;
  z.el.classList.add("fertig");
  z.el.querySelector(".s").textContent = kbyte(z.groesse) + " \u00b7 " +
    new Date().toLocaleTimeString("de-DE", {hour: "2-digit", minute: "2-digit"});
  fertigZaehler++;
  document.title = "(" + fertigZaehler + ") WinDrop";
}

function fehler(msg) {
  const z = zeilen[msg.id]; if (!z) return;
  z.el.classList.add("fehler");
  z.el.querySelector(".s").textContent = msg.grund || "fehlgeschlagen";
}

function verarbeite(msg) {
  if (msg.typ === "willkommen") {
    setStatus("on", "Verbunden mit " + msg.geraet);
  } else if (msg.typ === "datei") {
    starteDownload(msg);
  } else if (msg.typ === "fortschritt") {
    fortschritt(msg);
  } else if (msg.typ === "fertig") {
    fertig(msg);
  } else if (msg.typ === "fehler") {
    fehler(msg);
  }
}

// --- Verbindung: zuerst WebSocket, nach drei Fehlversuchen SSE als Rueckfall
// Nach Standby, Deckelzuklappen oder WLAN-Wechsel meldet der Browser den
// Abbruch oft erst verspaetet. Deshalb wird zusaetzlich bei jedem Zurueckkehren
// auf den Tab und im 15-Sekunden-Takt geprueft, ob die Leitung noch steht.
let ws = null, es = null, wsFehler = 0, wartezeit = 500, geplant = null;

function planeWS(ms) {
  if (geplant) clearTimeout(geplant);
  geplant = setTimeout(function () { geplant = null; verbindeWS(); }, ms);
}

function verbindeWS() {
  if (ws && (ws.readyState === 0 || ws.readyState === 1)) return;
  if (es) { try { es.close(); } catch (e) {} es = null; }
  const schema = location.protocol === "https:" ? "wss:" : "ws:";
  const dieser = new WebSocket(schema + "//" + location.host + "/ws?t=" + encodeURIComponent(TOKEN));
  ws = dieser;
  dieser.onopen = () => { wsFehler = 0; wartezeit = 500; setStatus("on", "Verbunden"); };
  dieser.onmessage = (e) => verarbeite(JSON.parse(e.data));
  dieser.onclose = () => {
    // Nur reagieren, wenn das noch die aktuelle Verbindung ist. Sonst
    // stapeln sich nach einem Neuversuch mehrere Leitungen.
    if (ws !== dieser) return;
    ws = null;
    setStatus("off", "Verbindung unterbrochen \u2013 neuer Versuch\u2026");
    wsFehler++;
    if (wsFehler >= 3) { verbindeSSE(); return; }
    planeWS(wartezeit);
    wartezeit = Math.min(wartezeit * 2, 5000);
  };
  dieser.onerror = () => { try { dieser.close(); } catch (e) {} };
}

function verbindeSSE() {
  if (es) return;
  setStatus("wait", "WebSocket nicht m\u00f6glich \u2013 nutze R\u00fcckfallebene");
  const dieses = new EventSource("/events?t=" + encodeURIComponent(TOKEN));
  es = dieses;
  dieses.onopen = () => { if (es === dieses) setStatus("on", "Verbunden (R\u00fcckfallebene)"); };
  dieses.onmessage = (e) => verarbeite(JSON.parse(e.data));
  dieses.onerror = () => {
    if (es !== dieses) return;
    setStatus("off", "Verbindung unterbrochen \u2013 neuer Versuch\u2026");
  };
}

// Sofort neu verbinden, wenn die Leitung offensichtlich tot ist.
function pruefeVerbindung(erzwingeWS) {
  if (ws && ws.readyState === 1) return;
  // Laeuft die Rueckfallebene, wird nur bei einer echten Gelegenheit
  // (Netz wieder da, Tab wieder sichtbar) erneut WebSocket versucht.
  if (es && es.readyState === 1 && !erzwingeWS) return;
  const alterWS = ws, alteSSE = es;
  ws = null; es = null;
  if (alterWS) { try { alterWS.close(); } catch (e) {} }
  if (alteSSE) { try { alteSSE.close(); } catch (e) {} }
  wsFehler = 0;
  wartezeit = 500;
  planeWS(0);
}

window.addEventListener("online", function () { pruefeVerbindung(true); });
window.addEventListener("focus", function () { pruefeVerbindung(true); });
window.addEventListener("pageshow", function () { pruefeVerbindung(true); });
document.addEventListener("visibilitychange", function () {
  if (!document.hidden) pruefeVerbindung(true);
});
setInterval(function () { pruefeVerbindung(false); }, 15000);

verbindeWS();
</script>
</body>
</html>
"""#
}
