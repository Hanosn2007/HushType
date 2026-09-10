# ControlCenter material ABI interface

`SwiftUI_SPI.swiftinterface` exposes only the system declarations needed by the floating snap guide. SwiftPM imports this text interface through an absolute, single-argument `-I<path>` flag and compiles it into its module cache; no precompiled module is checked in. Keep the flag atomic: splitting `-I` from its repeated path can leave a dangling flag in SwiftPM's generated test runner.

The interface uses `-module-abi-name SwiftUI`, so the definitions link to the system SwiftUI implementation. It does not implement a replacement material. The guide is guarded by macOS 26 availability; earlier systems keep their existing regular-material fallback.

The native ControlCenter preset resolves differently for inactive windows. The snap-guide-only panel overrides AppKit's private `_hasActiveAppearance` query to preserve its optical appearance while retaining `canBecomeKey == false`, `canBecomeMain == false`, and mouse pass-through. Do not acquire real focus, override key-window identity, or rewrite the system filters. Public material-active-appearance modifiers did not override this private glass path on the tested system.

These private interfaces require revalidation when updating the supported OS/SDK. The runtime tests check that the nonkey guide keeps refraction and nonuniform blur in both appearances without changing the actual key window. Source declaration pattern reference: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Platform/spi/Cocoa/SwiftUI_SPI.swiftinterface
