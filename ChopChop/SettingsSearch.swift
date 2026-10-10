import AppKit
import Combine
import SwiftUI

struct SettingSearchEntry: Identifiable, Equatable {
    let id: String
    let pane: SettingsPane
    let title: String
    var localizedTitle: String { L10n.key(title) }
}

enum SettingsSearchIndex {
    static let entries: [SettingSearchEntry] = [
        .init(id: "general.notifications", pane: .general, title: "Download Completion Notifications"),
        .init(id: "integrations.browser", pane: .integrations, title: "Browser Integration"),
        .init(id: "engine.version", pane: .engine, title: "Installed version"),
        .init(id: "engine.update", pane: .engine, title: "Engine Update"),
        .init(id: "engine.rpc-token", pane: .engine, title: "RPC token"),
        .init(id: "engine.rpc-port", pane: .engine, title: "RPC port"),
        .init(id: "bitTorrent.tracker-sources", pane: .bitTorrent, title: "Tracker Sources"),
        .init(id: "bitTorrent.tracker-list", pane: .bitTorrent, title: "Tracker List"),
        .init(id: "ed2k.servers", pane: .ed2k, title: "ED2K Servers"),
        .init(id: "general.show-in-menu-bar", pane: .general, title: "Show in menu bar"),
        .init(id: "general.keep-running-after-window-closes", pane: .general, title: "Keep running after window closes"),
        .init(id: "general.prevent-sleep-while-downloads-are-active", pane: .general, title: "Prevent sleep while downloads are active"),
        .init(id: "general.chopchop-updates", pane: .general, title: "ChopChop Updates"),
        .init(id: "downloads.default-save-location", pane: .downloads, title: "Default save location"),
        .init(id: "downloads.auto-organize-files", pane: .downloads, title: "Auto organize files"),
        .init(id: "downloads.confirm-before-removing-downloads", pane: .downloads, title: "Confirm before removing downloads"),
        .init(id: "downloads.move-files-to-trash-when-confirmation-is-skipped", pane: .downloads, title: "Move files to Trash when confirmation is skipped"),
        .init(id: "downloads.bandwidth-schedule", pane: .downloads, title: "Bandwidth Schedule"),
        .init(id: "network.max-active-downloads", pane: .network, title: "Max active downloads"),
        .init(id: "network.max-connections-per-server", pane: .network, title: "Max connections per server"),
        .init(id: "network.split-count", pane: .network, title: "Split count"),
        .init(id: "network.global-download-limit", pane: .network, title: "Global download limit"),
        .init(id: "network.global-upload-limit", pane: .network, title: "Global upload limit"),
        .init(id: "network.user-agent", pane: .network, title: "User-Agent"),
        .init(id: "network.proxy-url", pane: .network, title: "Proxy URL"),
        .init(id: "network.proxy-bypass-list", pane: .network, title: "Proxy bypass list"),
        .init(id: "network.retry-count", pane: .network, title: "Retry count"),
        .init(id: "network.retry-wait", pane: .network, title: "Retry wait"),
        .init(id: "network.connect-timeout", pane: .network, title: "Connect timeout"),
        .init(id: "network.transfer-timeout", pane: .network, title: "Transfer timeout"),
        .init(id: "network.file-allocation", pane: .network, title: "File allocation"),
        .init(id: "network.async-dns", pane: .network, title: "Async DNS"),
        .init(id: "bitTorrent.force-bittorrent-encryption", pane: .bitTorrent, title: "Force BitTorrent encryption"),
        .init(id: "bitTorrent.max-peers", pane: .bitTorrent, title: "Max peers"),
        .init(id: "bitTorrent.client-identity", pane: .bitTorrent, title: "Client Identity"),
        .init(id: "bitTorrent.dht", pane: .bitTorrent, title: "DHT"),
        .init(id: "bitTorrent.peer-exchange", pane: .bitTorrent, title: "Peer exchange"),
        .init(id: "bitTorrent.local-peer-discovery", pane: .bitTorrent, title: "Local peer discovery"),
        .init(id: "bitTorrent.seeding", pane: .bitTorrent, title: "Seeding"),
        .init(id: "bitTorrent.stop-at-ratio", pane: .bitTorrent, title: "Stop at ratio"),
        .init(id: "bitTorrent.stop-after", pane: .bitTorrent, title: "Stop after"),
        .init(id: "bitTorrent.bt-listen-port", pane: .bitTorrent, title: "BT listen port"),
        .init(id: "bitTorrent.dht-listen-port", pane: .bitTorrent, title: "DHT listen port"),
        .init(id: "bitTorrent.syncing", pane: .bitTorrent, title: "Sync Trackers"),
        .init(id: "bitTorrent.sync-tracker-sources-automatically", pane: .bitTorrent, title: "Sync tracker sources automatically"),
        .init(id: "bitTorrent.sync-frequency", pane: .bitTorrent, title: "Sync frequency:"),
        .init(id: "ed2k.ed2k-listen-port", pane: .ed2k, title: "ED2K listen port"),
        .init(id: "ed2k.ed2k-udp-listen-port", pane: .ed2k, title: "ED2K UDP listen port"),
        .init(id: "ed2k.upload-slots", pane: .ed2k, title: "Upload slots"),
        .init(id: "ed2k.server-met-url", pane: .ed2k, title: "server.met URL"),
        .init(id: "ed2k.nodes-dat-url", pane: .ed2k, title: "nodes.dat URL"),
        .init(id: "ed2k.sync-bootstrap-files-automatically", pane: .ed2k, title: "Sync bootstrap files automatically"),
        .init(id: "ed2k.sync-frequency", pane: .ed2k, title: "Sync frequency:"),
        .init(id: "ed2k.syncing", pane: .ed2k, title: "Sync Bootstrap Files"),
        .init(id: "ed2k.keyword", pane: .ed2k, title: "Keyword"),
        .init(id: "ed2k.file-type", pane: .ed2k, title: "File type:"),
        .init(id: "ed2k.minimum-sources", pane: .ed2k, title: "Minimum sources"),
        .init(id: "ed2k.search-timeout", pane: .ed2k, title: "Search timeout"),
        .init(id: "ed2k.cancel-search", pane: .ed2k, title: "Search ED2K"),
        .init(id: "integrations.receive-magnet-links", pane: .integrations, title: "Receive Magnet links"),
        .init(id: "integrations.receive-ed2k-links", pane: .integrations, title: "Receive ED2K links"),
        .init(id: "integrations.open-torrent-files", pane: .integrations, title: "Open Torrent files"),
        .init(id: "integrations.open-metalink-files", pane: .integrations, title: "Open Metalink files"),
        .init(id: "engine.start-engine", pane: .engine, title: "Start Engine"),
    ]
    static func results(for query: String) -> [SettingSearchEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let terms = [entry.title, entry.localizedTitle, entry.pane.rawValue, entry.pane.localizedTitle,
                         entry.id, chineseTitle(entry.title), aliases[entry.id] ?? ""].joined(separator: " ")
            return words.allSatisfy { terms.localizedStandardContains($0) }
        }
    }
    private static func chineseTitle(_ title: String) -> String {
        guard let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"), let bundle = Bundle(path: path) else { return "" }
        return bundle.localizedString(forKey: title, value: title, table: "Localizable")
    }
    static let aliases: [String: String] = [
        "network.global-upload-limit": "upload speed bandwidth 上传 速度 限速 带宽",
        "network.global-download-limit": "download speed bandwidth 下载 速度 限速 带宽",
        "network.proxy-url": "proxy 代理",
        "bitTorrent.seeding": "seed upload ratio 做种 上传 分享率",
        "downloads.default-save-location": "directory folder path 文件夹 目录 路径 保存",
        "general.chopchop-updates": "version release update 版本 更新",
        "engine.rpc-token": "authentication password 认证 密码 令牌"
    ]
}

@MainActor final class SettingsSearchModel: ObservableObject {
    struct NavigationRequest: Equatable {
        let id = UUID()
        let entry: SettingSearchEntry
    }

    @Published var query = ""
    @Published var isPresented = false
    @Published var selection: String?
    @Published private(set) var navigationRequest: NavigationRequest?
    var results: [SettingSearchEntry] { SettingsSearchIndex.results(for: query) }

    func select(_ entry: SettingSearchEntry) {
        query = ""
        isPresented = false
        selection = nil
        // Each activation is distinct, including a second search for the same setting.
        navigationRequest = NavigationRequest(entry: entry)
    }

    func finishNavigation(_ request: NavigationRequest) {
        guard navigationRequest == request else { return }
        navigationRequest = nil
    }

    func cancel() {
        query = ""
        isPresented = false
        selection = nil
        navigationRequest = nil
    }

    func move(_ offset: Int) {
        let items = results
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : items.count)
        selection = items[min(items.count - 1, max(0, index + offset))].id
    }
}

/// One native search control belongs to the settings shell, never to a pane.
/// AppKit owns the bezel, clear button, text editing and completion popover.
struct SettingsSearchField: NSViewRepresentable {
    @ObservedObject var model: SettingsSearchModel

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search settings")
        field.setAccessibilityLabel(String(localized: "Search settings"))
        field.setAccessibilityIdentifier("settings-global-search")
        field.controlSize = .regular
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
        context.coordinator.schedulePresentation()
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        field.delegate = nil
        coordinator.close()
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate, NSPopoverDelegate {
        let model: SettingsSearchModel
        weak var field: NSSearchField?
        let popover = NSPopover()
        private var presentationTask: Task<Void, Never>?

        init(model: SettingsSearchModel) {
            self.model = model
            super.init()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            let host = NSHostingController(rootView: SettingsSearchResults(model: model))
            host.sizingOptions = []
            popover.contentViewController = host
        }

        func schedulePresentation() {
            presentationTask?.cancel()
            presentationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.updatePresentation()
            }
        }

        private func updatePresentation() {
            guard model.isPresented, !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let field, field.window?.isVisible == true else {
                popover.close()
                return
            }
            popover.contentSize = NSSize(width: 360, height: model.results.isEmpty ? 64 : min(304, CGFloat(model.results.count) * 44 + 16))
            guard !popover.isShown, let editor = field.currentEditor() else { return }
            if let textView = editor as? NSTextView, textView.hasMarkedText() { return }
            let range = editor.selectedRange
            popover.show(relativeTo: field.bounds, of: field, preferredEdge: .maxY)
            // Completion choices must not steal text input or reset an IME selection.
            field.selectText(nil)
            field.currentEditor()?.selectedRange = range
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            model.isPresented = true
            schedulePresentation()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            model.query = field.stringValue
            model.selection = model.results.first?.id
            model.isPresented = true
            schedulePresentation()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): model.move(1)
            case #selector(NSResponder.moveUp(_:)): model.move(-1)
            case #selector(NSResponder.insertNewline(_:)):
                if let entry = model.results.first(where: { $0.id == model.selection }) ?? model.results.first {
                    model.select(entry)
                    field?.window?.makeFirstResponder(nil)
                }
            case #selector(NSResponder.cancelOperation(_:)): model.cancel()
            default: return false
            }
            schedulePresentation()
            return true
        }

        func popoverDidClose(_ notification: Notification) {
            model.isPresented = false
        }

        func close() {
            presentationTask?.cancel()
            popover.delegate = nil
            popover.close()
        }
    }
}

private struct SettingsSearchResults: View {
    @ObservedObject var model: SettingsSearchModel
    var body: some View {
        Group {
            if model.results.isEmpty {
                Text("No matching settings").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selection) {
                        ForEach(model.results) { entry in
                            Button { model.select(entry) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.localizedTitle)
                                    Text(entry.pane.localizedTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tag(entry.id).id(entry.id)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .padding(4)
    }
}

extension View {
    func settingsAnchor(_ identifier: String) -> some View { id(identifier) }
}
