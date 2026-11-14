import UIKit
import Display
import ComponentFlow

/// Regular content material, distinct from the refractive glass used by controls.
/// The effect itself always has alpha 1; clipping belongs to its container.
final class ConceptProfileMaterialView: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let tint = UIView()
    private let solidBackground = UIView()
    let contentView = UIView()
    private var dark: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true
        self.layer.cornerCurve = .continuous
        self.blur.isUserInteractionEnabled = false
        self.tint.isUserInteractionEnabled = false
        self.solidBackground.isUserInteractionEnabled = false
        self.addSubview(self.blur)
        self.addSubview(self.tint)
        self.addSubview(self.solidBackground)
        self.addSubview(self.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateAppearance(tintColor: UIColor, targetColor: UIColor = .clear, fraction: CGFloat = 0.0, isDark: Bool) {
        if self.dark != isDark {
            self.dark = isDark
            self.blur.overrideUserInterfaceStyle = isDark ? .dark : .light
        }
        self.blur.isHidden = UIAccessibility.isReduceTransparencyEnabled
        if UIAccessibility.isReduceTransparencyEnabled {
            self.tint.backgroundColor = UIColor.secondarySystemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: isDark ? .dark : .light))
            self.solidBackground.alpha = 0.0
            self.blur.alpha = 0.0
        } else {
            self.tint.backgroundColor = tintColor
            self.solidBackground.backgroundColor = targetColor
            self.solidBackground.alpha = fraction
            self.blur.alpha = max(0.0, min(1.0, 1.0 - fraction))
        }
    }

    func updateAppearance(color: UIColor, isDark: Bool) {
        self.updateAppearance(tintColor: color, targetColor: .clear, fraction: 0.0, isDark: isDark)
    }

    func update(size: CGSize, radius: CGFloat, tintColor: UIColor, targetColor: UIColor = .clear, fraction: CGFloat = 0.0, isDark: Bool, transition: ContainedViewLayoutTransition) {
        self.updateAppearance(tintColor: tintColor, targetColor: targetColor, fraction: fraction, isDark: isDark)
        self.layer.cornerRadius = radius
        let bounds = CGRect(origin: .zero, size: size)
        transition.updateFrame(view: self.blur, frame: bounds)
        transition.updateFrame(view: self.tint, frame: bounds)
        transition.updateFrame(view: self.solidBackground, frame: bounds)
        transition.updateFrame(view: self.contentView, frame: bounds)
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
