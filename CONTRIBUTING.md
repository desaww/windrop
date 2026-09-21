# Contributing

Forks, pull requests and issues are all welcome. There is no formal process —
open an issue if you want to discuss an idea first, or just send a pull
request.

## Getting set up

```bash
brew install xcodegen
xcodegen generate
open WinDrop.xcodeproj
```

`WinDrop.xcodeproj` is generated from `project.yml` and is not checked in. Run
`xcodegen generate` again whenever you add or rename a file.

## Where things live

```
Sources/Core/              shared engine, no UI
  HTTPServer.swift         the server: routing, file streaming, WebSocket, uploads
  TransferQueue.swift      queue, retries, receivers, progress
  ReceiverPage.swift       the HTML page served to the Windows browser
  WebSocketFrame.swift     RFC 6455 framing, written by hand
  Zipper.swift             bundles several files or a folder into one archive
  OutboxWatcher.swift      watches ~/WinDrop/Outbox
  Storage / AccessToken    folders, token handling (Helpers.swift)
  History / AppSettings    persisted state
Sources/App/               the menu bar app
  AppState.swift           glue between the interface and the engine
  MenuView.swift           the menu bar window
  DropWindow.swift         drop window, file picker
  SettingsView.swift       settings
  HistoryView.swift        history
Sources/ShareExtension/    the share menu extension
```

## Good to know

- **The app is the server.** Windows never runs anything, so every feature
  lands in `Sources/Core` and, if it needs a face, in `Sources/App`.
- **The share extension is sandboxed** and shares no code with the app. It
  hands files over with an HTTP upload to `127.0.0.1:8787`, which is also why
  the port is hardcoded in two places.
- **Drag and drop cannot live in the menu bar window.** `MenuBarExtra` closes
  as soon as the Finder takes over the drag; that is what the drop window is for.
- **The receiving page has no build step.** It is one HTML string in
  `ReceiverPage.swift` and must keep working on a machine that has nothing
  installed.
- **No third-party dependencies.** Please keep it that way if you can.

## Style

Follow what is already there: descriptive names, comments that explain *why*
rather than *what*, and no cleverness that a reader has to unpick.
