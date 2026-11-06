// SPDX-License-Identifier: GPL-3.0-only
// AXP archive format and read-request construction are adapted from ipb;
// Copyright (c) 2026 Borealin and ipbtools contributors, MIT.
// Full notice: ios-app/Licenses/ipb-MIT.txt.
//! AX keyed-archive object graphs, decoded as inert values only.
use std::io::Cursor;
use plist::{Dictionary, Integer, Uid, Value, stream::{BinaryReader, Event}};

const MAX_BYTES: usize = 20 * 1024 * 1024;
const MAX_OBJECTS: usize = 50_000;
const MAX_STEPS: usize = 500_000;
const MAX_DEPTH: usize = 512;
// Binary-plist container nesting is separate from the keyed UID graph.
// Limit it before plist::Value's recursive deserializer runs.
const MAX_PLIST_DEPTH: usize = 64;
const MAX_EXPANDED_BYTES: usize = 40 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum AxValue {
    Null, Bool(bool), Integer(Integer), Real(f64), String(String), Data(Vec<u8>),
    Array(Vec<AxValue>), Map(Vec<(AxValue, AxValue)>), Rect(String),
}
impl AxValue {
    pub fn field(&self, key: &str) -> Option<&Self> {
        match self { Self::Map(values) => values.iter().find_map(|(k, v)| (k == &Self::String(key.into())).then_some(v)), _ => None }
    }
    pub fn number_key(&self, key: u64) -> Option<&Self> {
        match self { Self::Map(values) => values.iter().find_map(|(k, v)| (k.uint() == Some(key)).then_some(v)), _ => None }
    }
    pub fn uint(&self) -> Option<u64> { match self { Self::Integer(v) => v.as_unsigned(), _ => None } }
    pub fn bool(&self) -> Option<bool> { match self { Self::Bool(v) => Some(*v), _ => None } }
    pub fn array(&self) -> Option<&[Self]> { match self { Self::Array(v) => Some(v), _ => None } }
    pub fn str(&self) -> Option<&str> { match self { Self::String(v) => Some(v), _ => None } }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ArchiveError { Invalid, Limit }

/// Check the binary plist event stream before building a Value. This bounds
/// alias expansion, nesting, and decoded byte volume as well as wire bytes.
fn checked_plist(bytes: &[u8]) -> Result<Value, ArchiveError> {
    if bytes.len() > MAX_BYTES { return Err(ArchiveError::Limit); }
    if bytes.len() < 40 || !bytes.starts_with(b"bplist00") { return Err(ArchiveError::Invalid); }
    // The binary plist offset table contains more entries than the keyed
    // archive's $objects array. Bound it before the plist reader allocates it.
    let trailer = &bytes[bytes.len() - 32..];
    let physical_objects = u64::from_be_bytes(trailer[8..16].try_into().map_err(|_| ArchiveError::Invalid)?);
    if physical_objects > 250_000 { return Err(ArchiveError::Limit); }
    let mut depth = 0usize; let mut work = 0usize; let mut expanded = 0usize;
    for event in BinaryReader::new(Cursor::new(bytes)) {
        work += 1;
        if work > MAX_STEPS { return Err(ArchiveError::Limit); }
        match event.map_err(|_| ArchiveError::Invalid)? {
            Event::StartArray(_) | Event::StartDictionary(_) => { depth += 1; if depth > MAX_PLIST_DEPTH { return Err(ArchiveError::Limit); } }
            Event::EndCollection => depth = depth.checked_sub(1).ok_or(ArchiveError::Invalid)?,
            Event::Data(v) => expanded = expanded.checked_add(v.len()).ok_or(ArchiveError::Limit)?,
            Event::String(v) => expanded = expanded.checked_add(v.len()).ok_or(ArchiveError::Limit)?,
            _ => {}
        }
        if expanded > MAX_EXPANDED_BYTES { return Err(ArchiveError::Limit); }
    }
    if depth != 0 { return Err(ArchiveError::Invalid); }
    Value::from_reader(Cursor::new(bytes)).map_err(|_| ArchiveError::Invalid)
}

pub(crate) fn decode(bytes: &[u8]) -> Result<AxValue, ArchiveError> {
    let archive = checked_plist(bytes)?;
    let root = archive.as_dictionary().ok_or(ArchiveError::Invalid)?;
    if root.get("$archiver").and_then(Value::as_string) != Some("NSKeyedArchiver") { return Err(ArchiveError::Invalid); }
    let objects = root.get("$objects").and_then(Value::as_array).ok_or(ArchiveError::Invalid)?;
    if objects.len() > MAX_OBJECTS { return Err(ArchiveError::Limit); }
    if objects.first().and_then(Value::as_string) != Some("$null") { return Err(ArchiveError::Invalid); }
    let first = root.get("$top").and_then(Value::as_dictionary).and_then(|d| d.get("root")).ok_or(ArchiveError::Invalid)?;
    enum Step<'a> { Visit(&'a Value, usize), EndRef(usize), Array(usize), Map, Fields(Vec<String>), Rect, ExpectArray, ExpectData }
    let mut pending = vec![Step::Visit(first, 0)];
    let mut values: Vec<AxValue> = Vec::new();
    let mut visiting = vec![false; objects.len()];
    let mut work = 0usize; let mut expanded = 0usize;
    while let Some(step) = pending.pop() {
        work += 1; if work > MAX_STEPS { return Err(ArchiveError::Limit); }
        match step {
            Step::EndRef(index) => visiting[index] = false,
            Step::Array(count) => {
                let start = values.len().checked_sub(count).ok_or(ArchiveError::Invalid)?;
                let items = values.split_off(start); values.push(AxValue::Array(items));
            }
            Step::Map => {
                let vals = values.pop().ok_or(ArchiveError::Invalid)?;
                let keys = values.pop().ok_or(ArchiveError::Invalid)?;
                let (AxValue::Array(keys), AxValue::Array(vals)) = (keys, vals) else { return Err(ArchiveError::Invalid); };
                if keys.len() != vals.len() { return Err(ArchiveError::Invalid); }
                values.push(AxValue::Map(keys.into_iter().zip(vals).collect()));
            }
            Step::Fields(keys) => {
                let start = values.len().checked_sub(keys.len()).ok_or(ArchiveError::Invalid)?;
                let fields = values.split_off(start);
                values.push(AxValue::Map(keys.into_iter().map(AxValue::String).zip(fields).collect()));
            }
            Step::Rect => {
                let value = values.pop().ok_or(ArchiveError::Invalid)?;
                let AxValue::String(text) = value else { return Err(ArchiveError::Invalid); };
                values.push(AxValue::Rect(text));
            }
            Step::ExpectArray => if !matches!(values.last(), Some(AxValue::Array(_))) { return Err(ArchiveError::Invalid); },
            Step::ExpectData => if !matches!(values.last(), Some(AxValue::Data(_))) { return Err(ArchiveError::Invalid); },
            Step::Visit(value, depth) => {
                if depth > MAX_DEPTH { return Err(ArchiveError::Limit); }
                match value {
                    Value::Uid(id) => {
                        let index = usize::try_from(id.get()).map_err(|_| ArchiveError::Invalid)?;
                        if index == 0 { values.push(AxValue::Null); continue; }
                        let target = objects.get(index).ok_or(ArchiveError::Invalid)?;
                        if visiting[index] { return Err(ArchiveError::Invalid); }
                        visiting[index] = true; pending.push(Step::EndRef(index)); pending.push(Step::Visit(target, depth + 1));
                    }
                    Value::Boolean(v) => values.push(AxValue::Bool(*v)),
                    Value::Integer(v) => values.push(AxValue::Integer(*v)),
                    Value::Real(v) if v.is_finite() => values.push(AxValue::Real(*v)),
                    Value::String(v) => { expanded = expanded.checked_add(v.len()).ok_or(ArchiveError::Limit)?; values.push(AxValue::String(v.clone())); }
                    Value::Data(v) => { expanded = expanded.checked_add(v.len()).ok_or(ArchiveError::Limit)?; values.push(AxValue::Data(v.clone())); }
                    Value::Array(items) => {
                        expanded = expanded.checked_add(items.len().checked_mul(16).ok_or(ArchiveError::Limit)?).ok_or(ArchiveError::Limit)?;
                        pending.push(Step::Array(items.len()));
                        for item in items.iter().rev() { pending.push(Step::Visit(item, depth + 1)); }
                    }
                    Value::Dictionary(map) => {
                        let class = if let Some(class_ref) = map.get("$class") {
                            let index = usize::try_from(class_ref.as_uid().ok_or(ArchiveError::Invalid)?.get()).map_err(|_| ArchiveError::Invalid)?;
                            Some(objects.get(index).and_then(Value::as_dictionary).and_then(|d| d.get("$classname")).and_then(Value::as_string).ok_or(ArchiveError::Invalid)?)
                        } else { None };
                        if class.is_some() && map.contains_key("NS.keys") {
                            pending.push(Step::Map);
                            pending.push(Step::Visit(map.get("NS.objects").ok_or(ArchiveError::Invalid)?, depth + 1));
                            pending.push(Step::Visit(map.get("NS.keys").ok_or(ArchiveError::Invalid)?, depth + 1));
                        } else if matches!(class, Some("NSArray" | "NSMutableArray")) {
                            pending.push(Step::ExpectArray); pending.push(Step::Visit(map.get("NS.objects").ok_or(ArchiveError::Invalid)?, depth + 1));
                        } else if matches!(class, Some("NSString" | "NSMutableString" | "NSAttributedString" | "NSMutableAttributedString")) && (map.contains_key("NSString") || map.contains_key("NS.string")) {
                            pending.push(Step::Visit(map.get("NSString").or_else(|| map.get("NS.string")).ok_or(ArchiveError::Invalid)?, depth + 1));
                        } else if matches!(class, Some("NSData" | "NSMutableData" | "NSConcreteData" | "__NSCFData")) {
                            pending.push(Step::ExpectData); pending.push(Step::Visit(map.get("NS.data").ok_or(ArchiveError::Invalid)?, depth + 1));
                        } else if class == Some("NSNull") { values.push(AxValue::Null); }
                        else if class == Some("NSValue") && map.contains_key("NS.rectval") {
                            pending.push(Step::Rect); pending.push(Step::Visit(map.get("NS.rectval").ok_or(ArchiveError::Invalid)?, depth + 1));
                        } else {
                            let fields: Vec<_> = map.iter().filter(|(k,_)| k.as_str() != "$class").collect();
                            expanded = expanded.checked_add(fields.len().checked_mul(32).ok_or(ArchiveError::Limit)?).ok_or(ArchiveError::Limit)?;
                            let mut keys = Vec::with_capacity(fields.len());
                            for (key, _) in &fields { expanded = expanded.checked_add(key.len()).ok_or(ArchiveError::Limit)?; keys.push((*key).clone()); }
                            pending.push(Step::Fields(keys));
                            for (_, value) in fields.into_iter().rev() { pending.push(Step::Visit(value, depth + 1)); }
                        }
                    }
                    _ => return Err(ArchiveError::Invalid),
                }
                if expanded > MAX_EXPANDED_BYTES { return Err(ArchiveError::Limit); }
            }
        }
    }
    if values.len() != 1 { return Err(ArchiveError::Invalid); }
    values.pop().ok_or(ArchiveError::Invalid)
}

#[derive(Clone, Debug)]
pub(crate) struct Token {
    pub pid: u64, pub object_id: u64, pub is_app: bool,
    populated: bool, raw: AxValue, bridge: AxValue,
}
impl Token {
    pub fn from_value(value: &AxValue) -> Result<Self, ArchiveError> {
        let pid = value.field("pid").and_then(AxValue::uint).filter(|p| *p > 0).ok_or(ArchiveError::Invalid)?;
        let object_id = value.field("objectID").and_then(AxValue::uint).ok_or(ArchiveError::Invalid)?;
        Ok(Self { pid, object_id, is_app: value.field("isApplicationElement").and_then(AxValue::bool).unwrap_or(false),
            populated: value.field("didPopuldateAppInfo").and_then(AxValue::bool).unwrap_or(false),
            raw: value.field("rawElementData").cloned().unwrap_or(AxValue::Null),
            bridge: value.field("bridgeDelegateToken").cloned().unwrap_or(AxValue::Null) })
    }
}

struct Builder { objects: Vec<Value>, classes: std::collections::HashMap<String, usize> }
impl Builder {
    fn add(&mut self, v: Value) -> Value { self.objects.push(v); Value::Uid(Uid::new((self.objects.len() - 1) as u64)) }
    fn class(&mut self, name: &str) -> Value {
        if let Some(i) = self.classes.get(name) { return Value::Uid(Uid::new(*i as u64)); }
        let index = self.objects.len();
        let mut c = Dictionary::new(); c.insert("$classname".into(), Value::String(name.into()));
        c.insert("$classes".into(), Value::Array(vec![Value::String(name.into()), Value::String("NSObject".into())]));
        let id = self.add(Value::Dictionary(c)); self.classes.insert(name.into(), index); id
    }
    fn encode(&mut self, value: &AxValue, depth: usize) -> Result<Value, ArchiveError> {
        if depth > MAX_PLIST_DEPTH || self.objects.len() >= MAX_OBJECTS { return Err(ArchiveError::Limit); }
        Ok(match value {
            AxValue::Null => Value::Uid(Uid::new(0)),
            AxValue::Bool(v) => self.add(Value::Boolean(*v)), AxValue::Integer(v) => self.add(Value::Integer(*v)),
            AxValue::Real(v) if v.is_finite() => self.add(Value::Real(*v)), AxValue::String(v) => self.add(Value::String(v.clone())), AxValue::Data(v) => self.add(Value::Data(v.clone())),
            AxValue::Array(values) => {
                let mut array = Vec::with_capacity(values.len()); for v in values { array.push(self.encode(v, depth + 1)?); }
                let class = self.class("NSArray"); let mut d = Dictionary::new(); d.insert("NS.objects".into(), Value::Array(array)); d.insert("$class".into(), class); self.add(Value::Dictionary(d))
            }
            AxValue::Map(values) => {
                let mut keys = Vec::with_capacity(values.len()); let mut vals = Vec::with_capacity(values.len());
                for (k,v) in values { keys.push(self.encode(k, depth + 1)?); vals.push(self.encode(v, depth + 1)?); }
                let class = self.class("NSDictionary"); let mut d = Dictionary::new(); d.insert("NS.keys".into(), Value::Array(keys)); d.insert("NS.objects".into(), Value::Array(vals)); d.insert("$class".into(), class); self.add(Value::Dictionary(d))
            }
            _ => return Err(ArchiveError::Invalid),
        })
    }
}
fn axstr(s: &str) -> AxValue { AxValue::String(s.into()) }
fn map(values: Vec<(&str, AxValue)>) -> AxValue { AxValue::Map(values.into_iter().map(|(k,v)| (axstr(k),v)).collect()) }
fn num(n: u64) -> AxValue { AxValue::Integer(n.into()) }

/// Type 6 performs a read-only point hit test. It is not a touch event.
pub(crate) fn hit_request(x: f64, y: f64) -> Result<Vec<u8>, ArchiveError> {
    if !x.is_finite() || !y.is_finite() || x < 0.0 || y < 0.0 || x > 16384.0 || y > 16384.0 { return Err(ArchiveError::Invalid); }
    let mut b = Builder { objects: vec![Value::String("$null".into())], classes: Default::default() };
    let point_string = b.encode(&axstr(&format!("{{{x}, {y}}}")), 0)?;
    let class = b.class("NSValue"); let mut point = Dictionary::new();
    point.insert("NS.pointval".into(), point_string); point.insert("NS.special".into(), Value::Integer(1u64.into())); point.insert("$class".into(), class);
    let point = b.add(Value::Dictionary(point));
    let point_key = b.encode(&axstr("point"), 0)?; let display_key = b.encode(&axstr("displayId"), 0)?;
    let display = b.encode(&num(0), 0)?; let class = b.class("NSDictionary");
    let mut params = Dictionary::new(); params.insert("NS.keys".into(), Value::Array(vec![point_key, display_key]));
    params.insert("NS.objects".into(), Value::Array(vec![point, display])); params.insert("$class".into(), class);
    let params = b.add(Value::Dictionary(params));
    let bytes = uuid::Uuid::new_v4(); let id = u64::from_be_bytes(bytes.as_bytes()[..8].try_into().unwrap());
    let object_id = b.encode(&num(id), 0)?; let class = b.class("AXPTranslationObject"); let mut translation = Dictionary::new();
    translation.insert("rawElementData".into(), Value::Uid(Uid::new(0))); translation.insert("bridgeDelegateToken".into(), Value::Uid(Uid::new(0)));
    translation.insert("objectID".into(), object_id); translation.insert("pid".into(), Value::Integer(0u64.into()));
    translation.insert("isApplicationElement".into(), Value::Boolean(false)); translation.insert("didPopuldateAppInfo".into(), Value::Boolean(false));
    translation.insert("$class".into(), class); let translation = b.add(Value::Dictionary(translation));
    let class = b.class("AXPTranslatorRequest"); let mut root = Dictionary::new();
    for (key, value) in [("requestType", 6u64), ("clientType", 0), ("actionType", 0), ("attributeType", 0)] { root.insert(key.into(), Value::Integer(value.into())); }
    root.insert("parameters".into(), params); root.insert("translation".into(), translation); root.insert("$class".into(), class);
    let root = b.add(Value::Dictionary(root)); let mut top = Dictionary::new(); top.insert("root".into(), root);
    let mut archive = Dictionary::new(); archive.insert("$version".into(), Value::Integer(100000.into()));
    archive.insert("$archiver".into(), Value::String("NSKeyedArchiver".into())); archive.insert("$top".into(), Value::Dictionary(top)); archive.insert("$objects".into(), Value::Array(b.objects));
    let mut out = Vec::new(); Value::Dictionary(archive).to_writer_binary(&mut out).map_err(|_| ArchiveError::Invalid)?; Ok(out)
}

/// Produce only the verified read requests. No action type is exposed.
pub(crate) fn request(pid: u64, token: Option<&Token>) -> Result<Vec<u8>, ArchiveError> {
    if pid == 0 || pid > i32::MAX as u64 { return Err(ArchiveError::Invalid); }
    let mut b = Builder { objects: vec![Value::String("$null".into())], classes: Default::default() };
    let (kind, parameters, translation) = if let Some(token) = token {
        if token.pid != pid || !token.is_app { return Err(ArchiveError::Invalid); }
        let options = map(vec![
            ("attributes", AxValue::Array([2001,2002,2003,2004,5019,2006,2025,5003,5004,3003].into_iter().map(num).collect())),
            ("maxDepth", num(48)), ("maxChildren", num(512)), ("maxArrayCount", num(512)),
            ("traverseFromParentsToChildren", AxValue::Bool(true)), ("snapshotKeyHonorModalViews", AxValue::Bool(false)),
        ]);
        let parameters = b.encode(&map(vec![("parameter", options)]), 0)?;
        let raw = b.encode(&token.raw, 0)?; let bridge = b.encode(&token.bridge, 0)?; let id = b.encode(&num(token.object_id), 0)?;
        let class = b.class("AXPTranslationObject"); let mut t = Dictionary::new();
        t.insert("rawElementData".into(), raw); t.insert("bridgeDelegateToken".into(), bridge); t.insert("objectID".into(), id);
        t.insert("pid".into(), Value::Integer(pid.into())); t.insert("isApplicationElement".into(), Value::Boolean(token.is_app));
        t.insert("didPopuldateAppInfo".into(), Value::Boolean(token.populated)); t.insert("$class".into(), class);
        (2u64, parameters, b.add(Value::Dictionary(t)))
    } else {
        let p = b.encode(&map(vec![("pid", num(pid))]), 0)?; (1u64, p, Value::Uid(Uid::new(0)))
    };
    let class = b.class("AXPTranslatorRequest"); let mut root = Dictionary::new();
    for (k,v) in [("requestType", kind), ("clientType", 0), ("actionType", 0), ("attributeType", if kind == 2 {52} else {0})] { root.insert(k.into(), Value::Integer(v.into())); }
    root.insert("translation".into(), translation); root.insert("parameters".into(), parameters); root.insert("$class".into(), class);
    let root = b.add(Value::Dictionary(root));
    let mut top = Dictionary::new(); top.insert("root".into(), root);
    let mut archive = Dictionary::new(); archive.insert("$version".into(), Value::Integer(100000.into())); archive.insert("$archiver".into(), Value::String("NSKeyedArchiver".into()));
    archive.insert("$top".into(), Value::Dictionary(top)); archive.insert("$objects".into(), Value::Array(b.objects));
    let mut out = Vec::new(); Value::Dictionary(archive).to_writer_binary(&mut out).map_err(|_| ArchiveError::Invalid)?;
    if out.len() > MAX_BYTES { return Err(ArchiveError::Limit); } Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn app_request_round_trip_preserves_read_only_fields() {
        let v = decode(&request(1234, None).unwrap()).unwrap();
        assert_eq!(v.field("requestType").and_then(AxValue::uint), Some(1));
        assert_eq!(v.field("actionType").and_then(AxValue::uint), Some(0));
        assert_eq!(v.field("parameters").and_then(|p| p.field("pid")).and_then(AxValue::uint), Some(1234));
        assert_eq!(v.field("translation"), Some(&AxValue::Null));
    }
    #[test]
    fn invalid_pid_is_rejected() { assert!(request(0, None).is_err()); }
    #[test]
    fn snapshot_request_keeps_unsigned_identifier_and_nil_raw_token() {
        let source = map(vec![("pid", num(123)), ("objectID", num(u64::MAX)),
            ("isApplicationElement", AxValue::Bool(true)), ("rawElementData", AxValue::Null)]);
        let token = Token::from_value(&source).unwrap();
        let value = decode(&request(123, Some(&token)).unwrap()).unwrap();
        assert_eq!(value.field("requestType").and_then(AxValue::uint), Some(2));
        assert_eq!(value.field("attributeType").and_then(AxValue::uint), Some(52));
        assert_eq!(value.field("actionType").and_then(AxValue::uint), Some(0));
        let translation = value.field("translation").unwrap();
        assert_eq!(translation.field("objectID").and_then(AxValue::uint), Some(u64::MAX));
        assert_eq!(translation.field("rawElementData"), Some(&AxValue::Null));
    }
    #[test]
    fn invalid_and_cyclic_uid_graphs_are_rejected() {
        fn make(target: u64) -> Vec<u8> {
            let mut inner = Dictionary::new(); inner.insert("reference".into(), Value::Uid(Uid::new(target)));
            let mut top = Dictionary::new(); top.insert("root".into(), Value::Uid(Uid::new(1)));
            let mut root = Dictionary::new(); root.insert("$archiver".into(), Value::String("NSKeyedArchiver".into()));
            root.insert("$objects".into(), Value::Array(vec![Value::String("$null".into()), Value::Dictionary(inner)]));
            root.insert("$top".into(), Value::Dictionary(top)); root.insert("$version".into(), Value::Integer(100000.into()));
            let mut bytes = Vec::new(); Value::Dictionary(root).to_writer_binary(&mut bytes).unwrap(); bytes
        }
        assert_eq!(decode(&make(1)), Err(ArchiveError::Invalid));
        assert_eq!(decode(&make(99)), Err(ArchiveError::Invalid));
    }
    #[test]
    fn keyed_reference_depth_is_bounded_without_recursive_traversal() {
        fn chain(length: usize) -> Vec<u8> {
            let mut objects = vec![Value::String("$null".into())];
            for i in 1..=length {
                let mut item = Dictionary::new();
                item.insert("next".into(), if i == length { Value::Uid(Uid::new(0)) } else { Value::Uid(Uid::new((i + 1) as u64)) });
                objects.push(Value::Dictionary(item));
            }
            let mut top = Dictionary::new(); top.insert("root".into(), Value::Uid(Uid::new(1)));
            let mut root = Dictionary::new(); root.insert("$archiver".into(), Value::String("NSKeyedArchiver".into()));
            root.insert("$objects".into(), Value::Array(objects)); root.insert("$top".into(), Value::Dictionary(top));
            root.insert("$version".into(), Value::Integer(100000.into()));
            let mut data = Vec::new(); Value::Dictionary(root).to_writer_binary(&mut data).unwrap(); data
        }
        assert!(decode(&chain(200)).is_ok());
        assert_eq!(decode(&chain(300)), Err(ArchiveError::Limit));
    }
}
