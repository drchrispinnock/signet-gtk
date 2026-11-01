import CAdwaita
import Foundation

/// Lets GTK's GLib main loop run Swift's main queue too. Anything on the main actor
/// (`WalletViewModel`, the views, `Task { @MainActor … }`) is queued on libdispatch's main queue,
/// which nothing drains unless the main thread runs `dispatchMain()` or a run loop that knows
/// about it. GLib watches the queue's file descriptor and drains it when it becomes readable,
/// the way CoreFoundation's run loop does on the Mac.
enum MainLoop {
    static func attachMainQueue() {
        let fd = _dispatch_get_main_queue_handle_4CF()
        g_unix_fd_add(fd, G_IO_IN, { fd, _, _ in
            // The descriptor is an eventfd: clear it, then run what is queued.
            var count: UInt64 = 0
            _ = read(fd, &count, MemoryLayout<UInt64>.size)
            _dispatch_main_queue_callback_4CF(nil)
            return gboolean(1)   // G_SOURCE_CONTINUE
        }, nil)
    }
}
