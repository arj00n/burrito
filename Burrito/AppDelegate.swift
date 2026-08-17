import Cocoa
import Combine
import SwiftUI
import ServiceManagement
import Sparkle
import NookSurface

extension Notification.Name {
    static let checkForBurritoUpdates = Notification.Name("CheckForBurritoUpdates")
    static let showBurritoDropZone = Notification.Name("ShowBurritoDropZone")
}

private typealias BurritoNook = Nook<NotchShelfView, EmptyView, EmptyView>

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let processor = ImageProcessor()
    private let notchInteraction = NotchInteractionModel()
    private var nooks: [CGDirectDisplayID: BurritoNook] = [:]
    private var nookCancellables = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()
    private var draggingDisplays = Set<CGDirectDisplayID>()
    private var earlyDragActive = false
    private var dragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
    private var earlyFileDragDetected = false
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var statusItem: NSStatusItem!
    var rightClickMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        adoptBalancedEngineDefaultIfNeeded()
        setupNotches()
        setupPresentationObservers()
        setupStatusItem()
        showNotch()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkForUpdates),
            name: .checkForBurritoUpdates,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildNotches),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func adoptBalancedEngineDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didAdoptBalancedEngineDefault") else { return }
        defaults.set("balanced", forKey: "enginePreset")
        defaults.set(true, forKey: "didAdoptBalancedEngineDefault")
    }

    private func setupNotches() {
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            nooks[displayID] = makeNook(for: screen, displayID: displayID)
        }
    }

    private func makeNook(for screen: NSScreen, displayID: CGDirectDisplayID) -> BurritoNook {
        let processor = processor
        let interaction = notchInteraction
        let nook = BurritoNook {
            NotchShelfView(
                processor: processor,
                interaction: interaction,
                requestExpansion: { [weak self] in self?.showNotch(expanded: true, on: screen) }
            )
        } compactLeading: {
            EmptyView()
        } compactTrailing: {
            EmptyView()
        }

        nook.presentation = .auto
        nook.screenProvider = { [weak self] in
            NSScreen.screens.first { self?.displayID(for: $0) == displayID }
        }
        nook.chromeAppearance = NSAppearance(named: .darkAqua)
        nook.backdrop = .vibrancy(.init(
            material: .hudWindow,
            blendingMode: .behindWindow,
            darkenOpacity: 0.52
        ))
        nook.onCompact = { [weak self, weak nook] in
            guard let self,
                  self.notchInteraction.isPinned
                    || self.notchInteraction.isChoosingFormat
                    || self.processor.isProcessing,
                  let nook else { return }
            Task { @MainActor in await nook.expand() }
        }

        nook.onFileDrop = { [weak self] urls in
            guard let self,
                  !urls.isEmpty,
                  !processor.isBatchRunning,
                  !interaction.isDraggingResults,
                  !self.containsCurrentOutput(urls) else { return false }
            processor.processDroppedURLs(urls, strategy: self.dropStrategyAtPointer())
            return true
        }

        nook.$isDragInFlight
            .removeDuplicates()
            .sink { [weak self] active in self?.setDragTracking(active, on: displayID) }
            .store(in: &nookCancellables)

        return nook
    }

    private func setupPresentationObservers() {
        notchInteraction.$isChoosingFormat
            .removeDuplicates()
            .sink { [weak self] choosing in
                self?.updateDragPresentation(choosing: choosing)
            }
            .store(in: &cancellables)

        notchInteraction.$isPinned
            .removeDuplicates()
            .sink { [weak self] pinned in
                self?.updateDragPresentation(pinned: pinned)
                if pinned {
                    self?.showNotch(expanded: true, on: self?.screen(containing: NSEvent.mouseLocation))
                } else {
                    self?.collapseAfterUnpin()
                }
            }
            .store(in: &cancellables)

        processor.$isProcessing
            .removeDuplicates()
            .sink { [weak self] processing in self?.setProcessingPresentation(processing) }
            .store(in: &cancellables)

        Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollForEarlyFileDrag() }
            .store(in: &cancellables)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        if let customIcon = NSImage(named: "MenuIcon") {
            customIcon.isTemplate = true
            customIcon.size = NSSize(width: 18, height: 18)
            button.image = customIcon
        } else {
            button.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Burrito")
        }

        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(handleMenuClick(_:))
        setupRightClickMenu()
    }

    private func setupRightClickMenu() {
        rightClickMenu = NSMenu()

        let loginItem = NSMenuItem(
            title: "Launch on Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        rightClickMenu.addItem(loginItem)
        rightClickMenu.addItem(.separator())

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        rightClickMenu.addItem(updateItem)
        rightClickMenu.addItem(.separator())

        rightClickMenu.addItem(NSMenuItem(title: "Quit Burrito", action: #selector(quitApp), keyEquivalent: "q"))
    }

    @objc private func handleMenuClick(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            statusItem.menu = rightClickMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            showNotch(expanded: true, on: screen(containing: NSEvent.mouseLocation))
        }
    }

    private func showNotch(expanded: Bool = false, on screen: NSScreen? = nil) {
        let targets: [BurritoNook]
        if let screen,
           let displayID = displayID(for: screen),
           let nook = nooks[displayID] {
            targets = [nook]
        } else {
            targets = Array(nooks.values)
        }

        for nook in targets {
            Task { @MainActor in
                if expanded {
                    await nook.expand()
                } else {
                    await nook.compact()
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first,
              url.scheme?.lowercased() == "burrito",
              url.host?.lowercased() == "convert",
              let format = TargetFormat(rawValue: url.lastPathComponent.lowercased()),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let fileURLs = components.queryItems?
            .filter { $0.name == "file" }
            .compactMap(\.value)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).standardizedFileURL } ?? []
        guard !fileURLs.isEmpty else { return }

        NotificationCenter.default.post(name: .showBurritoDropZone, object: nil)
        showNotch(expanded: true, on: screen(containing: NSEvent.mouseLocation))
        processor.processDroppedURLs(
            fileURLs,
            strategy: .highQuality,
            forcedTargetFormat: format,
            copyResultsOnSuccess: true
        )
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private var preferredNotchScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else { return false }
            return right.minX - left.maxX > 20
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func setDragTracking(_ active: Bool, on displayID: CGDirectDisplayID) {
        guard !notchInteraction.isDraggingResults else {
            draggingDisplays.remove(displayID)
            updateDragPresentation()
            return
        }
        if active {
            draggingDisplays.insert(displayID)
        } else {
            draggingDisplays.remove(displayID)
        }
        if active, let urls = draggedFileURLs {
            processor.previewMediaType(from: urls)
        }
        updateDragPresentation()
    }

    private func setProcessingPresentation(_ processing: Bool) {
        let active = !draggingDisplays.isEmpty || earlyDragActive
        for nook in nooks.values {
            nook.staysExpandedOnHoverExit = processing
                || active
                || notchInteraction.isChoosingFormat
                || notchInteraction.isPinned
            Task { @MainActor in
                if processing {
                    await nook.expand()
                } else if !nook.isHovering
                            && !self.notchInteraction.isChoosingFormat
                            && !self.notchInteraction.isPinned {
                    await nook.compact()
                }
            }
        }
    }

    private func dropStrategyAtPointer() -> ProcessingStrategy {
        let pointer = NSEvent.mouseLocation
        let midpoint = screen(containing: pointer)?.frame.midX ?? preferredNotchScreen?.frame.midX ?? 0
        return pointer.x < midpoint ? .highQuality : .webOptimized
    }

    private var draggedFileURLs: [URL]? {
        let urls = NSPasteboard(name: .drag)
            .readObjects(forClasses: [NSURL.self]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    private func pollForEarlyFileDrag() {
        guard !notchInteraction.isDraggingResults else {
            setEarlyDragActive(false)
            return
        }
        let pasteboardChangeCount = NSPasteboard(name: .drag).changeCount
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            dragPasteboardChangeCount = pasteboardChangeCount
            earlyFileDragDetected = false
            setEarlyDragActive(false)
            return
        }

        if pasteboardChangeCount != dragPasteboardChangeCount {
            dragPasteboardChangeCount = pasteboardChangeCount
            earlyFileDragDetected = draggedFileURLs != nil
        }

        guard earlyFileDragDetected,
              let urls = draggedFileURLs,
              let screen = screen(containing: NSEvent.mouseLocation) else {
            setEarlyDragActive(false)
            return
        }

        let point = NSEvent.mouseLocation
        let menuBarBottom = screen.frame.maxY - max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let region = NSRect(
            x: screen.frame.midX - 340,
            y: menuBarBottom - 210,
            width: 680,
            height: 202
        )

        guard region.contains(point) else {
            setEarlyDragActive(false)
            return
        }

        if !earlyDragActive {
            processor.previewMediaType(from: urls)
            setEarlyDragActive(true)
            showNotch(expanded: true, on: screen)
        }
        notchInteraction.activeStrategy = dropStrategyAtPointer()
    }

    private func setEarlyDragActive(_ active: Bool) {
        guard earlyDragActive != active else { return }
        earlyDragActive = active
        updateDragPresentation()
    }

    private func updateDragPresentation(choosing: Bool? = nil, pinned: Bool? = nil) {
        let active = !draggingDisplays.isEmpty || earlyDragActive
        notchInteraction.isDropTargeted = active
        let choosing = choosing ?? notchInteraction.isChoosingFormat
        let pinned = pinned ?? notchInteraction.isPinned
        for nook in nooks.values {
            nook.staysExpandedOnHoverExit = processor.isProcessing || active || choosing || pinned
        }
        guard !active else { return }
        if !choosing { processor.clearMediaTypePreview() }
        guard !processor.isProcessing, !choosing, !pinned else { return }
        for nook in nooks.values where !nook.isHovering {
            Task { @MainActor in await nook.compact() }
        }
    }

    private func collapseAfterUnpin() {
        guard !processor.isProcessing,
              !notchInteraction.isChoosingFormat,
              draggingDisplays.isEmpty,
              !earlyDragActive else { return }
        for nook in nooks.values {
            Task { @MainActor in await nook.compact() }
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? preferredNotchScreen
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    @objc private func rebuildNotches() {
        let oldNooks = Array(nooks.values)
        nooks.removeAll()
        nookCancellables.removeAll()
        draggingDisplays.removeAll()

        Task { @MainActor in
            for nook in oldNooks { await nook.hide() }
            self.setupNotches()
            self.showNotch()
            self.setProcessingPresentation(self.processor.isProcessing)
        }
    }

    private func containsCurrentOutput(_ urls: [URL]) -> Bool {
        let outputs = Set(processor.outputURLs.map(\.standardizedFileURL))
        return urls.contains { outputs.contains($0.standardizedFileURL) }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("Failed to toggle Burrito login item: %@", error.localizedDescription)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
