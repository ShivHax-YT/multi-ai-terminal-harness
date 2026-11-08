//! T-116: strict parsing, JCS vectors and the plan hash (hard rule 9). Reads `docs/spec/examples/` read-only.

mod plan {
    use harness_core::plan::jcs::{canonicalize, write_string};
    use harness_core::plan::parse::parse;
    use harness_core::plan::{ParseError, Plan, Value};
    use std::path::{Path, PathBuf};

    use sha2::{Digest, Sha256};

    const VALID_HASH: &str = "dae6b286198d47e913fe538bb32efb487fabd5ac51893218b828a7385db41401";

    fn root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
    }

    fn example(name: &str) -> Vec<u8> {
        std::fs::read(root().join("docs/spec/examples").join(name)).expect("example plan")
    }

    fn valid_json() -> serde_json::Value {
        serde_json::from_slice(&example("plan-valid.json")).expect("valid example is JSON")
    }

    fn plan_of(v: &serde_json::Value) -> Plan {
        Plan::from_bytes(&serde_json::to_vec(v).expect("serialize")).expect("parses")
    }

    fn hash_of(v: &serde_json::Value) -> String {
        plan_of(v).hash().to_owned()
    }

    /// Every leaf (non-container) location of `v` as a JSON pointer.
    fn leaves(v: &serde_json::Value, at: String, out: &mut Vec<String>) {
        match v {
            serde_json::Value::Object(map) => {
                for (k, child) in map {
                    leaves(child, format!("{at}/{k}"), out);
                }
            }
            serde_json::Value::Array(items) => {
                for (i, child) in items.iter().enumerate() {
                    leaves(child, format!("{at}/{i}"), out);
                }
            }
            _ => out.push(at),
        }
    }

    #[test]
    fn hash_matches_the_spike_for_the_examples() {
        // For these fixtures `jq -j -S -c 'del(.approval)'` emits the JCS bytes without a trailing newline.
        for (file, expected) in [
            ("plan-valid.json", VALID_HASH),
            ("plan-approved.json", VALID_HASH),
            (
                "plan-dup-fallback.json",
                "66b97387c3b14dc6f954c8a8624d5e7e31ca0ba679b5cdfa0df586007a317f40",
            ),
            (
                "plan-gemini-subscription.json",
                "651db2a0496ca20586802ab23cad97474305190dbf37972ef7354f3999e37b34",
            ),
            (
                "plan-over-turns.json",
                "6199c4edafae120fb119c5095171900bf97d49a90e5c951c4c0586fc64f91627",
            ),
            (
                "plan-stale-approval.json",
                "d3fd483780df72a41d47205c56858778e30f44552c8983c9fd169cf0b7bcb36e",
            ),
        ] {
            assert_eq!(
                Plan::from_bytes(&example(file)).unwrap().hash(),
                expected,
                "{file}"
            );
        }
    }

    #[test]
    fn approval_hash_excludes_the_old_spike_newline() {
        let approved = Plan::from_bytes(&example("plan-approved.json")).unwrap();
        let mut spike_framing = approved.canonical_bytes();
        spike_framing.push(b'\n');
        let spike_hash = hex::encode(Sha256::digest(&spike_framing));
        let stored = example_json("plan-approved.json")["approval"]["plan_hash"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(stored, approved.hash());
        assert_ne!(stored, spike_hash);
    }

    fn example_json(name: &str) -> serde_json::Value {
        serde_json::from_slice(&example(name)).unwrap()
    }

    #[test]
    fn hash_is_lowercase_hex_and_excludes_approval() {
        let valid = Plan::from_bytes(&example("plan-valid.json")).unwrap();
        assert_eq!(valid.hash().len(), 64);
        assert!(valid
            .hash()
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')));
        let mut with_approval = valid_json();
        with_approval["approval"] = serde_json::json!({"anything": [1, 2, 3]});
        assert_eq!(hash_of(&with_approval), valid.hash());
        // The canonical bytes are the bytes that were hashed, and carry no approval member.
        assert!(!String::from_utf8(valid.canonical_bytes())
            .unwrap()
            .contains("approval"));
    }

    #[test]
    fn hash_changes_on_any_field() {
        let base = valid_json();
        let base_hash = hash_of(&base);
        let mut pointers = Vec::new();
        leaves(&base, String::new(), &mut pointers);
        assert!(pointers.len() > 40, "walk found {} leaves", pointers.len());
        for ptr in &pointers {
            let mut changed = base.clone();
            let slot = changed.pointer_mut(ptr).expect("leaf exists");
            *slot = match slot {
                serde_json::Value::String(s) => serde_json::Value::String(format!("{s}x")),
                serde_json::Value::Number(n) => serde_json::json!(n.as_u64().unwrap() + 1),
                serde_json::Value::Bool(b) => serde_json::Value::Bool(!*b),
                other => panic!("unexpected leaf {other:?} at {ptr}"),
            };
            assert_ne!(
                hash_of(&changed),
                base_hash,
                "changing {ptr} left the hash unchanged"
            );
        }
        // Adding, removing and reordering also change it.
        let mut added = base.clone();
        added["tasks"][0]["extra"] = serde_json::json!(1);
        assert_ne!(hash_of(&added), base_hash);
        let mut removed = base.clone();
        removed["tasks"][0].as_object_mut().unwrap().remove("role");
        assert_ne!(hash_of(&removed), base_hash);
        let mut swapped = base.clone();
        swapped["tasks"][2]["depends_on"] = serde_json::json!(["t2", "t1"]);
        assert_ne!(hash_of(&swapped), base_hash);
        let mut dropped_task = base.clone();
        dropped_task["tasks"].as_array_mut().unwrap().pop();
        assert_ne!(hash_of(&dropped_task), base_hash);
    }

    /// Render `v` with object members in reverse document order and padded whitespace.
    fn render_reversed(v: &Value, out: &mut String) {
        match v {
            Value::Null => out.push_str("null"),
            Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Value::Int(n) => out.push_str(&n.to_string()),
            Value::String(s) => write_string(s, out),
            Value::Array(items) => {
                out.push_str("[ ");
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push_str(" ,\n");
                    }
                    render_reversed(item, out);
                }
                out.push_str(" ]");
            }
            Value::Object(entries) => {
                out.push_str("{\n");
                for (i, (k, member)) in entries.iter().rev().enumerate() {
                    if i > 0 {
                        out.push_str(" ,\n");
                    }
                    write_string(k, out);
                    out.push_str("  :  ");
                    render_reversed(member, out);
                }
                out.push_str("\n}");
            }
        }
    }

    #[test]
    fn hash_ignores_key_order() {
        let original = Plan::from_bytes(&example("plan-valid.json")).unwrap();
        let mut text = String::new();
        render_reversed(original.value(), &mut text);
        let reversed = Plan::from_bytes(text.as_bytes()).unwrap();
        assert_ne!(
            text.as_bytes(),
            example("plan-valid.json").as_slice(),
            "the copy must really differ"
        );
        assert_ne!(
            reversed.value(),
            original.value(),
            "member order differs in the parsed value"
        );
        assert_eq!(reversed.hash(), original.hash());
        assert_eq!(reversed.canonical_bytes(), original.canonical_bytes());
    }

    #[test]
    fn duplicate_keys_rejected() {
        let valid = String::from_utf8(example("plan-valid.json")).unwrap();
        // Top level.
        let top = valid.replacen("\"plan_id\"", "\"plan_id\": \"a\",\n  \"plan_id\"", 1);
        assert!(
            matches!(Plan::from_bytes(top.as_bytes()), Err(ParseError::DuplicateKey(k)) if k == "plan_id")
        );
        // Nested: a second "provider" inside the first task.
        let nested = valid.replacen(
            "\"provider\": \"claude\",",
            "\"provider\": \"claude\",\n      \"provider\": \"codex\",",
            1,
        );
        assert_ne!(nested, valid);
        assert!(
            matches!(Plan::from_bytes(nested.as_bytes()), Err(ParseError::DuplicateKey(k)) if k == "provider")
        );
        // Inside a fallback entry, inside the lead, and an escaped spelling of the same key.
        for doc in [
            r#"{"lead":{"provider":"claude","provider":"gemini","auth_mode":"api_key"}}"#,
            r#"{"tasks":[{"fallback_providers":[{"provider":"a","provider":"b"}]}]}"#,
        ] {
            assert!(
                matches!(
                    Plan::from_bytes(doc.as_bytes()),
                    Err(ParseError::DuplicateKey(_))
                ),
                "{doc}"
            );
        }
        let escaped = format!(
            "{{\"provider\":\"claude\",\"{0}u0070rovider\":\"gemini\"}}",
            '\\'
        );
        assert!(matches!(
            Plan::from_bytes(escaped.as_bytes()),
            Err(ParseError::DuplicateKey(_))
        ));
        // Duplicates are refused before shape checks, so they never reach a hash.
        assert!(parse(br#"{"a":1,"a":1}"#).is_err());
    }

    #[test]
    fn bad_encoding_rejected() {
        let mut bad_utf8 = example("plan-valid.json");
        let at = bad_utf8.windows(8).position(|w| w == b"settings").unwrap();
        bad_utf8[at] = 0xff;
        assert_eq!(
            Plan::from_bytes(&bad_utf8).unwrap_err(),
            ParseError::InvalidUtf8
        );
        // A raw encoded surrogate, a truncated sequence, and an overlong NUL.
        for raw in [&b"\"\xed\xa0\x80\""[..], b"\"\xe2\x82\"", b"\"\xc0\x80\""] {
            assert_eq!(Plan::from_bytes(raw).unwrap_err(), ParseError::InvalidUtf8);
        }
        // Lone surrogate escapes, in values and in keys.
        for doc in [
            r#"{"request_summary":"\ud800"}"#,
            r#"{"request_summary":"\udfff"}"#,
            r#"{"request_summary":"\ud800\ud800"}"#,
            r#"{"request_summary":"\ud83dx\ude00"}"#,
            r#"{"\ud800":"x"}"#,
        ] {
            assert!(
                matches!(
                    Plan::from_bytes(doc.as_bytes()),
                    Err(ParseError::LoneSurrogate(_))
                ),
                "{doc}"
            );
        }
        // A well-formed pair is fine and canonicalizes to the raw character.
        let pair = format!("{{\"request_summary\":\"{0}ud83d{0}ude00\"}}", '\\');
        let ok = Plan::from_bytes(pair.as_bytes()).unwrap();
        assert_eq!(
            String::from_utf8(ok.canonical_bytes()).unwrap(),
            "{\"request_summary\":\"\u{1F600}\"}"
        );
    }

    #[test]
    fn two_documents_rejected() {
        let one = example("plan-valid.json");
        let mut two = one.clone();
        two.extend_from_slice(&one);
        assert_eq!(
            Plan::from_bytes(&two).unwrap_err(),
            ParseError::TrailingData
        );
        let mut junk = one.clone();
        junk.extend_from_slice(b"\n0");
        assert_eq!(
            Plan::from_bytes(&junk).unwrap_err(),
            ParseError::TrailingData
        );
        let mut trailing_ws = one.clone();
        trailing_ws.extend_from_slice(b"\n\n  \t\r\n");
        assert!(Plan::from_bytes(&trailing_ws).is_ok());
        assert_eq!(Plan::from_bytes(b"").unwrap_err(), ParseError::Empty);
    }

    #[test]
    fn numbers_must_be_canonical_integers() {
        let valid = String::from_utf8(example("plan-valid.json")).unwrap();
        for replacement in [
            "20.0",
            "2e1",
            "2E1",
            "-0",
            "-20",
            "+20",
            "020",
            "20.",
            "1.5",
            "9007199254740992",
            "1e400",
            "0x14",
        ] {
            let doc = valid.replacen("\"turns\": 20", &format!("\"turns\": {replacement}"), 1);
            assert_ne!(doc, valid);
            assert!(
                matches!(
                    Plan::from_bytes(doc.as_bytes()),
                    Err(ParseError::NonCanonicalNumber(_) | ParseError::Syntax(_))
                ),
                "{replacement}"
            );
        }
        let max = valid.replacen("\"turns\": 20", "\"turns\": 9007199254740991", 1);
        assert!(Plan::from_bytes(max.as_bytes()).is_ok());
    }

    #[test]
    fn jcs_vectors() {
        let dir = root().join("src-tauri/crates/harness-core/tests/fixtures/jcs");
        let mut inputs: Vec<PathBuf> = std::fs::read_dir(&dir)
            .expect("fixture dir")
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|e| e == "in"))
            .collect();
        inputs.sort();
        assert!(
            inputs.len() >= 7,
            "expected the fixture set, found {}",
            inputs.len()
        );
        for input in inputs {
            let expected = std::fs::read(input.with_extension("jcs")).expect("expected output");
            let value =
                parse(&std::fs::read(&input).unwrap()).unwrap_or_else(|e| panic!("{input:?}: {e}"));
            let got = canonicalize(&value);
            assert_eq!(
                got,
                expected,
                "{input:?}: got {:?}",
                String::from_utf8_lossy(&got)
            );
            // Canonical form is a fixed point.
            assert_eq!(
                canonicalize(&parse(&got).unwrap()),
                got,
                "{input:?} not idempotent"
            );
        }
    }
}
