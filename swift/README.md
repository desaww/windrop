# WinDrop – Swift-Fassung (Meilenstein M3)

Menueleisten-App fuer macOS mit Teilen-Erweiterung (Share Extension). Gleiche
Funktion wie die Python-Fassung: Der Mac ist der Server, Windows haelt nur eine
Browser-Seite offen und bekommt die Dateien hineingeschoben.

Hinweis: Der Code entsteht in einer Linux-Umgebung ohne Swift-Werkzeuge und wird
hier nicht kompiliert. Rechne bei neuen Teilen mit Compiler-Fehlern und schicke
sie mir. Die Python-Fassung (`windrop.py`) bleibt die Rueckfallebene.

---

## 1. Bauen

Voraussetzungen: macOS 13 oder neuer, Xcode (aus dem App Store), Homebrew.

```bash
brew install xcodegen          # erzeugt die Xcode-Projektdatei aus project.yml
cd windrop-swift
xcodegen generate              # legt WinDrop.xcodeproj an
open WinDrop.xcodeproj
```

Warum XcodeGen: Eine `.xcodeproj` ist eine grosse, maschinell erzeugte Datei, die
man von Hand kaum sinnvoll schreiben kann. `project.yml` ist die lesbare
Kurzbeschreibung, aus der XcodeGen sie erzeugt.

In Xcode dann das Schema **WinDrop** waehlen und mit Cmd+R starten.

### Signieren (Code Signing)

Beide Ziele (`WinDrop` und `WinDropTeilen`) brauchen eine Signatur, weil macOS
Teilen-Erweiterungen sonst nicht laedt.

- Mit kostenlosem Apple-Konto: In Xcode je Ziel unter *Signing & Capabilities*
  → *Team* das persoenliche Team auswaehlen. *Automatically manage signing*
  bleibt an.
- Ohne Apple-Konto: je Ziel *Signing Certificate* → **Sign to Run Locally**.
  Das reicht fuer den eigenen Rechner.

Wenn Xcode ueber die Bundle-Kennung meckert (weil `de.lennard.windrop` bei
einem anderen Konto schon vergeben ist), in `project.yml` das Praefix
`bundleIdPrefix` und die beiden `PRODUCT_BUNDLE_IDENTIFIER` aendern und
`xcodegen generate` erneut laufen lassen. Die Kennung der Erweiterung muss mit
der Kennung der App beginnen (`...windrop` und `...windrop.teilen`).

---

## 2. Erweiterung sichtbar machen

Damit **WinDrop** im Teilen-Menue von Finder und anderen Programmen auftaucht:

1. Die gebaute App nach `/Applications` verschieben. macOS sucht
   Erweiterungen nur in installierten Programmen, nicht im Build-Ordner.
2. Die App einmal starten. Danach kennt das System die Erweiterung.
3. Falls sie fehlt: *Systemeinstellungen* → *Datenschutz & Sicherheit* →
   *Erweiterungen* → *Teilen* → Haken bei **WinDrop** setzen.
4. Zum Nachsehen im Terminal:
   ```bash
   pluginkit -m -p com.apple.share-services | grep -i windrop
   ```
   Ein `+` am Zeilenanfang heisst aktiv, ein `-` heisst deaktiviert.
   Nachhelfen geht mit:
   ```bash
   pluginkit -a /Applications/WinDrop.app/Contents/PlugIns/WinDropTeilen.appex
   ```

Ab- und Anmelden hilft, wenn das System die Erweiterung nach dem Verschieben
noch nicht bemerkt hat.

---

## 3. Benutzung

1. WinDrop starten. Im Menueleisten-Fenster steht die Adresse, zum Beispiel
   `http://macbook.local:8787/?t=<Zugangscode>`.
2. Diese Adresse einmal am Windows-Laptop in Microsoft Edge oeffnen und als
   Favorit ablegen. Der Tab bleibt offen liegen.
3. Auf dem Mac Dateien senden – vier Wege:
   - Teilen-Menue: Datei im Finder auswaehlen → Teilen → **WinDrop**.
   - Menueleisten-Fenster → *Dateien waehlen …* (Systemdialog).
   - Menueleisten-Fenster → *Ablagefenster oeffnen* und Dateien hineinziehen.
     Das Fenster bleibt im Vordergrund und kann liegen bleiben.
   - Dateien in den Ordner `~/WinDrop/Outbox` legen, der wird ueberwacht.
4. Der Browser am Windows-Laptop laedt die Datei von selbst herunter, sie landet
   in `Downloads`. Auf dem Mac wird nichts archiviert: Dateien aus der Outbox
   und aus dem Teilen-Menue werden nach dem Versand geloescht. Originale, die
   nur gezogen oder ausgewaehlt wurden, bleiben unberuehrt.

### Was M3 dazugebracht hat

| Neu | Wirkung |
| --- | --- |
| Mehrere Dateien in einem Rutsch | Werden mehrere Objekte auf einmal abgelegt oder ausgewaehlt, packt WinDrop sie zu einem ZIP-Archiv. Ein Archiv ist ein Download, also fragt der Browser nicht nach "mehreren Dateien". Abschaltbar in den Einstellungen. |
| Ordner senden | Ordner werden immer gepackt, das ist der einzige Weg. Im Teilen-Menue geht das nicht, dort bitte das Ablagefenster benutzen. |
| Wiederverbindung nach Standby | Die Empfangsseite prueft die Leitung alle 15 Sekunden sowie bei Netzwechsel und wenn der Tab wieder sichtbar wird. Der Mac startet den Server nach dem Aufwachen und bei einem Netzwechsel automatisch neu. TCP-Keepalive raeumt tote Verbindungen weg. |
| Fehlermeldungen | Gescheiterte Uebertragungen stehen rot im Menue und haben einen Knopf "Erneut". Optional kommt eine Systemmitteilung. |
| Verlauf | Die letzten 100 Uebertragungen stehen im Fenster "Verlauf" und in `~/WinDrop/verlauf.json`. |
| Einstellungen | Eigenes Fenster mit drei Reitern (Allgemein, Senden, Verbindung): Autostart beim Anmelden, ZIP-Buendelung, Mitteilungen, Adresse kopieren, Zugangscode neu erzeugen, Server neu starten. |

Der Autostart laeuft ueber den Systemdienst `SMAppService`. Damit das klappt,
muss die App in `/Applications` liegen. Ein neuer Zugangscode macht die alte
Adresse ungueltig; der Tab am Windows-Laptop muss dann einmal neu geoeffnet
werden.

Die Empfangsseite der Swift-Fassung ist seit M3 nicht mehr zeichengleich mit der
Python-Fassung: Sie enthaelt die bessere Wiederverbindung.

Ordner und Zugangscode liegen an derselben Stelle wie bei der Python-Fassung
(`~/WinDrop/`, Code in `~/WinDrop/token.txt`); einziger Unterschied: die
Swift-Fassung legt kein Archiv `Gesendet` an. Dadurch sind beide Fassungen
austauschbar: Die Windows-Seite muss nicht neu eingerichtet werden. Es darf aber
nur eine von beiden gleichzeitig laufen, weil sich sonst zwei Programme um den
Netzwerk-Port streiten.

---

## 4. Aufbau des Codes

```
project.yml                       Projektbeschreibung fuer XcodeGen
Sources/Kern/                     gemeinsamer Funktionskern
  HTTPServer.swift                Netzwerk-Server (Network.framework), Routen
  WebSocketRahmen.swift           WebSocket-Rahmen selbst kodiert (RFC 6455)
  Warteschlange.swift             serielle Warteschlange, bis zu 3 Versuche
  EmpfangsSeite.swift             die HTML-Seite fuer den Windows-Browser
  Hilfen.swift                    Zugangscode, Ordner, Netzwerkname, JSON
  Dateiname.swift                 sichere Dateinamen, Umlaute bleiben erhalten
  OutboxWaechter.swift            ueberwacht den Ordner ~/WinDrop/Outbox
  Paket.swift                     packt mehrere Dateien oder Ordner als ZIP
  Verlauf.swift                   Verlauf in ~/WinDrop/verlauf.json
  Einstellungen.swift             Einstellungen und Autostart
  Mitteilung.swift                Systemmitteilungen
Sources/App/                      die Menueleisten-App
  WinDropApp.swift                Einstiegspunkt (MenuBarExtra plus Fenster)
  MenuAnsicht.swift               das Fenster in der Menueleiste
  AblageFenster.swift             Ablagefenster, Dateiauswahl
  EinstellungenAnsicht.swift      Einstellungsfenster
  VerlaufAnsicht.swift            Verlaufsfenster
  AppZustand.swift                verbindet Oberflaeche und Kern
Sources/Teilen/                   die Teilen-Erweiterung
  ShareViewController.swift       nimmt Dateien an, laedt sie an die App hoch
  Info.plist                      meldet die Erweiterung beim System an
  Teilen.entitlements             Rechte: Sandbox plus Netzwerk-Zugriff
```

### Warum die Erweiterung per HTTP mit der App spricht

Eine Teilen-Erweiterung ist ein eigener, abgeschotteter Prozess (Sandbox) und
kann nicht einfach in die Ordner der App schreiben. Der ueblichen Weg dafuer
waere eine *App Group* (gemeinsamer Ordner), die aber ein bezahltes
Entwicklerkonto braucht. Deshalb schickt die Erweiterung die Datei ueber
`POST http://127.0.0.1:8787/api/upload` an die laufende App. `127.0.0.1` ist der
eigene Rechner, diese Verbindung verlaesst den Mac nie. Der Server nimmt diesen
Weg nur von der eigenen Maschine an und braucht dafuer keinen Zugangscode.

---

## 5. Stolperstellen

- **Port 8787 steht an zwei Stellen**: in `Hilfen.swift` (Server) und in
  `ShareViewController.swift` (Erweiterung). Wird er geaendert, muss er an
  beiden Stellen geaendert werden, sonst findet die Erweiterung die App nicht.
- **App muss laufen**, wenn ueber das Teilen-Menue gesendet wird. Laeuft sie
  nicht, meldet die Erweiterung einen Fehler.
- **Beim ersten Start** fragt macOS, ob WinDrop Verbindungen aus dem lokalen
  Netz annehmen darf. Das muss erlaubt werden, sonst erreicht der Windows-Laptop
  den Mac nicht.
- **Warum ein zweites Fenster fuers Ablegen?** Das Menueleisten-Fenster von
  SwiftUI (`MenuBarExtra`) ist ein nicht aktivierbares Panel. Es klappt zu,
  sobald eine andere Anwendung die Fuehrung uebernimmt – und genau das passiert,
  wenn man im Finder eine Datei anfasst. Ziehen und Ablegen ist dort deshalb
  systembedingt nicht moeglich. Das eigene Ablagefenster (`AblageFenster.swift`)
  bleibt offen und schwebt ueber anderen Fenstern.
- **Kein `.local`-Name?** Manche Netze blocken Bonjour. Dann die IP-Adresse
  verwenden, die im Menueleisten-Fenster als zweite Zeile steht.
