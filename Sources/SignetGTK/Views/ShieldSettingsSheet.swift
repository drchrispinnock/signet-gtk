import CAdwaita
import Foundation

/// Shielded settings: shielded transactions (TzEL) on or off per layer 1 network, the services
/// of the deployment Signet talks to there (each replaceable, with Use Default) and the
/// operator's access token. Opened from "Shielded settings…" under Networks in the menu. The
/// GTK counterpart of upstream's `Views/ShieldSettingsSheet.swift`.
@MainActor
final class ShieldSettingsSheet: Sheet {
    /// The layer 1 network whose shielded settings are being edited; starts on the one in use.
    private var editingNetworkName: String
    private var networkPicker: Widget!
    private var enabledToggle: Widget!
    private let switchGroup = Form.group([])
    private let servicesGroup = Form.group([])
    private let accessGroup = Form.group([])
    private let servicesHeader: Widget
    private let accessHeader: Widget
    private let helpIcon = UI.image(icon: "help-about-symbolic").classes("dim-label")
    private let servicesHelpIcon = UI.image(icon: "help-about-symbolic").classes("dim-label")
    private let tokenHelpIcon = UI.image(icon: "help-about-symbolic").classes("dim-label")
    private var fields: [SettingField] = []
    private var tokenEntry: Widget!
    private let tokenError = UI.label(classes: ["error-text"], wrap: true, xalign: 1)
    private let tokenButtons = UI.hbox(spacing: 8)
    /// Upstream's orange `lock.open` label under the services when one is plain HTTP.
    private let plainHTTPNote = Form.note("", icon: "channel-insecure-symbolic", style: "warning-text")

    init(model: WalletViewModel) {
        editingNetworkName = model.network.name
        servicesHeader = UI.hbox(spacing: 6, [UI.label("TzEL services", classes: ["heading"]), servicesHelpIcon])
        accessHeader = UI.hbox(spacing: 6, [UI.label("Access", classes: ["heading"]), tokenHelpIcon])
        super.init(model: model, width: 520)
        networkPicker = Form.picker("Network", options: Network.all.map { $0.name + ($0.name == model.network.name ? "  (in use)" : "") },
                                    selected: Network.all.firstIndex { $0.name == model.network.name } ?? 0) { [unowned self] in
            let index = Form.selected(self.networkPicker)
            guard Network.all.indices.contains(index) else { return }
            self.editingNetworkName = Network.all[index].name
            Form.clear(self.tokenEntry)
            self.setTokenError(nil)
            self.rebuild()
        }
        enabledToggle = Form.toggle("Enable Shielded Transactions", isOn: false) { [unowned self] in
            guard let base = self.editingNetwork else { return }
            let on = Form.isOn(self.enabledToggle)
            guard on != self.model.isShieldedEnabled(for: base) else { return }
            self.model.setShieldedEnabled(on, for: base)
            self.rebuild()
        }
        tokenEntry = PasswordEntry.make(placeholder: "", onChange: { [unowned self] _ in self.updateTokenButtons() },
                                        onSubmit: { [unowned self] in self.applyOperatorToken() })
        tokenEntry.size(width: 300).expand(h: true)
        tokenError.isVisible = false
        helpIcon.tooltip(help)
        servicesHelpIcon.tooltip(servicesHelp)
        tokenHelpIcon.tooltip(tokenHelp)
        let tokenRow = Form.stacked("Operator token", below: [tokenEntry, tokenError, tokenButtons.align(h: GTK_ALIGN_END)])
        Form.setRows(accessGroup, [tokenRow])
        content.setChildren([
            UI.hbox(spacing: 6, [UI.label("Shielded Transactions", classes: ["heading"]), helpIcon]), switchGroup,
            servicesHeader, servicesGroup,
            accessHeader, accessGroup,
        ])
        setButtons([button("Done", isDefault: true) { [unowned self] in self.dismiss() }])
        rebuild()
    }

    private var editingNetwork: Network? { Network.named(editingNetworkName) }

    private var help: String {
        "With Shielded Transactions on, the dashboard shows the account's shielded tez on the TzEL rollup of the chosen layer 1 network, and the menus offer Shield tez, Unshield tez, Send shielded and Shielded address. The choice and the settings below are kept per network."
    }

    // Upstream adds that macOS lets plain http through only for the hosts Signet ships with;
    // Linux has no such rule.
    private var servicesHelp: String {
        "The rollup node serves the notes and nullifiers; the rollup and bridge ticketer are checked before any tez move; the proving service makes the proofs; the operator relays them to the rollup. The producer fee is the note every shielded operation pays the DAL slot producer, in mutez, and the producer address is that producer's payment address, the JSON it publishes. Plain http is accepted. Use Default restores what Signet ships, or clears an item where it ships nothing."
    }

    private var tokenHelp: String {
        "The operator relays shielded operations only with its access token. It is kept with the shielded wallet in the wallet directory, never in Signet's settings, and shielding is refused until it is on file."
    }

    /// The switch and the warning beneath it, then the two sections shown while it is on.
    private func rebuild() {
        guard let base = editingNetwork else { return }
        let on = model.isShieldedEnabled(for: base)
        if Form.isOn(enabledToggle) != on { Form.setOn(enabledToggle, on) }
        renderSwitch()
        fields = on ? ShieldedConfig.Setting.allCases.map { setting in
            SettingField(
                title: setting.title,
                current: { [model] in model.shieldedSetting(setting, in: base) },
                defaultValue: base.shieldedDefault?.text(for: setting) ?? "",
                prompt: setting.prompt,
                monospaced: true,
                apply: { [unowned self] in
                    let applied = self.model.setShieldedSetting($0, for: setting, in: base)
                    self.renderSwitch()
                    return applied
                },
                problem: { _ in setting.problem },
                useDefault: { [unowned self] in self.model.useDefaultShieldedSetting(for: setting, in: base); self.renderSwitch() }
            )
        } : []
        Form.setRows(servicesGroup, fields.map(\.root) + (on ? [plainHTTPNote.row] : []))
        for widget in [servicesHeader, servicesGroup, accessHeader, accessGroup] { widget.isVisible = on }
    }

    /// Filling in or clearing an item can complete the deployment or break it.
    private func renderSwitch() {
        guard let base = editingNetwork else { return }
        var rows = [networkPicker!, enabledToggle!]
        if model.isShieldedEnabled(for: base) {
            if base.shieldedDefault == nil {
                rows.append(Form.note("Signet ships no TzEL services for \(base.name). Fill in every item below to shield there.", style: "warning-text").row)
            } else if model.resolved(base).shielded == nil {
                rows.append(Form.note("Shielding is off until every item below is filled in.", style: "warning-text").row)
            }
        }
        Form.setRows(switchGroup, rows)
        let plain = Self.plainHTTP(model.shieldedSetting(.operatorURL, in: base), model.shieldedSetting(.rollupNode, in: base))
        UI.setText(plainHTTPNote.label, plain ?? "")
        plainHTTPNote.row.isVisible = plain != nil
        updateTokenButtons()
    }

    /// What to say when the operator or the rollup node is reached over plain HTTP: the
    /// access token and every request travel unencrypted, and a network in between can
    /// change the answers. The shipped Shadownet deployment offers nothing else (November 2026).
    nonisolated static func plainHTTP(_ operatorURL: String, _ rollupNode: String) -> String? {
        let plain = [("operator", operatorURL), ("rollup node", rollupNode)].filter { $0.1.lowercased().hasPrefix("http://") }.map(\.0)
        guard !plain.isEmpty else { return nil }
        return "The \(plain.joined(separator: " and ")) \(plain.count == 1 ? "is" : "are") reached over plain HTTP: the access token and every request travel unencrypted, and anything between you and the service can read or change them. Use https where the deployment offers it."
    }

    // MARK: Operator token

    private var tokenText: String { String(cString: gtk_editable_get_text(tokenEntry.opaque)) }

    private func updateTokenButtons() {
        guard let base = editingNetwork else { return }
        let isSet = model.shieldedOperatorTokenIsSet(for: base)
        PasswordEntry.setPlaceholder(tokenEntry, isSet ? "On file; paste a new one to replace it" : "Paste the operator's access token")
        var buttons: [Widget] = []
        if isSet {
            buttons.append(UI.button("Remove") { [unowned self] in Form.clear(self.tokenEntry); self.applyOperatorToken() })
        }
        let apply = UI.button("Apply") { [unowned self] in self.applyOperatorToken() }
        apply.isSensitive = !tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        buttons.append(apply)
        tokenButtons.setChildren(buttons)
    }

    private func setTokenError(_ message: String?) {
        UI.setText(tokenError, message ?? "")
        tokenError.isVisible = message != nil
    }

    /// Keeps the token in the network's shielded wallet file; the field empties once it is on file.
    private func applyOperatorToken() {
        guard let base = editingNetwork else { return }
        setTokenError(nil)
        do {
            try model.setShieldedOperatorToken(tokenText, for: base)
            Form.clear(tokenEntry)
        } catch {
            setTokenError(error.localizedDescription)
        }
        updateTokenButtons()
    }

    override func closed() { Form.clear(tokenEntry) }
}
