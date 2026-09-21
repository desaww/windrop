import Foundation
import Network
import CryptoKit

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]

    var token: String? { query["t"] }
}

/// Small HTTP server built on Network.framework.
/// It does exactly what WinDrop needs: serve the page, stream files, speak
/// WebSocket and accept uploads from the share extension.
final class HTTPServer {

    enum StartError: Error, LocalizedError {
        case portInUse(UInt16)

        var errorDescription: String? {
            switch self {
            case .portInUse(let port):
                return "Port \(port) is already in use. Is WinDrop already running?"
            }
        }
    }

    private var listener: NWListener?
    private let workQueue = DispatchQueue(label: "de.lennard.windrop.server")
    private let queue: TransferQueue
    private let port: UInt16

    /// Keeps open sessions alive. Without this list the connection objects
    /// would be released right away, because NWConnection callbacks only
    /// hold them weakly.
    private var sessions: [ObjectIdentifier: Session] = [:]

    var onLog: ((String) -> Void)?
    var onStatus: ((Bool) -> Void)?

    init(queue: TransferQueue, port: UInt16 = WinDropInfo.port) {
        self.queue = queue
        self.port = port
    }

    func start() throws {
        // Keepalive: after sleep or a network change dead connections would
        // otherwise linger for minutes and the app would believe the Windows
        // laptop is still there.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveCount = 3
        tcp.keepaliveInterval = 5

        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw StartError.portInUse(port)
        }

        let l: NWListener
        do {
            l = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw StartError.portInUse(port)
        }

        l.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let session = Session(connection: connection, server: self,
                                  queue: self.queue, workQueue: self.workQueue)
            self.remember(session)
            session.start()
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStatus?(true)
            case .failed, .cancelled:
                self?.onStatus?(false)
            default:
                break
            }
        }
        l.start(queue: workQueue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        workQueue.async { self.sessions.removeAll() }
        onStatus?(false)
    }

    fileprivate func remember(_ session: Session) {
        workQueue.async { self.sessions[ObjectIdentifier(session)] = session }
    }

    fileprivate func forget(_ session: Session) {
        workQueue.async { self.sessions.removeValue(forKey: ObjectIdentifier(session)) }
    }

    fileprivate func log(_ text: String) {
        let line = Format.time() + " " + text
        DispatchQueue.main.async { self.onLog?(line) }
    }
}

// MARK: - One connection

final class Session {

    private enum Mode {
        case http
        case body(target: FileHandle, url: URL, name: String, remaining: Int)
        case websocket
        case stream               // event stream, nothing comes back here
    }

    private let connection: NWConnection
    private weak var server: HTTPServer?
    private let queue: TransferQueue
    private let workQueue: DispatchQueue

    private var buffer = Data()
    private var mode: Mode = .http
    private var receiver: Receiver?
    private var closed = false

    // State of the running file transfer
    private var reader: FileHandle?
    private var currentTransfer: Transfer?
    private var sent = 0
    private var lastReport = Date.distantPast

    init(connection: NWConnection, server: HTTPServer,
         queue: TransferQueue, workQueue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
        self.workQueue = workQueue
    }

    private var peer: String {
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: return "?"
            }
        }
        return "?"
    }

    private var isLocal: Bool {
        let address = peer
        return address.hasPrefix("127.") || address.hasPrefix("::1") || address == "localhost"
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.tearDown()
            default:
                break
            }
        }
        connection.start(queue: workQueue)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.handle()
            }
            if complete || error != nil {
                self.tearDown()
                return
            }
            if !self.closed { self.read() }
        }
    }

    private func tearDown() {
        guard !closed else { return }
        closed = true
        try? reader?.close()
        reader = nil
        if let transfer = currentTransfer, transfer.status == .sending {
            queue.abort(transfer)
            currentTransfer = nil
        }
        if let receiver {
            queue.remove(receiver)
            self.receiver = nil
        }
        connection.cancel()
        server?.forget(self)
    }

    // MARK: Parsing

    private func handle() {
        switch mode {
        case .http:      handleHTTP()
        case .body:      handleBody()
        case .websocket: handleWebSocket()
        case .stream:    buffer.removeAll()
        }
    }

    private func handleHTTP() {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerData = buffer.subdata(in: buffer.startIndex..<end.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)

        guard let header = String(data: headerData, encoding: .utf8) else {
            respond(400, text: "Could not read headers")
            return
        }
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines[0].components(separatedBy: " ")
        guard parts.count >= 2 else {
            respond(400, text: "Malformed request")
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let split = parts[1].components(separatedBy: "?")
        var query: [String: String] = [:]
        if split.count > 1 {
            for pair in split[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }

        route(HTTPRequest(method: parts[0], path: split[0],
                          query: query, headers: headers))
    }

    // MARK: Routes

    private func route(_ request: HTTPRequest) {
        if request.method == "GET", request.path.hasPrefix("/f/") {
            guard AccessToken.matches(request.token) else { respond(403, text: "forbidden"); return }
            sendFile(id: String(request.path.dropFirst(3)))
            return
        }

        switch (request.method, request.path) {

        case ("GET", "/favicon.ico"):
            respond(204, text: "")

        case ("GET", "/"), ("GET", "/r"), ("GET", "/index.html"):
            guard AccessToken.matches(request.token) else {
                respond(403, text: "WinDrop: missing or invalid access token.")
                return
            }
            let page = ReceiverPage.html
                .replacingOccurrences(of: "__TOKEN__", with: AccessToken.current)
            respond(200, text: page, type: "text/html; charset=utf-8")

        case ("GET", "/ws"):
            guard AccessToken.matches(request.token) else { respond(403, text: "forbidden"); return }
            webSocketHandshake(request)

        case ("GET", "/events"):
            guard AccessToken.matches(request.token) else { respond(403, text: "forbidden"); return }
            startEventStream()

        case ("GET", "/api/status"):
            guard isLocal, AccessToken.matches(request.token) else {
                respond(403, text: "forbidden"); return
            }
            let payload: [String: Any] = [
                "receivers": queue.receiverNames(),
                "transfers": queue.snapshots().map {
                    ["id": $0.id, "name": $0.name, "size": $0.size,
                     "size_text": Format.size($0.size),
                     "sent": $0.sent, "status": $0.status, "reason": $0.reason]
                },
            ]
            respond(200, text: JSONHelper.text(payload) ?? "{}",
                    type: "application/json; charset=utf-8")

        case ("POST", "/api/upload"):
            // This machine only. The share extension uploads its bytes here.
            guard isLocal else { respond(403, text: "forbidden"); return }
            beginUpload(request)

        default:
            respond(404, text: "not found")
        }
    }

    // MARK: Responses

    private func respond(_ status: Int, text: String,
                         type: String = "text/plain; charset=utf-8") {
        let body = Data(text.utf8)
        var header = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n\r\n"
        send(Data(header.utf8) + body)
    }

    private func send(_ data: Data, then: (() -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.tearDown()
                return
            }
            then?()
        })
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 410: return "Gone"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }

    // MARK: Serving a file

    private func sendFile(id: String) {
        guard let transfer = queue.transfer(id: id) else {
            respond(404, text: "Unknown file."); return
        }
        if transfer.status == .done {
            respond(410, text: "Already delivered."); return
        }
        guard let handle = try? FileHandle(forReadingFrom: transfer.path) else {
            respond(404, text: "File is gone."); return
        }

        reader = handle
        currentTransfer = transfer
        sent = 0
        lastReport = .distantPast
        queue.markSending(transfer)

        let ascii = FileNames.asciiFallback(transfer.name)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let encoded = transfer.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ascii

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/octet-stream\r\n"
        header += "Content-Length: \(transfer.size)\r\n"
        header += "Content-Disposition: attachment; filename=\"\(ascii)\"; "
        header += "filename*=UTF-8''\(encoded)\r\n"
        header += "Cache-Control: no-store\r\n\r\n"

        send(Data(header.utf8)) { [weak self] in self?.nextChunk() }
    }

    /// Sends the file piece by piece. The NWConnection callback only fires
    /// once a chunk is really out, so the pace adapts to the line by itself.
    private func nextChunk() {
        guard !closed, let handle = reader, let transfer = currentTransfer else { return }

        let chunk = (try? handle.read(upToCount: 128 * 1024)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            reader = nil
            currentTransfer = nil
            queue.progress(transfer, sent: transfer.size)
            queue.complete(transfer)
            return
        }

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                self.reader = nil
                self.currentTransfer = nil
                self.queue.abort(transfer)
                self.tearDown()
                return
            }
            self.sent += chunk.count
            if Date().timeIntervalSince(self.lastReport) >= 0.15 {
                self.lastReport = Date()
                self.queue.progress(transfer, sent: self.sent)
            }
            self.nextChunk()
        })
    }

    // MARK: Upload from the share extension

    private func beginUpload(_ request: HTTPRequest) {
        guard let lengthText = request.headers["content-length"],
              let length = Int(lengthText), length > 0 else {
            respond(400, text: "Content-Length missing or zero"); return
        }
        let name = FileNames.sanitize(request.query["name"] ?? "file")

        Storage.createFolders()
        let folder = Storage.staging.appendingPathComponent(RandomID.make(6))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: target.path, contents: nil)

        guard let writer = try? FileHandle(forWritingTo: target) else {
            respond(500, text: "Staging folder is not writable"); return
        }
        // The body goes straight to disk instead of into memory, otherwise a
        // 2 GB file would be a problem.
        mode = .body(target: writer, url: target, name: name, remaining: length)
        handleBody()
    }

    private func handleBody() {
        guard case .body(let target, let url, let name, let remaining) = mode else { return }

        var left = remaining
        if !buffer.isEmpty, left > 0 {
            let amount = min(left, buffer.count)
            try? target.write(contentsOf: buffer.prefix(amount))
            buffer.removeFirst(amount)
            left -= amount
        }

        if left > 0 {
            mode = .body(target: target, url: url, name: name, remaining: left)
            return
        }

        try? target.close()
        mode = .http
        if let transfer = queue.enqueue(path: url, cleanUpAfterSend: true) {
            respond(200, text: JSONHelper.text(["ok": true, "id": transfer.id, "name": name]) ?? "{}",
                    type: "application/json; charset=utf-8")
        } else {
            respond(500, text: "Could not queue the file")
        }
    }

    // MARK: WebSocket

    private func webSocketHandshake(_ request: HTTPRequest) {
        guard let key = request.headers["sec-websocket-key"] else {
            respond(400, text: "not a WebSocket handshake"); return
        }
        let raw = Data((key + WebSocketFrame.handshakeGUID).utf8)
        let accept = Data(Insecure.SHA1.hash(data: raw)).base64EncodedString()

        var header = "HTTP/1.1 101 Switching Protocols\r\n"
        header += "Upgrade: websocket\r\n"
        header += "Connection: Upgrade\r\n"
        header += "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

        mode = .websocket
        send(Data(header.utf8)) { [weak self] in
            guard let self else { return }
            let receiver = Receiver(address: self.peer, kind: "ws") { [weak self] text in
                self?.connection.send(content: WebSocketFrame.encode(text: text),
                                      completion: .contentProcessed { _ in })
            }
            self.receiver = receiver
            self.queue.add(receiver)
            self.schedulePing()
        }
    }

    private func schedulePing() {
        workQueue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.closed else { return }
            guard case .websocket = self.mode else { return }
            self.connection.send(content: WebSocketFrame.encode(Data(), opcode: 0x9),
                                 completion: .contentProcessed { _ in })
            self.schedulePing()
        }
    }

    private func handleWebSocket() {
        while let frame = WebSocketFrame.decode(buffer) {
            buffer.removeFirst(frame.consumed)
            switch frame.opcode {
            case 0x8:
                tearDown()
                return
            case 0x9:
                connection.send(content: WebSocketFrame.encode(frame.payload, opcode: 0xA),
                                completion: .contentProcessed { _ in })
            default:
                break            // no need for text messages from the browser yet
            }
        }
    }

    // MARK: Event stream as a fallback

    private func startEventStream() {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/event-stream; charset=utf-8\r\n"
        header += "Cache-Control: no-cache, no-transform\r\n"
        header += "Connection: keep-alive\r\n"
        header += "X-Accel-Buffering: no\r\n\r\n"

        mode = .stream
        send(Data(header.utf8)) { [weak self] in
            guard let self else { return }
            let receiver = Receiver(address: self.peer, kind: "sse") { [weak self] text in
                let line = "data: " + text + "\n\n"
                self?.connection.send(content: Data(line.utf8),
                                      completion: .contentProcessed { _ in })
            }
            self.receiver = receiver
            self.queue.add(receiver)
        }
    }
}
