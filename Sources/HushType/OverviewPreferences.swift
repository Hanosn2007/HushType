import Foundation

enum OverviewPreferences {
    static let developerModeKey = "hushtype.overview.developerMode"
    static let keepCaptionWindowKey = "hushtype.liveCaption.keepWindowAfterStopping"
    static let keepCaptionTextKey = "hushtype.liveCaption.keepTextOnRestart"

    static var keepsCaptionWindow: Bool { UserDefaults.standard.bool(forKey: keepCaptionWindowKey) }
    static var keepsCaptionText: Bool { UserDefaults.standard.bool(forKey: keepCaptionTextKey) }
}

enum OverviewTaskState: Equatable {
    case stopped, running, finishing
}
