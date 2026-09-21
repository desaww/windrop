#!/usr/bin/env python3
"""
WinDrop M1 - Funktionskern
Dateien vom Mac an einen Windows-Rechner senden, ohne dass auf der
Windows-Seite etwas installiert wird.

Neu gegenueber M0:
  - WebSocket statt Server-Sent Events (SSE bleibt als Rueckfallebene)
  - Warteschlange: eine Datei nach der anderen, mit Wiederholung
  - Fortschritt in Echtzeit im Browser und im Terminal
  - Statusabfrage ueber die Kommandozeile

Nur Python-Standardbibliothek.

  python3 windrop.py serve
  python3 windrop.py send ~/Desktop/bericht.pdf
  python3 windrop.py status
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import queue
import secrets
import shutil
import socket
import socketserver
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------- Konfiguration

VERSION = "0.2 (M1)"
PORT = 8787
BASE = Path.home() / "WinDrop"
OUTBOX = BASE / "Outbox"
SENT = BASE / "Gesendet"
STAGE = BASE / ".stage"
TOKEN_FILE = BASE / "token.txt"

ANGEBOT_TIMEOUT = 30.0    # Sekunden, bis ein unbeantwortetes Angebot zurueck in die Schlange geht
MAX_VERSUCHE = 3
AUFRAEUM_NACH = 3600.0    # Sekunden, bis erledigte Eintraege aus der Liste fallen
PING_INTERVALL = 20.0
WATCH_INTERVAL = 0.7
CHUNK = 128 * 1024
FORTSCHRITT_TAKT = 0.15   # Sekunden zwischen zwei Fortschrittsmeldungen

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

TOKEN = ""

# ---------------------------------------------------------------- Ausgabe

_druck_lock = threading.Lock()
_zeile_offen = False


def log(msg):
    global _zeile_offen
    with _druck_lock:
        if _zeile_offen:
            sys.stdout.write("\n")
            _zeile_offen = False
        sys.stdout.write(time.strftime("[%H:%M:%S] ") + msg + "\n")
        sys.stdout.flush()


def fortschrittszeile(text):
    global _zeile_offen
    with _druck_lock:
        sys.stdout.write("\r\033[K" + text)
        sys.stdout.flush()
        _zeile_offen = True


def zeile_abschliessen():
    global _zeile_offen
    with _druck_lock:
        if _zeile_offen:
            sys.stdout.write("\n")
            sys.stdout.flush()
            _zeile_offen = False


def human(n):
    n = float(n)
    for einheit in ("B", "KB", "MB", "GB"):
        if n < 1024 or einheit == "GB":
            return f"{n:.0f} {einheit}" if einheit == "B" else f"{n:.1f} {einheit}"
        n /= 1024


def balken(anteil, breite=24):
    voll = int(anteil * breite)
    return "#" * voll + "." * (breite - voll)


# ---------------------------------------------------------------- Zugangscode

def load_token():
    BASE.mkdir(parents=True, exist_ok=True)
    if TOKEN_FILE.exists():
        t = TOKEN_FILE.read_text().strip()
        if t:
            return t
    t = secrets.token_urlsafe(24)
    TOKEN_FILE.write_text(t)
    os.chmod(TOKEN_FILE, 0o600)
    return t


def token_ok(query):
    gegeben = urllib.parse.parse_qs(query).get("t", [""])[0]
    return bool(TOKEN) and secrets.compare_digest(gegeben, TOKEN)


# ---------------------------------------------------------------- Empfaenger

class Empfaenger:
    """Eine offene Verbindung zu einem Browser-Tab."""

    def __init__(self, art, adresse):
        self.art = art               # "ws" oder "sse"
        self.adresse = adresse
        self.name = adresse
        self.post = queue.Queue()
        self.lebt = True

    def sende(self, nachricht):
        if self.lebt:
            self.post.put(nachricht)

    def schliessen(self):
        self.lebt = False
        self.post.put(None)


_empfaenger = []
_empf_lock = threading.Lock()


def empfaenger_liste():
    with _empf_lock:
        return [e for e in _empfaenger if e.lebt]


def anmelden(e):
    with _empf_lock:
        _empfaenger.append(e)
    log(f"Empfaenger verbunden: {e.name} ({e.art.upper()})")
    _planer_wecken()


def abmelden(e):
    e.lebt = False
    with _empf_lock:
        if e in _empfaenger:
            _empfaenger.remove(e)
    log(f"Empfaenger getrennt: {e.name}")


def rundruf(nachricht):
    for e in empfaenger_liste():
        e.sende(nachricht)


# ---------------------------------------------------------------- Warteschlange

_schlange = []          # Liste von Transfers, aelteste zuerst
_schlange_lock = threading.RLock()
_wecker = threading.Event()


def _planer_wecken():
    _wecker.set()


def neuer_transfer(pfad: Path, ins_archiv=False):
    t = {
        "id": secrets.token_urlsafe(9),
        "pfad": str(pfad),
        "name": pfad.name,
        "groesse": pfad.stat().st_size,
        "status": "wartend",     # wartend | angeboten | laeuft | fertig | fehler
        "gesendet": 0,
        "versuche": 0,
        "angeboten_um": 0.0,
        "erzeugt": time.time(),
        "beendet": 0.0,
        "archivieren": ins_archiv,
        "grund": "",
    }
    with _schlange_lock:
        _schlange.append(t)
    log(f"In der Warteschlange: {t['name']} ({human(t['groesse'])})")
    _planer_wecken()
    return t


def transfer(tid):
    with _schlange_lock:
        for t in _schlange:
            if t["id"] == tid:
                return t
    return None


def transfer_oeffentlich(t):
    return {
        "id": t["id"], "name": t["name"], "groesse": t["groesse"],
        "groesse_text": human(t["groesse"]), "status": t["status"],
        "gesendet": t["gesendet"], "grund": t["grund"],
        "url": f"/f/{t['id']}?t={TOKEN}",
    }


def planer():
    """Gibt immer nur eine Datei gleichzeitig an den Browser weiter.

    Das haelt die Reihenfolge stabil, macht den Fortschritt eindeutig und
    vermeidet, dass der Browser mehrere gleichzeitige Downloads abwehrt."""
    while True:
        _wecker.wait(timeout=1.0)
        _wecker.clear()
        with _schlange_lock:
            laufend = [t for t in _schlange if t["status"] in ("angeboten", "laeuft")]

            # Angebot verfallen lassen, wenn der Browser nicht reagiert
            for t in list(laufend):
                if t["status"] == "angeboten" and time.time() - t["angeboten_um"] > ANGEBOT_TIMEOUT:
                    if t["versuche"] >= MAX_VERSUCHE:
                        t["status"] = "fehler"
                        t["grund"] = "Empfaenger hat nicht reagiert"
                        t["beendet"] = time.time()
                        log(f"Aufgegeben: {t['name']} (keine Reaktion)")
                        rundruf({"typ": "fehler", "id": t["id"], "grund": t["grund"]})
                    else:
                        t["status"] = "wartend"
                        log(f"Erneuter Versuch: {t['name']}")
                    laufend.remove(t)

            if not laufend:
                offen = [t for t in _schlange if t["status"] == "wartend"]
                if offen and empfaenger_liste():
                    t = offen[0]
                    t["status"] = "angeboten"
                    t["versuche"] += 1
                    t["angeboten_um"] = time.time()
                    t["gesendet"] = 0
                    rundruf({"typ": "datei", **transfer_oeffentlich(t)})
                    log(f"Angeboten: {t['name']} (Versuch {t['versuche']})")

            # Alte Eintraege aufraeumen
            for t in list(_schlange):
                if t["status"] in ("fertig", "fehler") and time.time() - t["beendet"] > AUFRAEUM_NACH:
                    _schlange.remove(t)


def transfer_abschliessen(t):
    t["status"] = "fertig"
    t["beendet"] = time.time()
    zeile_abschliessen()
    dauer = max(t["beendet"] - t["angeboten_um"], 0.001)
    log(f"Angekommen: {t['name']} ({human(t['groesse'])} in {dauer:.1f} s, "
        f"{human(t['groesse'] / dauer)}/s)")
    rundruf({"typ": "fertig", "id": t["id"]})
    if t["archivieren"]:
        threading.Thread(target=_ins_archiv, args=(t,), daemon=True).start()
    _planer_wecken()


def _ins_archiv(t):
    time.sleep(1)
    quelle = Path(t["pfad"])
    if not quelle.exists():
        return
    SENT.mkdir(parents=True, exist_ok=True)
    ziel = SENT / quelle.name
    i = 1
    while ziel.exists():
        ziel = SENT / f"{quelle.stem} ({i}){quelle.suffix}"
        i += 1
    try:
        shutil.move(str(quelle), str(ziel))
        t["pfad"] = str(ziel)
        shutil.rmtree(quelle.parent, ignore_errors=True)
    except OSError:
        pass


# ---------------------------------------------------------------- WebSocket

def ws_rahmen(nutzlast: bytes, opcode=0x1) -> bytes:
    """Serverseitige Rahmen werden nie maskiert."""
    kopf = bytearray([0x80 | opcode])
    n = len(nutzlast)
    if n < 126:
        kopf.append(n)
    elif n < 65536:
        kopf.append(126)
        kopf += struct.pack(">H", n)
    else:
        kopf.append(127)
        kopf += struct.pack(">Q", n)
    return bytes(kopf) + nutzlast


def ws_lesen(datei):
    """Liest genau einen Rahmen. Gibt (opcode, nutzlast) oder None zurueck."""
    kopf = datei.read(2)
    if len(kopf) < 2:
        return None
    fin_op, laenge_byte = kopf[0], kopf[1]
    opcode = fin_op & 0x0F
    maskiert = laenge_byte & 0x80
    laenge = laenge_byte & 0x7F
    if laenge == 126:
        laenge = struct.unpack(">H", datei.read(2))[0]
    elif laenge == 127:
        laenge = struct.unpack(">Q", datei.read(8))[0]
    if laenge > 1_000_000:
        return None
    maske = datei.read(4) if maskiert else b""
    daten = datei.read(laenge) if laenge else b""
    if maskiert:
        daten = bytes(b ^ maske[i % 4] for i, b in enumerate(daten))
    return opcode, daten


# ---------------------------------------------------------------- Empfangsseite

PAGE = r"""<!doctype html>
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
let wsFehler = 0, ws = null, wartezeit = 500;

function verbindeWS() {
  const schema = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(schema + "//" + location.host + "/ws?t=" + encodeURIComponent(TOKEN));
  ws.onopen = () => { wsFehler = 0; wartezeit = 500; setStatus("on", "Verbunden"); };
  ws.onmessage = (e) => verarbeite(JSON.parse(e.data));
  ws.onclose = () => {
    setStatus("off", "Verbindung unterbrochen \u2013 neuer Versuch\u2026");
    wsFehler++;
    if (wsFehler >= 3) { verbindeSSE(); return; }
    setTimeout(verbindeWS, wartezeit);
    wartezeit = Math.min(wartezeit * 2, 5000);
  };
  ws.onerror = () => { try { ws.close(); } catch (e) {} };
}

function verbindeSSE() {
  setStatus("wait", "WebSocket nicht m\u00f6glich \u2013 nutze Rueckfallebene");
  const es = new EventSource("/events?t=" + encodeURIComponent(TOKEN));
  es.onopen = () => setStatus("on", "Verbunden (Rueckfallebene)");
  es.onmessage = (e) => verarbeite(JSON.parse(e.data));
  es.onerror = () => setStatus("off", "Verbindung unterbrochen \u2013 neuer Versuch\u2026");
}

verbindeWS();
</script>
</body>
</html>
"""


# ---------------------------------------------------------------- Namen

UMSCHRIFT = {"ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue",
             "ß": "ss", "é": "e", "è": "e", "ê": "e", "á": "a", "à": "a", "â": "a",
             "í": "i", "ó": "o", "ô": "o", "ú": "u", "ç": "c", "ñ": "n"}


def ascii_ersatzname(name: str) -> str:
    """Reiner ASCII-Name als Rueckfallebene. Moderne Browser nehmen ohnehin
    filename*=UTF-8; nur wenn ein Client das ignoriert, greift dieser Name."""
    out = []
    for c in name:
        c = UMSCHRIFT.get(c, c)
        out.append(c if all(32 < ord(x) < 127 and x not in '"\\' for x in c) else "_")
    return "".join(out) or "datei"


# ---------------------------------------------------------------- HTTP-Server

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "WinDrop/0.2"
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _text(self, code, body, ctype="text/plain; charset=utf-8"):
        roh = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(roh)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(roh)

    def _json(self, code, obj):
        self._text(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def _lokal(self):
        return self.client_address[0] in ("127.0.0.1", "::1")

    # ---------- GET

    def do_GET(self):
        zerlegt = urllib.parse.urlsplit(self.path)
        pfad, query = zerlegt.path, zerlegt.query

        if pfad == "/favicon.ico":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if pfad in ("/", "/r", "/index.html"):
            if not token_ok(query):
                self._text(403, "WinDrop: ungueltiger oder fehlender Zugangscode.")
                return
            self._text(200, PAGE.replace("__TOKEN__", TOKEN), "text/html; charset=utf-8")
            return

        if pfad == "/ws":
            if not token_ok(query):
                self._text(403, "forbidden")
                return
            self._websocket()
            return

        if pfad == "/events":
            if not token_ok(query):
                self._text(403, "forbidden")
                return
            self._sse()
            return

        if pfad.startswith("/f/"):
            if not token_ok(query):
                self._text(403, "forbidden")
                return
            self._datei(pfad.split("/")[2])
            return

        if pfad == "/api/status" and self._lokal() and token_ok(query):
            with _schlange_lock:
                daten = [transfer_oeffentlich(t) for t in _schlange]
            self._json(200, {"empfaenger": [e.name for e in empfaenger_liste()],
                             "transfers": daten})
            return

        if pfad.startswith("/api/transfer/") and self._lokal() and token_ok(query):
            t = transfer(pfad.split("/")[3])
            if not t:
                self._json(404, {"fehler": "unbekannt"})
                return
            self._json(200, transfer_oeffentlich(t))
            return

        self._text(404, "not found")

    # ---------- POST

    def do_POST(self):
        zerlegt = urllib.parse.urlsplit(self.path)
        if zerlegt.path != "/api/send" or not self._lokal() or not token_ok(zerlegt.query):
            self._text(403, "forbidden")
            return
        laenge = int(self.headers.get("Content-Length", "0"))
        try:
            daten = json.loads(self.rfile.read(laenge) or b"{}")
            p = Path(daten["path"]).expanduser().resolve()
            if not p.is_file():
                self._json(404, {"fehler": f"Datei nicht gefunden: {p}"})
                return
            t = neuer_transfer(p)
            self._json(200, {"ok": True, "id": t["id"], "name": t["name"], "groesse": t["groesse"]})
        except Exception as e:
            self._json(400, {"fehler": str(e)})

    # ---------- WebSocket

    def _websocket(self):
        schluessel = self.headers.get("Sec-WebSocket-Key")
        if not schluessel or self.headers.get("Upgrade", "").lower() != "websocket":
            self._text(400, "kein WebSocket-Handschlag")
            return
        antwort = base64.b64encode(
            hashlib.sha1((schluessel + WS_GUID).encode()).digest()).decode()

        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", antwort)
        self.end_headers()

        e = Empfaenger("ws", self.client_address[0])
        schreib_lock = threading.Lock()

        def schreiben():
            while True:
                nachricht = e.post.get()
                if nachricht is None:
                    break
                try:
                    roh = json.dumps(nachricht, ensure_ascii=False).encode("utf-8")
                    with schreib_lock:
                        self.wfile.write(ws_rahmen(roh))
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError, ValueError):
                    break
            e.lebt = False

        def pingen():
            while e.lebt:
                time.sleep(PING_INTERVALL)
                try:
                    with schreib_lock:
                        self.wfile.write(ws_rahmen(b"", 0x9))
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError, ValueError):
                    break

        anmelden(e)
        e.sende({"typ": "willkommen", "geraet": socket.gethostname(), "version": VERSION})
        threading.Thread(target=schreiben, daemon=True).start()
        threading.Thread(target=pingen, daemon=True).start()
        self._nachliefern(e)

        try:
            while e.lebt:
                rahmen = ws_lesen(self.rfile)
                if rahmen is None:
                    break
                opcode, daten = rahmen
                if opcode == 0x8:               # Verbindung wird geschlossen
                    break
                if opcode == 0x9:               # Ping vom Browser
                    with schreib_lock:
                        self.wfile.write(ws_rahmen(daten, 0xA))
                        self.wfile.flush()
                elif opcode == 0x1:
                    try:
                        nachricht = json.loads(daten.decode("utf-8"))
                    except ValueError:
                        continue
                    if nachricht.get("typ") == "name":
                        e.name = str(nachricht.get("wert", e.name))[:60]
        except (BrokenPipeError, ConnectionResetError, OSError, struct.error):
            pass
        finally:
            e.schliessen()
            abmelden(e)
            self.close_connection = True

    # ---------- SSE als Rueckfallebene

    def _sse(self):
        e = Empfaenger("sse", self.client_address[0])
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache, no-transform")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            anmelden(e)
            e.sende({"typ": "willkommen", "geraet": socket.gethostname(), "version": VERSION})
            self._nachliefern(e)
            while e.lebt:
                try:
                    nachricht = e.post.get(timeout=PING_INTERVALL)
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                if nachricht is None:
                    break
                roh = "data: " + json.dumps(nachricht, ensure_ascii=False) + "\n\n"
                self.wfile.write(roh.encode("utf-8"))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            abmelden(e)
            self.close_connection = True

    def _nachliefern(self, e):
        """Ein frisch verbundener Tab bekommt sofort mit, was gerade ansteht."""
        with _schlange_lock:
            offen = [t for t in _schlange if t["status"] == "angeboten"]
        for t in offen:
            e.sende({"typ": "datei", **transfer_oeffentlich(t)})

    # ---------- Datei ausliefern

    def _datei(self, tid):
        t = transfer(tid)
        if not t:
            self._text(404, "Unbekannte Datei.")
            return
        if t["status"] == "fertig":
            self._text(410, "Bereits uebertragen.")
            return
        p = Path(t["pfad"])
        if not p.is_file():
            self._text(404, "Datei nicht mehr vorhanden.")
            return

        groesse = p.stat().st_size
        t["status"] = "laeuft"
        t["gesendet"] = 0

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(groesse))
        self.send_header("Content-Disposition",
                         'attachment; filename="%s"; filename*=UTF-8\'\'%s'
                         % (ascii_ersatzname(t["name"]), urllib.parse.quote(t["name"])))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        letzte_meldung = 0.0
        try:
            with p.open("rb") as fh:
                while True:
                    brocken = fh.read(CHUNK)
                    if not brocken:
                        break
                    self.wfile.write(brocken)
                    t["gesendet"] += len(brocken)
                    jetzt = time.time()
                    if jetzt - letzte_meldung >= FORTSCHRITT_TAKT:
                        letzte_meldung = jetzt
                        self._melde_fortschritt(t, groesse)
        except (BrokenPipeError, ConnectionResetError, OSError):
            zeile_abschliessen()
            t["status"] = "wartend"      # der Planer versucht es erneut
            log(f"Abbruch bei {t['name']} nach {human(t['gesendet'])} - kommt zurueck in die Schlange")
            _planer_wecken()
            return

        self._melde_fortschritt(t, groesse)
        transfer_abschliessen(t)

    def _melde_fortschritt(self, t, groesse):
        rundruf({"typ": "fortschritt", "id": t["id"], "gesendet": t["gesendet"]})
        anteil = t["gesendet"] / groesse if groesse else 1.0
        fortschrittszeile(
            f"           {t['name'][:34]:<34} [{balken(anteil)}] {anteil*100:5.1f} %  "
            f"{human(t['gesendet'])} / {human(groesse)}")


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# ---------------------------------------------------------------- Outbox

def watch_outbox():
    OUTBOX.mkdir(parents=True, exist_ok=True)
    STAGE.mkdir(parents=True, exist_ok=True)
    groessen = {}
    while True:
        time.sleep(WATCH_INTERVAL)
        try:
            eintraege = [p for p in OUTBOX.iterdir() if p.is_file() and not p.name.startswith(".")]
        except OSError:
            continue
        aktuell = set()
        for p in eintraege:
            try:
                s = p.stat().st_size
            except OSError:
                continue
            aktuell.add(p)
            # Erst senden, wenn die Groesse zwischen zwei Durchlaeufen gleich bleibt.
            # Sonst wuerde eine noch kopierende Datei halb uebertragen.
            if groessen.get(p) == s:
                ordner = STAGE / secrets.token_urlsafe(6)
                ordner.mkdir(parents=True, exist_ok=True)
                ziel = ordner / p.name
                try:
                    shutil.move(str(p), str(ziel))
                except OSError:
                    continue
                groessen.pop(p, None)
                neuer_transfer(ziel, ins_archiv=True)
            else:
                groessen[p] = s
        for weg in set(groessen) - aktuell:
            groessen.pop(weg, None)


def recover_stage():
    """Nach einem Serverneustart sind alte Angebote hinfaellig. Dateien, die noch
    im Zwischenlager liegen, wandern zurueck in die Outbox und werden neu erfasst."""
    if not STAGE.exists():
        return
    for ordner in STAGE.iterdir():
        if not ordner.is_dir():
            continue
        for datei in ordner.iterdir():
            ziel = OUTBOX / datei.name
            i = 1
            while ziel.exists():
                ziel = OUTBOX / f"{datei.stem} ({i}){datei.suffix}"
                i += 1
            try:
                shutil.move(str(datei), str(ziel))
                log(f"Wiederhergestellt in die Outbox: {ziel.name}")
            except OSError:
                pass
        shutil.rmtree(ordner, ignore_errors=True)


# ---------------------------------------------------------------- Netzwerk

def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 53))   # Dummy-Ziel, es fliessen keine Pakete
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def bonjour_name():
    h = socket.gethostname()
    return h if h.endswith(".local") else h + ".local"


# ---------------------------------------------------------------- Befehle

def cmd_serve(args):
    global TOKEN, PORT
    PORT = args.port
    TOKEN = load_token()
    OUTBOX.mkdir(parents=True, exist_ok=True)
    SENT.mkdir(parents=True, exist_ok=True)

    try:
        srv = ThreadedServer((args.bind, PORT), Handler)
    except OSError as e:
        print(f"\n  Port {PORT} ist belegt ({e.strerror}).")
        print("  Entweder laeuft WinDrop schon, oder ein anderes Programm nutzt den Port.")
        print(f"  Anderen Port waehlen:  python3 windrop.py serve --port {PORT + 1}\n")
        return 1

    recover_stage()
    threading.Thread(target=watch_outbox, daemon=True).start()
    threading.Thread(target=planer, daemon=True).start()

    print()
    print(f"  WinDrop {VERSION} laeuft")
    print("  " + "-" * 64)
    print("  Am Windows-Rechner einmalig oeffnen (Tab offen lassen, anheften):")
    print()
    print(f"    http://{bonjour_name()}:{PORT}/?t={TOKEN}")
    print()
    print("  Falls der Name nicht aufgeloest wird:")
    print(f"    http://{lan_ip()}:{PORT}/?t={TOKEN}")
    print()
    print("  Senden:  python3 windrop.py send DATEI")
    print(f"  Oder:    Datei nach {OUTBOX} ziehen")
    print("  Status:  python3 windrop.py status")
    print("  Beenden: Strg + C")
    print("  " + "-" * 64)
    print(flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        zeile_abschliessen()
        print("Beendet.")
    return 0


def _api(pfad, port, daten=None):
    url = f"http://127.0.0.1:{port}{pfad}{'&' if '?' in pfad else '?'}t={urllib.parse.quote(TOKEN)}"
    req = urllib.request.Request(
        url,
        data=json.dumps(daten).encode() if daten is not None else None,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def cmd_send(args):
    global TOKEN
    TOKEN = load_token()
    ids = []
    for roh in args.dateien:
        p = Path(roh).expanduser().resolve()
        if not p.is_file():
            print(f"Nicht gefunden: {p}")
            continue
        try:
            antwort = _api("/api/send", args.port, {"path": str(p)})
        except urllib.error.URLError:
            print(f"Kein laufender WinDrop-Server auf Port {args.port}.")
            print("Zuerst starten:  python3 windrop.py serve")
            return 1
        ids.append(antwort["id"])
        print(f"Eingereiht: {antwort['name']} ({human(antwort['groesse'])})")

    if args.nowait or not ids:
        return 0

    print()
    offen = list(ids)
    letzter_text = ""
    try:
        while offen:
            time.sleep(0.2)
            for tid in list(offen):
                try:
                    t = _api(f"/api/transfer/{tid}", args.port)
                except urllib.error.URLError:
                    return 1
                anteil = t["gesendet"] / t["groesse"] if t["groesse"] else 1.0
                if t["status"] == "fertig":
                    sys.stdout.write("\r\033[K")
                    print(f"Angekommen: {t['name']}")
                    offen.remove(tid)
                elif t["status"] == "fehler":
                    sys.stdout.write("\r\033[K")
                    print(f"Fehlgeschlagen: {t['name']} ({t['grund']})")
                    offen.remove(tid)
                else:
                    zustand = {"wartend": "wartet auf Empfaenger",
                               "angeboten": "wartet auf Browser",
                               "laeuft": "uebertraegt"}.get(t["status"], t["status"])
                    text = (f"{t['name'][:30]:<30} [{balken(anteil)}] "
                            f"{anteil*100:5.1f} %  {zustand}")
                    if text != letzter_text:
                        sys.stdout.write("\r\033[K" + text)
                        sys.stdout.flush()
                        letzter_text = text
    except KeyboardInterrupt:
        print("\nAbgekoppelt. Die Uebertragung laeuft im Server weiter.")
    return 0


def cmd_status(args):
    global TOKEN
    TOKEN = load_token()
    try:
        s = _api("/api/status", args.port)
    except urllib.error.URLError:
        print(f"Kein laufender WinDrop-Server auf Port {args.port}.")
        return 1
    if s["empfaenger"]:
        print("Verbundene Empfaenger: " + ", ".join(s["empfaenger"]))
    else:
        print("Kein Empfaenger verbunden.")
    if not s["transfers"]:
        print("Warteschlange leer.")
        return 0
    print()
    print(f"{'Datei':<34} {'Groesse':>10}  Status")
    print("-" * 62)
    for t in s["transfers"]:
        zustand = t["status"]
        if zustand == "laeuft" and t["groesse"]:
            zustand = f"laeuft ({t['gesendet']*100//t['groesse']} %)"
        print(f"{t['name'][:34]:<34} {t['groesse_text']:>10}  {zustand}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=f"WinDrop {VERSION}")
    sub = ap.add_subparsers(dest="befehl", required=True)

    s = sub.add_parser("serve", help="Server starten")
    s.add_argument("--port", type=int, default=PORT)
    s.add_argument("--bind", default="0.0.0.0")
    s.set_defaults(func=cmd_serve)

    d = sub.add_parser("send", help="Datei(en) senden")
    d.add_argument("dateien", nargs="+")
    d.add_argument("--port", type=int, default=PORT)
    d.add_argument("--nowait", action="store_true", help="nicht auf den Fortschritt warten")
    d.set_defaults(func=cmd_send)

    st = sub.add_parser("status", help="Warteschlange anzeigen")
    st.add_argument("--port", type=int, default=PORT)
    st.set_defaults(func=cmd_status)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
