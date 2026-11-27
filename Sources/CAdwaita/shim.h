#include <adwaita.h>
#include <glib-unix.h>

/* libdispatch's hooks for a foreign run loop, as CoreFoundation uses them: a file descriptor that
   becomes readable when the main queue has work, and the call that drains it. Exported by
   libdispatch on every platform swift-corelibs-libdispatch supports. */
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);
#if defined(__FreeBSD__)
/* Swift 6.4's libdispatch gives FreeBSD a pipe, not an eventfd: the handle is a uint64_t with
   the read end in the high 32 bits and the write end in the low 32 (6.5 has an eventfd again). */
extern unsigned long long signet_dispatch_main_queue_pipe_4CF(void)
    __asm__("_dispatch_get_main_queue_handle_4CF");
#endif

/* The recovery sheet is also drawn into a PDF in memory, for its tests. */
#include <cairo-pdf.h>
