import Foundation

enum ProfileEditorPreferences {
    static let autosaveKey = "hushtype.profiles.autosave"
    static var autosaveEnabled: Bool {
        UserDefaults.standard.object(forKey: autosaveKey) as? Bool ?? true
    }
}
