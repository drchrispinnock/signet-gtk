import CAdwaita
import CWebKit
import Foundation

/// WebKit's navigation types under the names upstream's policy and its tests use
/// (`WKNavigationType`), mapped from WebKitGTK's `WebKitNavigationType`.
enum WKNavigationType: Int, Sendable {
    case linkActivated, formSubmitted, backForward, reload, formResubmitted
    case other = -1

    init(_ type: WebKitNavigationType) {
        self = switch type {
        case WEBKIT_NAVIGATION_TYPE_LINK_CLICKED: .linkActivated
        case WEBKIT_NAVIGATION_TYPE_FORM_SUBMITTED: .formSubmitted
        case WEBKIT_NAVIGATION_TYPE_BACK_FORWARD: .backForward
        case WEBKIT_NAVIGATION_TYPE_RELOAD: .reload
        case WEBKIT_NAVIGATION_TYPE_FORM_RESUBMITTED: .formResubmitted
        default: .other
        }
    }
}

/// Hosts the on-ramp's widget inside the app. The embedded page has no address bar, so the policy
/// is strict (S23): the main frame may only ever show HTTPS pages on the provider's own hosts,
/// and the sheet shows which host is up. Links the widget opens elsewhere go to the browser,
/// where the user can see where they are; any other foreign navigation (a redirect, a script, a
/// form posting away) is simply cancelled. Frames may only load HTTPS. Camera and microphone are
/// granted only to the provider's exact hosts, over HTTPS (its identity checks need them). The
/// GTK counterpart of upstream's `Views/BuyWebView.swift`, a WebKitGTK web view.
///
/// WebKitGTK does not say which frame a navigation is for when it is proposed, only when its
/// response arrives (`is_main_frame_main_resource`). So a proposed navigation is first checked
/// as a frame's would be (HTTPS or `about:blank`, else cancelled), and a main-frame page that is
/// not the provider's is stopped at its response, before it is shown: sent to the browser when
/// the user's own click or form led there, cancelled otherwise. Likewise a permission request
/// carries no frame, so camera and microphone go by the page the main frame is showing; WebKit
/// already keeps them from a cross-origin frame the page has not delegated them to.
@MainActor
final class BuyWebView {
    let root: Widget
    let provider: BuyProvider
    /// Called when loading starts or stops, fails, or the main frame's URL changes.
    var onChange: (@MainActor () -> Void)?
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// The URL the main frame is showing or loading, for the sheet's origin line.
    private(set) var currentURL: URL?
    /// The last foreign page the user's own click or form asked for: if the main frame's
    /// response turns out to be that page (or where it redirected), it goes to the browser.
    private var userRequested: URL?

    /// What to do with a navigation the web view proposes.
    enum NavigationPolicy: Equatable, Sendable {
        case allow
        /// A foreign page the user asked for: show it in the browser instead.
        case openInBrowser
        case cancel
    }

    init(url: URL, provider: BuyProvider = .current) {
        self.provider = provider
        let view = webkit_web_view_new()!
        root = Widget(view)
        let webView = UnsafeMutableRawPointer(view).assumingMemoryBound(to: WebKitWebView.self)
        let settings = webkit_web_view_get_settings(webView)
        webkit_settings_set_enable_fullscreen(settings, 0)
        webkit_settings_set_enable_javascript(settings, 1)
        webkit_settings_set_enable_back_forward_navigation_gestures(settings, 0)
        root.retain(self, key: "signet-buy-web-view")
        connect()
        currentURL = url
        webkit_web_view_load_uri(webView, url.absoluteString)
    }

    private var webView: UnsafeMutablePointer<WebKitWebView> { root.as() }

    // MARK: Policy (pure, tested)

    /// An HTTPS URL on one of the provider's hosts.
    nonisolated static func isTrusted(_ url: URL?, provider: BuyProvider = .current) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              let host = url.host()?.lowercased() else { return false }
        return isTrustedHost(host, provider: provider)
    }

    nonisolated static func isTrustedHost(_ host: String, provider: BuyProvider) -> Bool {
        let lower = host.lowercased()
        return provider.trustedHosts.contains(lower) || lower.hasSuffix(provider.trustedDomainSuffix)
    }

    /// Decides every navigation, main frame or not, whatever started it.
    nonisolated static func policy(for url: URL?, navigationType: WKNavigationType, isMainFrame: Bool, provider: BuyProvider) -> NavigationPolicy {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == "about", url.absoluteString == "about:blank" { return .allow }
        guard scheme == "https" else { return .cancel }    // plain http, custom schemes, data:, file:
        guard isMainFrame else { return .allow }           // frames: any HTTPS, no browser hand-off
        if isTrusted(url, provider: provider) { return .allow }
        // Only something the user did on the page earns a trip to the browser; a redirect, a
        // script or a timer does not.
        switch navigationType {
        case .linkActivated, .formSubmitted: return .openInBrowser
        default: return .cancel
        }
    }

    /// Whether `window.open(url)` may be forwarded to the browser: only web URLs.
    nonisolated static func mayOpenInBrowser(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// Camera/microphone: the provider's exact hosts, over HTTPS, asked for by the main frame
    /// whose own origin is that host.
    nonisolated static func mayCaptureMedia(originProtocol: String, originHost: String, isMainFrame: Bool, frameProtocol: String?, frameHost: String?, provider: BuyProvider, originPort: Int = 443, framePort: Int = 443) -> Bool {
        guard originProtocol.lowercased() == "https", isMainFrame, (originPort == 0 || originPort == 443), (framePort == 0 || framePort == 443) else { return false }
        let host = originHost.lowercased()
        guard provider.trustedHosts.contains(host) else { return false }
        return frameProtocol?.lowercased() == "https" && frameHost?.lowercased() == host
    }

    // MARK: WebKitGTK

    private func connect() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        let decide: @convention(c) (OpaquePointer?, UnsafeMutablePointer<WebKitPolicyDecision>?, WebKitPolicyDecisionType, gpointer?) -> gboolean = { _, decision, type, data in
            let view = Unmanaged<BuyWebView>.fromOpaque(data!).takeUnretainedValue()
            return MainActor.assumeIsolated { view.decide(decision!, type: type) ? 1 : 0 }
        }
        g_signal_connect_data(root.raw, "decide-policy", unsafeBitCast(decide, to: GCallback.self), me, nil, GConnectFlags(rawValue: 0))

        let changed: @convention(c) (OpaquePointer?, WebKitLoadEvent, gpointer?) -> Void = { _, event, data in
            let view = Unmanaged<BuyWebView>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated { view.loadChanged(event) }
        }
        g_signal_connect_data(root.raw, "load-changed", unsafeBitCast(changed, to: GCallback.self), me, nil, GConnectFlags(rawValue: 0))

        let failed: @convention(c) (OpaquePointer?, WebKitLoadEvent, UnsafePointer<CChar>?, UnsafeMutablePointer<GError>?, gpointer?) -> gboolean = { _, _, _, error, data in
            let view = Unmanaged<BuyWebView>.fromOpaque(data!).takeUnretainedValue()
            return MainActor.assumeIsolated { view.loadFailed(error) ? 1 : 0 }
        }
        g_signal_connect_data(root.raw, "load-failed", unsafeBitCast(failed, to: GCallback.self), me, nil, GConnectFlags(rawValue: 0))

        let permission: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean = { _, request, data in
            let view = Unmanaged<BuyWebView>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated { view.decidePermission(request!) }
            return 1
        }
        g_signal_connect_data(root.raw, "permission-request", unsafeBitCast(permission, to: GCallback.self), me, nil, GConnectFlags(rawValue: 0))
    }

    /// Every policy decision WebKit asks for; true when it has been made here.
    private func decide(_ decision: UnsafeMutablePointer<WebKitPolicyDecision>, type: WebKitPolicyDecisionType) -> Bool {
        let specific = OpaquePointer(decision)   // the navigation or response decision it is
        switch type {
        case WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION:
            guard let action = webkit_navigation_policy_decision_get_navigation_action(specific) else { webkit_policy_decision_ignore(decision); return true }
            let url = Self.url(of: action)
            let kind = WKNavigationType(webkit_navigation_action_get_navigation_type(action))
            // The frame is not known yet: a frame's rule now, the main frame's at the response.
            guard Self.policy(for: url, navigationType: kind, isMainFrame: false, provider: provider) == .allow else {
                webkit_policy_decision_ignore(decision)
                return true
            }
            if let url, Self.policy(for: url, navigationType: kind, isMainFrame: true, provider: provider) == .openInBrowser {
                userRequested = url
            }
            webkit_policy_decision_use(decision)
            return true
        case WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION:
            // `window.open` and `target="_blank"`: web pages go to the browser; nothing opens here.
            if let action = webkit_navigation_policy_decision_get_navigation_action(specific), let url = Self.url(of: action), Self.mayOpenInBrowser(url) {
                UI.open(url, from: root)
            }
            webkit_policy_decision_ignore(decision)
            return true
        case WEBKIT_POLICY_DECISION_TYPE_RESPONSE:
            guard webkit_response_policy_decision_is_main_frame_main_resource(specific) != 0 else { return false }
            let request = webkit_response_policy_decision_get_request(specific)
            let url = request.flatMap { webkit_uri_request_get_uri($0) }.flatMap { URL(string: String(cString: $0)) }
            guard let url, !Self.isTrusted(url, provider: provider), url.absoluteString != "about:blank" else { return false }
            webkit_policy_decision_ignore(decision)
            if let requested = userRequested {
                userRequested = nil
                UI.open(requested, from: root)
            } else {
                loadError = "Blocked a page outside \(provider.title): \(url.host() ?? url.scheme ?? "unknown"). Use “Open in browser instead” if you need it."
                onChange?()
            }
            return true
        default:
            return false
        }
    }

    private static func url(of action: OpaquePointer) -> URL? {
        guard let request = webkit_navigation_action_get_request(action), let uri = webkit_uri_request_get_uri(request) else { return nil }
        return URL(string: String(cString: uri))
    }

    private func showCurrent() {
        if let uri = webkit_web_view_get_uri(webView) { currentURL = URL(string: String(cString: uri)) }
    }

    private func loadChanged(_ event: WebKitLoadEvent) {
        switch event {
        case WEBKIT_LOAD_STARTED:
            isLoading = true
            loadError = nil
        case WEBKIT_LOAD_FINISHED:
            isLoading = false
            userRequested = nil
        default:
            break
        }
        showCurrent()
        onChange?()
    }

    /// True keeps WebKit's own error page away; a cancelled load or one stopped by policy is
    /// not an error worth showing.
    private func loadFailed(_ error: UnsafeMutablePointer<GError>?) -> Bool {
        isLoading = false
        if let error {
            let domain = error.pointee.domain
            let code = error.pointee.code
            let cancelled = (domain == webkit_network_error_quark() && code == Int32(WEBKIT_NETWORK_ERROR_CANCELLED.rawValue))
                || (domain == webkit_policy_error_quark() && code == Int32(WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE.rawValue))
            if !cancelled { loadError = String(cString: error.pointee.message) }
        }
        showCurrent()
        onChange?()
        return false
    }

    /// Camera and microphone (and the device list the page reads first) for the provider's own
    /// page; everything else is refused.
    private func decidePermission(_ request: OpaquePointer) {
        let instance = UnsafeMutableRawPointer(request).assumingMemoryBound(to: GTypeInstance.self)
        let media = g_type_check_instance_is_a(instance, webkit_user_media_permission_request_get_type()) != 0
            || g_type_check_instance_is_a(instance, webkit_device_info_permission_request_get_type()) != 0
        let page = webkit_web_view_get_uri(webView).flatMap { URL(string: String(cString: $0)) }
        let allowed = media && page.map { page in
            Self.mayCaptureMedia(originProtocol: page.scheme ?? "", originHost: page.host() ?? "", isMainFrame: true,
                                 frameProtocol: page.scheme, frameHost: page.host(), provider: provider,
                                 originPort: page.port ?? 0, framePort: page.port ?? 0)
        } == true
        allowed ? webkit_permission_request_allow(request) : webkit_permission_request_deny(request)
    }
}
