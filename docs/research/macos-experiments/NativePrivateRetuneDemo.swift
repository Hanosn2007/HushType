import AppKit
import SwiftUI
import QuartzCore

// Stand-alone diagnostic only. CABackdropLayer and CAFilter are resolved at
// runtime because neither is a public API contract.

private enum ScrollBlurDynamics {
    static let speedForMinimumRadius: CGFloat = 1_800
    static let speedTau: CFTimeInterval = 0.10
    static let liveRadiusTau: CFTimeInterval = 0.16
    static let idleDelay: TimeInterval = 0.10
    static let speedDecayTau: CFTimeInterval = 0.25
    static let idleRadiusTau: CFTimeInterval = 0.24
    static let idleTick: TimeInterval = 1.0 / 30.0

    static func targetRadius(speed: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let low = min(minimum, maximum)
        let high = max(minimum, maximum)
        let t = min(1, max(0, abs(speed) / speedForMinimumRadius))
        let smoothstep = t * t * (3 - 2 * t)
        return high - (high - low) * smoothstep
    }

    static func approach(_ current: CGFloat, _ target: CGFloat, elapsed: CFTimeInterval, tau: CFTimeInterval) -> CGFloat {
        guard elapsed > 0, tau > 0 else { return current }
        return current + (target - current) * (1 - CGFloat(exp(-elapsed / tau)))
    }
}

private struct BlurConfiguration: Equatable {
    var minimumRadius: CGFloat = 10.5
    var maximumRadius: CGFloat = 30
    var strength: CGFloat = 0.10
    var height: CGFloat = 72
    var tail: CGFloat = 24
    var smoothMask = true
    var continuous = true
    var tint = false
}

private struct MaskSpec: Equatable {
    let width: Int
    let height: Int
    let strength: CGFloat
    let smooth: Bool
}

private final class BackdropOverlay: NSView {
    private let backdrop: CALayer?
    private var filter: NSObject?
    private let tintLayer = CAGradientLayer()
    private var maskSpec: MaskSpec?
    private var maskImage: CGImage?
    private var configuration = BlurConfiguration()
    private var originalComparison = false
    private var currentRadius: CGFloat = 30
    private var filteredSpeed: CGFloat = 0
    private var lastSample: (offset: CGFloat, time: CFTimeInterval)?
    private var lastMotionTime: CFTimeInterval = 0
    private var settlingTimer: Timer?
    private var availability: ((Bool) -> Void)?

    init(availability: @escaping (Bool) -> Void) {
        self.availability = availability
        let factory = NSSelectorFromString("filterWithType:")
        if let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
           filterType.responds(to: factory),
           let filter = filterType.perform(factory, with: "variableBlur")?.takeUnretainedValue() as? NSObject,
           let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type {
            let backdrop = backdropType.init()
            backdrop.filters = [filter] // One layer, one variableBlur filter: intentionally no parent/filter stage.
            self.filter = filter
            self.backdrop = backdrop
        } else {
            self.backdrop = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        if let backdrop { layer?.addSublayer(backdrop) }
        layer?.addSublayer(tintLayer)
        availability(backdrop != nil && filter != nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { settlingTimer?.invalidate() }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); updateFramesAndMaskIfNeeded() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateFramesAndMaskIfNeeded() }

    func apply(_ next: BlurConfiguration, originalComparison: Bool) {
        let old = configuration
        configuration = next
        self.originalComparison = originalComparison
        if originalComparison {
            currentRadius = 18
        } else if !next.continuous {
            currentRadius = next.maximumRadius
            filteredSpeed = 0
            stopSettling()
        } else if old.minimumRadius != next.minimumRadius || old.maximumRadius != next.maximumRadius {
            // Editing the resting radius must take effect without another scroll.
            currentRadius = ScrollBlurDynamics.targetRadius(speed: filteredSpeed, minimum: next.minimumRadius, maximum: next.maximumRadius)
        }
        updateFramesAndMaskIfNeeded()
        applyRadius(currentRadius)
    }

    func scrollDidMove(to offset: CGFloat, originalComparison: Bool) {
        guard !originalComparison, configuration.continuous else { return }
        let now = CACurrentMediaTime()
        guard let previous = lastSample else {
            lastSample = (offset, now)
            return
        }
        lastSample = (offset, now)
        let elapsed = now - previous.time
        let distance = abs(offset - previous.offset)
        guard elapsed > 0, elapsed < 0.35, distance > 0.2 else { return }
        filteredSpeed = ScrollBlurDynamics.approach(filteredSpeed, distance / elapsed, elapsed: elapsed, tau: ScrollBlurDynamics.speedTau)
        let target = ScrollBlurDynamics.targetRadius(speed: filteredSpeed, minimum: configuration.minimumRadius, maximum: configuration.maximumRadius)
        currentRadius = ScrollBlurDynamics.approach(currentRadius, target, elapsed: elapsed, tau: ScrollBlurDynamics.liveRadiusTau)
        applyRadius(currentRadius)
        lastMotionTime = now
        scheduleSettling()
    }

    private func scheduleSettling() {
        if let settlingTimer {
            settlingTimer.fireDate = Date(timeIntervalSinceNow: ScrollBlurDynamics.idleDelay)
            return
        }
        let timer = Timer(timeInterval: ScrollBlurDynamics.idleTick, repeats: true) { [weak self] timer in
            self?.settle(timer)
        }
        timer.fireDate = Date(timeIntervalSinceNow: ScrollBlurDynamics.idleDelay)
        settlingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func settle(_ timer: Timer) {
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - lastMotionTime)
        lastMotionTime = now
        filteredSpeed = ScrollBlurDynamics.approach(filteredSpeed, 0, elapsed: elapsed, tau: ScrollBlurDynamics.speedDecayTau)
        let target = ScrollBlurDynamics.targetRadius(speed: filteredSpeed, minimum: configuration.minimumRadius, maximum: configuration.maximumRadius)
        currentRadius = ScrollBlurDynamics.approach(currentRadius, target, elapsed: elapsed, tau: ScrollBlurDynamics.idleRadiusTau)
        if filteredSpeed <= 1, abs(currentRadius - configuration.maximumRadius) <= 0.02 {
            currentRadius = configuration.maximumRadius
            filteredSpeed = 0
            stopSettling(timer)
        }
        applyRadius(currentRadius)
    }

    private func stopSettling(_ timer: Timer? = nil) {
        (timer ?? settlingTimer)?.invalidate()
        settlingTimer = nil
    }

    private func applyRadius(_ radius: CGFloat) {
        guard let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
              let nextFilter = filterType.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?.takeUnretainedValue() as? NSObject else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Use a fresh filter identity: reassigning an array containing the same
        // mutable CAFilter can still leave the render server's old values intact.
        nextFilter.setValue(radius, forKey: "inputRadius")
        nextFilter.setValue(maskImage, forKey: "inputMaskImage")
        nextFilter.setValue(true, forKey: "inputNormalizeEdges")
        filter = nextFilter
        backdrop?.filters = [nextFilter]
        CATransaction.commit()
    }

    private func updateFramesAndMaskIfNeeded() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let spec = MaskSpec(width: max(2, Int((bounds.width * scale).rounded())),
                            height: max(2, Int((bounds.height * scale).rounded())),
                            strength: configuration.strength,
                            smooth: !originalComparison && configuration.smoothMask)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        backdrop?.setValue(scale, forKey: "scale")
        tintLayer.frame = bounds
        tintLayer.isHidden = !configuration.tint
        tintLayer.startPoint = CGPoint(x: 0.5, y: 1)
        tintLayer.endPoint = CGPoint(x: 0.5, y: 0)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tintLayer.colors = [
                NSColor.windowBackgroundColor.withAlphaComponent(0.24).cgColor,
                NSColor.windowBackgroundColor.withAlphaComponent(0).cgColor
            ]
        }
        if spec != maskSpec {
            maskImage = Self.makeMask(spec)
            maskSpec = spec
            applyRadius(currentRadius)
        }
        CATransaction.commit()
    }

    private static func makeMask(_ spec: MaskSpec) -> CGImage? {
        guard let context = CGContext(data: nil, width: spec.width, height: spec.height,
                                      bitsPerComponent: 8, bytesPerRow: spec.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let total = CGFloat(spec.height)
        // The source snapshot creates a black radius mask. The last tail points
        // extend the band so a smooth edge can end flat instead of looking cut off.
        for row in 0..<spec.height {
            // CGContext rows go from the clear end (0) to the full-strength
            // top end (height - 1), as in the saved ProbeBackdrop implementation.
            let t = CGFloat(row) / max(1, total - 1)
            // Historical variable-smooth snapshot: t = 1 - clamp(y), then
            // (exp(2t) - 1 - 2t) / (exp(2) - 3). It has zero slope at the
            // clear edge, unlike the linear comparison mask.
            let shaped: CGFloat
            if spec.smooth {
                let numerator = exp(2 * t) - 1 - 2 * t
                shaped = numerator / (exp(2) - 3)
            } else {
                shaped = t
            }
            let alpha = spec.strength * shaped
            context.setFillColor(CGColor(gray: 0, alpha: alpha))
            context.fill(CGRect(x: 0, y: row, width: spec.width, height: 1))
        }
        return context.makeImage()
    }

    var debugSingleLayerIsIntact: Bool {
        guard let backdrop, let filter else { return false }
        return backdrop.superlayer === layer && backdrop.filters?.count == 1 && (backdrop.filters?.first as AnyObject?) === filter
    }
    var debugConfigurationApplied: Bool { maskSpec?.strength == configuration.strength && maskSpec?.smooth == (!originalComparison && configuration.smoothMask) }
    var debugRadius: CGFloat { currentRadius }
}

private struct RowContent: View {
    let label: String
    var body: some View {
        VStack(spacing: 0) {
            ForEach(1...100, id: \.self) { row in
                HStack(spacing: 12) {
                    Image(systemName: row.isMultiple(of: 3) ? "waveform" : "slider.horizontal.3")
                        .foregroundStyle(row.isMultiple(of: 2) ? .blue : .purple)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(label) · 原生内容第 \(row) 项")
                        Text(row.isMultiple(of: 2) ? "滚动时可看顶部半径是否连续收缩" : "这里保留真实 SwiftUI 行内容与公开控件")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: .constant(row.isMultiple(of: 4))).labelsHidden()
                }
                .padding(.horizontal, 14).frame(height: 48)
                Divider()
            }
        }.padding(.top, 6)
    }
}

private final class NativeScrollPanel: NSView {
    private let glass = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let documentView: NSHostingView<RowContent>
    private let overlay: BackdropOverlay
    private let originalComparison: Bool
    private var clipObserver: NSObjectProtocol?
    var configuration = BlurConfiguration() {
        didSet {
            overlay.apply(configuration, originalComparison: originalComparison)
            needsLayout = true
        }
    }

    init(title: String, originalComparison: Bool, availability: @escaping (Bool) -> Void) {
        self.originalComparison = originalComparison
        overlay = BackdropOverlay(availability: availability)
        documentView = NSHostingView(rootView: RowContent(label: title))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        glass.material = .sidebar
        glass.blendingMode = .withinWindow
        glass.state = .active
        addSubview(glass)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)
        addSubview(overlay)
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                object: scrollView.contentView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.overlay.scrollDidMove(to: self.scrollView.contentView.bounds.origin.y, originalComparison: self.originalComparison)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        overlay.apply(configuration, originalComparison: originalComparison)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) } }
    override func layout() {
        super.layout()
        glass.frame = bounds
        scrollView.frame = bounds
        // Include dividers and padding in the fitting height; hard-coding only
        // the row heights compresses the document and cuts off its first row.
        documentView.setFrameSize(CGSize(width: max(1, scrollView.contentSize.width), height: documentView.frame.height))
        documentView.frame = CGRect(x: 0, y: 0, width: max(1, scrollView.contentSize.width),
                                    height: max(bounds.height, documentView.fittingSize.height))
        let visibleHeight = min(bounds.height, configuration.height + configuration.tail)
        overlay.frame = CGRect(x: 0, y: max(0, bounds.height - visibleHeight), width: bounds.width, height: visibleHeight)
    }
}

private struct PanelHost: NSViewRepresentable {
    let title: String
    let originalComparison: Bool
    let configuration: BlurConfiguration
    @Binding var available: Bool
    func makeNSView(context: Context) -> NativeScrollPanel {
        NativeScrollPanel(title: title, originalComparison: originalComparison) { isAvailable in
            DispatchQueue.main.async { available = isAvailable }
        }
    }
    func updateNSView(_ view: NativeScrollPanel, context: Context) { view.configuration = configuration }
}

private struct DemoView: View {
    @State private var minimum = 10.5
    @State private var maximum = 30.0
    @State private var strength = 0.10
    @State private var height = 72.0
    @State private var tail = 24.0
    @State private var smoothMask = true
    @State private var continuous = true
    @State private var tint = false
    @State private var baseAvailable = false
    @State private var smoothAvailable = false

    private var config: BlurConfiguration {
        BlurConfiguration(minimumRadius: minimum, maximumRadius: maximum, strength: strength,
                          height: height, tail: tail, smoothMask: smoothMask,
                          continuous: continuous, tint: tint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("原生私有可变模糊 · 早期效果重调").font(.title2.bold())
                    Text("系统原生背景模糊；两栏独立滚动。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text((baseAvailable && smoothAvailable) ? "私有接口已解析" : "私有接口不可用：未用染色伪装模糊")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle((baseAvailable && smoothAvailable) ? .green : .orange)
            }
            HStack(alignment: .top, spacing: 14) {
                panel(title: "基础效果", subtitle: "固定半径 18 · 线性渐变", original: true, available: $baseAvailable)
                panel(title: "平滑调参", subtitle: continuous ? "随本栏滚动连续改变模糊" : "已固定最大半径", original: false, available: $smoothAvailable)
                controls
            }
        }
        .padding(18)
        .frame(minWidth: 1120, minHeight: 620)
    }

    private func panel(title: String, subtitle: String, original: Bool, available: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            PanelHost(title: title, originalComparison: original, configuration: config, available: available)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.quaternary))
        }.frame(minWidth: 300, maxWidth: .infinity, minHeight: 520)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("平滑调参").font(.headline)
            slider("最小半径", value: $minimum, range: 0...60, step: 0.5, unit: "")
            slider("最大半径", value: $maximum, range: 0...60, step: 0.5, unit: "")
            slider("顶部强度", value: $strength, range: 0...1, step: 0.01, unit: "", decimals: 2)
            slider("效果高度", value: $height, range: 30...240, step: 1, unit: " pt", decimals: 0)
            slider("延长尾部", value: $tail, range: 0...80, step: 1, unit: " pt", decimals: 0)
            Divider()
            Toggle("空间平滑遮罩", isOn: $smoothMask)
            Toggle("随滚动连续变化", isOn: $continuous)
            Text("静止时使用最大半径；快速滚动时趋向最小半径。关闭连续变化可直接比较最大半径。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("染色（单独开关）", isOn: $tint)
            Divider()
            HStack(spacing: 8) {
                Button("早期参数") { applyEarlyParameters() }
                Button("后续实践") { applyLaterPractice() }
            }.controlSize(.small)
            Text("基础效果固定 radius 18 与线性遮罩；两栏共用高度、尾部与强度，便于同高比较。输出圆角是面板裁切，不表示滤镜输入已经排除边缘。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(width: 235, alignment: .topLeading)
    }

    private func applyEarlyParameters() {
        minimum = 18; maximum = 18; strength = 1; height = 72; tail = 24
        smoothMask = true; continuous = false; tint = false
    }

    private func applyLaterPractice() {
        minimum = 10.5; maximum = 30; strength = 0.10; height = 72; tail = 24
        smoothMask = true; continuous = true; tint = false
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String, decimals: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text(String(format: "%.\(decimals)f%@", value.wrappedValue, unit)).monospacedDigit().foregroundStyle(.secondary) }
                .font(.caption)
            Slider(value: value, in: range, step: step)
        }
    }
}

private enum SelfTest {
    static func run() -> Int32 {
        let config = BlurConfiguration()
        guard config.minimumRadius == 10.5, config.maximumRadius == 30,
              config.strength == 0.1, config.height == 72, config.tail == 24,
              config.continuous, !config.tint else {
            fputs("FAIL defaults\\n", stderr); return 1
        }
        let target = ScrollBlurDynamics.targetRadius(speed: 1_800, minimum: config.minimumRadius, maximum: config.maximumRadius)
        guard abs(target - config.minimumRadius) < 0.001 else { fputs("FAIL dynamics\\n", stderr); return 1 }
        var available = false
        let overlay = BackdropOverlay { available = $0 }
        overlay.frame = CGRect(x: 0, y: 0, width: 300, height: config.height + config.tail)
        overlay.apply(config, originalComparison: false)
        if available {
            guard overlay.debugSingleLayerIsIntact, overlay.debugConfigurationApplied else {
                fputs("FAIL private-layer structure/configuration\\n", stderr); return 1
            }
            var edited = config
            edited.maximumRadius = 60
            overlay.apply(edited, originalComparison: false)
            guard overlay.debugRadius == 60 else { fputs("FAIL idle radius edit\n", stderr); return 1 }
            edited.maximumRadius = 0
            edited.minimumRadius = 0
            edited.strength = 0
            overlay.apply(edited, originalComparison: false)
            guard overlay.debugRadius == 0, overlay.debugConfigurationApplied, overlay.debugSingleLayerIsIntact else {
                fputs("FAIL zero radius/strength edit\n", stderr); return 1
            }
            print("PASS: defaults, dynamics, one CABackdropLayer + one variableBlur, configuration application")
        } else {
            print("PASS: defaults/dynamics; private API unavailable is explicitly detected")
        }
        return 0
    }
}

@main
private struct NativePrivateRetuneApp: App {
    init() {
        if CommandLine.arguments.contains("--self-test") {
            let status = SelfTest.run()
            exit(status)
        }
    }
    var body: some Scene {
        WindowGroup("HushType · 原生模糊重新调参") { DemoView() }
            .windowResizability(.contentMinSize)
    }
}
