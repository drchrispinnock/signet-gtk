import CAdwaita
import Foundation

/// Round avatar for an address from TzKT's avatar service (TzProfiles logo, known-account logo,
/// or an identicon). Always mainnet: a TzProfile is a mainnet identity. The GTK counterpart of
/// upstream's `Views/AccountAvatarView.swift`.
@MainActor
final class AccountAvatarView {
    let root: Widget
    private let size: Int32

    init(address: Address, size: Int32 = 44) {
        self.address = address
        self.size = size
        root = UI.vbox(spacing: 0).size(width: size, height: size)
        root.expand().align(h: GTK_ALIGN_START, v: GTK_ALIGN_CENTER)
        show()
    }

    var address: Address {
        didSet { if address != oldValue { show() } }
    }

    private func show() {
        let size = size
        let placeholder = {
            let person = UI.image(icon: "avatar-default-symbolic", pixelSize: Int32(Double(size) * 0.45)).classes("dim-label")
            return UI.circle(person, size: size, classes: "account-avatar")
        }
        let urls = Profiles.avatarURL(for: address).map { [$0] } ?? []
        let image = RemoteImage.make(urls: urls, size: size, round: true, placeholder: placeholder)
        if !urls.isEmpty { image.classes("account-avatar") }
        root.setChildren([image])
    }
}
