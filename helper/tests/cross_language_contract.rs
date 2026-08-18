use std::{fs, path::PathBuf};

use omarchy_android_helper::protocol::PROTOCOL_VERSION;

fn project_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("helper crate has a project root")
        .to_path_buf()
}

fn source(path: &str) -> String {
    fs::read_to_string(project_root().join(path))
        .unwrap_or_else(|error| panic!("read {path}: {error}"))
}

fn assert_absent(path: &str) {
    assert!(
        !project_root().join(path).exists(),
        "retired architecture file must be removed: {path}"
    );
}

fn assert_excludes(input: &str, retired_names: &[&str], surface: &str) {
    for retired_name in retired_names {
        assert!(
            !input.contains(*retired_name),
            "{surface} retains retired routing name {retired_name}"
        );
    }
}

#[test]
fn protocol_v11_phone_target_endpoint_is_aligned_across_languages() {
    assert_eq!(PROTOCOL_VERSION, 11, "the clean-cutover protocol is v11");

    let pairing_state = source("qml/state/PairingState.qml");
    let widget = source("BarWidget.qml");
    let protocol = source("helper/src/protocol.rs");
    let phone_bindings = source("integrations/phone-bindings.lua");

    assert!(
        pairing_state.contains("readonly property int protocolVersion: 11"),
        "QML and Rust protocol versions drifted"
    );
    assert!(
        widget.contains("function phoneTarget("),
        "ollie.android must expose the phoneTarget shell endpoint"
    );
    assert!(
        !widget.contains("function action("),
        "the generic semantic action shell endpoint must be removed"
    );
    assert!(
        protocol.contains("PhoneTarget")
            && protocol.contains("helper_epoch")
            && protocol.contains("session_generation"),
        "Rust phone-target must carry the two-part session identity"
    );
    assert!(
        phone_bindings.contains("omarchy-shell ollie.android phoneTarget"),
        "Lua target bindings must dispatch only through phoneTarget"
    );
    assert!(
        widget.contains("function configureScrcpy(")
            && phone_bindings.contains("omarchy-shell ollie.android configureScrcpy"),
        "Lua and QML must use the exact configureScrcpy shell endpoint"
    );
    assert!(
        !phone_bindings.contains("ollie.android phone-target")
            && !phone_bindings.contains("ollie.android configure-scrcpy"),
        "kebab-case shell endpoints are not callable QML IPC methods"
    );
}

#[test]
fn phone_binding_assets_are_a_clean_cutover_from_action_routing() {
    let phone_bindings = source("integrations/phone-bindings.lua");
    let template = source("integrations/omarchy-android.lua.example");

    for retired_path in [
        "integrations/hyprland.lua",
        "integrations/action-catalog.lua",
        "scripts/omarchy-android-action",
        "qml/state/SemanticActionRouter.qml",
    ] {
        assert_absent(retired_path);
    }

    let retired_names = [
        "routes",
        "customBindings",
        "smartDefaults",
        "actionId",
        "commandPassthrough",
        "install_custom_bindings",
        "omarchy-android-action",
    ];
    assert_excludes(&phone_bindings, &retired_names, "phone-binding API");
    assert_excludes(&template, &retired_names, "user template");

    assert!(
        phone_bindings.contains("define_submap")
            && phone_bindings.contains("close_panel")
            && phone_bindings.contains("expiresAtUnixMs"),
        "the Lua API must own the named submap, mandatory close, and typed deadline"
    );
    assert!(
        template.contains("android.define_submap(\"omarchy-android\"")
            && template.contains("android.bind("),
        "the user template must declare direct bindings in one named submap"
    );
}

#[test]
fn installer_and_template_share_the_exact_user_config_contract() {
    let configurator = source("scripts/configure-phone-bindings");
    let template = source("integrations/omarchy-android.lua.example");
    let loader_block = concat!(
        "-- Omarchy Android plugin loader (managed)\n",
        "require(\"hypr.omarchy-android\")"
    );

    assert!(
        configurator.contains("install") && configurator.contains("uninstall"),
        "the configurator must expose install and uninstall"
    );
    assert!(
        configurator.contains("XDG_CONFIG_HOME")
            && configurator.contains("omarchy-android.lua")
            && configurator.contains(loader_block),
        "the configurator and managed loader block drifted"
    );
    assert!(
        template.contains("/.config/omarchy/plugins/ollie.android/integrations/phone-bindings.lua"),
        "the user template must load the plugin-owned API"
    );
}
