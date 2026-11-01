import CAdwaita
import Foundation

/// Loads an image through `ImageLoader`, trying each URL in turn, and shows `placeholder` until
/// it arrives (or for good, if none loads). The GTK counterpart of upstream's `RemoteImage` in
/// `Views/NFTGridView.swift`: the picture fills a `size` square and is centre-cropped to it,
/// round when `round` is set.
@MainActor
enum RemoteImage {
    static func make(urls: [URL], size: Int32, round: Bool, placeholder: () -> Widget) -> Widget {
        // An overlay takes its size from its main child alone, so the picture laid over it is
        // cut to the square rather than asking for its texture's full size.
        let slot = Widget(gtk_overlay_new()!)
        gtk_overlay_set_child(slot.opaque, placeholder().pointer)
        slot.size(width: size, height: size).expand().align(h: GTK_ALIGN_START, v: GTK_ALIGN_CENTER)
        gtk_widget_set_overflow(slot.pointer, GTK_OVERFLOW_HIDDEN)
        if round { slot.classes("round-image") }
        guard !urls.isEmpty else { return slot }
        // The pixels asked for cover the square on a 2× display.
        let pixels = Int(size) * 2
        let task = Task { @MainActor in
            guard let image = await ImageLoader.shared.image(for: urls, maxPixelSize: max(pixels, 80)), !Task.isCancelled else { return }
            let picture = Widget(gtk_picture_new_for_paintable(image.texture)!)
            gtk_picture_set_content_fit(picture.opaque, GTK_CONTENT_FIT_COVER)
            gtk_overlay_set_child(slot.opaque, UI.vbox().size(width: size, height: size).pointer)
            gtk_overlay_add_overlay(slot.opaque, picture.pointer)
        }
        // `.task(id:)` ends with the view.
        Signals.connect(slot, "destroy") { task.cancel() }
        return slot
    }
}
