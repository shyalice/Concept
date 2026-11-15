import UIKit
import Display
import ComponentFlow

/// Regular content material, distinct from the refractive glass used by controls.
/// The effect itself always has alpha 1; clipping belongs to its container.
final class ConceptProfileMaterialView: UIView {
    private struct Appearance: Equatable {
        let tintColor: UIColor
        let targetColor: UIColor
        let fraction: CGFloat
        let isDark: Bool
        let reduceTransparency: Bool
    }
    private let blur = ConceptContactsMaterialView()
    private let tint = UIView()
    private let solidBackground = UIView()
    let contentView = UIView()
    private var appearance: Appearance?
    private var geometry: (CGSize, CGFloat)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerCurve = .continuous
        self.tint.layer.cornerCurve = .continuous
        self.solidBackground.layer.cornerCurve = .continuous
        self.blur.isUserInteractionEnabled = false
        self.tint.isUserInteractionEnabled = false
        self.solidBackground.isUserInteractionEnabled = false
        self.addSubview(self.blur)
        self.addSubview(self.tint)
        self.addSubview(self.solidBackground)
        self.addSubview(self.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateAppearance(tintColor: UIColor, targetColor: UIColor = .clear, fraction: CGFloat = 0.0, isDark: Bool, transition: ContainedViewLayoutTransition = .immediate) {
        let appearance = Appearance(tintColor: tintColor, targetColor: targetColor, fraction: max(0.0, min(1.0, fraction)), isDark: isDark, reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
        guard appearance != self.appearance else { return }
        let transition: ContainedViewLayoutTransition = self.appearance == nil ? .immediate : transition
        self.appearance = appearance
        self.blur.isHidden = appearance.reduceTransparency
        if appearance.reduceTransparency {
            let fallback = UIColor.secondarySystemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: isDark ? .dark : .light))
            transition.updateBackgroundColor(layer: self.tint.layer, color: fallback)
            transition.updateAlpha(layer: self.solidBackground.layer, alpha: 0.0)
        } else {
            transition.updateBackgroundColor(layer: self.tint.layer, color: ConceptContactsMaterialView.nativeAvailable ? .clear : tintColor)
            self.blur.update(radius: self.geometry?.1 ?? 24.0, isDark: isDark)
            transition.updateBackgroundColor(layer: self.solidBackground.layer, color: targetColor)
            // Cover the stable blur with the actual application theme when collapsing.
            // Fading the effect itself or swapping its appearance produces brightness flashes.
            transition.updateAlpha(layer: self.solidBackground.layer, alpha: appearance.fraction)
        }
    }

    func updateAppearance(color: UIColor, isDark: Bool, transition: ContainedViewLayoutTransition = .immediate) {
        self.updateAppearance(tintColor: color, targetColor: .clear, fraction: 0.0, isDark: isDark, transition: transition)
    }

    func updateLayout(size: CGSize, radius: CGFloat, transition: ContainedViewLayoutTransition) {
        if let geometry = self.geometry, geometry.0 == size, geometry.1 == radius { return }
        self.geometry = (size, radius)
        self.tint.layer.cornerRadius = radius
        self.solidBackground.layer.cornerRadius = radius
        let bounds = CGRect(origin: .zero, size: size)
        transition.updateFrame(view: self.blur, frame: bounds)
        self.blur.update(radius: radius, isDark: self.appearance?.isDark ?? false)
        transition.updateFrame(view: self.tint, frame: bounds)
        transition.updateFrame(view: self.solidBackground, frame: bounds)
        transition.updateFrame(view: self.contentView, frame: bounds)
    }

    func update(size: CGSize, radius: CGFloat, tintColor: UIColor, targetColor: UIColor = .clear, fraction: CGFloat = 0.0, isDark: Bool, transition: ContainedViewLayoutTransition) {
        self.updateAppearance(tintColor: tintColor, targetColor: targetColor, fraction: fraction, isDark: isDark, transition: transition)
        self.updateLayout(size: size, radius: radius, transition: transition)
    }

    func update(size: CGSize, radius: CGFloat, color: UIColor, isDark: Bool, transition: ContainedViewLayoutTransition) {
        self.update(size: size, radius: radius, tintColor: color, targetColor: .clear, fraction: 0.0, isDark: isDark, transition: transition)
    }
}
