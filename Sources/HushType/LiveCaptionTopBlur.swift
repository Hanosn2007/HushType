import AppKit
import QuartzCore
import SwiftUI

/// A compositor-backed progressive blur for the fixed Live Caption header.
///
/// The backdrop stays in the live layer tree for the panel's full lifetime, so
/// changing content or moving between desktop backgrounds does not replace it
/// with a SwiftUI scroll-edge snapshot. The private runtime classes are optional:
/// the panel's existing HUD material remains the complete fallback.
struct LiveCaptionTopBlur: NSViewRepresentable {
    static let height: CGFloat = 32
    static let cornerRadius: CGFloat = 16
    static let edgeInsetPixels: CGFloat = 2
    static let radius: CGFloat = 30

    /// Keep raw transcript pixels inside the same boundary as the backdrop.
    /// Otherwise the inset reserved around the blur exposes a sharp text strip.
    static func contentClipShape(backingScale: CGFloat) -> some Shape {
        let scale = max(1, backingScale.isFinite ? backingScale : 2)
        return RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
            .inset(by: edgeInsetPixels / scale)
    }

    func makeNSView(context _: Context) -> BackdropView {
        BackdropView()
    }

    func updateNSView(_ view: BackdropView, context _: Context) {
        view.updateGeometry()
    }

    final class BackdropView: NSView {
        private let blurStage = CALayer()
        private let sourceClip = CAShapeLayer()
        private let outputClip = CAShapeLayer()
        private let outputBandClip = CAShapeLayer()
        private let tintStage = CALayer()
        private let tintGradient = CAGradientLayer()
        private let tintClip = CAShapeLayer()
        private let tintBandClip = CAShapeLayer()
        private var backdrop: CALayer?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true

            outputClip.mask = outputBandClip
            blurStage.mask = outputClip
            layer?.addSublayer(blurStage)

            tintClip.mask = tintBandClip
            tintStage.mask = tintClip
            tintStage.addSublayer(tintGradient)
            layer?.addSublayer(tintStage)

            installBackdropIfAvailable()
            updateTintColors()
        }

        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is unsupported")
        }

        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            updateGeometry()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateGeometry()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateGeometry()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateTintColors()
            updateGeometry()
        }

        func updateGeometry() {
            let geometry = LiveCaptionTopBlurGeometry(
                bounds: bounds,
                backingScale: window?.backingScaleFactor ?? 2
            )

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            blurStage.frame = geometry.bandFrame
            tintStage.frame = geometry.bandFrame
            tintGradient.frame = geometry.bandBounds

            guard geometry.hasVisibleRegion, let backdrop else {
                blurStage.isHidden = true
                tintStage.isHidden = true
                return
            }

            blurStage.isHidden = false
            tintStage.isHidden = false
            backdrop.frame = geometry.backdropFrame
            backdrop.setValue(geometry.backingScale, forKey: "scale")

            sourceClip.frame = backdrop.bounds
            sourceClip.path = CGPath(
                roundedRect: geometry.panelFrameInBackdrop,
                cornerWidth: geometry.clippedCornerRadius,
                cornerHeight: geometry.clippedCornerRadius,
                transform: nil
            )
            backdrop.mask = sourceClip

            applyOutputPath(
                clip: outputClip,
                bandClip: outputBandClip,
                geometry: geometry
            )
            applyOutputPath(
                clip: tintClip,
                bandClip: tintBandClip,
                geometry: geometry
            )
        }

        private func installBackdropIfAvailable() {
            guard let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
                  let filter = Self.makeVariableBlurFilter(),
                  let mask = Self.radiusMaskImage
            else {
                blurStage.isHidden = true
                tintStage.isHidden = true
                return
            }

            filter.setValue(LiveCaptionTopBlur.radius, forKey: "inputRadius")
            filter.setValue(mask, forKey: "inputMaskImage")
            filter.setValue(true, forKey: "inputNormalizeEdges")

            let backdrop = backdropType.init()
            // Configure a fresh filter before attaching it. The render server
            // does not reliably notice mutations to a filter already installed.
            backdrop.filters = [filter]
            blurStage.addSublayer(backdrop)
            self.backdrop = backdrop
        }

        private func applyOutputPath(
            clip: CAShapeLayer,
            bandClip: CAShapeLayer,
            geometry: LiveCaptionTopBlurGeometry
        ) {
            clip.frame = geometry.bandBounds
            clip.path = CGPath(
                roundedRect: geometry.panelFrameInBand,
                cornerWidth: geometry.clippedCornerRadius,
                cornerHeight: geometry.clippedCornerRadius,
                transform: nil
            )
            bandClip.frame = geometry.bandBounds
            bandClip.path = CGPath(rect: geometry.backdropFrame, transform: nil)
        }

        private func updateTintColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let base = NSColor.windowBackgroundColor
                let samples = 32
                tintGradient.colors = (0...samples).map { index in
                    let normalized = CGFloat(index) / CGFloat(samples)
                    let inverse = 1 - normalized
                    let opacity = 0.35 * inverse * inverse * (3 - 2 * inverse)
                    return base.withAlphaComponent(opacity).cgColor
                }
                tintGradient.locations = (0...samples).map {
                    NSNumber(value: Double($0) / Double(samples))
                }
                tintGradient.startPoint = CGPoint(x: 0.5, y: 1)
                tintGradient.endPoint = CGPoint(x: 0.5, y: 0)
            }
        }

        private static func makeVariableBlurFilter() -> NSObject? {
            let factory = NSSelectorFromString("filterWithType:")
            let keysSelector = NSSelectorFromString("inputKeys")
            guard let type = NSClassFromString("CAFilter") as? NSObject.Type,
                  type.responds(to: factory),
                  let filter = type.perform(factory, with: "variableBlur")?.takeUnretainedValue() as? NSObject,
                  filter.responds(to: keysSelector),
                  let keys = filter.perform(keysSelector)?.takeUnretainedValue() as? [String],
                  Set(["inputRadius", "inputMaskImage", "inputNormalizeEdges"]).isSubset(of: Set(keys))
            else { return nil }
            return filter
        }

        /// The filter stretches this narrow mask across its bounds. Keeping it
        /// independent of panel width avoids raster work during frame animation.
        static let radiusMaskImage: CGImage? = {
            let width = 1
            let height = 256
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            let gradient = CAGradientLayer()
            gradient.frame = CGRect(x: 0, y: 0, width: width, height: height)
            gradient.colors = [
                NSColor.black.withAlphaComponent(0.1).cgColor,
                NSColor.black.withAlphaComponent(0).cgColor,
            ]
            gradient.locations = [0, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.render(in: context)
            return context.makeImage()
        }()
    }
}

/// Pure geometry kept separate from the private Core Animation objects so the
/// backing-pixel inset and full-panel corner alignment can be unit tested.
struct LiveCaptionTopBlurGeometry: Equatable {
    let bandFrame: CGRect
    let bandBounds: CGRect
    let backdropFrame: CGRect
    let panelFrameInBand: CGRect
    let panelFrameInBackdrop: CGRect
    let clippedCornerRadius: CGFloat
    let backingScale: CGFloat

    var hasVisibleRegion: Bool {
        backdropFrame.width > 0 && backdropFrame.height > 0
    }

    init(bounds: CGRect, backingScale requestedScale: CGFloat) {
        let scale = max(1, requestedScale.isFinite ? requestedScale : 2)
        let inset = LiveCaptionTopBlur.edgeInsetPixels / scale
        let bandHeight = min(LiveCaptionTopBlur.height, max(0, bounds.height))
        let width = max(0, bounds.width)

        backingScale = scale
        bandFrame = CGRect(
            x: 0,
            y: max(0, bounds.height - bandHeight),
            width: width,
            height: bandHeight
        )
        bandBounds = CGRect(x: 0, y: 0, width: width, height: bandHeight)
        backdropFrame = bandBounds.insetBy(dx: inset, dy: inset)
        panelFrameInBand = CGRect(
            x: inset,
            y: bandHeight - bounds.height + inset,
            width: max(0, width - 2 * inset),
            height: max(0, bounds.height - 2 * inset)
        )
        panelFrameInBackdrop = panelFrameInBand.offsetBy(
            dx: -backdropFrame.minX,
            dy: -backdropFrame.minY
        )
        clippedCornerRadius = max(0, LiveCaptionTopBlur.cornerRadius - inset)
    }
}
