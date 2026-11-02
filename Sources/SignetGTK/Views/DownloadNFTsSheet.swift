import CAdwaita
import Foundation

/// Saves the artwork of one or many NFTs into the wallet directory's `nfts` folder, a row per
/// token with its progress, and opens the folder in the file manager when asked ("Show in
/// Finder" upstream). Closing the sheet stops whatever is still downloading; what was saved
/// stays. The GTK counterpart of upstream's `Views/DownloadNFTsSheet.swift`.
@MainActor
final class DownloadNFTsSheet: Sheet {
    let downloader: NFTDownloader
    let download: NFTDownload

    enum Outcome: Equatable {
        case saved(URL)
        case failed(String)
    }

    private var outcomes: [NFT.ID: Outcome] = [:] { didSet { render() } }
    private let rows = UI.vbox(spacing: 8)
    private let summary = UI.hbox(spacing: 6)
    private let showButton: Widget
    private var runner: Task<Void, Never>?

    init(model: WalletViewModel, downloader: NFTDownloader, download: NFTDownload) {
        self.downloader = downloader
        self.download = download
        showButton = UI.button("Open Folder") {}
        super.init(model: model, width: 480)
        let title = download.nfts.count == 1 ? "Download NFT" : "Download \(download.nfts.count) NFTs"
        let explanation = UI.label("", classes: ["dim-label"], wrap: true)
        gtk_label_set_markup(explanation.opaque, "The full artwork of each token is saved into <b>\(Self.escaped(UI.tilde(downloader.directory)))</b>, named after the token, its contract and its id.")
        let scroller = Widget(gtk_scrolled_window_new()!)
        gtk_scrolled_window_set_policy(scroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller.opaque, rows.pointer)
        gtk_scrolled_window_set_propagate_natural_height(scroller.opaque, 1)
        gtk_scrolled_window_set_min_content_height(scroller.opaque, 60)
        gtk_scrolled_window_set_max_content_height(scroller.opaque, 280)
        content.setChildren([Sheet.title(title), explanation, scroller, summary])
        Signals.connect(showButton, "clicked") { [unowned self] in self.reveal() }
        status.setChildren([showButton])
        status.isVisible = true
        render()
        runner = Task { await run() }
    }

    private var finished: Bool { outcomes.count == download.nfts.count }
    private var saved: [URL] { download.nfts.compactMap { if case .saved(let url) = outcomes[$0.id] { url } else { nil } } }

    private static func escaped(_ text: String) -> String {
        String(cString: g_markup_escape_text(text, -1))
    }

    private func render() {
        rows.setChildren(download.nfts.map(row))
        showButton.isSensitive = !saved.isEmpty
        if finished {
            let failed = download.nfts.count - saved.count
            if failed == 0 {
                summary.setChildren([UI.image(icon: "object-select-symbolic"), UI.label(saved.count == 1 ? "Saved" : "Saved \(saved.count) files")])
                summary.setClass("success-icon", true)
                summary.setClass("warning-text", false)
            } else {
                summary.setChildren([UI.image(icon: "dialog-warning-symbolic"), UI.label("Saved \(saved.count) of \(download.nfts.count)")])
                summary.setClass("success-icon", false)
                summary.setClass("warning-text", true)
            }
            summary.isVisible = true
            setButtons([button("Done", role: .prominent, isDefault: true) { [unowned self] in self.dismiss() }])
        } else {
            summary.isVisible = false
            setButtons([cancelButton()])
        }
    }

    private func row(_ nft: NFT) -> Widget {
        let icon: Widget
        let detail: Widget
        switch outcomes[nft.id] {
        case .saved(let url):
            icon = UI.image(icon: "object-select-symbolic").classes("success-icon")
            detail = UI.label(url.lastPathComponent, classes: ["dim-label", "caption"])
            gtk_label_set_ellipsize(detail.opaque, PANGO_ELLIPSIZE_MIDDLE)
        case .failed(let reason):
            icon = UI.image(icon: "process-stop-symbolic").classes("error-text")
            detail = UI.label(reason, classes: ["error-text", "caption"], wrap: true)
        case nil:
            icon = Widget(gtk_spinner_new()!)
            gtk_spinner_start(icon.opaque)
            detail = UI.label(nft.isMoving ? "Downloading the video or sound…" : "Downloading…", classes: ["dim-label", "caption"])
        }
        let name = UI.label(nft.name)
        gtk_label_set_ellipsize(name.opaque, PANGO_ELLIPSIZE_END)
        return UI.hbox(spacing: 10, [icon.size(width: 18).align(v: GTK_ALIGN_CENTER), UI.vbox(spacing: 2, [name, detail]).expand(h: true)])
    }

    /// Three at a time: the public client has six slots and the tiles may be loading too.
    private func run() async {
        let downloader = downloader
        await withTaskGroup(of: (NFT.ID, Outcome).self) { group in
            var pending = download.nfts[...]
            var running = 0
            func start(_ nft: NFT) {
                group.addTask {
                    do { return (nft.id, .saved(try await downloader.download(nft))) }
                    catch is CancellationError { return (nft.id, .failed("Cancelled")) }
                    catch { return (nft.id, .failed(error.localizedDescription)) }
                }
            }
            while running < 3, let next = pending.popFirst() { start(next); running += 1 }
            for await (id, outcome) in group {
                if !Task.isCancelled { outcomes[id] = outcome }
                if let next = pending.popFirst() { start(next) }
            }
        }
    }

    /// The folder, with the first saved file selected where the file manager can.
    private func reveal() {
        guard let first = saved.first else { return }
        UI.reveal(first, from: content)
    }

    override func closed() { runner?.cancel() }
}
