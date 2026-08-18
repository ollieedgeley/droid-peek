use std::{collections::BTreeSet, fs, path::PathBuf};

use omarchy_android_helper::{
    actions::{ACTION_SCHEMA_VERSION, SemanticAction},
    protocol::PROTOCOL_VERSION,
};
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActionManifest {
    schema_version: u8,
    actions: Vec<ActionEntry>,
}

#[derive(Deserialize)]
struct ActionEntry {
    id: String,
}

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

fn manifest_ids() -> BTreeSet<String> {
    let manifest: ActionManifest =
        serde_json::from_str(&source("actions.json")).expect("valid action manifest");
    assert_eq!(manifest.schema_version, ACTION_SCHEMA_VERSION);
    manifest
        .actions
        .into_iter()
        .map(|action| action.id)
        .collect()
}

fn qml_router_contract(input: &str) -> (BTreeSet<String>, BTreeSet<String>) {
    let body = input
        .split_once("function validSemanticAction(actionId, actionArgument) {")
        .and_then(|(_, rest)| rest.split_once("\n    }"))
        .map(|(body, _)| body)
        .expect("semantic action validator");
    let mut ids = BTreeSet::new();
    let mut package_argument_ids = BTreeSet::new();
    let mut pending_cases = Vec::new();

    for line in body.lines().map(str::trim) {
        if let Some(id) = line
            .strip_prefix("case \"")
            .and_then(|line| line.split_once('"').map(|(id, _)| id))
        {
            pending_cases.push(id.to_owned());
            continue;
        }

        if !line.starts_with("return ") || pending_cases.is_empty() {
            continue;
        }
        match line {
            "return actionArgument === \"\"" => {}
            "return validPackage(actionArgument)" => {
                package_argument_ids.extend(pending_cases.iter().cloned());
            }
            _ => panic!("unsupported semantic action argument grammar: {line}"),
        }
        ids.extend(pending_cases.drain(..));
    }

    assert!(
        pending_cases.is_empty(),
        "semantic action case has no return"
    );
    (ids, package_argument_ids)
}

fn shell_action_ids(input: &str) -> BTreeSet<String> {
    let case_body = input
        .split_once("case \"$action_id\" in")
        .and_then(|(_, rest)| rest.split_once("esac"))
        .map(|(body, _)| body)
        .expect("dispatcher action case");

    case_body
        .lines()
        .filter_map(|line| line.trim().strip_suffix(')'))
        .flat_map(|arm| arm.split(" | "))
        .filter(|id| *id != "*")
        .map(str::to_owned)
        .collect()
}

fn lua_target_ids(input: &str) -> BTreeSet<String> {
    input
        .lines()
        .filter_map(|line| {
            line.split("actionId = \"")
                .nth(1)?
                .split_once('"')
                .map(|(id, _)| id)
        })
        .map(str::to_owned)
        .collect()
}

#[test]
fn action_ids_remain_compatible_across_rust_qml_lua_and_shell() {
    let manifest = manifest_ids();
    let rust = SemanticAction::ALL
        .into_iter()
        .map(|action| action.as_str().to_owned())
        .collect::<BTreeSet<_>>();
    let (router, _) = qml_router_contract(&source("qml/state/SemanticActionRouter.qml"));
    let shell = shell_action_ids(&source("scripts/omarchy-android-action"));
    let mut lua = lua_target_ids(&source("integrations/action-catalog.lua"));
    lua.insert("android-launch-app".to_owned());

    assert_eq!(rust, manifest, "Rust and actions.json vocabularies drifted");
    assert!(
        router.is_subset(&manifest),
        "QML accepts an undeclared action"
    );
    assert_eq!(
        shell, lua,
        "Lua targets and shell dispatcher vocabularies drifted"
    );
    assert!(
        shell.is_subset(&router),
        "dispatcher accepts an action QML rejects"
    );
}

#[test]
fn protocol_and_argument_contracts_remain_aligned() {
    let state = source("qml/state/PairingState.qml");
    let (_, package_argument_ids) =
        qml_router_contract(&source("qml/state/SemanticActionRouter.qml"));
    let shell = source("scripts/omarchy-android-action");
    let lua = source("integrations/hyprland.lua");

    assert!(
        state.contains(&format!(
            "readonly property int protocolVersion: {PROTOCOL_VERSION}"
        )),
        "QML and Rust protocol versions drifted"
    );
    assert_eq!(
        package_argument_ids,
        BTreeSet::from(["android-launch-app".to_owned()]),
        "QML must allow a package argument only for package launch"
    );
    assert!(
        shell.contains("android-launch-app)")
            && shell.contains("[[ -z \"$action_argument\" ]] || exit 64"),
        "shell must allow an argument only for package launch"
    );
    assert!(
        lua.contains("action_id = \"android-launch-app\"")
            && lua.contains("argument = value.package"),
        "Lua package routes must use the declared package-launch action"
    );
}
