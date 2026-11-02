import AppKit
import QuartzCore
import SwiftUI

/// A looping layer animation run by Core Animation.
enum LoopMotion: Equatable {
    /// Scale between two sizes anchored at the bottom center, rising `lift` points at the peak.
    case breathe(from: CGSize, to: CGSize, lift: CGFloat)
    /// Fade between two opacities.
    case pulse(from: Float, to: Float)
}

/// Hosts SwiftUI content in a layer that loops with Core Animation. The loop runs in the render
/// server, so it costs no app CPU; a SwiftUI repeatForever loop re-renders at the display rate
/// (120 Hz) and cost ~5–8% CPU just to idle.
struct LayerLoop<Content: View>: NSViewRepresentable {
    var active: Bool
    var motion: LoopMotion
    var period: Double = 1.8
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> LoopHostView<Content> {
        LoopHostView(rootView: content)
    }

    func updateNSView(_ view: LoopHostView<Content>, context: Context) {
        view.rootView = content
        view.configure(LoopHostView<Content>.Config(active: active, motion: motion, period: period))
    }
}

final class LoopHostView<Content: View>: NSHostingView<Content> {
    struct Config: Equatable {
        var active: Bool, motion: LoopMotion, period: Double
    }

    private static var key: String { "loop" }
    private var config: Config?
    private var installedWidth: CGFloat = -1

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Mouse handling belongs to the window's pet view (drag, double-click, right-click).
    // Returning nil from hitTest doesn't fall through: the enclosing NSHostingView treats this
    // area as ours and the click passes through the transparent window. So take the hit and forward it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var petView: NSView? { window?.contentView }

    override func mouseDown(with event: NSEvent) { petView?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { petView?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { petView?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { petView?.rightMouseDown(with: event) }

    func configure(_ new: Config) {
        guard new != config else { return }
        config = new
        install()
    }

    override func layout() {
        super.layout()
        if bounds.width != installedWidth { install() }
    }

    private func install() {
        guard let layer, let config else { return }
        layer.removeAnimation(forKey: Self.key)
        installedWidth = bounds.width
        guard config.active, bounds.width > 0 else { return }

        let animation: CABasicAnimation
        switch config.motion {
        case .pulse(let from, let to):
            animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = to
        case .breathe(let from, let to, let lift):
            animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = breathTransform(from, rise: 0)
            animation.toValue = breathTransform(to, rise: lift)
        }
        animation.duration = config.period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.key)
    }

    private func breathTransform(_ s: CGSize, rise: CGFloat) -> CATransform3D {
        guard let layer else { return CATransform3DIdentity }

        // A layer transform is applied about its anchorPoint, in the superlayer's y-up space
        // (contentsAreFlipped only affects how content is drawn), so the bottom-center pivot is
        // y = 0 relative to the anchor. Verified by mapping the presentation layer's corners.
        let pivot = CGPoint(x: bounds.midX - layer.anchorPoint.x * bounds.width,
                            y: -layer.anchorPoint.y * bounds.height)
        var t = CATransform3DMakeTranslation(pivot.x, pivot.y + rise, 0)
        t = CATransform3DScale(t, s.width, s.height, 1)
        return CATransform3DTranslate(t, -pivot.x, -pivot.y, 0)
    }
}
