import Foundation

enum CoreLocalization {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Folivyn_EditorCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static func string(_ key: String, bundle: Bundle = CoreLocalization.bundle, arguments: [CVarArg] = []) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
