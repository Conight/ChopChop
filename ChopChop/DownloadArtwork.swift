import AppKit
import Combine
import SwiftUI

/// Keeps decorative time independent of download progress and freezes it while offscreen.
nonisolated struct ArtworkClock {
    private var accumulated: TimeInterval = 0
    private var startedAt: TimeInterval?

    func elapsed(at uptime: TimeInterval) -> TimeInterval {
        accumulated + (startedAt.map { max(0, uptime - $0) } ?? 0)
    }

    mutating func setRunning(_ running: Bool, at uptime: TimeInterval) {
        if running, startedAt == nil {
            startedAt = uptime
        } else if !running, let startedAt {
            accumulated += max(0, uptime - startedAt)
            self.startedAt = nil
        }
    }
}

struct DownloadArtwork: View {
    var showsBrand = true
    var animates = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var activity = ArtworkActivity()
    @State private var clock = ArtworkClock()
    @State private var isPresented = false

    private var isAnimating: Bool { animates && isPresented && !reduceMotion && activity.canAnimate }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { _ in
            DownloadFlowScene(elapsed: clock.elapsed(at: ProcessInfo.processInfo.systemUptime),
                accent: Color(nsColor: .controlAccentColor), dark: colorScheme == .dark,
                increasedContrast: contrast == .increased)
                .id(activity.paletteRevision)
        }
        .overlay(alignment: .topLeading) {
            if showsBrand {
            Text(verbatim: "ChopChop")
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 25)
            }
        }
        .background(ArtworkWindowAnchor(activity: activity))
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isPresented = true }
        .onDisappear {
            isPresented = false
            clock.setRunning(false, at: ProcessInfo.processInfo.systemUptime)
            activity.attach(to: nil)
        }
        .onChange(of: isAnimating, initial: true) { _, running in
            clock.setRunning(running, at: ProcessInfo.processInfo.systemUptime)
        }
    }
}

/// A quiet, static continuation of the sheet artwork. Keeping it below the working
/// area avoids decorative movement behind task progress and does not drive list updates.
struct DownloadWorkspaceBackdrop: View {
    var sidebar = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .bottom) {
            if !sidebar {
                Color(nsColor: .windowBackgroundColor)
                    .mix(with: Color(nsColor: .separatorColor), by: 0.035)
            }
            if contrast != .increased {
                DownloadArtwork(showsBrand: false, animates: false)
                    .frame(height: sidebar ? 220 : 260)
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.48),
                        .init(color: .black, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .opacity(sidebar ? 0.40 : (colorScheme == .dark ? 0.55 : 0.80))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// All fills are opaque. Reduce Transparency needs no separate translucent fallback.
/// Only this small Canvas redraws; form controls and their layout have no animation clock.
struct DownloadFlowScene: View {
    var elapsed: TimeInterval
    var accent: Color
    var dark: Bool
    var increasedContrast = false

    var body: some View {
        Canvas(opaque: true) { context, size in
            let base = dark ? Color(white: 0.105) : Color(white: 0.975)
            let colorAmount = increasedContrast ? 0.72 : 1.0
            func tinted(_ neutral: Color, _ amount: Double) -> Color {
                neutral.mix(with: accent, by: amount * colorAmount)
            }
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .linearGradient(
                Gradient(colors: [base, tinted(base, 0.025), tinted(base, dark ? 0.07 : 0.10)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))

            // Anchor the composition to the bottom at a constant aspect ratio. Opening
            // advanced options adds quiet space above instead of stretching the artwork.
            let height = min(size.height, size.width * 2)
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: size.width * x, y: size.height - height + height * y)
            }
            let phase = elapsed * .pi * 2 / 32
            let drift = sin(phase) * 0.008
            let light = (sin(phase + 0.8) + 1) / 2
            context.fill(Path(bounds), with: .radialGradient(
                Gradient(colors: [tinted(base, dark ? 0.12 : 0.17).opacity(0.7), base.opacity(0)]),
                center: point(0.9, 0.62 + drift), startRadius: 0, endRadius: size.width * 1.5))

            var fold = Path()
            fold.move(to: point(-0.35, 0.48))
            fold.addCurve(to: point(1.3, 0.30),
                control1: point(0.45, 1.14 + drift), control2: point(0.30, 0.35 + drift))
            var foreground = Path()
            foreground.move(to: point(-0.3, 1.05))
            foreground.addCurve(to: point(1.3, 0.72),
                control1: point(0.15, 0.76 - drift), control2: point(0.65, 0.67 - drift))

            for (index, edge) in [fold, foreground].enumerated() {
                var surface = edge
                surface.addLine(to: point(1.3, 1.3))
                surface.addLine(to: point(-0.35, 1.3))
                surface.closeSubpath()
                // Soft occlusion at the fold gives volume without drawing an outline.
                context.drawLayer { shadow in
                    shadow.addFilter(.blur(radius: 9))
                    shadow.translateBy(x: 0, y: -2)
                    shadow.stroke(edge, with: .color(.black.opacity(dark ? 0.15 : 0.045)), lineWidth: 9)
                }
                let crest = tinted(dark ? Color(white: 0.21) : .white, dark ? 0.10 : 0.035)
                let middle = tinted(dark ? Color(white: 0.14) : Color(white: 0.95), dark ? 0.13 : 0.15)
                let shade = tinted(dark ? Color(white: 0.09) : Color(white: 0.86), dark ? 0.09 : 0.23)
                context.fill(surface, with: .linearGradient(Gradient(stops: [
                    .init(color: crest, location: 0),
                    .init(color: middle, location: 0.48),
                    .init(color: shade, location: 1)
                ]), startPoint: point(index == 0 ? 0.05 : 0.4, index == 0 ? 0.4 : 0.75),
                    endPoint: point(1.15, index == 0 ? 1.0 : 1.25)))
                context.drawLayer { lighting in
                    lighting.clip(to: surface)
                    lighting.fill(Path(bounds), with: .radialGradient(
                        Gradient(colors: [Color.white.opacity(dark ? 0.035 : 0.40), .clear]),
                        center: point(-0.1 + light * 0.8, index == 0 ? 0.55 + light * 0.18 : 0.94),
                        startRadius: 0, endRadius: size.width * 1.25))
                    lighting.addFilter(.blur(radius: 4))
                    lighting.stroke(edge, with: .linearGradient(
                        Gradient(colors: [.clear, Color.white.opacity(dark ? 0.10 : 0.45), .clear]),
                        startPoint: point(-0.3, 0.9), endPoint: point(1.3, 0.3)), lineWidth: 5)
                }
            }
        }
    }
}

@MainActor
final class ArtworkActivity: ObservableObject {
    @Published private(set) var canAnimate = false
    @Published private(set) var paletteRevision = 0
    private(set) weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach(to: nil) }
        })
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.paletteRevision += 1 }
        })
        refresh()
    }

    private func refresh() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        canAnimate = visible && NSApp.isActive && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        window = nil
        canAnimate = false
    }

    isolated deinit { detach() }
}

private struct ArtworkWindowAnchor: NSViewRepresentable {
    let activity: ArtworkActivity
    final class Anchor: NSView {
        weak var activity: ArtworkActivity?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                activity?.attach(to: window)
            }
        }
    }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.identifier = NSUserInterfaceItemIdentifier("download-artwork-anchor")
        view.activity = activity
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {}
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.activity?.attach(to: nil)
        view.activity = nil
    }
}
