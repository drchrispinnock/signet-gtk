import CAdwaita
import Foundation

/// One line under the balances: who the wallet delegates to (or that it is a baker). Click → Staking.
/// The GTK counterpart of upstream's `Views/DelegateRowView.swift`.
@MainActor
final class DelegateRowView {
    let model: WalletViewModel
    let root: Widget
    private let iconSlot = UI.vbox(spacing: 0).size(width: 44, height: 44)
    private let headlineLabel = UI.label(classes: ["delegate-headline"], wrap: true)
    private let subtitleLabel = UI.label(classes: ["dim-label", "caption"], wrap: true)
    private var delegateName: String?
    /// The delegate `delegateName` was looked up for (`.task(id:)` upstream).
    private var namedDelegate: Address??
    private var lookup: Task<Void, Never>?
    private var iconKey: String?
    private var tracker: Tracker?

    init(model: WalletViewModel) {
        self.model = model
        let text = UI.vbox(spacing: 2, [headlineLabel, subtitleLabel]).expand(h: true).align(v: GTK_ALIGN_CENTER)
        let chevron = UI.image(icon: "go-next-symbolic", pixelSize: 16).classes("dim-label")
        let row = UI.hbox(spacing: 12, [iconSlot, text, chevron])
        root = UI.button(content: row, classes: ["flat", "delegate-row"]) { [model] in
            if let wallet = model.selectedWallet, wallet.address.isContract {
                // A contract delegates through its signers: open Sign multisig on this contract.
                model.signMultisigPreset = .init(contract: MultisigContract(alias: wallet.alias, address: wallet.address), delegating: true)
                model.isPresentingSignMultisig = true
            } else {
                model.isPresentingStaking = true
            }
        }
        root.tooltip("Delegation and staking")
        tracker = Tracker { [unowned self] in self.update() }
    }

    deinit { lookup?.cancel() }

    private func update() {
        let info = model.delegateInfo
        let delegate = info?.delegate
        if namedDelegate != .some(delegate) {
            namedDelegate = .some(delegate)
            lookDelegateUp(delegate, isBaker: info?.isBaker == true)
        }
        updateIcon()
        updateText()
    }

    private func lookDelegateUp(_ delegate: Address?, isBaker: Bool) {
        lookup?.cancel()
        delegateName = nil
        guard let delegate, !isBaker else { return }
        let known = model.displayName(for: delegate, indexerAlias: nil)
        if known.isOurs { delegateName = known.name; return }
        lookup = Task { [weak self, model] in
            let name = await model.profileName(for: delegate) ?? delegate.shortened()
            guard let self, !Task.isCancelled else { return }
            self.delegateName = name
            self.updateText()
        }
    }

    private func updateIcon() {
        let info = model.delegateInfo
        let key: String
        let icon: Widget
        if let info, let delegate = info.delegate, !info.isBaker {
            key = "avatar:\(delegate.value)"
            guard key != iconKey else { return }
            icon = AccountAvatarView(address: delegate, size: 44).root
        } else {
            let isBaker = info?.isBaker == true
            key = isBaker ? "baker" : "none"
            guard key != iconKey else { return }
            let inner = isBaker ? UI.label("👨‍🍳", classes: ["title-2"], xalign: 0.5)
                                : UI.image(icon: "dialog-question-symbolic", pixelSize: 20).classes("dim-label")
            icon = UI.circle(inner, size: 44, classes: "delegate-circle")
        }
        iconKey = key
        iconSlot.setChildren([icon])
    }

    private func updateText() {
        UI.setText(headlineLabel, headline)
        UI.setText(subtitleLabel, subtitle)
    }

    private var headline: String {
        guard let info = model.delegateInfo else { return "Delegation" }
        if info.isBaker { return model.selectedWallet?.keyKind.canSign == true ? "You are a baker" : "This address is a baker" }
        if let delegate = info.delegate { return "Delegated to \(delegateName ?? delegate.shortened())" }
        return "Not delegated"
    }

    private var subtitle: String {
        guard let info = model.delegateInfo else { return "Checking…" }
        if model.selectedWallet?.address.isContract == true {
            return "A multisig delegates with its signers' signatures; tap to propose a change."
        }
        if let baker = info.baker {
            if let kind = model.selectedWallet?.keyKind, !kind.canSign {
                let why = kind == .remote ? "it signs remotely" : "Signet holds only its public key"
                return (baker.deactivated ? "Deactivated. " : "") + "Watch only: \(why). Baking shows its keys and parameters."
            }
            return baker.deactivated ? "Deactivated; reactivate under Baking in the menu" : "Self-delegated; keys and staking parameters under Baking"
        }
        if info.delegate != nil {
            switch info.delegateAcceptsStaking {
            case .some(true): return "This baker accepts staking"
            case .some(false): return "This baker does not accept staking"
            case .none: return "Tap to stake or change delegate"
            }
        }
        return "Delegate to a baker to earn rewards"
    }
}
