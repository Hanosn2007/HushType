import AppKit

/// Installs the standard macOS command surface that a programmatic LSUIElement
/// app does not receive from a storyboard. Responder-chain actions keep text
/// editing and window shortcuts native.
@MainActor
final class HushTypeMainMenuController: NSObject {
    static let shared = HushTypeMainMenuController()

    private var openSettings: () -> Void = {}

    private override init() {
        super.init()
    }

    func install(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettings(_ sender: Any?) {
        openSettings()
    }

    private func appMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "HushType")
        root.submenu = menu

        let about = NSMenuItem(
            title: L10n.string("menu.about", fallback: "About HushType"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp
        menu.addItem(about)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: L10n.string("common.button.settings", fallback: "Settings…"),
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let hide = NSMenuItem(
            title: L10n.string("app_menu.hide", fallback: "Hide HushType"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApp
        menu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: L10n.string("app_menu.hide_others", fallback: "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        menu.addItem(hideOthers)

        let showAll = NSMenuItem(
            title: L10n.string("app_menu.show_all", fallback: "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAll.target = NSApp
        menu.addItem(showAll)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: L10n.string("menu.quit", fallback: "Quit HushType"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
        return root
    }

    private func fileMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: L10n.string("app_menu.file", fallback: "File"))
        root.submenu = menu
        menu.addItem(NSMenuItem(
            title: L10n.string("app_menu.close_window", fallback: "Close Window"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        return root
    }

    private func editMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: L10n.string("app_menu.edit", fallback: "Edit"))
        root.submenu = menu
        menu.addItem(NSMenuItem(title: L10n.string("app_menu.undo", fallback: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L10n.string("app_menu.redo", fallback: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.string("app_menu.cut", fallback: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: L10n.string("app_menu.copy", fallback: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: L10n.string("app_menu.paste", fallback: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: L10n.string("app_menu.select_all", fallback: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        return root
    }

    private func windowMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: L10n.string("app_menu.window", fallback: "Window"))
        root.submenu = menu

        menu.addItem(NSMenuItem(
            title: L10n.string("app_menu.minimize", fallback: "Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        menu.addItem(NSMenuItem(
            title: L10n.string("app_menu.zoom", fallback: "Zoom"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        let bringAll = NSMenuItem(
            title: L10n.string("app_menu.bring_all_to_front", fallback: "Bring All to Front"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        bringAll.target = NSApp
        menu.addItem(bringAll)
        NSApp.windowsMenu = menu
        return root
    }
}
