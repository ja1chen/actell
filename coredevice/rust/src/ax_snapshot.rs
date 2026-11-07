// SPDX-License-Identifier: GPL-3.0-only
// Native snapshot field interpretation is adapted from ipb;
// Copyright (c) 2026 Borealin and ipbtools contributors, MIT.
// Full notice: ios-app/Licenses/ipb-MIT.txt.
//! Validate a native AX tree and expose only snapshot-local node identities.
use std::collections::VecDeque;
use serde_json::{json, Value};
use crate::ax_archive::{AxValue, Token};
use crate::ax_dtx::Failure;

const MAX_NODES: usize = 512;
const MAX_DEPTH: usize = 32;

fn scalar(value: &AxValue) -> Result<Value, Failure> {
    Ok(match value {
        AxValue::Null => Value::Null, AxValue::Bool(v) => json!(v), AxValue::String(v) => json!(v),
        AxValue::Integer(v) => {
            if let Some(n) = v.as_signed() { json!(n) }
            else if let Some(n) = v.as_unsigned() { if n > 9_007_199_254_740_991 { json!(n.to_string()) } else { json!(n) } }
            else { return Err(Failure::Snapshot); }
        }
        AxValue::Real(v) if v.is_finite() => json!(v),
        _ => return Err(Failure::Snapshot),
    })
}
fn frame(value: Option<&AxValue>) -> Result<(Value, &'static str), Failure> {
    let Some(value) = value else { return Ok((Value::Null, "missing")); };
    if value == &AxValue::Null { return Ok((Value::Null, "unavailable")); }
    let AxValue::Rect(text) = value else { return Err(Failure::Snapshot); };
    let parts: Vec<_> = text.split(|c: char| c == '{' || c == '}' || c == ',' || c.is_ascii_whitespace()).filter(|s| !s.is_empty()).collect();
    if parts.len() != 4 { return Err(Failure::Snapshot); }
    let nums: Vec<f64> = parts.iter().map(|s| s.parse::<f64>().map_err(|_| Failure::Snapshot)).collect::<Result<_,_>>()?;
    if nums[0] == f64::INFINITY && nums[1] == f64::INFINITY && nums[2] == 0.0 && nums[3] == 0.0 { return Ok((Value::Null, "CGRectNull")); }
    if nums.iter().any(|v| !v.is_finite()) || nums[2] < 0.0 || nums[3] < 0.0 { return Err(Failure::Snapshot); }
    Ok((json!({"x":nums[0], "y":nums[1], "width":nums[2], "height":nums[3]}), "available"))
}
fn boolean(value: Option<&AxValue>) -> Result<Value, Failure> {
    Ok(match value {
        None | Some(AxValue::Null) => Value::Null,
        Some(AxValue::Bool(v)) => json!(v),
        Some(AxValue::Integer(v)) if v.as_unsigned() == Some(0) => json!(false),
        Some(AxValue::Integer(v)) if v.as_unsigned() == Some(1) => json!(true),
        _ => return Err(Failure::Snapshot),
    })
}
fn field(value: &AxValue, key: u64) -> Result<Value, Failure> {
    value.number_key(key).map(scalar).transpose().map(|v| v.unwrap_or(Value::Null))
}

pub(crate) fn normalize(tree: &AxValue, root: &Token, started: u128, ended: u128) -> Result<Value, Failure> {
    let first = Token::from_value(tree.field("UIAccessibilitySnapshotKeyElement").ok_or(Failure::Snapshot)?).map_err(|_| Failure::Snapshot)?;
    if first.pid != root.pid || first.object_id != root.object_id { return Err(Failure::Mismatch); }
    let mut queue = VecDeque::from([(tree, None::<usize>, Vec::<usize>::new(), 0usize)]);
    let mut nodes: Vec<Value> = Vec::new(); let mut assigned = 1usize;
    while let Some((record, parent, path, id)) = queue.pop_front() {
        if path.len() > MAX_DEPTH || id >= MAX_NODES || id != nodes.len() { return Err(Failure::Limit); }
        let token = Token::from_value(record.field("UIAccessibilitySnapshotKeyElement").ok_or(Failure::Snapshot)?).map_err(|_| Failure::Snapshot)?;
        let attrs = record.field("UIAccessibilitySnapshotKeyAttributes").ok_or(Failure::Snapshot)?;
        if !matches!(attrs, AxValue::Map(_)) { return Err(Failure::Snapshot); }
        let children = record.field("UIAccessibilitySnapshotKeyChildren").and_then(AxValue::array).ok_or(Failure::Snapshot)?;
        let count = record.field("UIAccessibilitySnapshotKeyChildrenCount").and_then(AxValue::uint).ok_or(Failure::Snapshot)?;
        if count != children.len() as u64 { return Err(Failure::Snapshot); }
        let external = token.pid != root.pid;
        if external && (attrs.number_key(5003).and_then(AxValue::str) != Some("AXRemoteElement") || !children.is_empty()) { return Err(Failure::Snapshot); }
        if assigned.checked_add(children.len()).is_none_or(|n| n > MAX_NODES) || (!children.is_empty() && path.len() == MAX_DEPTH) { return Err(Failure::Limit); }
        let mut child_ids = Vec::with_capacity(children.len());
        for (index, child) in children.iter().enumerate() {
            let child_id = assigned; assigned += 1; child_ids.push(format!("n{child_id}"));
            let mut child_path = path.clone(); child_path.push(index);
            queue.push_back((child, Some(id), child_path, child_id));
        }
        let (rect, status) = frame(attrs.number_key(2003))?;
        let traits = match attrs.number_key(2004) {
            None | Some(AxValue::Null) => Value::Null,
            Some(AxValue::Integer(v)) => {
                let n = v.as_unsigned().or_else(|| v.as_signed().map(|x| x as u64)).ok_or(Failure::Snapshot)?;
                json!(n.to_string())
            }
            _ => return Err(Failure::Snapshot),
        };
        let mut metadata = serde_json::Map::new();
        for k in [5003u64, 5004, 3003] {
            if let Some(v) = attrs.number_key(k) {
                if v != &AxValue::Null { metadata.insert(k.to_string(), json!(v.str().ok_or(Failure::Snapshot)?)); }
            }
        }
        let hint = match attrs.number_key(2002) {
            None | Some(AxValue::Null) => Value::Null,
            Some(v) => json!(v.str().ok_or(Failure::Snapshot)?),
        };
        nodes.push(json!({
            "nodeId":format!("n{id}"), "parentId":parent.map(|p| format!("n{p}")), "path":path,
            "children":child_ids, "label":field(attrs,2001)?, "hint":hint, "identifier":field(attrs,5019)?,
            "value":field(attrs,2006)?, "frame":rect, "frameStatus":status, "traits":traits,
            "visible":boolean(attrs.number_key(2025))?, "externalProcessReference":external,
            "fieldPresence":{
                "label":attrs.number_key(2001).is_some(), "hint":attrs.number_key(2002).is_some(),
                "identifier":attrs.number_key(5019).is_some(), "value":attrs.number_key(2006).is_some(),
                "frame":attrs.number_key(2003).is_some(), "traits":attrs.number_key(2004).is_some(), "visible":attrs.number_key(2025).is_some()
            },
            "processIdentifier":if external { Some(token.pid) } else { None }, "nativeAttributes":metadata,
        }));
    }
    Ok(json!({
        "schemaVersion":1, "status":"available", "snapshotId":uuid::Uuid::new_v4().to_string(),
        "application":{"pid":root.pid,"bundleId":Value::Null}, "selection":{"method":"explicit-pid"},
        "hierarchySource":"AXUserTestingSnapshot", "stateScope":"native-snapshot", "atomic":false,
        "captureWindow":{"startedAtUnixMs":started as u64,"endedAtUnixMs":ended as u64},
        "coordinateSpace":{"unit":"logical-point","displayId":Value::Null,"orientation":Value::Null,"geometryId":Value::Null,"mappingStatus":"unverified"},
        "nodes":nodes,"supplementalAX":{"status":"not-requested"}
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn map(values: Vec<(&str, AxValue)>) -> AxValue { AxValue::Map(values.into_iter().map(|(k,v)| (AxValue::String(k.into()),v)).collect()) }
    fn token(pid: u64, id: u64) -> AxValue { map(vec![("pid", AxValue::Integer(pid.into())), ("objectID", AxValue::Integer(id.into())), ("isApplicationElement", AxValue::Bool(true))]) }
    fn node(pid: u64, id: u64, children: Vec<AxValue>, attrs: Vec<(u64, AxValue)>) -> AxValue {
        map(vec![("UIAccessibilitySnapshotKeyElement", token(pid, id)),
            ("UIAccessibilitySnapshotKeyChildrenCount", AxValue::Integer((children.len() as u64).into())),
            ("UIAccessibilitySnapshotKeyChildren", AxValue::Array(children)),
            ("UIAccessibilitySnapshotKeyAttributes", AxValue::Map(attrs.into_iter().map(|(k,v)| (AxValue::Integer(k.into()),v)).collect()))])
    }
    #[test] fn rect_validation_distinguishes_zero_null_and_invalid() {
        assert_eq!(frame(Some(&AxValue::Rect("{{0, 0}, {0, 0}}".into()))).unwrap().1, "available");
        assert_eq!(frame(Some(&AxValue::Rect("{{inf, inf}, {0, 0}}".into()))).unwrap().1, "CGRectNull");
        assert!(frame(Some(&AxValue::Rect("{{nan, 0}, {1, 1}}".into()))).is_err());
    }
    #[test] fn preserves_paths_false_and_duplicate_handles_without_exposing_token() {
        let leaf = node(7, 5, vec![], vec![(2001, AxValue::String(String::new())), (2025, AxValue::Bool(false)), (2004, AxValue::Integer(u64::MAX.into()))]);
        let tree = node(7, 1, vec![leaf.clone(), node(7, 2, vec![leaf], vec![])], vec![]);
        let root = Token::from_value(&token(7,1)).unwrap();
        let output = normalize(&tree, &root, 1, 2).unwrap();
        let nodes = output["nodes"].as_array().unwrap(); assert_eq!(nodes.len(), 4);
        assert_eq!(nodes[1]["path"], json!([0])); assert_eq!(nodes[3]["path"], json!([1,0]));
        assert_eq!(nodes[1]["visible"], false); assert_eq!(nodes[1]["label"], "");
        assert_eq!(nodes[1]["traits"], u64::MAX.to_string());
        assert!(nodes[1].get("objectID").is_none());
    }
    #[test] fn rejects_truncation_and_unknown_cross_process_children() {
        let root = Token::from_value(&token(7, 1)).unwrap();
        let mut bad = node(7, 1, vec![], vec![]);
        if let AxValue::Map(ref mut fields) = bad { fields.retain(|(k,_)| k.str() != Some("UIAccessibilitySnapshotKeyChildren")); }
        assert!(normalize(&bad, &root, 1, 2).is_err());
        let bad = node(7, 1, vec![node(8, 2, vec![], vec![])], vec![]);
        assert!(normalize(&bad, &root, 1, 2).is_err());
        let good = node(7, 1, vec![node(8, 2, vec![], vec![(5003, AxValue::String("AXRemoteElement".into()))])], vec![]);
        assert_eq!(normalize(&good, &root, 1, 2).unwrap()["nodes"][1]["externalProcessReference"], true);
    }
    #[test] fn rejects_over_depth_without_truncating() {
        let root = Token::from_value(&token(7, 1)).unwrap();
        let mut nested = node(7, 2, vec![], vec![]);
        for _ in 0..MAX_DEPTH { nested = node(7, 2, vec![nested], vec![]); }
        let tree = node(7, 1, vec![nested], vec![]);
        assert_eq!(normalize(&tree, &root, 1, 2), Err(Failure::Limit));
    }
}
