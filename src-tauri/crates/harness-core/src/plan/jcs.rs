//! RFC 8785 (JSON Canonicalization Scheme) for the plan subset: objects, arrays, strings, booleans, null and canonical
//! integers. Floats are not representable in [`Value`], so the number-formatting half of the RFC is not needed.
//!
//! * No insignificant whitespace.
//! * Object members sorted by key in UTF-16 code unit order (not UTF-8 or code point order: U+1F600 sorts before U+FB33).
//! * Strings escape only `"`, `\`, and U+0000 to U+001F (`\b \t \n \f \r` short forms, others as lowercase `\u00xx`).
//!   Everything else, including U+007F, U+2028 and non-BMP characters, is emitted raw as UTF-8.

use crate::plan::model::Value;
use std::cmp::Ordering;
use std::fmt::Write;

/// The canonical bytes of `value`.
pub fn canonicalize(value: &Value) -> Vec<u8> {
    let mut out = String::new();
    write_value(value, &mut out);
    out.into_bytes()
}

fn write_value(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Int(n) => {
            let _ = write!(out, "{n}");
        }
        Value::String(s) => write_string(s, out),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(item, out);
            }
            out.push(']');
        }
        Value::Object(entries) => {
            let mut sorted: Vec<&(String, Value)> = entries.iter().collect();
            sorted.sort_by(|a, b| cmp_utf16(&a.0, &b.0));
            out.push('{');
            for (i, (key, member)) in sorted.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write_value(member, out);
            }
            out.push('}');
        }
    }
}

/// Compare by UTF-16 code units, as RFC 8785 section 3.2.3 requires.
pub fn cmp_utf16(a: &str, b: &str) -> Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// Append the canonical JSON string literal for `s`.
pub fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::parse::parse;

    fn canon(src: &str) -> String {
        String::from_utf8(canonicalize(&parse(src.as_bytes()).unwrap())).unwrap()
    }

    /// `\u` escapes are assembled at run time so the source never depends on how an editor treats them.
    fn esc(template: &str) -> String {
        template.replace('~', "\\")
    }

    #[test]
    fn sorts_keys_and_drops_whitespace() {
        assert_eq!(
            canon(r#" { "b" : [ 1 , 2 ] , "a" : { "z" : null , "y" : true } } "#),
            r#"{"a":{"y":true,"z":null},"b":[1,2]}"#
        );
    }

    #[test]
    fn keys_sort_by_utf16_units() {
        // U+1F600 is the surrogate pair D83D DE00, which is below U+FB33 in UTF-16 but above it in UTF-8/code points.
        assert_eq!(
            canon(&esc(r#"{"~ufb33":1,"~ud83d~ude00":2}"#)),
            "{\"\u{1F600}\":2,\"\u{FB33}\":1}"
        );
    }

    #[test]
    fn string_escapes() {
        let input = esc(r#""~u0000~u001f~b~t~n~f~r~"~~/""#);
        assert_eq!(canon(&input), esc(r#""~u0000~u001f~b~t~n~f~r~"~~/""#));
        // U+007F, U+2028 and U+00E9 stay raw, however they were written.
        let escaped = esc(r#""~u007f~u2028~u00e9""#);
        assert_eq!(canon(&escaped), "\"\u{7f}\u{2028}\u{e9}\"");
    }
}
