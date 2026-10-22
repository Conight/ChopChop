import AppKit
import Combine
import Network
import SwiftUI

nonisolated enum BrowserCaptureHTTP {
    static let maximumBody = 128 * 1024
    static let maximumHeader = 8 * 1024
    enum ParseResult { case incomplete, rejected(Int), request([String: String], Data) }

    static func parse(_ data: Data) -> ParseResult {
        guard let delimiter = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeader ? .rejected(431) : .incomplete
        }
        guard delimiter.lowerBound <= maximumHeader,
              let header = String(data: data[..<delimiter.lowerBound], encoding: .utf8) else { return .rejected(400) }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first, ["POST /v1/import HTTP/1.1", "POST /v1/receipt HTTP/1.1", "POST /v2/import HTTP/1.1", "POST /v2/receipt HTTP/1.1", "POST /v2/capabilities HTTP/1.1"].contains(first) else { return .rejected(404) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .rejected(400) }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return .rejected(400) }
            guard headers[key] == nil else { return .rejected(400) }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let rawLength = headers["content-length"], !rawLength.isEmpty, rawLength.allSatisfy(\.isNumber),
              let length = Int(rawLength), length > 0, length <= maximumBody else { return .rejected(413) }
        let body = data[delimiter.upperBound...]
        guard body.count >= length else { return .incomplete }
        guard body.count == length else { return .rejected(400) }
        headers["x-bridge-route"] = first.contains("/capabilities ") ? "capabilities" : (first.contains("/receipt ") ? "receipt" : "import")
        headers["x-bridge-version"] = first.contains("/v2/") ? "2" : "1"
        return .request(headers, Data(body))
    }

    static func isAuthorized(headers: [String: String], token: String, port: UInt16) -> Bool {
        guard token.count == 64, headers["authorization"] == "Bearer \(token)",
              headers["host"] == "127.0.0.1:\(port)",
              headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/json" else { return false }
        return headers["origin"].map { $0.hasPrefix("chrome-extension://") } ?? true
    }

    static func authorizedURLs(headers: [String: String], body: Data, token: String, port: UInt16) -> [String]? {
        guard isAuthorized(headers: headers, token: token, port: port) else { return nil }
        struct Payload: Decodable { var urls: [String] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body),
              !payload.urls.isEmpty, payload.urls.count <= 100 else { return nil }
        var unique: [String] = []
        for source in payload.urls {
            guard source.utf8.count <= 8192,
                  let decoded = try? AddDownloadDraft.normalizedResource(source),
                  !decoded.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
            if !AddDownloadDraft.isED2KFileResource(decoded) {
                guard let url = URLComponents(string: decoded),
                      ["http", "https", "sftp", "magnet", "ed2k"].contains(url.scheme?.lowercased() ?? ""),
                      url.user == nil, url.password == nil else { return nil }
                if ["http", "https", "sftp"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty != false { return nil }
            }
            if !unique.contains(source) { unique.append(source) }
        }
        return unique
    }

    static func response(_ code: Int, json: Data? = nil) -> Data {
        let accepted = code == 202 || code == 200
        let body = json.flatMap { String(data: $0, encoding: .utf8) } ?? (accepted ? #"{"accepted":true}"# : #"{"accepted":false}"#)
        return Data("HTTP/1.1 \(code) \(accepted ? "Accepted" : "Rejected")\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }
}

@MainActor
final class BrowserCaptureServer: ObservableObject {
    nonisolated static let defaultPort: UInt16 = UInt16(29101 + AppIdentity.portOffset)
    @Published private(set) var status = String(localized: "Browser integration is off.")
    @Published private(set) var isListening = false
    @Published private(set) var port: UInt16 = BrowserCaptureServer.defaultPort
    var onImport: (([String]) -> Void)?
    var onSubmission: ((BrowserSubmission) -> Void)?
    var onReadTasks: (([String]) -> [[String: Any]])?
    var onRevealTasks: (([String]) -> Void)?
    var receiptStore = BrowserReceiptStore()
    private var token = ""
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var generation = UUID()
    private var lastImport = Date.distantPast
    private let queue = DispatchQueue(label: ReleaseConfiguration.current.bundleIdentifier + ".browser-capture")

    func start(token: String, port: UInt16 = BrowserCaptureServer.defaultPort) {
        stop()
        guard token.count == 64, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        self.token = token
        self.port = port
        let request = UUID()
        generation = request
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            status = String(localized: "Connecting to the browser extension…")
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.generation == request else { return }
                    switch state {
                    case .ready:
                        self.port = listener?.port?.rawValue ?? port
                        self.isListening = true
                        self.status = String(localized: "Ready to receive links from your paired browser extension.")
                    case .failed:
                        self.stop()
                        self.status = String(localized: "Browser integration could not start. Another app may be using its connection port.")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == request, self.connections.count < 8 else { connection.cancel(); return }
                    let id = UUID()
                    self.connections[id] = connection
                    connection.start(queue: self.queue)
                    self.receive(connection, id: id, buffer: Data())
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        self?.connections.removeValue(forKey: id)?.cancel()
                    }
                }
            }
            listener.start(queue: queue)
        } catch { status = String(localized: "Browser integration could not start.") }
    }

    func stop() {
        generation = UUID()
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections = [:]
        token = ""; isListening = false; status = String(localized: "Browser integration is off.")
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch BrowserCaptureHTTP.parse(buffer) {
                case .incomplete:
                    guard !complete, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
                    self.receive(connection, id: id, buffer: buffer)
                case .rejected(let code): self.reply(code, connection: connection, id: id)
                case .request(let headers, let body):
                    if headers["x-bridge-route"] == "capabilities" {
                        guard BrowserCaptureHTTP.isAuthorized(headers: headers, token: self.token, port: self.port) else {
                            self.reply(403, connection: connection, id: id); return
                        }
                        let capabilities: [String: Any] = ["protocolVersion": 2, "receipts": true, "requestContext": true]
                        self.reply(200, connection: connection, id: id, json: try? JSONSerialization.data(withJSONObject: capabilities))
                        return
                    }
                    if headers["x-bridge-route"] == "receipt" {
                        guard let payload = try? JSONDecoder().decode(ReceiptQuery.self, from: body),
                              BrowserCaptureHTTP.isAuthorized(headers: headers, token: self.token, port: self.port) else {
                            self.reply(403, connection: connection, id: id); return
                        }
                        self.receiptStore.pruneExpired()
                        guard self.receiptStore.isAvailable else { self.reply(503, connection: connection, id: id); return }
                        guard let receipt = self.receiptStore.receipts[payload.requestID] else {
                            self.reply(404, connection: connection, id: id); return
                        }
                        if payload.reveal == true { self.onRevealTasks?(receipt.taskIDs) }
                        self.replyReceipt(receipt, code: 200, connection: connection, id: id)
                        return
                    }
                    guard let urls = BrowserCaptureHTTP.authorizedURLs(headers: headers, body: body, token: self.token, port: self.port) else {
                        self.reply(403, connection: connection, id: id); return
                    }
                    if var submission = try? JSONDecoder().decode(BrowserSubmission.self, from: body) {
                        guard submission.context?.isValid != false,
                              submission.context == nil || (urls.count == 1 && ["http", "https"].contains(URL(string: urls[0])?.scheme ?? "") && submission.context?.matches(urls[0]) == true) else {
                            self.reply(400, connection: connection, id: id); return
                        }
                        submission.urls = urls
                        do {
                            if self.receiptStore.receipts[submission.requestID] != nil {
                                let (receipt, _) = try self.receiptStore.admit(submission, body: body)
                                self.replyReceipt(receipt, code: 202, connection: connection, id: id)
                                return
                            }
                            guard Date().timeIntervalSince(self.lastImport) >= 0.5 else {
                                self.reply(429, connection: connection, id: id); return
                            }
                            let (receipt, fresh) = try self.receiptStore.admit(submission, body: body)
                            self.lastImport = Date()
                            if fresh { self.onSubmission?(submission) }
                            self.replyReceipt(receipt, code: 202, connection: connection, id: id)
                        } catch { self.reply(409, connection: connection, id: id) }
                        return
                    }
                    // A malformed v2 identity cannot silently degrade to legacy admission.
                    if headers["x-bridge-version"] == "2" || (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["requestID"] != nil {
                        self.reply(400, connection: connection, id: id); return
                    }
                    guard Date().timeIntervalSince(self.lastImport) >= 0.5 else {
                        self.reply(429, connection: connection, id: id); return
                    }
                    self.lastImport = Date()
                    self.onImport?(urls)
                    self.reply(202, connection: connection, id: id)
                }
            }
        }
    }

    private struct ReceiptQuery: Decodable { var requestID: UUID; var reveal: Bool? }

    private func replyReceipt(_ receipt: BrowserReceipt, code: Int, connection: NWConnection, id: UUID) {
        let value: [String: Any] = ["requestID": receipt.requestID.uuidString, "state": receipt.state.rawValue,
            "tasks": onReadTasks?(receipt.taskIDs) ?? []]
        reply(code, connection: connection, id: id, json: try? JSONSerialization.data(withJSONObject: value))
    }

    private func reply(_ code: Int, connection: NWConnection, id: UUID, json: Data? = nil) {
        connection.send(content: BrowserCaptureHTTP.response(code, json: json), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        })
    }
}

struct BrowserIntegrationView: View {
    @Environment(DownloadStore.self) private var store
    @ObservedObject var server: BrowserCaptureServer
    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
            Toggle(String(localized: "Receive downloads from Chrome and Edge"), isOn: Binding(
                get: { store.preferences.browserCaptureEnabled },
                set: { store.setBrowserCaptureEnabled($0) }))
            Text(server.status).font(.callout).foregroundStyle(.secondary)
            if server.receiptStore.receipts.values.filter({ Date().timeIntervalSince($0.createdAt) < 7 * 86400 }).count >= 512 {
                Text(String(localized: "Browser receipt history is full. Review Downloads before resetting pairing to accept more requests."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !server.receiptStore.isAvailable {
                Text(String(localized: "Browser submission history is unavailable. Review Downloads before resetting pairing."))
                    .font(.callout).foregroundStyle(.red)
            }
            step(String(localized: "1. Enable Receiving")) {
                Text(String(localized: "Keep ChopChop open and turn on receiving above. When ready, this Mac accepts links only from paired extensions."))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            step(String(localized: "2. Export the Extension")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Save the extension in a folder you will keep. Exporting does not install it in your browser."))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Export Extension…"), action: exportExtension)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            step(String(localized: "3. Load in Chrome or Edge")) {
                Text(String(localized: "Open chrome://extensions or edge://extensions, enable Developer mode, choose Load unpacked, and select the exported folder."))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            step(String(localized: "4. Pair the Browser")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Copy the pairing code, open the extension’s settings, and save it there. Resetting pairing disconnects all previously paired browsers."))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        FeedbackButton(title: String(localized: "Copy Pairing Code"), systemImage: "doc.on.doc", successTitle: String(localized: "Copied")) {
                            NSPasteboard.general.clearContents()
                            return NSPasteboard.general.setString("\(server.port):\(store.preferences.browserCaptureToken)", forType: .string)
                        }.disabled(!server.isListening)
                        Button(String(localized: "Reset Pairing")) { store.resetBrowserPairing() }.disabled(!server.isListening)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(String(localized: "Right-click a link to send it to ChopChop, or open the extension to find media in the current page. Every download opens for review. Cookies and authentication headers are not collected."))
                .fixedSize(horizontal: false, vertical: true)
                .font(.callout).foregroundStyle(.secondary)
            if let exportMessage { Text(exportMessage).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func step<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.controlSpacing) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exportExtension() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Export Browser Extension")
        panel.prompt = String(localized: "Export")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let directory = panel.url,
                  let source = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) else { return }
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
            do {
                let destination = directory.appendingPathComponent("ChopChop Browser Extension")
                try FileManager.default.copyItem(at: source, to: destination)
                exportMessage = String(localized: "Extension exported. Select this folder when loading it in your browser.")
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { exportMessage = String(localized: "Could not export the extension. Choose an empty destination folder and try again.") }
        }
    }
}
