import CoreServices
import Foundation

/// Carries the narrow intent to show Settings across a Sparkle-installed
/// process replacement. The target build is part of the value so a marker
/// left behind by an interrupted update cannot affect an ordinary launch.
enum UpdateRelaunchIntent {
    private static let recordKey = "hushtype.openSettingsAfterUpdate.record"
    /// A Sparkle handoff normally takes seconds. Keeping this narrow limits an
    /// interrupted handoff from changing a later ordinary launch.
    static let maximumAge: TimeInterval = 60

    private enum RecordKey {
        static let targetBuild = "targetBuild"
        static let systemUptime = "systemUptime"
    }

    /// Call only from Sparkle's immediate pre-relaunch delegate callback.
    /// Synchronizing is intentional: Sparkle terminates this process directly
    /// after the callback returns.
    static func markForRelaunch(
        targetBuild: String,
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        defaults: UserDefaults = .standard
    ) {
        guard !targetBuild.isEmpty else { return }
        defaults.set([
            RecordKey.targetBuild: targetBuild,
            RecordKey.systemUptime: systemUptime,
        ], forKey: recordKey)
        defaults.synchronize()
    }

    /// Consumes the marker regardless of its result. Build equality verifies
    /// the installed payload, not the launch cause: Login Item launches are
    /// explicitly excluded via the system's open-application AppleEvent. The
    /// monotonic uptime both bounds the handoff and expires records after a
    /// reboot, when uptime becomes smaller than the stored value.
    static func consumeIfMatching(
        currentBuild: String?,
        isLoginItemLaunch: Bool,
        silentRelaunch: Bool = false,
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let record = defaults.dictionary(forKey: recordKey),
              let targetBuild = record[RecordKey.targetBuild] as? String,
              let markedUptime = record[RecordKey.systemUptime] as? TimeInterval
        else {
            return false
        }
        defaults.removeObject(forKey: recordKey)
        defaults.synchronize()
        let age = systemUptime - markedUptime
        return !isLoginItemLaunch
            && !silentRelaunch
            && targetBuild == currentBuild
            && age >= 0
            && age <= maximumAge
    }

}

/// Apple's public launch AppleEvent marks Login Items with this parameter.
/// The check is deliberately strict: unrelated events never suppress normal
/// update-relaunch presentation.
enum AppLaunchReason {
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication)
        else {
            return false
        }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }
}
