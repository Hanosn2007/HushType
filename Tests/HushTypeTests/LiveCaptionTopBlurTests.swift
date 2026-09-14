import AppKit
import SwiftUI
import XCTest
@testable import HushType

@MainActor
final class LiveCaptionTopBlurTests: XCTestCase {
    func testTranscriptClipMatchesBackdropInsetAndLeavesNoRawTextAtTopEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 180)
        for scale in [CGFloat(1), CGFloat(2)] {
            let geometry = LiveCaptionTopBlurGeometry(bounds: bounds, backingScale: scale)
            let path = LiveCaptionTopBlur.contentClipShape(backingScale: scale).path(in: bounds)
            let inset = LiveCaptionTopBlur.edgeInsetPixels / scale

            XCTAssertEqual(path.boundingRect.minX, geometry.backdropFrame.minX, accuracy: 0.001)
            XCTAssertEqual(path.boundingRect.maxX, geometry.backdropFrame.maxX, accuracy: 0.001)
            XCTAssertEqual(path.boundingRect.maxY, geometry.bandFrame.minY + geometry.panelFrameInBand.maxY, accuracy: 0.001)
            XCTAssertFalse(path.contains(CGPoint(x: bounds.midX, y: bounds.maxY - inset / 2)))
            XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: bounds.maxY - inset - 1)))
        }
    }

    func testTwoBackingPixelsBecomeOnePointAtTwoX() {
        let geometry = LiveCaptionTopBlurGeometry(
            bounds: CGRect(x: 0, y: 0, width: 400, height: 160),
            backingScale: 2
        )

        XCTAssertEqual(geometry.bandFrame, CGRect(x: 0, y: 128, width: 400, height: 32))
        XCTAssertEqual(geometry.backdropFrame, CGRect(x: 1, y: 1, width: 398, height: 30))
        XCTAssertEqual(geometry.panelFrameInBand.maxY, 31)
        XCTAssertEqual(geometry.panelFrameInBackdrop.maxY, 30)
        XCTAssertEqual(geometry.clippedCornerRadius, 15)
        XCTAssertTrue(geometry.hasVisibleRegion)
    }

    func testTwoBackingPixelsBecomeTwoPointsAtOneX() {
        let geometry = LiveCaptionTopBlurGeometry(
            bounds: CGRect(x: 0, y: 0, width: 400, height: 160),
            backingScale: 1
        )

        XCTAssertEqual(geometry.backdropFrame, CGRect(x: 2, y: 2, width: 396, height: 28))
        XCTAssertEqual(geometry.panelFrameInBand.maxY, 30)
        XCTAssertEqual(geometry.panelFrameInBackdrop.maxY, 28)
        XCTAssertEqual(geometry.clippedCornerRadius, 14)
    }

    func testTopBandKeepsFullPanelCornerGeometry() {
        let geometry = LiveCaptionTopBlurGeometry(
            bounds: CGRect(x: 0, y: 0, width: 480, height: 240),
            backingScale: 2
        )

        XCTAssertEqual(geometry.bandBounds.height, LiveCaptionTopBlur.height)
        XCTAssertEqual(geometry.panelFrameInBand.height, 238)
        XCTAssertEqual(geometry.panelFrameInBand.minY, -207)
        XCTAssertEqual(geometry.panelFrameInBand.maxY, 31)
    }

    func testRadiusMaskIsNarrowAndReusableAcrossGeometryUpdates() throws {
        let mask = try XCTUnwrap(LiveCaptionTopBlur.BackdropView.radiusMaskImage)
        XCTAssertEqual(mask.width, 1)
        XCTAssertEqual(mask.height, 256)

        let view = LiveCaptionTopBlur.BackdropView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        view.layoutSubtreeIfNeeded()
        let firstBackdrop = backdropLayer(in: view.layer)

        view.frame = CGRect(x: 0, y: 0, width: 640, height: 240)
        view.layoutSubtreeIfNeeded()
        let secondBackdrop = backdropLayer(in: view.layer)

        if let firstBackdrop, let secondBackdrop {
            XCTAssertTrue(firstBackdrop === secondBackdrop)
        } else {
            XCTAssertNil(firstBackdrop)
            XCTAssertNil(secondBackdrop)
        }
    }

    private func backdropLayer(in layer: CALayer?) -> CALayer? {
        guard let layer else { return nil }
        if NSStringFromClass(type(of: layer)).contains("CABackdropLayer") {
            return layer
        }
        for child in layer.sublayers ?? [] {
            if let match = backdropLayer(in: child) { return match }
        }
        return nil
    }
}
