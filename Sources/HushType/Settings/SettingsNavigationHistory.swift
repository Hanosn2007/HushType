import Foundation

struct SettingsNavigationHistory {
    private(set) var entries: [HushTypeSettingsSection] = [.overview]
    private(set) var index = 0
    var current: HushTypeSettingsSection { entries[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }

    mutating func visit(_ page: HushTypeSettingsSection) {
        guard page != current else { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(page)
        index += 1
    }
    mutating func back() -> HushTypeSettingsSection? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }
    mutating func forward() -> HushTypeSettingsSection? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}
