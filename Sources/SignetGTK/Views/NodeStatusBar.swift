import CAdwaita
import Foundation

/// Thin strip at the bottom of the window: a coloured light and a line about the layer 1 node
/// and, while the network has Layer 2 on, a second line beneath it for the Layer 2 Michelson
/// node. The lines are a grid so hosts and summaries line up in columns. A healthy node shows
/// just the green light and its host; the level, head age and latency are in the tooltip.
/// The GTK counterpart of upstream's `Views/NodeStatusBar.swift`.
@MainActor
final class NodeStatusBar {
    let root: Widget
    private let rows: [Row]
    private var tracker: Tracker?

    /// One node's cells: light, label, host and, unless the node is healthy, the summary.
    /// Clicking the host or summary checks that node again.
    @MainActor private final class Row {
        let monitor: NodeMonitor
        let label: String
        let light = UI.vbox().classes("node-light").align(h: GTK_ALIGN_CENTER, v: GTK_ALIGN_CENTER)
        let title: Widget
        let host = UI.label(classes: ["node-host"])
        let summary = UI.label(classes: ["dim-label"], xalign: 1)

        @MainActor init(monitor: NodeMonitor, label: String) {
            self.monitor = monitor
            self.label = label
            title = UI.label(label, classes: ["dim-label"])
            gtk_label_set_ellipsize(summary.opaque, PANGO_ELLIPSIZE_END)
            summary.expand(h: true)
            for target in [host, summary] {
                UI.onClick(target) { Task { await monitor.checkNow() } }
            }
        }

        @MainActor func cells() -> [Widget] { [light, title, host, summary] }

        @MainActor func update() {
            let status = monitor.status
            for colour in ["grey", "green", "yellow", "red"] { light.removeClass(colour) }
            let colour = switch status.light {
            case .grey: "grey"
            case .green: "green"
            case .yellow: "yellow"
            case .red: "red"
            }
            light.classes(colour)
            let hostText = monitor.endpoint.map { $0.host() ?? $0.absoluteString } ?? "—"
            UI.setText(host, hostText)
            UI.setText(summary, status.isHealthy ? "" : status.summary)
            let help = Self.helpText(for: monitor)
            host.tooltip(help)
            summary.tooltip(help)
            host.accessibleLabel("\(label) \(hostText): \(status.summary)")
        }

        @MainActor static func helpText(for monitor: NodeMonitor) -> String {
            var lines = [monitor.endpoint?.absoluteString ?? "No node", monitor.status.detail]
            if let level = monitor.status.level { lines.append("Head level \(level.formatted())") }
            if case .healthy(_, _, let latency) = monitor.status {
                lines.append("Reply in \(String(format: "%.2f", latency)) s")
            }
            if let checked = monitor.lastChecked {
                lines.append("Checked \(checked.formatted(date: .omitted, time: .standard))")
            }
            lines.append("Click to check again.")
            return lines.joined(separator: "\n")
        }
    }

    init(monitor: NodeMonitor, layer2: NodeMonitor? = nil) {
        let grid = Widget(gtk_grid_new()!)
        gtk_grid_set_column_spacing(grid.as(), 8)
        gtk_grid_set_row_spacing(grid.as(), 4)
        var rows = [Row(monitor: monitor, label: "Layer 1:")]
        if let layer2 { rows.append(Row(monitor: layer2, label: "Layer 2:")) }
        self.rows = rows
        for (index, row) in rows.enumerated() {
            for (column, cell) in row.cells().enumerated() {
                gtk_grid_attach(grid.as(), cell.pointer, Int32(column), Int32(index), 1, 1)
            }
        }
        root = grid.classes("status-bar")
        tracker = Tracker { [unowned self] in
            for row in self.rows { row.update() }
            // The Layer 2 line shows only while that node is configured.
            if self.rows.count > 1 {
                let shown = self.rows[1].monitor.endpoint != nil
                for cell in self.rows[1].cells() { cell.isVisible = shown }
            }
        }
    }
}
