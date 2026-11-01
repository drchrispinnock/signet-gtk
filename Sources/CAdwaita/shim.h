#include <adwaita.h>
#include <glib-unix.h>

/* libdispatch's hooks for a foreign run loop, as CoreFoundation uses them: a file descriptor that
   becomes readable when the main queue has work, and the call that drains it. Exported by
   libdispatch on every platform swift-corelibs-libdispatch supports. */
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);
