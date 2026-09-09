import Foundation

struct TextInsertionConfiguration: Equatable {
    enum Method: String { case clipboard, unicode }
    static let methodKey = "hushtype.input.method"
    static let batchSizeKey = "hushtype.input.unicodeBatchSize"
    static let intervalKey = "hushtype.input.unicodeIntervalMilliseconds"
    static let restoreDelayKey = "hushtype.input.clipboardRestoreMilliseconds"
    static let markersKey = "hushtype.input.temporaryClipboardMarkers"
    static let batchSizes = [1, 8, 20, 50, 100]
    static let intervals = [0, 1, 5, 10, 20, 50]
    static let restoreDelays = [100, 300, 500, 1000, 2000]

    let method: Method
    let unicodeBatchSize: Int
    let unicodeIntervalMilliseconds: Int
    let clipboardRestoreMilliseconds: Int
    let temporaryMarkers: Bool

    init(method: Method = .clipboard, unicodeBatchSize: Int = 100,
         unicodeIntervalMilliseconds: Int = 1, clipboardRestoreMilliseconds: Int = 500,
         temporaryMarkers: Bool = true) {
        self.method = method
        self.unicodeBatchSize = Self.batchSizes.contains(unicodeBatchSize) ? unicodeBatchSize : 100
        self.unicodeIntervalMilliseconds = Self.intervals.contains(unicodeIntervalMilliseconds) ? unicodeIntervalMilliseconds : 1
        self.clipboardRestoreMilliseconds = Self.restoreDelays.contains(clipboardRestoreMilliseconds) ? clipboardRestoreMilliseconds : 500
        self.temporaryMarkers = temporaryMarkers
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(method: defaults.string(forKey: methodKey).flatMap(Method.init(rawValue:)) ?? .clipboard,
             unicodeBatchSize: (defaults.object(forKey: batchSizeKey) as? Int) ?? 100,
             unicodeIntervalMilliseconds: (defaults.object(forKey: intervalKey) as? Int) ?? 1,
             clipboardRestoreMilliseconds: (defaults.object(forKey: restoreDelayKey) as? Int) ?? 500,
             temporaryMarkers: (defaults.object(forKey: markersKey) as? Bool) ?? true)
    }
}
