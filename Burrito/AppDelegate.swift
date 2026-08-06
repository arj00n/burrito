import Cocoa
import SwiftUI
import ServiceManagement
import Sparkle

extension Notification.Name {
    static let dismissDropShelf = Notification.Name("DismissDropShelf")
    static let checkForBurritoUpdates = Notification.Name("CheckForBurritoUpdates")
}

final class DropShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shelfFrameAutosaveName = "BurritoDropShelf"
    private var restoredUsableShelfFrame = false
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var statusItem: NSStatusItem!
    var shelfPanel: DropShelfPanel!
    var rightClickMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        adoptBalancedEngineDefaultIfNeeded()
        setupShelfPanel()
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideShelf),
            name: .dismissDropShelf,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkForUpdates),
            name: .checkForBurritoUpdates,
            object: nil
        )
    }

    private func adoptBalancedEngineDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didAdoptBalancedEngineDefault") else { return }
        defaults.set("balanced", forKey: "enginePreset")
        defaults.set(true, forKey: "didAdoptBalancedEngineDefault")
    }

    private func setupShelfPanel() {
        shelfPanel = DropShelfPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        shelfPanel.contentViewController = NSHostingController(rootView: ContentView())
        shelfPanel.backgroundColor = .clear
        shelfPanel.appearance = NSAppearance(named: .vibrantDark)
        shelfPanel.isOpaque = false
        shelfPanel.hasShadow = true
        shelfPanel.level = .floating
        shelfPanel.isFloatingPanel = true
        shelfPanel.hidesOnDeactivate = false
        shelfPanel.becomesKeyOnlyIfNeeded = true
        shelfPanel.worksWhenModal = true
        shelfPanel.isMovableByWindowBackground = true
        shelfPanel.isReleasedWhenClosed = false
        shelfPanel.animationBehavior = .utilityWindow
        shelfPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        if #available(macOS 26.0, *) {
            shelfPanel.collectionBehavior.insert(.canJoinAllApplications)
        } else {
            shelfPanel.collectionBehavior.insert(.fullScreenAuxiliary)
        }

        restoredUsableShelfFrame = shelfPanel.setFrameUsingName(shelfFrameAutosaveName)
            && shelfFrameIntersectsAVisibleScreen
        shelfPanel.setFrameAutosaveName(shelfFrameAutosaveName)
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
        } else if shelfPanel.isVisible {
            hideShelf()
        } else {
            showShelf()
        }
    }

    private func showShelf() {
        if !restoredUsableShelfFrame {
            positionShelfBelowStatusItem()
            restoredUsableShelfFrame = true
        }
        shelfPanel.orderFrontRegardless()
    }

    @objc private func hideShelf() {
        shelfPanel.orderOut(nil)
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private var shelfFrameIntersectsAVisibleScreen: Bool {
        NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(shelfPanel.frame)
            return intersection.width >= 120 && intersection.height >= 80
        }
    }

    private func positionShelfBelowStatusItem() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let panelSize = shelfPanel.frame.size
        let visibleFrame = screen.visibleFrame
        let proposedX = buttonRectOnScreen.midX - (panelSize.width / 2)
        let x = min(max(proposedX, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
        let y = max(buttonRectOnScreen.minY - panelSize.height - 8, visibleFrame.minY + 8)
        shelfPanel.setFrameOrigin(NSPoint(x: x, y: y))
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
