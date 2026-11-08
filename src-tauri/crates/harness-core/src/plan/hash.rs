//! The plan hash: `lowercase_hex(sha256(jcs(plan without "approval")))`.
//!
//! The `approval` key is removed from the parsed value, never by editing text, so the hash covers exactly what the user
//! saw: provider, scope, usage estimates, fallbacks and dependencies (hard rule 9).

use crate::plan::jcs::canonicalize;
use crate::plan::model::Value;
use sha2::{Digest, Sha256};

/// The canonical bytes that are hashed: `value` with the top-level `approval` member removed.
pub fn canonical_without_approval(value: &Value) -> Vec<u8> {
    match value {
        Value::Object(entries) => {
            let without: Vec<(String, Value)> = entries
                .iter()
                .filter(|(k, _)| k != "approval")
                .cloned()
                .collect();
            canonicalize(&Value::Object(without))
        }
        other => canonicalize(other),
    }
}

/// The hash of `value` with the top-level `approval` member removed.
pub fn plan_hash(value: &Value) -> String {
    hex::encode(Sha256::digest(canonical_without_approval(value)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::parse::parse;

    fn h(s: &str) -> String {
        plan_hash(&parse(s.as_bytes()).unwrap())
    }

    #[test]
    fn approval_is_excluded_and_order_is_ignored() {
        let base = h(r#"{"a":1,"b":[true]}"#);
        assert_eq!(base.len(), 64);
        assert_eq!(base, h(r#"{ "b" : [true], "a" : 1 }"#));
        assert_eq!(base, h(r#"{"a":1,"approval":{"x":"y"},"b":[true]}"#));
        assert_ne!(base, h(r#"{"a":2,"b":[true]}"#));
        // Only the top-level approval is dropped.
        assert_ne!(h(r#"{"a":{"approval":1}}"#), h(r#"{"a":{}}"#));
    }

    #[test]
    fn known_answer() {
        // sha256 of the bytes `{"a":1}`.
        assert_eq!(
            h(r#"{ "a" : 1 }"#),
            "015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862"
        );
    }
}
