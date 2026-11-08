//! Strict JSON parser for plans: one document, no duplicate keys, no lone surrogates, canonical integers only.
//!
//! The whole buffer is validated as UTF-8 first. Parsers disagree about duplicate keys, invalid encodings and extra
//! documents, so a plan that any of those could split between "what was hashed" and "what was run" is refused here
//! rather than interpreted (hard rule 9). Numbers other than canonical non-negative integers are refused at parse time,
//! so a float never reaches the canonicalizer.

use crate::plan::model::{Value, MAX_SAFE_INT};
use std::collections::HashSet;

/// Largest plan document accepted, in bytes.
pub const MAX_PLAN_BYTES: usize = 4 * 1024 * 1024;
/// Deepest array/object nesting accepted.
pub const MAX_DEPTH: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ParseError {
    #[error("plan is larger than {MAX_PLAN_BYTES} bytes")]
    TooLarge,
    #[error("plan is not valid UTF-8")]
    InvalidUtf8,
    #[error("plan is empty")]
    Empty,
    #[error("plan nests deeper than {MAX_DEPTH} levels")]
    TooDeep,
    #[error("plan file must contain exactly one JSON document")]
    TrailingData,
    #[error("duplicate object key {0:?}")]
    DuplicateKey(String),
    #[error("lone surrogate escape at byte {0}")]
    LoneSurrogate(usize),
    #[error("number at byte {0} is not a canonical integer (0 or [1-9][0-9]*, at most 2^53-1)")]
    NonCanonicalNumber(usize),
    #[error("invalid JSON at byte {0}")]
    Syntax(usize),
}

/// Parse exactly one JSON document from `bytes`.
pub fn parse(bytes: &[u8]) -> Result<Value, ParseError> {
    if bytes.len() > MAX_PLAN_BYTES {
        return Err(ParseError::TooLarge);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| ParseError::InvalidUtf8)?;
    let mut p = Parser {
        src: text.as_bytes(),
        text,
        pos: 0,
    };
    p.skip_ws();
    if p.pos >= p.src.len() {
        return Err(ParseError::Empty);
    }
    let value = p.value(0)?;
    p.skip_ws();
    if p.pos != p.src.len() {
        return Err(ParseError::TrailingData);
    }
    Ok(value)
}

struct Parser<'a> {
    src: &'a [u8],
    text: &'a str,
    pos: usize,
}

impl Parser<'_> {
    fn skip_ws(&mut self) {
        while matches!(self.src.get(self.pos), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn syntax(&self) -> ParseError {
        ParseError::Syntax(self.pos)
    }

    fn literal(&mut self, word: &str, value: Value) -> Result<Value, ParseError> {
        if self.src[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(value)
        } else {
            Err(self.syntax())
        }
    }

    fn value(&mut self, depth: usize) -> Result<Value, ParseError> {
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(Value::String(self.string()?)),
            Some(b't') => self.literal("true", Value::Bool(true)),
            Some(b'f') => self.literal("false", Value::Bool(false)),
            Some(b'n') => self.literal("null", Value::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => Err(self.syntax()),
        }
    }

    fn number(&mut self) -> Result<Value, ParseError> {
        let start = self.pos;
        // Take the whole run of number-ish characters so `1.5`, `2e1` and `-0` are one refusal, not a syntax error
        // somewhere inside them.
        while matches!(
            self.peek(),
            Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
        ) {
            self.pos += 1;
        }
        let token = &self.text[start..self.pos];
        let bytes = token.as_bytes();
        let canonical = match bytes {
            [b'0'] => true,
            [b'1'..=b'9', rest @ ..] => rest.iter().all(u8::is_ascii_digit),
            _ => false,
        };
        // 16 digits is the longest text that can be <= 2^53-1; the length check also bounds the parse below.
        if !canonical || bytes.len() > 16 {
            return Err(ParseError::NonCanonicalNumber(start));
        }
        let n: u64 = token
            .parse()
            .map_err(|_| ParseError::NonCanonicalNumber(start))?;
        if n > MAX_SAFE_INT {
            return Err(ParseError::NonCanonicalNumber(start));
        }
        Ok(Value::Int(n))
    }

    fn array(&mut self, depth: usize) -> Result<Value, ParseError> {
        if depth >= MAX_DEPTH {
            return Err(ParseError::TooDeep);
        }
        self.pos += 1; // [
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Value::Array(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value(depth + 1)?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Value::Array(items));
                }
                _ => return Err(self.syntax()),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value, ParseError> {
        if depth >= MAX_DEPTH {
            return Err(ParseError::TooDeep);
        }
        self.pos += 1; // {
        let mut entries: Vec<(String, Value)> = Vec::new();
        let mut keys = HashSet::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Value::Object(entries));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(self.syntax());
            }
            let key = self.string()?;
            // Compare decoded names, including keys spelled with escapes.
            if !keys.insert(key.clone()) {
                return Err(ParseError::DuplicateKey(key));
            }
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(self.syntax());
            }
            self.pos += 1;
            self.skip_ws();
            let value = self.value(depth + 1)?;
            entries.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Value::Object(entries));
                }
                _ => return Err(self.syntax()),
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, ParseError> {
        let mut n = 0u32;
        for _ in 0..4 {
            let digit = match self.peek() {
                Some(c @ b'0'..=b'9') => c - b'0',
                Some(c @ b'a'..=b'f') => c - b'a' + 10,
                Some(c @ b'A'..=b'F') => c - b'A' + 10,
                _ => return Err(self.syntax()),
            };
            n = n * 16 + u32::from(digit);
            self.pos += 1;
        }
        Ok(n)
    }

    fn string(&mut self) -> Result<String, ParseError> {
        self.pos += 1; // opening quote
        let mut out = String::new();
        loop {
            // Copy the run of plain characters in one slice; the buffer is valid UTF-8 and the run stops at ASCII
            // bytes only, so the slice boundaries are character boundaries.
            let run_start = self.pos;
            while let Some(b) = self.peek() {
                if b == b'"' || b == b'\\' || b < 0x20 {
                    break;
                }
                self.pos += 1;
            }
            out.push_str(&self.text[run_start..self.pos]);
            match self.peek() {
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    let escape_at = self.pos;
                    self.pos += 1;
                    let c = match self.peek() {
                        Some(b'"') => '"',
                        Some(b'\\') => '\\',
                        Some(b'/') => '/',
                        Some(b'b') => '\u{8}',
                        Some(b'f') => '\u{c}',
                        Some(b'n') => '\n',
                        Some(b'r') => '\r',
                        Some(b't') => '\t',
                        Some(b'u') => {
                            self.pos += 1;
                            let c = self.unicode_escape(escape_at)?;
                            out.push(c);
                            continue;
                        }
                        _ => return Err(self.syntax()),
                    };
                    self.pos += 1;
                    out.push(c);
                }
                // A raw control character, or the end of input inside a string.
                _ => return Err(self.syntax()),
            }
        }
    }

    /// After `\u`: one scalar value, or a high+low surrogate pair. Anything else is refused.
    fn unicode_escape(&mut self, escape_at: usize) -> Result<char, ParseError> {
        let first = self.hex4()?;
        match first {
            0xD800..=0xDBFF => {
                if self.src[self.pos..].starts_with(b"\\u") {
                    self.pos += 2;
                    let second = self.hex4()?;
                    if (0xDC00..=0xDFFF).contains(&second) {
                        let scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
                        return char::from_u32(scalar).ok_or(ParseError::LoneSurrogate(escape_at));
                    }
                }
                Err(ParseError::LoneSurrogate(escape_at))
            }
            0xDC00..=0xDFFF => Err(ParseError::LoneSurrogate(escape_at)),
            _ => char::from_u32(first).ok_or(ParseError::LoneSurrogate(escape_at)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Result<Value, ParseError> {
        parse(s.as_bytes())
    }

    #[test]
    fn parses_plain_documents() {
        assert_eq!(p(" 0 ").unwrap(), Value::Int(0));
        assert_eq!(p("[true,false,null]").unwrap().as_array().unwrap().len(), 3);
        let v = p(r#"{"a":{"b":[1,"x"]}}"#).unwrap();
        assert_eq!(
            v.get("a").unwrap().get("b").unwrap().as_array().unwrap()[0],
            Value::Int(1)
        );
    }

    #[test]
    fn duplicate_keys_rejected_at_any_depth() {
        assert!(matches!(p(r#"{"a":1,"a":2}"#), Err(ParseError::DuplicateKey(k)) if k == "a"));
        assert!(matches!(
            p(r#"{"tasks":[{"provider":"claude","provider":"codex"}]}"#),
            Err(ParseError::DuplicateKey(k)) if k == "provider"
        ));
        // Same key spelled with an escape.
        let escaped = format!("{{\"a\":1,\"{0}u0061\":2}}", '\\');
        assert!(matches!(p(&escaped), Err(ParseError::DuplicateKey(_))));
        // Same key name in different objects is fine.
        assert!(p(r#"{"a":{"a":1},"b":{"a":2}}"#).is_ok());
    }

    #[test]
    fn invalid_utf8_rejected() {
        assert_eq!(parse(b"\"\xff\""), Err(ParseError::InvalidUtf8));
        // A raw encoded surrogate (ED A0 80) is invalid UTF-8.
        assert_eq!(parse(b"\"\xed\xa0\x80\""), Err(ParseError::InvalidUtf8));
        assert_eq!(parse(b"\"\xc3\""), Err(ParseError::InvalidUtf8));
    }

    #[test]
    fn lone_surrogate_escapes_rejected() {
        for bad in [
            r#""\ud800""#,
            r#""\udc00""#,
            r#""\ud800x""#,
            r#""\udc00\ud800""#,
            r#"{"\ud800":1}"#,
        ] {
            assert!(matches!(p(bad), Err(ParseError::LoneSurrogate(_))), "{bad}");
        }
        let lone_then_scalar = format!("\"{0}ud800{0}u0041\"", '\\');
        assert!(matches!(
            p(&lone_then_scalar),
            Err(ParseError::LoneSurrogate(_))
        ));
        let pair = format!("\"{0}ud83d{0}ude00\"", '\\');
        assert_eq!(p(&pair).unwrap(), Value::String("\u{1F600}".into()));
    }

    #[test]
    fn two_documents_rejected() {
        assert_eq!(p("{} {}"), Err(ParseError::TrailingData));
        assert_eq!(p("1 2"), Err(ParseError::TrailingData));
        assert_eq!(p("{}\n{}\n"), Err(ParseError::TrailingData));
        assert_eq!(p("{}x"), Err(ParseError::TrailingData));
        assert_eq!(p(""), Err(ParseError::Empty));
        assert_eq!(p("  \n"), Err(ParseError::Empty));
    }

    #[test]
    fn numbers_must_be_canonical_integers() {
        for bad in [
            "1.0",
            "20.0",
            "2e1",
            "1E2",
            "-0",
            "-1",
            "+1",
            "01",
            "00",
            "1.",
            ".5",
            "1e",
            "9007199254740992",
            "99999999999999999999",
        ] {
            assert!(
                matches!(
                    p(bad),
                    Err(ParseError::NonCanonicalNumber(_) | ParseError::Syntax(_))
                ),
                "{bad}: {:?}",
                p(bad)
            );
        }
        assert_eq!(p("9007199254740991").unwrap(), Value::Int(MAX_SAFE_INT));
        assert_eq!(p("0").unwrap(), Value::Int(0));
        assert!(matches!(
            p("9007199254740992"),
            Err(ParseError::NonCanonicalNumber(_))
        ));
        assert!(matches!(p("1.5"), Err(ParseError::NonCanonicalNumber(_))));
    }

    #[test]
    fn syntax_errors_rejected() {
        for bad in [
            "{",
            "[1,]",
            r#"{"a":1,}"#,
            r#"{"a"}"#,
            "[1 2]",
            "'x'",
            "tru",
            "nul",
            r#""abc"#,
            "\"a\nb\"",
            r#""\x""#,
            r#""\u12""#,
            "{1:2}",
            "\u{feff}{}",
        ] {
            assert!(p(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn depth_and_size_are_bounded() {
        let deep = "[".repeat(MAX_DEPTH + 1) + &"]".repeat(MAX_DEPTH + 1);
        assert_eq!(p(&deep), Err(ParseError::TooDeep));
        let ok = "[".repeat(MAX_DEPTH) + &"]".repeat(MAX_DEPTH);
        assert!(p(&ok).is_ok());
        assert_eq!(
            parse(&vec![b' '; MAX_PLAN_BYTES + 1]),
            Err(ParseError::TooLarge)
        );
    }
}
