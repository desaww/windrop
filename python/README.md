# WinDrop M1

Dateien vom Mac an einen Windows-Rechner senden, ohne dass auf dem
Windows-Rechner irgendetwas installiert wird.

Eine einzige Datei, nur Python-Standardbibliothek. Kein pip, kein Homebrew.

Neu in M1: WebSocket statt Server-Sent Events, Warteschlange mit Wiederholung,
Fortschritt in Echtzeit auf beiden Seiten, Statusabfrage.

## Auf dem Mac starten

```bash
python3 windrop.py serve
```

Beim Start werden zwei Adressen angezeigt, nach diesem Muster:

```
http://DEIN-MACBOOK.local:8787/?t=ZUGANGSCODE
http://192.168.x.y:8787/?t=ZUGANGSCODE
```

Der Zugangscode wird beim ersten Start einmal erzeugt und in
`~/WinDrop/token.txt` abgelegt, damit die Adresse dauerhaft gleich bleibt.

Beim ersten Start fragt macOS, ob Python eingehende Verbindungen annehmen darf.
Das muss erlaubt werden, sonst kommt der Windows-Rechner nicht durch.

## Am Windows-Rechner einrichten (einmalig)

1. Die erste Adresse in Edge öffnen. Klappt das nicht, die zweite nehmen.
2. Rechtsklick auf den Tab, dann "Registerkarte anheften".
3. Optional, damit der Tab nach jedem Neustart von allein da ist:
   Edge, Einstellungen, "Start, Startseite und neue Registerkarten",
   "Diese Seiten öffnen", Adresse eintragen.

Der Tab zeigt einen grünen Punkt, sobald er verbunden ist.

## Senden

```bash
python3 windrop.py send ~/Desktop/bericht.pdf
python3 windrop.py send datei1.png datei2.png
python3 windrop.py send grosse-datei.zip --nowait   # nicht auf den Abschluss warten
python3 windrop.py status                           # Warteschlange ansehen
```

Der `send`-Befehl bleibt offen und zeigt den Fortschritt:

```
Eingereiht: demo.bin (900.0 MB)

demo.bin                       [#########...............]  41.1 %  uebertraegt
Angekommen: demo.bin
```

Strg + C koppelt nur die Anzeige ab, die Uebertragung laeuft im Server weiter.

Oder ganz ohne Terminal: Datei nach `~/WinDrop/Outbox` ziehen. Der Ordner wird
überwacht; alles, was dort landet, geht raus und wandert danach nach
`~/WinDrop/Gesendet`.

## Was WinDrop kann

- Automatischer Download im Windows-Downloads-Ordner, ohne Klick
- Fortschrittsbalken im Browser-Tab und im Terminal
- Warteschlange: eine Datei nach der anderen, in der Reihenfolge des Absendens
- Wiederholung: Bricht eine Uebertragung ab, geht die Datei zurueck in die
  Schlange und wird bis zu dreimal erneut angeboten
- Nachlieferung: Was gesendet wurde, während der Tab zu war, kommt beim
  nächsten Öffnen nach
- Dateinamen mit Umlauten
- Zugangscode in der Adresse, ohne den der Server nichts herausgibt
- Wiederherstellung nach einem Serverneustart: unfertige Übertragungen
  landen wieder in der Outbox
- Rueckfallebene: Klappt der WebSocket nach drei Versuchen nicht, schaltet die
  Seite automatisch auf Server-Sent Events um

## Was noch fehlt (kommt in M2 und M3)

- Teilen-Menü auf dem Mac statt Terminal oder Ordner
- Auswahl zwischen mehreren Zielgeräten
- Rückrichtung Windows nach Mac
- Verschlüsselung (aktuell unverschlüsseltes HTTP im lokalen Netz)

## Testprotokoll für den echten Windows-Laptop

Diese vier Punkte entscheiden, ob die Architektur trägt:

| # | Test | Erwartung |
|---|------|-----------|
| 1 | Erste Adresse mit `.local` in Edge öffnen | Seite lädt, grüner Punkt |
| 2 | Eine Datei senden | Landet ohne Rückfrage in `Downloads` |
| 3 | Zwei weitere Dateien direkt nacheinander senden | Höchstens einmal die Frage "mehrere Dateien zulassen", danach nie wieder |
| 4 | Laptop in den Ruhezustand, aufwecken, Datei senden | Tab verbindet sich von allein neu, Datei kommt an |

Scheitert Punkt 1, ist im Netz kein mDNS erlaubt: dann mit der IP-Adresse
arbeiten und für M2 eine feste Adresse vorsehen.

## Wenn etwas klemmt

"Kein laufender WinDrop-Server" - Der `serve`-Befehl läuft nicht oder in einem
anderen Terminalfenster. Erst `serve`, dann in einem zweiten Fenster `send`.

Seite lädt nicht, Server läuft aber - macOS-Firewall blockt Python, oder das
WLAN trennt Geräte voneinander (Client-Isolation, häufig in Gastnetzen).

Download bleibt aus, Punkt ist grün - Edge hat automatische Downloads mehrerer
Dateien blockiert. Schloss-Symbol in der Adressleiste, Berechtigungen,
"Automatische Downloads" auf "Zulassen".