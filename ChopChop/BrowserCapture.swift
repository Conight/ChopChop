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
        guard lines.first == "POST /v1/import HTTP/1.1" else { return .rejected(404) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .rejected(400) }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { return .rejected(400) }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let rawLength = headers["content-length"], !rawLength.isEmpty, rawLength.allSatisfy(\.isNumber),
              let length = Int(rawLength), length > 0, length <= maximumBody else { return .rejected(413) }
        let body = data[delimiter.upperBound...]
        guard body.count >= length else { return .incomplete }
        guard body.count == length else { return .rejected(400) }
        return .request(headers, Data(body))
    }

    static func authorizedURLs(headers: [String: String], body: Data, token: String, port: UInt16) -> [String]? {
        // Token and literal Host validation prevent web pages and DNS rebinding from using the bridge.
        guard token.count == 64, headers["authorization"] == "Bearer \(token)",
              headers["host"] == "127.0.0.1:\(port)",
              headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/json" else { return nil }
        if let origin = headers["origin"], !origin.hasPrefix("chrome-extension://") { return nil }
        struct Payload: Decodable { var urls: [String] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body),
              !payload.urls.isEmpty, payload.urls.count <= 100 else { return nil }
        var unique: [String] = []
        for source in payload.urls {
            guard source.utf8.count <= 8192, let url = URLComponents(string: source),
                  ["http", "https", "magnet", "ed2k"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil else { return nil }
            if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty != false { return nil }
            if !unique.contains(source) { unique.append(source) }
        }
        return unique
    }

    static func response(_ code: Int) -> Data {
        let accepted = code == 202
        let body = accepted ? #"{"accepted":true}"# : #"{"accepted":false}"#
        return Data("HTTP/1.1 \(code) \(accepted ? "Accepted" : "Rejected")\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }
}

@MainActor
final class BrowserCaptureServer: ObservableObject {
    nonisolated static let defaultPort: UInt16 = 29101
    @Published private(set) var status = String(localized: "Browser integration is off.")
    @Published private(set) var isListening = false
    @Published private(set) var port: UInt16 = BrowserCaptureServer.defaultPort
    var onImport: (([String]) -> Void)?
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
                    guard let urls = BrowserCaptureHTTP.authorizedURLs(headers: headers, body: body, token: self.token, port: self.port) else {
                        self.reply(403, connection: connection, id: id); return
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

    private func reply(_ code: Int, connection: NWConnection, id: UUID) {
        connection.send(content: BrowserCaptureHTTP.response(code), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        })
    }
}

struct BrowserIntegrationView: View {
    @EnvironmentObject private var store: DownloadStore
    @ObservedObject var server: BrowserCaptureServer
    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
            Toggle(String(localized: "Receive downloads from Chrome and Edge"), isOn: Binding(
                get: { store.preferences.browserCaptureEnabled },
                set: { store.setBrowserCaptureEnabled($0) }))
            Text(server.status).font(.callout).foregroundStyle(.secondary)
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
                        Button(String(localized: "Copy Pairing Code")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(server.port):\(store.preferences.browserCaptureToken)", forType: .string)
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
