import CAdwaita
import Foundation

/// Networks: which node Signet talks to on each network, the Layer 2 (Etherlink) node, and
/// the TzKT API, block explorer and faucet links it uses there. Opened from the burger menu and
/// from the network badge; the network in use is switched with the badge, not here. The GTK
/// counterpart of upstream's `Views/NetworksSheet.swift`.
@MainActor
final class NetworksSheet: Sheet {
    /// The network whose node is being edited; starts on the one in use.
    private var editingNetworkName: String
    private var networkPicker: Widget!
    private let nodeEntry = Widget(gtk_entry_new()!)
    private let nodeMessage = UI.label(wrap: true, xalign: 1)
    private let nodeButtons = UI.hbox(spacing: 8)
    private let nodeHelpIcon = UI.image(icon: "help-about-symbolic").classes("dim-label")
    private let linksHelpIcon = UI.image(icon: "help-about-symbolic").classes("dim-label")
    private let links = Form.group([])
    private var linkFields: [LinkField] = []
    /// A node on a network that pins a chain id is asked which chain it serves before Apply
    /// adopts it; a wrong or silent answer is shown here with a Use Anyway button.
    private var nodeError: String?
    private var nodeWarning: NodeIdentity?
    private var nodeChecking = false
    // Layer 2: the switch, the Michelson node and the governance contracts, in a group of
    // their own under the network's node.
    private let layer2 = Form.group([])
    private var l2Toggle: Widget!
    private let l2NodeEntry = Widget(gtk_entry_new()!)
    private let l2NodeMessage = UI.label(wrap: true, xalign: 1)
    private let l2NodeButtons = UI.hbox(spacing: 8)
    private var l2NodeRow: Widget!
    private var governanceFields: [SettingField] = []
    private var l2NodeError: String?
    private var l2NodeWarning: NodeIdentity?
    private var l2NodeChecking = false

    init(model: WalletViewModel) {
        editingNetworkName = model.network.name
        super.init(model: model, width: 520)
        networkPicker = Form.picker("Network", options: Network.all.map { $0.name + ($0.name == model.network.name ? "  (in use)" : "") },
                                    selected: Network.all.firstIndex { $0.name == model.network.name } ?? 0) { [unowned self] in
            let index = Form.selected(self.networkPicker)
            guard Network.all.indices.contains(index) else { return }
            self.editingNetworkName = Network.all[index].name
            self.syncNodeText()
            self.rebuildLayer2()
            self.rebuildLinks()
        }
        nodeEntry.classes("monospace")
        Signals.connect(nodeEntry, "changed") { [unowned self] in self.nodeWarning = nil; self.updateNode() }
        Signals.connect(nodeEntry, "activate") { [unowned self] in self.applyNode() }
        nodeMessage.isVisible = false
        let nodeRow = Form.stacked("Node", below: [nodeEntry, nodeMessage, nodeButtons.align(h: GTK_ALIGN_END)])

        l2Toggle = Form.toggle("Enable Layer 2", isOn: false) { [unowned self] in
            guard let base = self.editingNetwork else { return }
            let on = Form.isOn(self.l2Toggle)
            guard on != self.model.isL2Enabled(for: base) else { return }
            self.model.setL2Enabled(on, for: base)
            self.syncNodeText()
            self.rebuildLayer2()
        }
        l2NodeEntry.classes("monospace")
        PasswordEntry.setPlaceholder(l2NodeEntry, "https://…")
        Signals.connect(l2NodeEntry, "changed") { [unowned self] in self.l2NodeWarning = nil; self.updateL2Node() }
        Signals.connect(l2NodeEntry, "activate") { [unowned self] in self.applyL2Node() }
        l2NodeMessage.isVisible = false
        l2NodeRow = Form.stacked("Layer 2 Michelson node", below: [l2NodeEntry, l2NodeMessage, l2NodeButtons.align(h: GTK_ALIGN_END)])

        content.setChildren([
            sectionHeader("Networks", icon: nodeHelpIcon), UI.vbox(spacing: 12, [Form.group([networkPicker, nodeRow]), layer2]),
            sectionHeader("Links", icon: linksHelpIcon), links,
        ])
        setButtons([button("Done", isDefault: true) { [unowned self] in self.dismiss() }])
        syncNodeText()
        rebuildLayer2()
        rebuildLinks()
        // `.onChange(of: model.network)`.
        trackers.append(Tracker { [unowned self] in
            _ = self.model.network
            if self.editingNetworkName == self.model.network.name { self.syncNodeText() }
        })
    }

    /// `SectionHeader`: a title with an ⓘ that explains it on hover.
    private func sectionHeader(_ title: String, icon: Widget) -> Widget {
        UI.hbox(spacing: 6, [UI.label(title, classes: ["heading"]), icon])
    }

    private var editingNetwork: Network? { Network.named(editingNetworkName) }
    private var nodeText: String { String(cString: gtk_editable_get_text(nodeEntry.opaque)) }

    private var nodeIsDirty: Bool {
        guard let base = editingNetwork else { return false }
        return Network.nodeURL(from: nodeText) != model.nodeURL(for: base)
    }

    private var nodeHelp: String {
        guard let base = editingNetwork else { return "" }
        var text = "The node Signet uses for \(base.name). Each network keeps its own; switch networks with the badge at the top of the main window."
        if base.chain == "custom" {
            text += " Custom is yours to point anywhere, for example a node you run yourself."
        } else {
            text += " The default is \(base.defaultRPCURL.absoluteString)."
        }
        if base.chain == "weeklynet" {
            text += " Weeklynet restarts every Wednesday and its address carries that date, so the default follows the calendar."
        }
        if base.expectedChainID != nil {
            text += " A new node is asked which chain it serves before it is used, and one on another chain is warned about."
        }
        if model.isL2Enabled(for: base) {
            text += " With Layer 2 on, the dashboard shows each tz1, tz2 or tz3 account's balance on Etherlink, read from the Layer 2 Michelson node"
            text += base.l2DefaultRPCURL.map { " (default \($0.absoluteString))." } ?? " you enter here."
            text += " The slow and fast governance contracts are Etherlink's kernel-upgrade votes on layer 1 (\(base.defaultEtherlinkGovernance.isEmpty ? "none shipped for \(base.name)" : "mainnet's are shipped")); with one set, Governance gains an Etherlink tab for bakers and their voting keys. Leave a field empty to do without that process."
        }
        return text
    }

    private var servicesFooter: String {
        guard let base = editingNetwork else { return "" }
        var text = "The TzKT API feeds the history, token and NFT lists; the explorer is where operations are opened; the faucet is behind Get test tez. Leave a link empty to do without it."
        if base.isMainnet {
            text += " Mainnet has no faucet."
        } else {
            text += base.faucetKind == .pqpark
                ? " A replacement faucet must speak PQPark's faucet API."
                : " A replacement faucet must speak the teztnets faucet API."
        }
        return text
    }

    private func updateNode() {
        nodeHelpIcon.tooltip(nodeHelp)
        linksHelpIcon.tooltip(servicesFooter)
        if let nodeError {
            nodeMessage.setClass("error-text", true); nodeMessage.setClass("warning-text", false)
            UI.setText(nodeMessage, nodeError)
            nodeMessage.isVisible = true
        } else if let nodeWarning, let base = editingNetwork {
            nodeMessage.setClass("error-text", false); nodeMessage.setClass("warning-text", true)
            UI.setText(nodeMessage, warning(nodeWarning, for: base))
            nodeMessage.isVisible = true
        } else if nodeChecking {
            nodeMessage.setClass("error-text", false); nodeMessage.setClass("warning-text", false)
            UI.setText(nodeMessage, "Checking which chain the node serves…")
            nodeMessage.isVisible = true
        } else {
            nodeMessage.isVisible = false
        }
        let useDefault = UI.button("Use Default") { [unowned self] in
            if let base = self.editingNetwork { self.model.useDefaultNode(for: base); self.syncNodeText() }
        }
        useDefault.isSensitive = !(editingNetwork.map { model.nodeURL(for: $0) == $0.defaultRPCURL } ?? true)
        let second: Widget
        if nodeWarning != nil {
            second = UI.button("Use Anyway") { [unowned self] in
                if let base = self.editingNetwork { self.model.setNode(self.nodeText, for: base); self.syncNodeText() }
            }
        } else {
            second = UI.button("Apply") { [unowned self] in self.applyNode() }
            second.isSensitive = nodeIsDirty && !nodeChecking
        }
        nodeButtons.setChildren([useDefault, second])
    }

    /// The warning under a node field: the node serves another chain, or could not be asked.
    private func warning(_ identity: NodeIdentity, for base: Network, layer: NodeMonitor.Layer = .one) -> String {
        let name = layer == .two ? "\(base.name)'s Etherlink" : base.name
        switch identity {
        case .mismatch(let found, let expected):
            return "This node serves chain \(found), not \(name) (\(expected)). Signet would show it in red and refuse to sign through it."
        case .unchecked(let reason):
            return "Signet could not check which chain this node serves. \(reason)."
        case .unpinned, .matches:
            return ""
        }
    }

    private func syncNodeText() {
        if let base = editingNetwork {
            gtk_editable_set_text(nodeEntry.opaque, model.nodeURL(for: base).nodeDisplayTextStandalone)
            gtk_editable_set_text(l2NodeEntry.opaque, model.l2NodeURL(for: base)?.nodeDisplayTextStandalone ?? "")
        }
        nodeError = nil
        nodeWarning = nil
        l2NodeError = nil
        l2NodeWarning = nil
        updateNode()
        updateL2Node()
    }

    // MARK: Layer 2

    /// The switch, and while it is on the node and the two governance contracts.
    private func rebuildLayer2() {
        guard let base = editingNetwork else { return }
        let on = model.isL2Enabled(for: base)
        if Form.isOn(l2Toggle) != on { Form.setOn(l2Toggle, on) }
        governanceFields = on ? EtherlinkGovernance.Process.allCases.map { process in
            SettingField(
                title: process.settingTitle,
                current: { [model] in model.etherlinkGovernanceContract(for: process, in: base) },
                defaultValue: base.defaultEtherlinkGovernance[process]?.value ?? "",
                prompt: "KT1…",
                monospaced: true,
                apply: { [model] in model.setEtherlinkGovernanceContract($0, for: process, in: base) },
                problem: { _ in "Enter the governance contract's address (KT1…), or leave it empty to do without this process." },
                useDefault: { [model] in model.useDefaultEtherlinkGovernanceContract(for: process, in: base) }
            )
        } : []
        Form.setRows(layer2, [l2Toggle] + (on ? [l2NodeRow] + governanceFields.map(\.root) : []))
        updateNode()
    }

    private var l2NodeText: String { String(cString: gtk_editable_get_text(l2NodeEntry.opaque)) }

    private var l2NodeIsDirty: Bool {
        guard let base = editingNetwork else { return false }
        return Network.nodeURL(from: l2NodeText) != model.l2NodeURL(for: base)
    }

    private func updateL2Node() {
        guard let base = editingNetwork else { return }
        var message: (String, String?)?
        if let l2NodeError {
            message = (l2NodeError, "error-text")
        } else if let l2NodeWarning {
            message = (warning(l2NodeWarning, for: base, layer: .two), "warning-text")
        } else if l2NodeChecking {
            message = ("Checking which chain the node serves…", nil)
        } else if model.l2NodeURL(for: base) == nil {
            message = ("Enter the Layer 2 Michelson node to use; the balance is not shown until then.", "warning-text")
        }
        l2NodeMessage.setClass("error-text", message?.1 == "error-text")
        l2NodeMessage.setClass("warning-text", message?.1 == "warning-text")
        UI.setText(l2NodeMessage, message?.0 ?? "")
        l2NodeMessage.isVisible = message != nil

        let useDefault = UI.button("Use Default") { [unowned self] in
            self.model.useDefaultL2Node(for: base)
            self.syncNodeText()
        }
        useDefault.isSensitive = !(base.l2DefaultRPCURL == nil || model.l2NodeURL(for: base) == base.l2DefaultRPCURL)
        let second: Widget
        if l2NodeWarning != nil {
            second = UI.button("Use Anyway") { [unowned self] in
                self.model.setL2Node(self.l2NodeText, for: base)
                self.syncNodeText()
            }
        } else {
            second = UI.button("Apply") { [unowned self] in self.applyL2Node() }
            second.isSensitive = l2NodeIsDirty && !l2NodeChecking
        }
        l2NodeButtons.setChildren([useDefault, second])
    }

    private func applyL2Node() {
        guard let base = editingNetwork else { return }
        guard Network.nodeURL(from: l2NodeText) != nil else { l2NodeError = Network.nodeURLProblem(l2NodeText); updateL2Node(); return }
        l2NodeError = nil
        l2NodeWarning = nil
        l2NodeChecking = true
        updateL2Node()
        let text = l2NodeText
        Task {
            let identity = await model.checkNode(text, for: base, layer: .two)
            l2NodeChecking = false
            defer { updateL2Node() }
            guard text == l2NodeText, editingNetwork?.name == base.name else { return }
            switch identity {
            case .unpinned, .matches:
                model.setL2Node(text, for: base)
                syncNodeText()
            case .mismatch, .unchecked:
                l2NodeWarning = identity
            }
        }
    }

    /// The links beside the node, one field per service the network offers.
    private func rebuildLinks() {
        guard let base = editingNetwork else { return }
        linkFields = Network.Service.allCases.filter { base.offers($0) }.map { service in
            LinkField(title: service.title,
                      current: { [model] in model.serviceURL(for: service, in: base) },
                      defaultURL: base.defaultURL(for: service),
                      apply: { [model] in model.setServiceURL($0, for: service, in: base) },
                      useDefault: { [model] in model.useDefaultServiceURL(for: service, in: base) })
        }
        Form.setRows(links, linkFields.map(\.root))
        updateNode()
    }

    /// Apply asks a node on a pinned network which chain it serves first; only a matching (or
    /// unpinned) node is adopted straight away, anything else waits for Use Anyway.
    private func applyNode() {
        guard let base = editingNetwork else { return }
        guard Network.nodeURL(from: nodeText) != nil else { nodeError = Network.nodeURLProblem(nodeText); updateNode(); return }
        nodeError = nil
        nodeWarning = nil
        nodeChecking = true
        updateNode()
        let text = nodeText
        Task {
            let identity = await model.checkNode(text, for: base)
            nodeChecking = false
            defer { updateNode() }
            // The field or the dropdown moved on while the node was being asked.
            guard text == nodeText, editingNetwork?.name == base.name else { return }
            switch identity {
            case .unpinned, .matches:
                model.setNode(text, for: base)
                syncNodeText()
            case .mismatch, .unchecked:
                nodeWarning = identity
            }
        }
    }
}

/// One URL field with its error line and Use Default / Apply buttons.
@MainActor
private final class LinkField {
    let root: Widget
    private let entry = Widget(gtk_entry_new()!)
    private let errorLabel = UI.label(classes: ["error-text"], wrap: true, xalign: 1)
    private let useDefaultButton: Widget
    private let applyButton: Widget
    private let current: @MainActor () -> URL?
    private let defaultURL: URL?
    /// Applies the text; false when it was refused.
    private let apply: @MainActor (String) -> Bool
    private var tracker: Tracker?

    init(title: String, current: @escaping @MainActor () -> URL?, defaultURL: URL?,
         apply: @escaping @MainActor (String) -> Bool, useDefault: @escaping @MainActor () -> Void) {
        self.current = current
        self.defaultURL = defaultURL
        self.apply = apply
        entry.classes("monospace")
        PasswordEntry.setPlaceholder(entry, "https://…")
        errorLabel.isVisible = false
        useDefaultButton = UI.button("Use Default") {}
        applyButton = UI.button("Apply") {}
        let buttons = UI.hbox(spacing: 8, [useDefaultButton, applyButton]).align(h: GTK_ALIGN_END)
        root = Form.stacked(title, below: [entry, errorLabel, buttons])
        Signals.connect(useDefaultButton, "clicked") { [unowned self] in useDefault(); self.setError(nil) }
        Signals.connect(applyButton, "clicked") { [unowned self] in self.submit() }
        Signals.connect(entry, "activate") { [unowned self] in self.submit() }
        Signals.connect(entry, "changed") { [unowned self] in self.updateButtons() }
        // `.onAppear(perform: sync)` and `.onChange(of: current) { sync() }`.
        tracker = Tracker { [unowned self] in self.sync() }
    }

    private var text: String { String(cString: gtk_editable_get_text(entry.opaque)) }

    private var typed: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Network.nodeURL(from: trimmed)
    }

    private var isDirty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? current() != nil : typed != current()
    }

    private func sync() {
        gtk_editable_set_text(entry.opaque, current()?.nodeDisplayTextStandalone ?? "")
        setError(nil)
    }

    private func updateButtons() {
        useDefaultButton.isSensitive = defaultURL != nil && current() != defaultURL
        applyButton.isSensitive = isDirty
    }

    private func setError(_ message: String?) {
        UI.setText(errorLabel, message ?? "")
        errorLabel.isVisible = message != nil
        updateButtons()
    }

    private func submit() {
        setError(apply(text) ? nil : Network.nodeURLProblem(text))
    }
}
