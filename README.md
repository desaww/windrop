# WinDrop

AirDrop-Brücke von macOS zu Windows 11 – **ohne dass auf dem Windows-Rechner
irgendetwas installiert wird**.

Eine Datei auf dem Mac auswählen, Teilen → WinDrop, fertig: Am Windows-Laptop
liegt sie ein paar Sekunden später im Ordner `Downloads`. Kein Programm, kein
Konto, kein Adminrecht auf der Windows-Seite. Dort läuft nur ein Browser-Tab.

---

## Aufbau

```txt
  MacBook (Server)                         Windows 11 (nur Browser)
  ┌───────────────────────────┐            ┌────────────────────────┐
  │ Teilen-Menü (Erweiterung) │            │  Tab: http://mac.local │
  │ Ablagefenster             │            │       :8787/?t=…       │
  │ Ordner ~/WinDrop/Outbox   │            │                        │
  │            ↓              │  WebSocket │                        │
  │      Warteschlange   ─────┼───────────►│  "neue Datei: …"       │
  │            ↓              │            │            ↓           │
  │      HTTP-Server     ◄────┼────────────┤  lädt /f/<id>          │
  │                           │   Download │            ↓           │
  └───────────────────────────┘            │  Downloads\datei.pdf   │
                                           └────────────────────────┘
```

Der Mac ist der Server, Windows der Dauergast. Die Verbindung wird **vom
Windows-Gerät** aufgebaut und offen gehalten – deshalb braucht Windows keinen
offenen Port und keine Firewall-Ausnahme. Erreichbar ist der Mac über seinen
`.local`-Namen; Windows 10 und 11 lösen den ohne Zusatzsoftware auf. Die
IP-Adresse bleibt als Rückfallebene.

## Was drin ist

- **Menüleisten-App für macOS** (SwiftUI), kein Dock-Symbol
- **Teilen-Erweiterung**, also der native Weg über Finder → Teilen
- **Ablagefenster** zum Ziehen und Ablegen, schwebt über anderen Fenstern
- **Überwachter Ordner** `~/WinDrop/Outbox`: Was dort landet, geht raus
- **Eigener HTTP- und WebSocket-Server** (Network.framework), RFC 6455 von Hand
  umgesetzt, ohne Fremdbibliothek; Server-Sent Events als Rückfallebene
- **Warteschlange** mit bis zu drei Versuchen, serverseitig gezähltem
  Fortschritt und Nachlieferung, wenn der Tab zwischendurch zu war
- **Mehrere Dateien und Ordner** werden zu einem ZIP-Archiv gebündelt
- **Wiederverbindung nach Standby**: Die Seite prüft die Leitung selbst, der
  Mac startet den Server nach dem Aufwachen und bei Netzwechsel neu
- **Verlauf** der letzten 100 Übertragungen und **Einstellungen** mit Autostart,
  Mitteilungen und Zugangscode-Verwaltung

## Installation (Mac)

Voraussetzungen: macOS 13 oder neuer, Xcode, [Homebrew](https://brew.sh).

```bash
brew install xcodegen      # erzeugt die Xcode-Projektdatei aus project.yml
cd swift
xcodegen generate
open WinDrop.xcodeproj
```

In Xcode für **beide** Ziele (`WinDrop` und `WinDropTeilen`) unter *Signing &
Capabilities* das eigene Team wählen – ohne Apple-Konto reicht *Sign to Run
Locally*. Ohne Signatur lädt macOS die Teilen-Erweiterung nicht.

Danach die gebaute App nach `/Applications` verschieben und einmal starten.
Erst dann kennt das System die Erweiterung. Falls sie im Teilen-Menü fehlt:
*Systemeinstellungen → Datenschutz & Sicherheit → Erweiterungen → Teilen*.

Ausführlicher steht das in [swift/README.md](swift/README.md).

## Einrichtung (Windows, einmalig)

1. Die Adresse aus dem Menüleisten-Fenster in Microsoft Edge öffnen, etwa
   `http://macbook.local:8787/?t=<Zugangscode>`
2. Rechtsklick auf den Tab → *Registerkarte anheften*
3. Fertig. Der Tab bleibt liegen, alles Weitere passiert von allein.

## Benutzung

| Weg | Wie |
| --- | --- |
| Teilen-Menü | Datei im Finder auswählen → Teilen → WinDrop |
| Ablagefenster | Dateien oder Ordner hineinziehen |
| Dateiauswahl | Menüleiste → *Dateien wählen …* |
| Ordner | Alles in `~/WinDrop/Outbox` legen |

## Sicherheit

Der Mac öffnet einen Port im lokalen Netz. Dagegen steht:

- Jede Adresse enthält einen langen Zufalls-Zugangscode; ohne ihn antwortet der
  Server mit 403, weder Seite noch Datei
- Der Code liegt nur lokal in `~/WinDrop/token.txt` (Rechte 600) und lässt sich
  jederzeit neu erzeugen
- Vergleich des Codes läuft laufzeitkonstant, verrät also nichts über die Antwortzeit
- Der Upload-Weg der Teilen-Erweiterung wird nur von `127.0.0.1` angenommen

Die Übertragung läuft unverschlüsselt über HTTP. Im eigenen WLAN ist das
vertretbar; HTTPS bräuchte ein Zertifikat, dem Windows vertraut – und dessen
Installation ist genau das, was hier vermieden werden soll. Für ein fremdes
oder öffentliches Netz ist das Werkzeug nicht gedacht.

## Grenzen

- Beide Geräte müssen im selben WLAN sein; Netze mit Client-Isolation
  (Gastnetze) blockieren die Verbindung
- Rückrichtung Windows → Mac ist noch nicht eingebaut
- Ordner lassen sich nicht über das Teilen-Menü senden, nur über das
  Ablagefenster – eine Teilen-Erweiterung darf in ihrer Abschottung nicht packen
- Der Port 8787 steht fest im Code (an zwei Stellen), weil die Erweiterung die
  Einstellungen der App nicht lesen kann

## Python-Fassung

Unter [`python/`](python/) liegt die Vorstufe: eine einzelne Datei, nur
Standardbibliothek, ohne Xcode lauffähig.

```bash
python3 python/windrop.py serve
python3 python/windrop.py send ~/Desktop/bericht.pdf
```

Sie kann alles bis auf das native Teilen-Menü, benutzt dieselben Ordner und
denselben Zugangscode und dient als Rückfallebene.

## Entstehung

Dieses Projekt ist **mit Hilfe von künstlicher Intelligenz entstanden**.
Konzept, Architekturentscheidungen, Code und diese Dokumentation wurden
gemeinsam mit einem KI-Assistenten erarbeitet. Die Entscheidungen
darüber, was gebaut wird, sowie sämtliche Tests auf echter Hardware – MacBook
und Windows-11-Laptop – stammen von mir.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
