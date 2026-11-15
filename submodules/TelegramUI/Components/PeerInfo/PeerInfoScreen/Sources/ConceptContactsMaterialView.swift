import UIKit
import SwiftUI
import Darwin

/// The card material used by Contacts, distinct from its lightweight avatar material.
/// Keep the owning system image loaded while the material retains its provider.
private enum ContactsProfileMaterial {
    private static let image: UnsafeMutableRawPointer? = {
        guard #available(iOS 26.0, *) else { return nil }
        return dlopen("/System/Library/PrivateFrameworks/ContactsUICore.framework/ContactsUICore", RTLD_LAZY | RTLD_LOCAL)
    }()

    static let nativeAvailable: Bool = image.flatMap { dlsym($0, "$s14ContactsUICore24ContactCardStyleProviderV25defaultBackgroundMaterial7SwiftUI0I0VvgZ") } != nil
    static let value: SwiftUI.Material = {
        guard let image, let address = dlsym(image, "$s14ContactsUICore24ContactCardStyleProviderV25defaultBackgroundMaterial7SwiftUI0I0VvgZ") else {
            return .ultraThinMaterial
        }
        typealias Getter = @convention(thin) () -> SwiftUI.Material
        return unsafeBitCast(address, to: Getter.self)()
    }()
}

final class ConceptContactsMaterialView: UIView {
    private struct Surface: SwiftUI.View {
        let radius: CGFloat
        let isDark: Bool

        var body: some SwiftUI.View {
            RoundedRectangle(cornerRadius: self.radius, style: .continuous)
                .fill(ContactsProfileMaterial.value)
                .environment(\.colorScheme, self.isDark ? .dark : .light)
                .ignoresSafeArea()
        }
    }

    static var nativeAvailable: Bool { ContactsProfileMaterial.nativeAvailable }
    private let host: UIHostingController<Surface>
    private var configuration: (radius: CGFloat, isDark: Bool)

    override init(frame: CGRect) {
        self.configuration = (24.0, false)
        self.host = UIHostingController(rootView: Surface(radius: 24.0, isDark: false))
        super.init(frame: frame)
        if #available(iOS 16.4, *) { self.host.safeAreaRegions = [] }
        self.host.view.backgroundColor = .clear
        self.host.view.isUserInteractionEnabled = false
        self.host.view.frame = self.bounds
        self.host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.addSubview(self.host.view)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(radius: CGFloat, isDark: Bool) {
        guard radius != self.configuration.radius || isDark != self.configuration.isDark else { return }
        self.configuration = (radius, isDark)
        self.host.rootView = Surface(radius: radius, isDark: isDark)
    }
}
