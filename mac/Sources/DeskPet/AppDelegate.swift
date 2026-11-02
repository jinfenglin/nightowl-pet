import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PetStore.shared
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var monitor: BehaviorMonitor!
    private var settingsWindow: NSWindow?
    private var host: PetHostingView<PetView>!
    private var language = AppLanguage.resolved
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()
        NSApp.mainMenu = makeMainMenu()
        setupPanel()
        setupStatusItem()

        monitor = BehaviorMonitor(store: store)
        monitor.start()

        // Menus and window titles are plain strings; rebuild them when the language changes.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.languageMayHaveChanged() }
            .store(in: &cancellables)

        if store.petImage == nil {
            store.say(L("右键我 → 设置 → 形象，用一张照片把我变成你想要的样子吧！",
                        "Right-click me → Settings → Appearance, and turn me into anything with a photo!"), seconds: 12)
        }
    }

    private func languageMayHaveChanged() {
        guard AppLanguage.resolved != language else { return }
        language = AppLanguage.resolved
        host.menu = makeMenu()
        statusItem.menu = makeMenu()
        settingsWindow?.title = Self.settingsTitle
        DashboardWindow.refreshTitle()
    }

    private static var settingsTitle: String { L("DeskPet 设置", "DeskPet Settings") }

    // MARK: - Windows

    private func setupPanel() {
        let size = NSSize(width: 280, height: 420)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true

        host = PetHostingView(rootView: PetView(store: store))
        host.onDoubleClick = { [weak self] in self?.store.poke() }
        host.menu = makeMenu()
        panel.contentView = host

        if !panel.setFrameUsingName("DeskPetWindow"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 20, y: f.minY + 20))
        }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)  // restored frame may be from an older size
        panel.setFrameAutosaveName("DeskPetWindow")
        panel.orderFrontRegardless()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = makeMenu()
        store.$hp
            .sink { [weak self] hp in self?.statusItem.button?.title = hp > 0 ? "❤️ \(hp)" : "💀 0" }
            .store(in: &cancellables)
    }

    /// Only the quick, everyday actions; everything else lives in Settings.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        @discardableResult
        func item(_ title: String, _ action: Selector, _ key: String = "", in parent: NSMenu? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            (parent ?? menu).addItem(i)
            return i
        }
        let styles = NSMenu()
        for style in AttackStyle.allCases {
            item(style.title, #selector(selectAttackStyle(_:)), in: styles).representedObject = style.rawValue
        }
        let stylesItem = NSMenuItem(title: L("攻击特效", "Attack Effect"), action: nil, keyEquivalent: "")
        stylesItem.submenu = styles
        menu.addItem(stylesItem)
        item(L("测试一次攻击（不扣血）", "Test Attack (No Damage)"), #selector(testAttack))
        item(L("回满血（作弊）", "Full Heal (Cheat)"), #selector(fullHeal))
        menu.addItem(.separator())
        item(L("血量看板…", "HP Dashboard…"), #selector(openDashboard))
        item(L("设置…", "Settings…"), #selector(openSettings), ",")
        item(L("隐藏宠物", "Hide Pet"), #selector(togglePet))
        item(L("退出", "Quit"), #selector(quit), "q")
        return menu
    }

    /// Accessory apps have no menu bar, but text fields need an Edit menu for ⌘C/⌘V.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        DashboardWindow.show()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            w.title = Self.settingsTitle
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func selectAttackStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: Pref.attackStyle)
        testAttack()
    }

    @objc private func testAttack() {
        store.damage(9, reason: PetStore.testAttackReason, preview: true)
    }

    @objc private func fullHeal() {
        store.heal(store.maxHP, reason: PetStore.fullHealReason)
    }

    @objc private func togglePet() {
        panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectAttackStyle(_:)) {
            item.state = item.representedObject as? String == AttackStyle.current.rawValue ? .on : .off
        }
        if item.action == #selector(fullHeal) {
            return store.hp < store.maxHP
        }
        if item.action == #selector(togglePet) {
            item.title = panel.isVisible ? L("隐藏宠物", "Hide Pet") : L("显示宠物", "Show Pet")
        }
        return true
    }
}

/// Drag anywhere to move the pet; double-click to poke it; right-click for the menu.
final class PetHostingView<Content: View>: NSHostingView<Content> {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
