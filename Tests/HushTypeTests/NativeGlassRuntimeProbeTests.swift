import AppKit
import QuartzCore
import SwiftUI
import XCTest
import ExceptionCatcher
@testable import HushType

/// A one-shot runtime inventory for the system-owned layers behind
/// `NSGlassEffectView`. It deliberately does not assume that a private
/// `glassBackground` filter exists in every macOS build.
final class NativeGlassRuntimeProbeTests: XCTestCase {
    @MainActor
    func testControlCenterGuidePreservesOpticalPresetWithoutChangingKeyWindow() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires ControlCenter glass") }
        _ = NSApplication.shared
        let keyWindowBefore = NSApp.keyWindow
        let guide = FloatingOverlaySnapTargetWindow()
        defer { guide.hide() }

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            guide.appearance = NSAppearance(named: appearance)
            guide.show(frame: NSRect(x: 360, y: 200, width: 240, height: 48), opacity: 1)
            guide.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            CATransaction.flush()
            XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
            XCTAssertFalse(guide.isKeyWindow)
            XCTAssertFalse(guide.canBecomeKey)
            XCTAssertFalse(guide.canBecomeMain)
            XCTAssertTrue(guide.ignoresMouseEvents)

            var optics: [String: Double] = [:]
            for layer in recursiveLayers(from: guide.contentView?.layer) {
                for case let filter as NSObject in layer.filters ?? [] {
                    let keys = safely {
                        filter.perform(NSSelectorFromString("inputKeys"))?.takeUnretainedValue() as? [String]
                    } ?? nil
                    guard keys?.contains("inputOuterRefractionAmount") == true else { continue }
                    for key in ["inputOuterRefractionAmount", "inputOuterRefractionHeight", "inputBlurOpacity1"] {
                        if let value: NSNumber = safely({ filter.value(forKey: key) as? NSNumber }) ?? nil {
                            optics[key] = value.doubleValue
                        }
                    }
                }
            }
            XCTAssertGreaterThan(try XCTUnwrap(optics["inputOuterRefractionAmount"]), 0)
            XCTAssertGreaterThan(try XCTUnwrap(optics["inputOuterRefractionHeight"]), 0)
            XCTAssertLessThan(try XCTUnwrap(optics["inputBlurOpacity1"]), 1,
                              "The inactive uniform blur is not the accepted ControlCenter preset")
            guide.hide()
        }
    }

    @MainActor
    func testControlCenterGuideRendersResizesAndFadesWithoutTakingFocus() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires native glass") }
        _ = NSApplication.shared
        let window = FloatingOverlaySnapTargetWindow()
        defer { window.hide() }
        let initial = NSRect(x: 100, y: 100, width: 240, height: 48)
        window.show(frame: initial, opacity: 1)
        let host = try XCTUnwrap(window.contentView as? FloatingOverlayGlassView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        CATransaction.flush()
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertEqual(host.bounds.size, initial.size)
        let layers = recursiveLayers(from: host.layer)
        XCTAssertTrue(layers.contains { NSStringFromClass(type(of: $0)).contains("Backdrop") },
                      "The SPI material must create a live system backdrop")
        XCTAssertFalse(layers.contains { $0.name == "HushType.GuideBlur" })

        let resized = NSRect(x: 130, y: 110, width: 280, height: 56)
        window.show(frame: resized, opacity: 0.25)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame, resized)
        XCTAssertEqual(host.bounds.size, resized.size)
        XCTAssertEqual(window.alphaValue, 0.25, accuracy: 0.001)
        window.show(frame: resized, opacity: 0)
        XCTAssertEqual(window.alphaValue, 0, accuracy: 0.001)
        window.hide()
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testReportsNativeGlassBackdropAndRefractionCapabilities() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSGlassEffectView requires macOS 26")
        }

        _ = NSApplication.shared
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 72))
        glass.style = .clear
        glass.cornerRadius = 16
        glass.tintColor = .clear
        XCTAssertTrue(setNativeVariant(on: glass, variant: 19), "Variant 19 must reach set_variant:")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 72),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = glass
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        glass.layoutSubtreeIfNeeded()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(100))
        glass.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let selector = NSSelectorFromString("set_variant:")
        let backdropLayers = recursiveLayers(from: glass.layer).filter {
            NSStringFromClass(type(of: $0)).contains("CABackdropLayer")
        }
        let reports = backdropLayers.flatMap { self.reports(for: $0) }
        let refractionKeys = Set([
            "inputInnerRefractionAmount",
            "inputInnerRefractionHeight",
            "inputOuterRefractionAmount",
            "inputOuterRefractionHeight",
        ])
        let supportingFilters = reports.filter { refractionKeys.isSubset(of: Set($0.inputKeys)) }
        let readable = !supportingFilters.isEmpty && supportingFilters.allSatisfy { $0.readbackSucceeded }
        let backdropTuning = backdropLayers.allSatisfy { supportsBackdropTuning(on: $0) }

        let filterSummary = reports.map { $0.summary }.joined(separator: " | ")
        print("Native glass probe: variant19=true selector=\(glass.responds(to: selector)) backdrops=\(backdropLayers.count) backdropGaussian0Saturation1=\(backdropTuning) filters=\(filterSummary) refractionFilters=\(supportingFilters.count) refractionChangedReadbackAndRestore=\(readable)")

        XCTAssertTrue(glass.responds(to: selector), "Native variants require NSGlassEffectView.set_variant:")
        XCTAssertFalse(backdropLayers.isEmpty, "The visible native glass should create a CABackdropLayer")
    }

    private struct FilterReport {
        let className: String
        let inputKeys: [String]
        let readbackSucceeded: Bool

        var summary: String {
            "\(className)[\(inputKeys.sorted().joined(separator: ","))]"
        }
    }

    private func recursiveLayers(from root: CALayer?) -> [CALayer] {
        guard let root else { return [] }
        return [root] + (root.sublayers ?? []).flatMap { recursiveLayers(from: $0) }
    }

    private func reports(for backdrop: CALayer) -> [FilterReport] {
        let filters: [NSObject] = safely {
            (backdrop.value(forKey: "filters") as? [NSObject]) ?? []
        } ?? []
        return filters.map { filter in
            let keys: [String] = safely {
                let selector = NSSelectorFromString("inputKeys")
                return (filter.perform(selector)?.takeUnretainedValue() as? [String]) ?? []
            } ?? []
            let refractionKeys = [
                "inputInnerRefractionAmount",
                "inputInnerRefractionHeight",
                "inputOuterRefractionAmount",
                "inputOuterRefractionHeight",
            ]
            let canReadBack = refractionKeys.allSatisfy { key in
                keys.contains(key) && safely {
                    guard let baseline = filter.value(forKey: key) as? NSNumber else { return false }
                    guard let copy = (filter as? NSCopying)?.copy(with: nil) as? NSObject,
                          copy !== filter else { return false }
                    let changed = NSNumber(value: baseline.doubleValue + 0.125)
                    copy.setValue(changed, forKey: key)
                    let changedReadback = (copy.value(forKey: key) as? NSNumber)?.doubleValue
                    let restored = (filter.value(forKey: key) as? NSNumber)?.doubleValue
                    return changedReadback == changed.doubleValue && restored == baseline.doubleValue
                } == true
            }
            return FilterReport(
                className: NSStringFromClass(type(of: filter)),
                inputKeys: keys,
                readbackSucceeded: canReadBack
            )
        }
    }

    @available(macOS 26.0, *)
    private func setNativeVariant(on view: NSGlassEffectView, variant: Int) -> Bool {
        let selector = NSSelectorFromString("set_variant:")
        return safely {
            guard view.responds(to: selector), let implementation = view.method(for: selector) else {
                return false
            }
            typealias Setter = @convention(c) (NSObject, Selector, Int64) -> Void
            let setter = unsafeBitCast(implementation, to: Setter.self)
            setter(view, selector, Int64(variant))
            return true
        } == true
    }

    private func supportsBackdropTuning(on backdrop: CALayer) -> Bool {
        safely {
            backdrop.setValue(0, forKey: "gaussianRadius")
            backdrop.setValue(1, forKey: "saturationFactor")
            let gaussian = (backdrop.value(forKey: "gaussianRadius") as? NSNumber)?.doubleValue
            let saturation = (backdrop.value(forKey: "saturationFactor") as? NSNumber)?.doubleValue
            return gaussian == 0 && saturation == 1
        } == true
    }

    /// Invalid private KVC is an Objective-C exception. Every probe access is
    /// contained so an OS revision can only report "unsupported", never crash
    /// the app or the test process.
    private func safely<T>(_ body: () -> T) -> T? {
        var value: T?
        var error: NSError?
        let succeeded = HTCatchException({ value = body() }, &error)
        guard succeeded else {
            print("Native glass probe guarded exception: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return value
    }
}
