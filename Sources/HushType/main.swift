import AppKit
import SwiftUI

NSApplication.shared.setActivationPolicy(.accessory)

if #available(macOS 26.0, *) {
    HushTypeSceneApplication.main()
} else {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
