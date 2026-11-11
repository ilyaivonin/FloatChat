import AppKit

enum AppMenu {
    @MainActor
    static func install(appName: String, language: AppLanguage? = nil) {
        NSApp.mainMenu = buildMenu(appName: appName, language: language ?? L10n.current)
    }

    @MainActor
    static func updateAppName(_ name: String) {
        let appItem = NSApp.mainMenu?.items.first
        appItem?.title = name
        guard let appMenu = appItem?.submenu else { return }
        appMenu.items.first?.title = name
        for item in appMenu.items where item.action == #selector(NSApplication.terminate(_:)) {
            item.title = L10n.t("Завершить \(name)", "Quit \(name)")
        }
    }

    @MainActor
    private static func buildMenu(appName: String, language: AppLanguage) -> NSMenu {
        func t(_ ru: String, _ en: String) -> String {
            language == .ru ? ru : en
        }

        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: appName, action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: t("Скрыть \(appName)", "Hide \(appName)"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: t("Скрыть остальные", "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: t("Показать все", "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: t("Завершить \(appName)", "Quit \(appName)"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editItem = NSMenuItem()
        editItem.title = t("Правка", "Edit")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: t("Правка", "Edit"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: t("Отменить", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: t("Повторить", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: t("Вырезать", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: t("Копировать", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: t("Вставить", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: t("Удалить", "Delete"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: t("Выбрать всё", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        windowItem.title = t("Окно", "Window")
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: t("Окно", "Window"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: t("Свернуть", "Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: t("Закрыть", "Close"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
