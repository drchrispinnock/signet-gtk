import CAdwaita
import Foundation

/// The app's stylesheet: the few looks libadwaita has no class for, drawn after upstream's
/// SwiftUI modifiers. Colours come from libadwaita's named colours so dark mode follows.
@MainActor
enum Style {
    static let css = """
    /* Theme.tezosBlue (#0D61FF). */
    @define-color tezos_blue #0d61ff;

    /* NetworkBadgeMenu: green lozenge on mainnet, orange on a testnet. */
    menubutton.network-badge > button {
      min-height: 0; padding: 2px 6px 2px 8px; border-radius: 999px;
      font-size: smaller; font-weight: 600; border: 1px solid transparent;
    }
    menubutton.network-badge.mainnet > button { background: alpha(@success_color, 0.2); color: @success_color; }
    menubutton.network-badge.testnet > button { background: alpha(@warning_color, 0.2); color: @warning_color; }
    menubutton.network-badge.mainnet > button:hover { background: alpha(@success_color, 0.35); border-color: alpha(@success_color, 0.6); }
    menubutton.network-badge.testnet > button:hover { background: alpha(@warning_color, 0.35); border-color: alpha(@warning_color, 0.6); }

    /* AccountAvatarView: a grey circle (the placeholder until remote avatars load). */
    .account-avatar { border-radius: 999px; background-color: alpha(currentColor, 0.1); border: 1px solid alpha(currentColor, 0.25); }

    /* WalletIdentityView. */
    menubutton.account-picker > button { padding: 0 4px; min-height: 0; }
    .alias { font-size: 1.45em; font-weight: 600; }
    .address { font-family: monospace; }
    .tag {
      padding: 1px 6px; border-radius: 999px; font-size: x-small; font-weight: 600;
      background: alpha(currentColor, 0.1);
    }
    .tag.session { color: @warning_color; background: alpha(@warning_color, 0.2); border: 1px solid alpha(@warning_color, 0.5); }

    /* NoWalletsView's StartOption. */
    button.start-option {
      padding: 12px 14px; border-radius: 10px;
      background: alpha(currentColor, 0.08); border: 1px solid alpha(currentColor, 0.3);
    }
    button.start-option.prominent { background: alpha(currentColor, 0.14); border-color: alpha(@accent_bg_color, 0.6); }
    button.start-option .symbol { color: alpha(currentColor, 0.55); }
    button.start-option label { font-weight: normal; }
    button.start-option label.heading { font-weight: bold; }
    button.start-option.prominent .symbol { color: @accent_color; }
    .welcome-title { font-size: 1.2em; font-weight: 600; }

    /* NodeStatusBar. */
    .status-bar { padding: 6px 12px; font-size: smaller; background: @headerbar_bg_color; }
    .node-light { min-width: 9px; min-height: 9px; border-radius: 999px; border: 1px solid alpha(black, 0.15); }
    .node-light.grey { background: #8e8e93; }
    .node-light.green { background: #34c759; }
    .node-light.yellow { background: #ffcc00; }
    .node-light.red { background: #ff3b30; }
    .node-host { font-weight: 500; }

    /* ActionButtonsView's ActionButtonStyle: equal tiles that fill the row. */
    button.action-tile {
      padding: 12px 0; border-radius: 8px;
      background: alpha(currentColor, 0.12); border: 1px solid alpha(currentColor, 0.35);
    }
    button.action-tile:hover { background: alpha(currentColor, 0.18); }
    button.action-tile:active { background: alpha(currentColor, 0.25); }
    button.action-tile label { font-weight: normal; }

    /* AssetListView. */
    .token-badge { border-radius: 999px; border: 1.5px solid alpha(currentColor, 0.55); }

    /* DelegateRowView. */
    button.delegate-row { padding: 0; }
    .delegate-headline { font-weight: 500; }
    .delegate-circle { border-radius: 999px; background: alpha(currentColor, 0.1); }

    /* AccountNotOnChainView. */
    .warning-circle { border-radius: 999px; background: alpha(@warning_color, 0.15); color: @warning_color; }

    /* ActivityTabsView. */
    .round-image { border-radius: 999px; }
    .transaction-row { padding: 8px 4px; border-radius: 8px; }
    .transaction-row:hover { background: alpha(currentColor, 0.08); }
    .transaction-headline { font-weight: 500; }
    .transaction-amount { font-weight: 500; }
    .transaction-amount.incoming { color: @success_color; }
    .verified { color: @success_color; }
    .failed-tag {
      padding: 1px 5px; border-radius: 999px; font-size: x-small; font-weight: 600;
      color: @error_color; background: alpha(@error_color, 0.15);
    }
    .direction-badge { border-radius: 999px; color: white; border: 1.5px solid @window_bg_color; }
    .direction-badge.green { background: #34c759; }
    .direction-badge.orange { background: #ff9500; }
    .direction-badge.blue { background: #007aff; }
    .direction-badge.grey { background: #8e8e93; }
    .standard-tag {
      padding: 1px 5px; border-radius: 999px; font-size: x-small; font-weight: 600;
      background: alpha(currentColor, 0.1);
    }
    .token-placeholder { border-radius: 999px; background: alpha(currentColor, 0.1); }
    .portfolio-note { color: @warning_color; }
    .nft-tile { border-radius: 10px; border: 1px solid alpha(currentColor, 0.25); }
    .nft-placeholder { background: alpha(currentColor, 0.1); }
    .tile-chip { padding: 2px 6px; border-radius: 999px; background: alpha(black, 0.6); color: white; }
    button.menu-item { font-weight: normal; }

    .error-message { color: @error_color; }
    """

    static func install() {
        // libadwaita's look assumes its own symbolic icons; another desktop's theme (XFCE's, say)
        // may lack them, and GTK then falls back to that theme's coloured ones.
        "Adwaita".withCString { name in
            setStringProperty(UnsafeMutableRawPointer(gtk_settings_get_default()!), "gtk-icon-theme-name", name)
        }
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }

    /// `g_object_set` is variadic, which Swift cannot call; this sets one string property.
    private static func setStringProperty(_ object: gpointer, _ name: String, _ value: UnsafePointer<CChar>) {
        var gvalue = GValue()
        g_value_init(&gvalue, gType(16))   // G_TYPE_STRING
        g_value_set_string(&gvalue, value)
        g_object_set_property(UnsafeMutablePointer(OpaquePointer(object)), name, &gvalue)
        g_value_unset(&gvalue)
    }
}
