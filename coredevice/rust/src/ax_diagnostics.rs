// SPDX-License-Identifier: GPL-3.0-only
//! Small optional failure metadata, never a copy of an AX response or UI tree.
use crate::ax_archive::AxValue;
use serde_json::{Map, Value, json};
use std::time::Instant;

pub(crate) struct Diagnostic {
    started: Instant,
    step_started: Instant,
    fields: Map<String, Value>,
}
impl Diagnostic {
    pub fn new(selection: &'static str) -> Self {
        let now = Instant::now();
        let fields = Map::from_iter([
            ("version".into(), json!(1)), ("selection".into(), json!(selection)),
            ("phase".into(), json!("start")),
        ]);
        Self { started: now, step_started: now, fields }
    }
    pub fn enter(&mut self, phase: &'static str, request_type: Option<u64>) {
        self.step_started = Instant::now();
        self.fields.insert("phase".into(), json!(phase));
        self.fields.remove("request_type");
        if let Some(value) = request_type { self.fields.insert("request_type".into(), json!(value)); }
    }
    pub fn subscribed(&mut self) {
        self.fields.insert("subscription_ack_ms".into(), json!(millis(self.started)));
    }
    pub fn begin_pid_fallback(&mut self, pid: u32) {
        self.fields.insert("selection".into(), json!("explicit_pid"));
        self.fields.insert("fallback_from".into(), json!("selection_initial"));
        self.fields.insert("initial_remote_code".into(), json!("8"));
        self.pid("target_pid", u64::from(pid));
        for key in ["error_type", "has_result", "remote_code", "remote_boolean", "remote_domain", "remote_domain_redacted", "subscription_ack_ms"] {
            self.fields.remove(key);
        }
        self.enter("target_validation", None);
    }
    pub fn pid(&mut self, field: &'static str, value: u64) {
        self.fields.insert(field.into(), json!(value));
    }
    pub fn remote_error(&mut self, error: &AxValue, has_result: bool) {
        let shape = match error {
            AxValue::Null => "null", AxValue::Bool(_) => "boolean", AxValue::Integer(_) => "integer",
            AxValue::Real(_) => "real", AxValue::String(_) => "string", AxValue::Data(_) => "data",
            AxValue::Array(_) => "array", AxValue::Map(_) => "object", AxValue::Rect(_) => "rect",
        };
        self.fields.insert("error_type".into(), json!(shape));
        self.fields.insert("has_result".into(), json!(has_result));
        let code = error.field("NSCode").or_else(|| error.field("code")).unwrap_or(error);
        if let AxValue::Integer(value) = code {
            // Decimal strings preserve signed and unsigned codes across the C/Swift boundary.
            let value = value.as_signed().map(|v| v.to_string()).or_else(|| value.as_unsigned().map(|v| v.to_string()));
            if let Some(value) = value { self.fields.insert("remote_code".into(), json!(value)); }
        }
        if let AxValue::Bool(value) = error { self.fields.insert("remote_boolean".into(), json!(value)); }
        if let Some(domain) = error.field("NSDomain").or_else(|| error.field("domain")).and_then(AxValue::str) {
            // Error identifiers only: exclude descriptions, userInfo, arbitrary text and log injection.
            if !domain.is_empty() && domain.len() <= 128 && domain.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)) {
                self.fields.insert("remote_domain".into(), json!(domain));
            } else { self.fields.insert("remote_domain_redacted".into(), json!(true)); }
        }
    }
    pub fn payload(&self) -> Option<Vec<u8>> {
        let mut fields = self.fields.clone();
        fields.insert("elapsed_ms".into(), json!(millis(self.started)));
        fields.insert("phase_elapsed_ms".into(), json!(millis(self.step_started)));
        serde_json::to_vec(&fields).ok().filter(|bytes| bytes.len() <= 2048)
    }
}
fn millis(started: Instant) -> u64 { started.elapsed().as_millis().min(u64::MAX as u128) as u64 }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failure_metadata_keeps_signed_codes_but_never_descriptions_or_tree_content() {
        let error = AxValue::Map(vec![
            (AxValue::String("NSCode".into()), AxValue::Integer((-25204i64).into())),
            (AxValue::String("NSDomain".into()), AxValue::String("com.apple.Accessibility".into())),
            (AxValue::String("NSLocalizedDescription".into()), AxValue::String("PRIVATE_SCREEN_TEXT".into())),
            (AxValue::String("NSUserInfo".into()), AxValue::Data(vec![0x42; 4096])),
        ]);
        let mut trace = Diagnostic::new("hit_test");
        trace.enter("selection_verify", Some(6)); trace.subscribed(); trace.remote_error(&error, false);
        let bytes = trace.payload().unwrap();
        let json: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(json["remote_code"], "-25204"); assert_eq!(json["remote_domain"], "com.apple.Accessibility");
        assert_eq!(json["phase"], "selection_verify"); assert_eq!(json["request_type"], 6);
        assert!(!String::from_utf8(bytes).unwrap().contains("PRIVATE_SCREEN_TEXT"));
        assert!(json.get("NSUserInfo").is_none());
    }
    #[test]
    fn fallback_keeps_initial_reason_separate_from_the_new_failure() {
        let mut trace = Diagnostic::new("hit_test");
        trace.enter("selection_initial", Some(6));
        trace.remote_error(&AxValue::Integer(8.into()), false);
        trace.begin_pid_fallback(7);
        let value: Value = serde_json::from_slice(&trace.payload().unwrap()).unwrap();
        assert_eq!(value["phase"], "target_validation");
        assert_eq!(value["initial_remote_code"], "8");
        assert_eq!(value["fallback_from"], "selection_initial");
        assert!(value.get("remote_code").is_none());
        assert!(value.get("request_type").is_none());
        trace.enter("root_initial", Some(1));
        trace.remote_error(&AxValue::Integer(9.into()), false);
        let value: Value = serde_json::from_slice(&trace.payload().unwrap()).unwrap();
        assert_eq!(value["initial_remote_code"], "8");
        assert_eq!(value["remote_code"], "9");
    }
    #[test]
    fn invalid_domains_are_redacted_and_boolean_errors_remain_distinguishable() {
        let mut trace = Diagnostic::new("hit_test");
        trace.remote_error(&AxValue::Map(vec![(AxValue::String("domain".into()), AxValue::String("private\ntext".into()))]), false);
        trace.remote_error(&AxValue::Bool(false), true);
        let json: Value = serde_json::from_slice(&trace.payload().unwrap()).unwrap();
        assert_eq!(json["remote_domain_redacted"], true); assert!(json.get("remote_domain").is_none());
        assert_eq!(json["error_type"], "boolean"); assert_eq!(json["remote_boolean"], false);
    }
}
