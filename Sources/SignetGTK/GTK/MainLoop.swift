import CAdwaita
import Foundation

/// Lets GTK's GLib main loop run Swift's main queue too. Anything on the main actor
/// (`WalletViewModel`, the views, `Task { @MainActor … }`) is queued on libdispatch's main queue,
/// which nothing drains unless the main thread runs `dispatchMain()` or a run loop that knows
/// about it. GLib watches the queue's file descriptor and drains it when it becomes readable,
/// the way CoreFoundation's run loop does on the Mac.
enum MainLoop {
    static func attachMainQueue() {
        #if os(FreeBSD) && !compiler(>=6.5)
        // A pipe: watch its read end (the handle's high half; the low half is the write end,
        // which never becomes readable) and empty it, since each wakeup writes a byte.
        let fd = Int32(truncatingIfNeeded: signet_dispatch_main_queue_pipe_4CF() >> 32)
        g_unix_fd_add(fd, G_IO_IN, { fd, _, _ in
            var bytes = [UInt8](repeating: 0, count: 64)
            while read(fd, &bytes, bytes.count) > 0 {}
            _dispatch_main_queue_callback_4CF(nil)
            return gboolean(1)   // G_SOURCE_CONTINUE
        }, nil)
        #else
        let fd = _dispatch_get_main_queue_handle_4CF()
        g_unix_fd_add(fd, G_IO_IN, { fd, _, _ in
            // The descriptor is an eventfd: clear it, then run what is queued.
            var count: UInt64 = 0
            _ = read(fd, &count, MemoryLayout<UInt64>.size)
            _dispatch_main_queue_callback_4CF(nil)
            return gboolean(1)   // G_SOURCE_CONTINUE
        }, nil)
        #endif
    }
}
