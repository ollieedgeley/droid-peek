use std::{
    fs,
    path::{Path, PathBuf},
};

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

fn collect_qml(dir: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries {
        let path = entry.expect("read qml entry").path();
        if path.is_dir() {
            collect_qml(&path, files);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("qml") {
            files.push(path);
        }
    }
}

fn production_qml_files() -> Vec<PathBuf> {
    let root = project_root();
    let mut files = Vec::new();
    collect_qml(&root.join("qml"), &mut files);
    for name in ["BarWidget.qml", "Panel.qml"] {
        let path = root.join(name);
        if path.exists() {
            files.push(path);
        }
    }
    files.sort();
    files
}

fn has_scrcpy_reserved_list(contents: &str) -> bool {
    contents.contains("\"--select-usb\"")
        && contents.contains("\"--serial\"")
        && contents.contains("reserved")
}

#[test]
fn qml_keeps_one_scrcpy_reserved_list() {
    let root = project_root();
    let copies: Vec<_> = production_qml_files()
        .into_iter()
        .filter(|path| has_scrcpy_reserved_list(&fs::read_to_string(path).unwrap()))
        .map(|path| {
            path.strip_prefix(&root)
                .expect("qml path stays under project root")
                .to_path_buf()
        })
        .collect();

    assert_eq!(
        copies,
        [PathBuf::from("qml/state/PairingState.qml")],
        "same-process QML must keep exactly one reserved list"
    );

    let widget = source("BarWidget.qml");
    assert!(
        !widget.contains("function validScrcpyArguments"),
        "BarWidget must not keep a widget-local reserved-list check"
    );
    assert!(
        widget.contains("function configureScrcpy(")
            && widget.contains("/^[0-9a-f]{16}$/")
            && widget.contains("decodeEnvelope(encodedConfiguration")
            && widget.contains("setScrcpyConfiguration"),
        "BarWidget must still decode and hex-check, then fail closed on the panel"
    );
    assert!(
        !root.join("qml/ScrcpyArgs.js").exists() && !root.join("ScrcpyArgs.js").exists(),
        "do not add a shared ScrcpyArgs.js helper"
    );

    let lua = source("integrations/phone-bindings.lua");
    let rust = source("helper/src/scrcpy_config.rs");
    assert!(
        lua.contains("reserved_scrcpy_arguments") && lua.contains("[\"--serial\"]"),
        "Lua reserved list must remain"
    );
    assert!(
        rust.contains("RESERVED_ARGUMENTS") && rust.contains("\"--serial\""),
        "Rust reserved list must remain"
    );
}
