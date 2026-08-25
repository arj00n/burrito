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
    /// Desired chrome presentation for one display. Requests coalesce onto the newest
    /// intent - see ``setIntent(_:on:)``.
    private enum ChromeIntent {
        case expanded
        case compact
    }

    /// NookSurface tags its panel with this accessibility identifier. It's the only
    /// public handle on the window, so it's how we recognize a panel resize that the
    /// package performed behind our back.
    private static let nookPanelIdentifier = "opennook.panel"

    /// Slack around the expanded chrome inside which an incoming file drag pre-opens the
    /// notch, so the drop target is on screen before the pointer arrives. Applied to the
    /// real chrome rect rather than describing a box of its own - see
    /// ``dragApproachRegion(on:)``.
    private static let dragApproachMargin = NSEdgeInsets(top: 0, left: 56, bottom: 44, right: 56)

    private let processor = ImageProcessor()
    private let notchInteraction = NotchInteractionModel()
    private var nooks: [CGDirectDisplayID: BurritoNook] = [:]
    private var nookCancellables: [CGDirectDisplayID: Set<AnyCancellable>] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var chromeIntents: [CGDirectDisplayID: ChromeIntent] = [:]
    private var chromeDrivers: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var geometryTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var draggingDisplays = Set<CGDirectDisplayID>()
    private var earlyDragActive = false
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragPasteboardChangeCount = 0
    private var earlyFileDragDetected = false
    private var earlyDragMonitors: [Any] = []
    private var dragPollTimer: Timer?
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
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        endEarlyDragPolling()
        for monitor in earlyDragMonitors { NSEvent.removeMonitor(monitor) }
        earlyDragMonitors.removeAll()
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
            nooks[displayID] = makeNook(for: displayID)
        }
    }

    /// Build the nook for one display.
    ///
    /// Keyed on `displayID`, never on a captured `NSScreen`: AppKit replaces its
    /// `NSScreen` instances on every screen-parameter change and NookSurface compares
    /// screens by object identity, so a captured instance silently stops matching and
    /// makes the package rebuild its window on every expand.
    private func makeNook(for displayID: CGDirectDisplayID) -> BurritoNook {
        let processor = processor
        let interaction = notchInteraction

        // `[.keepVisible]` rather than the default `.all`: `.all` also includes
        // `.hapticFeedback`, which fires a trackpad haptic on every hover transition and
        // buzzes continuously as the pointer crosses the chrome edge.
        let nook = BurritoNook(hoverBehavior: [.keepVisible]) {
            NotchShelfView(
                processor: processor,
                interaction: interaction,
                requestExpansion: { [weak self] in self?.setIntent(.expanded, on: displayID) }
            )
        } compactLeading: {
            EmptyView()
        } compactTrailing: {
            EmptyView()
        }

        nook.presentation = .auto
        nook.screenProvider = { [weak self] in self?.liveScreen(for: displayID) }
        nook.chromeAppearance = NSAppearance(named: .darkAqua)
        nook.backdrop = .vibrancy(.init(
            material: .hudWindow,
            blendingMode: .behindWindow,
            darkenOpacity: 0.52
        ))

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
            .store(in: &nookCancellables[displayID, default: []])

        // Every signal that can change the chrome's rendered size, funnelled into one
        // geometry pass. NookSurface publishes no "window rebuilt" event, so this covers
        // the state-, hover-, and drag-driven paths; `observePanelResizes()` catches the
        // rebuilds that publish nothing at all.
        Publishers.Merge4(
            nook.$state.map { _ in () },
            nook.$isHovering.map { _ in () },
            nook.$isDragInFlight.map { _ in () },
            nook.$isLayoutGraceActive.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self, weak nook] _ in
            guard let self, let nook else { return }
            self.scheduleChromeGeometry(for: nook, displayID: displayID)
        }
        .store(in: &nookCancellables[displayID, default: []])

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
                guard let self else { return }
                // `updateDragPresentation` already drives the collapse on unpin; the
                // separate `collapseAfterUnpin` it used to be paired with issued a
                // second, competing transition for the same event.
                self.updateDragPresentation(pinned: pinned)
                if pinned {
                    self.showNotch(expanded: true, on: self.screen(containing: NSEvent.mouseLocation))
                }
            }
            .store(in: &cancellables)

        processor.$isProcessing
            .removeDuplicates()
            .sink { [weak self] processing in self?.setProcessingPresentation(processing) }
            .store(in: &cancellables)

        observePanelResizes()
        setupEarlyDragMonitors()
    }

    /// Catch panel resizes that NookSurface performed itself.
    ///
    /// The package sizes a freshly built panel to `screen.width x screen.height / 2` and
    /// never shrinks it - only ``applyChromeGeometry(to:displayID:)`` does. It rebuilds
    /// that panel on screen-parameter changes and on a same-state move to another
    /// screen, neither of which republishes `state`, so nothing else here would notice
    /// and a full-width, half-screen-tall panel would be left sitting above every other
    /// window, swallowing hover and fighting the pointer for cursor ownership.
    ///
    /// Safe against feedback: `applyChromeGeometry` is a no-op when the frame already
    /// matches, so the resize this handler triggers terminates on its own next pass.
    private func observePanelResizes() {
        NotificationCenter.default
            .publisher(for: NSWindow.didResizeNotification)
            .compactMap { $0.object as? NSWindow }
            .filter { $0.accessibilityIdentifier() == Self.nookPanelIdentifier }
            .sink { [weak self] _ in self?.reassertAllChromeGeometry() }
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
        let targets: [CGDirectDisplayID]
        if let screen,
           let displayID = displayID(for: screen),
           nooks[displayID] != nil {
            targets = [displayID]
        } else {
            targets = Array(nooks.keys)
        }

        for displayID in targets {
            setIntent(expanded ? .expanded : .compact, on: displayID)
        }
    }

    /// Record the chrome state a display should be in, and make sure a driver is applying it.
    ///
    /// Every open/close request funnels through here and intents coalesce: the newest
    /// one wins and intermediate ones are dropped. Each call site used to spawn its own
    /// detached `Task { await nook.expand() }`; those ran in arbitrary order and each
    /// claimed a fresh transition generation inside NookSurface, cancelling the others,
    /// so which state the notch ended up in came down to scheduling luck. That is what
    /// made opening and closing inconsistent.
    private func setIntent(_ intent: ChromeIntent, on displayID: CGDirectDisplayID) {
        guard nooks[displayID] != nil else { return }
        chromeIntents[displayID] = intent
        guard chromeDrivers[displayID] == nil else { return }

        chromeDrivers[displayID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.chromeDrivers[displayID] = nil }

            while let next = self.chromeIntents[displayID] {
                self.chromeIntents[displayID] = nil
                guard let nook = self.nooks[displayID] else { return }
                let screen = self.liveScreen(for: displayID)
                switch next {
                case .expanded: await nook.expand(on: screen)
                case .compact: await nook.compact(on: screen)
                }
                // `expand`/`compact` await their own settle, so the animation has
                // finished and the frame can be applied without clipping content.
                self.applyChromeGeometry(to: nook, displayID: displayID)
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
        let stays = processing
            || active
            || notchInteraction.isChoosingFormat
            || notchInteraction.isPinned

        for nook in nooks.values {
            nook.staysExpandedOnHoverExit = stays
        }

        // `isHovering` is read synchronously here. It used to be read inside a detached
        // `Task`, by which point it described a different moment than the decision.
        for (displayID, nook) in nooks {
            if processing {
                setIntent(.expanded, on: displayID)
            } else if !nook.isHovering,
                      !notchInteraction.isChoosingFormat,
                      !notchInteraction.isPinned {
                setIntent(.compact, on: displayID)
            }
        }
    }

    private func dropStrategyAtPointer() -> ProcessingStrategy {
        let pointer = NSEvent.mouseLocation
        let midpoint = screen(containing: pointer)?.frame.midX ?? preferredNotchScreen?.frame.midX ?? 0
        return pointer.x < midpoint ? .highQuality : .webOptimized
    }

    private var draggedFileURLs: [URL]? {
        let urls = dragPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    /// Watch for an incoming file drag only while the left button is held.
    ///
    /// This used to be a 20 Hz `Timer` running for the entire lifetime of the app that
    /// hit the drag pasteboard on every tick - an IPC round trip to the pasteboard
    /// server twenty times a second, forever, whether or not anything was being dragged.
    /// Bounding the poll to a mouse-down/up window leaves the app fully idle otherwise.
    private func setupEarlyDragMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown {
                self.beginEarlyDragPolling()
            } else {
                self.endEarlyDragPolling()
            }
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) {
            earlyDragMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handle(event)
            return event
        }) {
            earlyDragMonitors.append(local)
        }
    }

    private func beginEarlyDragPolling() {
        guard dragPollTimer == nil else { return }
        dragPasteboardChangeCount = dragPasteboard.changeCount
        earlyFileDragDetected = false

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollForEarlyFileDrag()
        }
        RunLoop.main.add(timer, forMode: .common)
        dragPollTimer = timer
    }

    private func endEarlyDragPolling() {
        dragPollTimer?.invalidate()
        dragPollTimer = nil
        earlyFileDragDetected = false
        setEarlyDragActive(false)
    }

    private func pollForEarlyFileDrag() {
        guard !notchInteraction.isDraggingResults else {
            setEarlyDragActive(false)
            return
        }

        // Self-healing stop: a mouse-up consumed by an active drag session never reaches
        // the monitors, so the poll also ends itself once the button comes back up.
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endEarlyDragPolling()
            return
        }

        let changeCount = dragPasteboard.changeCount
        if changeCount != dragPasteboardChangeCount {
            dragPasteboardChangeCount = changeCount
            earlyFileDragDetected = draggedFileURLs != nil
        }

        let pointer = NSEvent.mouseLocation
        guard earlyFileDragDetected,
              let urls = draggedFileURLs,
              let screen = screen(containing: pointer),
              dragApproachRegion(on: screen).contains(pointer) else {
            setEarlyDragActive(false)
            return
        }

        if !earlyDragActive {
            processor.previewMediaType(from: urls)
            setEarlyDragActive(true)
        }
        notchInteraction.activeStrategy = dropStrategyAtPointer()
    }

    /// Region in which an approaching file drag pre-opens the notch: the expanded chrome
    /// rect plus ``dragApproachMargin``.
    ///
    /// Derived from ``chromeFrame(on:state:style:)`` so the hot zone cannot drift away
    /// from the chrome it is supposed to describe. The hardcoded 680x202 box this
    /// replaces was 174 pt wider than the real 506 pt panel - drags opened the notch
    /// from well outside it - and started 8 pt below the screen top, so a drag held right
    /// under the menu bar missed the zone entirely.
    private func dragApproachRegion(on screen: NSScreen) -> NSRect {
        let style = displayID(for: screen).flatMap { nooks[$0]?.style } ?? .standard
        let chrome = chromeFrame(on: screen, state: .expanded, style: style)
        let margin = Self.dragApproachMargin
        return NSRect(
            x: chrome.minX - margin.left,
            y: chrome.minY - margin.bottom,
            width: chrome.width + margin.left + margin.right,
            height: chrome.height + margin.bottom + margin.top
        )
    }

    private func setEarlyDragActive(_ active: Bool) {
        guard earlyDragActive != active else { return }
        earlyDragActive = active
        updateDragPresentation()
    }

    /// Single owner of "should the chrome be open right now, and should it stay open".
    ///
    /// Both directions are driven from here through ``setIntent(_:on:)``, so an
    /// approaching drag and NookSurface's own drag-destination auto-expand can no longer
    /// disagree. The package snapshots `state` when a drag enters its panel and restores
    /// that snapshot when the drag leaves; if the approach zone had already expanded the
    /// chrome, the snapshot was `.expanded` and the restore did nothing, leaving the
    /// notch open after the drag was gone. Making our intent authoritative removes both
    /// that and the mirror-image case where the package collapsed the chrome while the
    /// pointer was still inside the approach zone.
    private func updateDragPresentation(choosing: Bool? = nil, pinned: Bool? = nil) {
        let active = !draggingDisplays.isEmpty || earlyDragActive
        let choosing = choosing ?? notchInteraction.isChoosingFormat
        let pinned = pinned ?? notchInteraction.isPinned

        // Guarded to avoid a re-entrant publish: this runs inside sinks on
        // `notchInteraction`'s own publishers.
        if notchInteraction.isDropTargeted != active {
            notchInteraction.isDropTargeted = active
        }

        let stays = processor.isProcessing || active || choosing || pinned
        for nook in nooks.values {
            nook.staysExpandedOnHoverExit = stays
        }

        if active {
            for displayID in dragTargetDisplayIDs() {
                setIntent(.expanded, on: displayID)
            }
            return
        }

        if !choosing { processor.clearMediaTypePreview() }
        guard !processor.isProcessing, !choosing, !pinned else { return }

        // A chrome the pointer is resting on stays open; `staysExpandedOnHoverExit` is
        // false by now, so NookSurface collapses it as soon as the pointer leaves.
        for (displayID, nook) in nooks where !nook.isHovering {
            setIntent(.compact, on: displayID)
        }
    }

    /// Displays that should show the drop target: those with a live drag session, or -
    /// for the approach-zone case, which has no session yet - the one under the pointer.
    private func dragTargetDisplayIDs() -> [CGDirectDisplayID] {
        guard draggingDisplays.isEmpty else { return Array(draggingDisplays) }
        guard let screen = screen(containing: NSEvent.mouseLocation),
              let displayID = displayID(for: screen) else { return [] }
        return [displayID]
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? preferredNotchScreen
    }

    /// The current `NSScreen` for a display, looked up fresh every time - see ``makeNook(for:)``.
    private func liveScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(for: $0) == displayID }
    }

    /// The window rect the chrome should occupy for `state` on `screen`.
    ///
    /// The single place notch window geometry is computed. Both the window frame and the
    /// drag approach zone read it, so the panel the user sees and the region that reacts
    /// to a drag are guaranteed to describe the same rectangle.
    private func chromeFrame(on screen: NSScreen, state: NookState, style: NookStyle) -> NSRect {
        let menuHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let hasNotch = screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        let insets = style.expandedContentInsets
        let width = NotchShelfView.contentSize.width
            + insets.leading + insets.trailing
            + (style.topCornerRadius * 2)

        let height: CGFloat
        switch state {
        case .expanded:
            height = NotchShelfView.contentSize.height
                + insets.top + insets.bottom
                + (hasNotch ? 0 : menuHeight + 8)
        case .compact:
            height = hasNotch
                ? max(screen.safeAreaInsets.top, menuHeight)
                : (menuHeight * 2) + 8
        case .hidden:
            height = 0
        }

        return NSRect(
            x: screen.frame.midX - (width / 2),
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Grow the panel immediately, shrink it only once the conversion animation has
    /// settled - shrinking mid-collapse clips the animating content.
    ///
    /// Any newer trigger cancels a pending shrink, so flicking the pointer in and out of
    /// the chrome cannot queue a stale resize. This replaces a fixed 450 ms sleep that
    /// matched none of the package's actual timings (250/400/550 ms) and was never
    /// cancelled, so rapid hover queued one `setFrame` per event.
    private func scheduleChromeGeometry(for nook: BurritoNook, displayID: CGDirectDisplayID) {
        geometryTasks[displayID]?.cancel()
        geometryTasks[displayID] = nil

        guard nook.state != .hidden,
              let screen = liveScreen(for: displayID) else { return }

        let target = chromeFrame(on: screen, state: nook.state, style: nook.style)
        let current = currentChromeFrame(of: nook)
        let grows = current.map { target.width > $0.width || target.height > $0.height } ?? true

        guard !grows else {
            applyChromeGeometry(to: nook, displayID: displayID)
            return
        }

        let settle = nook.transitionConfiguration.animationDuration ?? 0.4
        geometryTasks[displayID] = Task { @MainActor [weak self, weak nook] in
            try? await Task.sleep(for: .seconds(settle))
            guard !Task.isCancelled, let self, let nook else { return }
            self.geometryTasks[displayID] = nil
            self.applyChromeGeometry(to: nook, displayID: displayID)
        }
    }

    /// Re-assert the notch window's frame. Idempotent, so it is safe to call from every
    /// trigger - including ``observePanelResizes()``, which this method's own `setFrame`
    /// feeds.
    private func applyChromeGeometry(to nook: BurritoNook, displayID: CGDirectDisplayID) {
        guard nook.state != .hidden,
              let screen = liveScreen(for: displayID) else { return }

        let target = chromeFrame(on: screen, state: nook.state, style: nook.style)
        nook.configureWindow { window in
            guard window.frame != target else { return }
            window.setFrame(target, display: true)
        }
    }

    private func reassertAllChromeGeometry() {
        for (displayID, nook) in nooks {
            applyChromeGeometry(to: nook, displayID: displayID)
        }
    }

    private func currentChromeFrame(of nook: BurritoNook) -> NSRect? {
        var frame: NSRect?
        nook.configureWindow { frame = $0.frame }
        return frame
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    /// React to a display being attached or removed.
    ///
    /// Only nooks whose display actually disappeared are retired, and only genuinely new
    /// displays get one; surviving displays keep theirs and NookSurface re-places the
    /// panel itself (caught by ``observePanelResizes()``).
    ///
    /// The previous version tore down and rebuilt every nook, awaiting `hide()` on each
    /// old one *serially*. `hide()` defers indefinitely while the pointer is over the
    /// chrome - `.keepVisible` polls until it leaves - so a display change with the
    /// pointer on the notch hung the rebuild partway and the notch never came back until
    /// relaunch. `Nook` has no `deinit` either, so a discarded nook whose hide got
    /// superseded left its panel ordered on screen with nothing able to close it.
    @objc private func handleScreenParametersChange() {
        let live = Set(NSScreen.screens.compactMap(displayID(for:)))

        for (displayID, nook) in nooks where !live.contains(displayID) {
            retire(nook, on: displayID)
        }

        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen), nooks[displayID] == nil else { continue }
            nooks[displayID] = makeNook(for: displayID)
            setIntent(.compact, on: displayID)
        }

        setProcessingPresentation(processor.isProcessing)
        reassertAllChromeGeometry()
    }

    /// Drop the nook for a display that no longer exists, closing its panel synchronously
    /// rather than awaiting `hide()` - see ``handleScreenParametersChange()``.
    private func retire(_ nook: BurritoNook, on displayID: CGDirectDisplayID) {
        chromeDrivers[displayID]?.cancel()
        chromeDrivers[displayID] = nil
        chromeIntents[displayID] = nil
        geometryTasks[displayID]?.cancel()
        geometryTasks[displayID] = nil
        nookCancellables[displayID] = nil
        draggingDisplays.remove(displayID)
        nooks[displayID] = nil

        nook.configureWindow { window in
            window.orderOut(nil)
            window.close()
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
