use std::{fs, path::PathBuf};

use droid_peek_helper::protocol::PROTOCOL_VERSION;

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
        "ollieedgeley.droidpeek must expose the phoneTarget shell endpoint"
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
        phone_bindings.contains("omarchy-shell ollieedgeley.droidpeek phoneTarget"),
        "Lua target bindings must dispatch only through phoneTarget"
    );
    assert!(
        widget.contains("function configureScrcpy(")
            && phone_bindings.contains("omarchy-shell ollieedgeley.droidpeek configureScrcpy"),
        "Lua and QML must use the exact configureScrcpy shell endpoint"
    );
    assert!(
        !phone_bindings.contains("ollieedgeley.droidpeek phone-target")
            && !phone_bindings.contains("ollieedgeley.droidpeek configure-scrcpy"),
        "kebab-case shell endpoints are not callable QML IPC methods"
    );
    assert!(
        phone_bindings.contains("omarchy-shell shell hide ollieedgeley.droidpeek")
            && !phone_bindings.contains("omarchy-shell ollieedgeley.droidpeek close"),
        "panel close must use the shell hide router, not the raw plugin target"
    );
}

#[test]
fn phone_binding_assets_are_a_clean_cutover_from_action_routing() {
    let phone_bindings = source("integrations/phone-bindings.lua");
    let template = source("integrations/droid-peek.lua.example");

    for retired_path in [
        "integrations/hyprland.lua",
        "integrations/action-catalog.lua",
        "scripts/droid-peek-action",
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
        "droid-peek-action",
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
        template.contains("android.define_submap(\"droid-peek\"")
            && template.contains("android.bind("),
        "the user template must declare direct bindings in one named submap"
    );
}

#[test]
fn installer_and_template_share_the_exact_user_config_contract() {
    assert_absent("scripts/configure-droid-peek");

    let hyprland = source("scripts/lib/hyprland.sh");
    let common = source("scripts/lib/common.sh");
    let template = source("integrations/droid-peek.lua.example");
    let loader_block = concat!(
        "-- Droid Peek plugin loader (managed)\n",
        "require(\"hypr.droid-peek\")"
    );

    assert!(
        hyprland.contains("install_user_config") && hyprland.contains("remove_managed_loader"),
        "setup/cleanup must absorb managed-loader install and uninstall"
    );
    assert!(
        common.contains("XDG_CONFIG_HOME")
            && common.contains("droid-peek.lua")
            && common.contains(loader_block),
        "the Hyprland helper and managed loader block drifted"
    );
    assert!(
        template.contains(
            "/.config/omarchy/plugins/ollieedgeley.droidpeek/integrations/phone-bindings.lua"
        ),
        "the user template must load the plugin-owned API"
    );
}

#[test]
fn public_docs_state_the_live_scrcpy_control_rule() {
    let explanation = source("docs/explanation.md");
    let use_and_configure = source("docs/how-to-use-and-configure.md");
    let public_docs = [
        ("README.md", source("README.md")),
        ("docs/explanation.md", explanation.clone()),
        (
            "docs/how-to-fix-problems.md",
            source("docs/how-to-fix-problems.md"),
        ),
        (
            "docs/how-to-install-update-remove.md",
            source("docs/how-to-install-update-remove.md"),
        ),
        (
            "docs/how-to-use-and-configure.md",
            use_and_configure.clone(),
        ),
        ("docs/how-to-verify.md", source("docs/how-to-verify.md")),
        ("docs/reference.md", source("docs/reference.md")),
    ];

    for (path, text) in &public_docs {
        assert!(
            !text.contains("with control disabled")
                && !text.contains("control is always off")
                && !text.contains("runs scrcpy with control disabled"),
            "{path} must not claim scrcpy control is always off"
        );
    }

    let template = source("integrations/droid-peek.lua.example");
    assert!(
        template.contains("--keep-active")
            && template.contains("--turn-screen-off")
            && template.contains("--stay-awake")
            && template.contains("--keyboard=uhid"),
        "the shipped template must keep the device-awake flags that require control and the UHID keyboard default"
    );
    assert!(
        use_and_configure.contains("`scrcpyArgs`")
            && use_and_configure.contains("--keep-active")
            && use_and_configure.contains("--stay-awake")
            && use_and_configure.contains("--turn-screen-off")
            && use_and_configure
                .contains("The shipped configuration includes these arguments by default."),
        "the use-and-configure guide must state the live control arguments and that the shipped configuration enables them by default"
    );
    assert!(
        explanation.contains(
            "Only validated pointer, keyboard, quick-action, and Lua-binding inputs return"
        ) && explanation.contains("Bindings cannot become arbitrary `adb shell` commands."),
        "the explanation guide must keep the validated input boundary"
    );
}

#[test]
fn public_docs_and_template_cover_component_launch() {
    let template = source("integrations/droid-peek.lua.example");
    let docs = source("docs/how-to-use-and-configure.md");

    for needle in [
        "android.component.launch",
        "OnePlus Global Search",
        "Google App Search",
        "Samsung Finder",
        "com.oppo.quicksearchbox",
        "com.oplus.globalsearch.ui.SearchActivity",
        "com.google.android.googlequicksearchbox",
        "com.google.android.googlequicksearchbox.SearchActivity",
        "com.samsung.android.app.galaxyfinder",
        ".GalaxyFinderActivity",
        "SUPER + SPACE",
        "--keyboard=uhid",
    ] {
        assert!(template.contains(needle), "template must include {needle}");
    }

    assert!(
        docs.contains("android.component.launch")
            && docs.contains("Couldn't open")
            && docs.contains("Termux.")
            && docs.contains("Samsung Finder")
            && docs.contains("--keyboard=uhid")
            && docs.contains("Later setup runs preserve that user-owned file."),
        "the use-and-configure guide must document component launch, friendly failures, the UHID default, and preservation of existing user Lua"
    );
}
