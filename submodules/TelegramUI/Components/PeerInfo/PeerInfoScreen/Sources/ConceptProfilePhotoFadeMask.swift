import UIKit

/// Fade the gallery's sharp tail before its replicated reflection. The caller
/// continues to own the gallery frame, transforms and mask bounds.
final class ConceptProfilePhotoFadeMask: CAGradientLayer {
    private var geometry: (CGSize, CGRect)?

    override init() {
        super.init()
        self.colors = [UIColor.white.cgColor, UIColor.white.cgColor,
            UIColor(white: 1.0, alpha: 0.844).cgColor, UIColor(white: 1.0, alpha: 0.5).cgColor,
            UIColor(white: 1.0, alpha: 0.156).cgColor, UIColor.clear.cgColor]
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(size: CGSize, photoFrame: CGRect?) {
        let validPhoto = photoFrame.flatMap { $0.width.isFinite && $0.height.isFinite && $0.maxY.isFinite && $0.width > 0.0 && $0.height > 0.0 ? $0 : nil }
        // At a wrap the old index notification may precede the replacement node.
        // Never expose the reflected tail while waiting for its laid-out frame.
        if validPhoto == nil, self.geometry?.0 == size { return }
        let photo = validPhoto ?? CGRect(origin: .zero, size: size)
        if let geometry = self.geometry, geometry.0 == size, geometry.1 == photo { return }
        self.geometry = (size, photo)
        let height = max(1.0, size.height)
        let end = min(1.0, max(0.0, photo.maxY / height))
        let fade = min(end, max(1.0 / height, photo.height * 0.2 / height))
        self.locations = [0.0, NSNumber(value: Double(end - fade)),
            NSNumber(value: Double(end - fade * 0.75)), NSNumber(value: Double(end - fade * 0.5)),
            NSNumber(value: Double(end - fade * 0.25)), NSNumber(value: Double(end))]
    }
}
