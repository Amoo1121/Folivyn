import Foundation

/// Uses the app's preferred system language, with English as the development fallback.
public enum L10n {
    public static let appName = "Folivyn"
    public static let resourceBundle: Bundle = {
        // Packaged apps keep SwiftPM resources in the standard macOS resource directory.
        if let url = Bundle.main.url(forResource: "Folivyn_EditorUI", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    public enum Key: String, CaseIterable {
        case untitled = "document.untitled"
        case windowTitle = "window.title"
        case about = "menu.about"
        case quit = "menu.quit"
        case fileMenu = "menu.file"
        case new = "action.new"
        case open = "action.open"
        case save = "action.save"
        case saveAs = "action.save_as"
        case reloadFromDisk = "action.reload_from_disk"
        case reload = "action.reload"
        case closeTab = "action.close_tab"
        case editMenu = "menu.edit"
        case undo = "action.undo"
        case redo = "action.redo"
        case cut = "action.cut"
        case copy = "action.copy"
        case paste = "action.paste"
        case selectAll = "action.select_all"
        case tabsMenu = "menu.tabs"
        case previousTab = "action.previous_tab"
        case nextTab = "action.next_tab"
        case largeText = "status.large_text"
        case unsaved = "status.unsaved"
        case diskChanged = "status.disk_changed"
        case newDocument = "status.new_document"
        case openMessage = "dialog.open.message"
        case saveCopyTitle = "dialog.save_copy.title"
        case saveTitle = "dialog.save.title"
        case alreadyOpenTitle = "dialog.already_open.title"
        case alreadyOpenMessage = "dialog.already_open.message"
        case conflictTitle = "dialog.conflict.title"
        case conflictMessage = "dialog.conflict.message"
        case cancel = "action.cancel"
        case reloadTitle = "dialog.reload.title"
        case reloadMessage = "dialog.reload.message"
        case discardAndReload = "action.discard_and_reload"
        case saveCopyAndReload = "action.save_copy_and_reload"
        case copyLocationTitle = "dialog.copy_location.title"
        case copyLocationMessage = "dialog.copy_location.message"
        case closeTitle = "dialog.close.title"
        case closeMessage = "dialog.close.message"
        case dontSave = "action.dont_save"
        case aboutMessage = "dialog.about.message"
        case operationFailed = "dialog.error.title"
        case ok = "action.ok"
        case plainText = "syntax.plain_text"
        case highlightingLimit = "syntax.limit"
    }

    public static func text(_ key: Key, language: String? = nil) -> String {
        bundle(for: language).localizedString(forKey: key.rawValue, value: nil, table: nil)
    }

    public static func format(_ key: Key, _ arguments: CVarArg..., language: String? = nil) -> String {
        let locale = language.map { Locale(identifier: $0) } ?? Locale.current
        return String(format: text(key, language: language), locale: locale, arguments: arguments)
    }

    private static func bundle(for language: String?) -> Bundle {
        guard let language else { return resourceBundle }
        // Explicit language lookup is used by localization validation. The normal UI
        // leaves this nil so Foundation follows the user's macOS language preference.
        let url = resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language)
            ?? resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en")
        return url.flatMap { Bundle(url: $0.deletingLastPathComponent()) } ?? resourceBundle
    }
}
