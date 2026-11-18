import CAdwaita
import CWebKit
import Foundation

/// Help > Getting Started: the book's Getting Started chapter (`manuscript/110-starting.md` and
/// its screenshots, bundled with the app) rendered by `Markua` and shown in a window of its own,
/// as upstream's `GettingStartedView` (a `Window` scene there). Links within the chapter
/// scroll; every other link opens in the browser. The page runs no JavaScript.
@MainActor
final class GettingStartedView {
    static let chapterResource = "110-starting"

    private static var shown: Widget?

    /// Brings the window up, or to the front when it is already open.
    static func present(app: Widget) {
        if let shown {
            gtk_window_present(shown.as())
            return
        }
        let window = Widget(adw_window_new()!)
        gtk_window_set_application(window.as(), app.as())
        gtk_window_set_title(window.as(), "Getting Started")
        gtk_window_set_default_size(window.as(), 860, 780)
        // `.frame(minWidth: 560, minHeight: 480)`.
        window.size(width: 560, height: 480)

        let body: Widget
        if let html = chapterHTML() {
            body = ChapterWebView(html: html, baseURL: resourceDirectory).root
        } else {
            let link = UI.button("Read it online", classes: ["flat"]) { UI.open(SignetApp.gettingStartedURL, from: window) }
            body = UI.vbox(spacing: 12, [UI.label("The Getting Started chapter is missing from this copy of Signet.", xalign: 0.5), link.align(h: GTK_ALIGN_CENTER)])
                .align(h: GTK_ALIGN_CENTER, v: GTK_ALIGN_CENTER).margins(40)
        }
        let toolbar = Widget(adw_toolbar_view_new()!)
        adw_toolbar_view_add_top_bar(toolbar.opaque, adw_header_bar_new())
        adw_toolbar_view_set_content(toolbar.opaque, body.pointer)
        adw_window_set_content(window.as(), toolbar.pointer)
        Signals.connect(window, "destroy") { shown = nil }
        shown = window
        gtk_window_present(window.as())
    }

    /// Where the chapter's pictures are (`110/…` beside it).
    static var resourceDirectory: URL? { Bundle.module.resourceURL }

    /// The chapter as HTML, from the bundle (upstream reads `Bundle.main`, which holds no
    /// resources in a SwiftPM build).
    static func chapterHTML(bundle: Bundle = .module) -> String? {
        guard let url = bundle.url(forResource: chapterResource, withExtension: "md"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Markua.html(from: source, title: "Getting Started")
    }
}

/// A web view for one rendered page: no JavaScript, nothing fetched but the bundled pictures.
@MainActor
private final class ChapterWebView {
    let root: Widget

    init(html: String, baseURL: URL?) {
        let view = webkit_web_view_new()!
        root = Widget(view)
        let webView: UnsafeMutablePointer<WebKitWebView> = root.as()
        let settings = webkit_web_view_get_settings(webView)
        webkit_settings_set_enable_javascript(settings, 0)
        webkit_settings_set_enable_back_forward_navigation_gestures(settings, 0)
        root.retain(self, key: "signet-chapter-web-view")
        let decide: @convention(c) (OpaquePointer?, UnsafeMutablePointer<WebKitPolicyDecision>?, WebKitPolicyDecisionType, gpointer?) -> gboolean = { view, decision, type, _ in
            MainActor.assumeIsolated { ChapterWebView.decide(decision!, type: type, view: view) ? 1 : 0 }
        }
        g_signal_connect_data(root.raw, "decide-policy", unsafeBitCast(decide, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
        // The directory URL with its trailing slash, so `110/…` resolves inside it.
        webkit_web_view_load_html(webView, html, baseURL.map { $0.absoluteString.hasSuffix("/") ? $0.absoluteString : $0.absoluteString + "/" })
    }

    /// Link clicks: a place in the chapter scrolls there, a web or mail link goes to the browser,
    /// anything else is refused. The page itself and its pictures load.
    private static func decide(_ decision: UnsafeMutablePointer<WebKitPolicyDecision>, type: WebKitPolicyDecisionType, view: OpaquePointer?) -> Bool {
        guard type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION || type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION else { return false }
        let specific = OpaquePointer(decision)
        guard let action = webkit_navigation_policy_decision_get_navigation_action(specific) else { return false }
        let isLink = webkit_navigation_action_get_navigation_type(action) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED
        guard isLink || type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION else { return false }
        let url = webkit_navigation_action_get_request(action).flatMap { webkit_uri_request_get_uri($0) }.flatMap { URL(string: String(cString: $0)) }
        if let url, url.fragment != nil, url.scheme == "file" || url.scheme == "about", type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION {
            webkit_policy_decision_use(decision)
            return true
        }
        if let url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""), let view {
            UI.open(url, from: Widget(view))
        }
        webkit_policy_decision_ignore(decision)
        return true
    }
}
