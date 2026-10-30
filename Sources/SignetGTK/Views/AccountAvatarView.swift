import CAdwaita
import Foundation

/// Round avatar for an address. Upstream loads TzKT's avatar service (`Profiles.avatarURL`);
/// remote images wait on the port of `ImageLoader`, so for now this is the placeholder upstream
/// shows while loading: a person in a grey circle.
@MainActor
final class AccountAvatarView {
    let root: Widget
    var address: Address

    init(address: Address, size: Int32 = 44) {
        self.address = address
        let person = UI.image(icon: "avatar-default-symbolic", pixelSize: Int32(Double(size) * 0.45)).classes("dim-label")
        root = UI.circle(person, size: size, classes: "account-avatar")
    }
}
