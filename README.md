<div align="center">

# WinDrop

**AirDrop for the Mac-to-Windows gap.**
Send a file from your Mac to a Windows 11 laptop in one click — with nothing
installed on the Windows side.

</div>

---

Pick a file on the Mac, choose **Share → WinDrop**, and a few seconds later it
is sitting in `Downloads` on the Windows machine. No app, no account, no admin
rights over there. All Windows needs is a browser tab left open.

## What you get

- **Native share menu.** WinDrop appears in Finder's share menu, like AirDrop does.
- **Drop window.** A small floating window that takes files and folders by drag and drop.
- **Watched folder.** Anything you move into `~/WinDrop/Outbox` is sent automatically.
- **Nothing to install on Windows.** One pinned browser tab, set up once.
- **Several files at once.** They are bundled into a single ZIP, so the browser never asks twice.
- **Folders too.** Packed automatically.
- **Survives sleep.** The tab reconnects by itself, the Mac restarts its server after waking or switching networks.
- **Progress, history and retries.** Live progress on both sides, the last 100 transfers on record, one click to try again.
- **Quiet by default.** Menu bar only, no dock icon, optional notifications.

## Requirements

- macOS 13 or newer, Xcode, [Homebrew](https://brew.sh)
- A Windows PC with any modern browser (tested with Microsoft Edge)
- Both machines on the same Wi-Fi

## Install

```bash
git clone https://github.com/desaww/windrop.git
cd windrop
brew install xcodegen
xcodegen generate
open WinDrop.xcodeproj
```

In Xcode, pick your team under *Signing & Capabilities* for **both** targets
(`WinDrop` and `WinDropShare`) — without a signature macOS refuses to load the
share extension. No Apple account? *Sign to Run Locally* is enough.

Build, then move the app to `/Applications` and launch it once. macOS only
looks for extensions inside installed apps. If WinDrop is missing from the
share menu, enable it under *System Settings → Privacy & Security → Extensions
→ Sharing*.

## Set up Windows (once)

1. Open the address shown in the menu bar window, for example
   `http://macbook.local:8787/?t=<token>`
2. Right-click the tab → **Pin tab**
3. That's it. Leave it open and forget about it.

## Sending

| Way | How |
| --- | --- |
| Share menu | Select a file in Finder → Share → WinDrop |
| Drop window | Drag files or folders into it |
| File picker | Menu bar → *Choose files …* |
| Watched folder | Move anything into `~/WinDrop/Outbox` |

## Security

Every address carries a long random token. Without it the server answers 403
and hands out neither the page nor a file. The token lives only on your Mac in
`~/WinDrop/token.txt` and can be regenerated at any time. Uploads from the
share extension are accepted from `127.0.0.1` only.

Transfers run over plain HTTP. Inside your own Wi-Fi that is a reasonable
trade — HTTPS would need a certificate Windows trusts, and installing one is
exactly what this project avoids. Don't use WinDrop on a public network.

## Make it yours

WinDrop is meant to be forked, modified and extended. Everything is plain
Swift with no third-party dependencies, and the whole server is about a
thousand readable lines. Ideas that are wide open:

- Windows → Mac, the receiving page already has a place for an upload field
- iPhone and iPad senders, the server side stays exactly the same
- Text and clipboard items as their own message type
- HTTPS with a locally trusted certificate for people who can install one

Pull requests are welcome, and so are forks that go their own way. See
[CONTRIBUTING.md](CONTRIBUTING.md) for a short tour of the code.

## Built with AI

This project was built with the help of AI. The concept, the architecture
decisions, the code and this documentation were worked out together with an AI
assistant. What to build, and every test on real hardware — a MacBook and a
Windows 11 laptop — came from me.

## License

MIT. Do what you like with it.
