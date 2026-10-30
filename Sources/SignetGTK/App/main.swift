import CAdwaita
import Foundation

// Placeholder window while the views are ported: proves GTK4, libadwaita and the Signet module
// link together and that the bridge loads.

let app = adw_application_new("org.tezos.signet", G_APPLICATION_DEFAULT_FLAGS)!

let activate: @convention(c) (UnsafeMutablePointer<GApplication>?, gpointer?) -> Void = { application, _ in
    let window = adw_application_window_new(UnsafeMutablePointer(OpaquePointer(application)))!
    gtk_window_set_title(UnsafeMutablePointer(OpaquePointer(window)), "Signet")
    gtk_window_set_default_size(UnsafeMutablePointer(OpaquePointer(window)), 480, 640)
    let page = adw_status_page_new()!
    adw_status_page_set_title(OpaquePointer(page), "Signet")
    adw_status_page_set_description(OpaquePointer(page), "A Tezos wallet. The GTK port is starting up.")
    adw_application_window_set_content(UnsafeMutablePointer(OpaquePointer(window)), page)
    gtk_window_present(UnsafeMutablePointer(OpaquePointer(window)))
}
g_signal_connect_data(app, "activate", unsafeBitCast(activate, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
exit(g_application_run(UnsafeMutablePointer(OpaquePointer(app)), CommandLine.argc, CommandLine.unsafeArgv))
