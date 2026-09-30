import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI

// MARK: - Window

/// Hosts Settings in its own window rather than inside the shelf.
///
/// The shelf is a 460 pt strip that collapses the moment the pointer leaves it, which is
/// the wrong place for anything you need to read, compare, or come back to.
final class SettingsWindowController: NSWindowController {
    private let updates: UpdateModel
    private let hosting: NSHostingController<SettingsView>

    init(updates: UpdateModel) {
        self.updates = updates
        hosting = NSHostingController(rootView: SettingsView(updates: updates))
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Burrito Settings"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        // The stock open animation zooms from a point and then the hosting controller
        // resizes the content under it - which is what read as the window "opening
        // weirdly". Show() does a short fade instead.
        window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }

        // An accessory app has no Dock presence, so its windows open behind whatever is
        // frontmost unless it activates first.
        NSApp.activate(ignoringOtherApps: true)
        updates.refresh()

        guard !window.isVisible else {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Size to the content *before* showing, so the window appears once at its final
        // size in its final place instead of appearing and then growing into it.
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
        center(window, onScreenContaining: NSEvent.mouseLocation)

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// Open on the display the pointer is on - the one the user was looking at when they
    /// clicked the gear.
    private func center(_ window: NSWindow, onScreenContaining point: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: (visible.midX - (size.width / 2)).rounded(),
            y: (visible.midY - (size.height / 2) + (visible.height * 0.06)).rounded()
        ))
    }
}

// MARK: - Updates

/// Update status for the Settings window, backed by Sparkle.
///
/// Uses `checkForUpdateInformation()`, which asks the appcast without showing any UI, so
/// opening Settings can say "2.4 is available" instead of making the user press a button to
/// find out. Installing still goes through Sparkle's own flow.
final class UpdateModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum Status: Equatable {
        case unknown
        case checking
        case upToDate
        case available(version: String)
        case failed
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var lastChecked: Date?
    @Published var checksAutomatically = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    private weak var controller: SPUStandardUpdaterController?

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    func attach(_ controller: SPUStandardUpdaterController) {
        self.controller = controller
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        lastChecked = controller.updater.lastUpdateCheckDate
    }

    /// Quietly ask whether an update exists.
    func refresh() {
        guard let updater = controller?.updater, updater.canCheckForUpdates, status != .checking else { return }
        status = .checking
        updater.checkForUpdateInformation()
    }

    /// Hand over to Sparkle to download and install.
    func install() {
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(version: item.displayVersionString)
        lastChecked = Date()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = .upToDate
        lastChecked = Date()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        // Sparkle reports "no update" as an error too (`SUNoUpdateError`, 1001); that case
        // has already been handled above. Anything else still marked as checking failed.
        guard status == .checking else { return }
        if let error = error as NSError?, error.code != 1001 {
            status = .failed
        } else {
            status = .upToDate
        }
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass on macOS 26 and later, bordered on earlier systems.
    ///
    /// Glass is used for controls only, never for content groups: that is the platform's
    /// own guidance for the material, and layering frosted panels behind frosted controls
    /// is what made the first version of this window look heavy.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var updates: UpdateModel

    @AppStorage(DisplayScope.storageKey) private var displayScope = DisplayScope.both.rawValue
    @AppStorage(OutputLocation.storageKey) private var outputLocation = OutputLocation.optimizedFolder.rawValue
    @AppStorage("enginePreset") private var enginePreset = "balanced"
    @AppStorage("pdfTargetBytes") private var pdfTargetBytes = 0

    @State private var hasExternal = DisplayScope.hasExternalDisplay
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Group corner radius. Anything drawn inside a group derives its own radius from this
    /// and its inset, so inner shapes stay concentric with the group around them.
    private static let groupRadius: CGFloat = 10
    private static let rowInset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            group("Display") {
                row("Show on") {
                    Picker("Show on", selection: $displayScope) {
                        Text("Built-in").tag(DisplayScope.builtIn.rawValue)
                        Text("External").tag(DisplayScope.external.rawValue)
                        Text("All").tag(DisplayScope.both.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                if DisplayScope.currentSelectionIsInactive {
                    caption("No external monitor connected — showing on the built-in for now.")
                }
            }

            group("Saving") {
                Picker("Save to", selection: $outputLocation) {
                    radioLabel("Optimized Files folder", "A new folder beside each original")
                        .tag(OutputLocation.optimizedFolder.rawValue)
                    radioLabel("Beside the originals", "Same folder, named “name optimized”")
                        .tag(OutputLocation.besideOriginals.rawValue)
                    radioLabel("Ask every time", "Pick a folder for each batch")
                        .tag(OutputLocation.askEveryTime.rawValue)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(.horizontal, Self.rowInset)
                .padding(.vertical, 10)
            }

            group("Conversion") {
                row("Engine") {
                    Picker("Engine", selection: $enginePreset) {
                        Text("Fast").tag("fast")
                        Text("Balanced").tag("balanced")
                        Text("Smallest").tag("smallest")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                separator
                row("PDF size target") {
                    Picker("PDF size target", selection: $pdfTargetBytes) {
                        Text("Automatic").tag(0)
                        Text("Under 500 KB").tag(480_000)
                        Text("Under 1 MB").tag(950_000)
                        Text("Under 2 MB").tag(1_900_000)
                        Text("Under 5 MB").tag(4_800_000)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }

            group("General") {
                row("Launch at login") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                }
                separator
                row("Check for updates automatically") {
                    Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        // Short and gentle: state changes cross-fade rather than bounce.
        .animation(.easeInOut(duration: 0.18), value: updates.status)
        .animation(.easeInOut(duration: 0.18), value: displayScope)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasExternal = DisplayScope.hasExternalDisplay
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Burrito").font(.system(size: 13, weight: .semibold))
                Text(updateLine)
                    .font(.system(size: 11))
                    .foregroundStyle(updates.status == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .contentTransition(.opacity)
            }

            Spacer()

            updateControl
        }
    }

    /// Update status folded into the version line, so the header stays one quiet row.
    private var updateLine: String {
        switch updates.status {
        case .unknown, .checking: "Version \(updates.currentVersion) · Checking…"
        case .upToDate: "Version \(updates.currentVersion) · Up to date"
        case let .available(version): "Version \(version) is available"
        case .failed: "Couldn’t check for updates"
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch updates.status {
        case .available:
            Button("Update") { updates.install() }
                .glassButton(prominent: true)
                .controlSize(.small)
        case .checking, .unknown:
            ProgressView().controlSize(.small)
        default:
            Button("Check Now") { updates.refresh() }
                .glassButton()
                .controlSize(.small)
        }
    }

    // MARK: Building blocks

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                )
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, Self.rowInset)
        .frame(minHeight: 36)
    }

    private func radioLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Self.rowInset)
            .padding(.bottom, 9)
            .transition(.opacity)
    }

    private var separator: some View {
        Divider().padding(.horizontal, Self.rowInset)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Reflect what actually happened rather than what was asked for.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            NSLog("Failed to toggle Burrito login item: %@", error.localizedDescription)
        }
    }
}
