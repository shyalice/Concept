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
    private let blur = BlurredBackgroundView(color: nil)
    private let tint = UIView()
    private let solidBackground = UIView()
    let contentView = UIView()
    private var appearance: Appearance?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true
        self.layer.cornerCurve = .continuous
        self.blur.updateColor(color: .clear, forceKeepBlur: true, transition: .immediate)
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
            transition.updateBackgroundColor(layer: self.tint.layer, color: tintColor)
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
        self.layer.cornerRadius = radius
        let bounds = CGRect(origin: .zero, size: size)
        transition.updateFrame(view: self.blur, frame: bounds)
        self.blur.update(size: size, transition: transition)
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

final class ConceptProfileMaterialComponent: Component {
    let isDark: Bool
    let fallbackColor: UIColor
    init(isDark: Bool, fallbackColor: UIColor) {
        self.isDark = isDark
        self.fallbackColor = fallbackColor
    }
    static func == (lhs: ConceptProfileMaterialComponent, rhs: ConceptProfileMaterialComponent) -> Bool {
        return lhs.isDark == rhs.isDark && lhs.fallbackColor.isEqual(rhs.fallbackColor)
    }
    final class View: UIView {
        let material = ConceptProfileMaterialView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            self.isUserInteractionEnabled = false
            self.clipsToBounds = true
            self.layer.cornerCurve = .continuous
            self.addSubview(self.material)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    func makeView() -> View { return View(frame: .zero) }
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        transition.setFrame(view: view.material, frame: CGRect(origin: .zero, size: availableSize))
        view.material.update(size: availableSize, radius: availableSize.height * 0.5, color: self.fallbackColor, isDark: self.isDark, transition: .immediate)
        return availableSize
    }
}
