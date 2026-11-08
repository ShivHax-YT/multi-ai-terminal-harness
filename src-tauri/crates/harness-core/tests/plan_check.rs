//! T-116: the rule checker, ported from `spike/plan/check.jq` (hard rules 1, 2, 7 and 9). The rule numbers and message
//! substrings are the ones `spike/tests/test_plan.sh` asserts. Reads `docs/spec/examples/` read-only.

mod plan {
    use harness_core::plan::{check, Mode, ParseError, Plan, Violation};
    use serde_json::{json, Value};
    use std::path::Path;

    fn example(name: &str) -> Vec<u8> {
        std::fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../../docs/spec/examples")
                .join(name),
        )
        .expect("example plan")
    }

    fn example_json(name: &str) -> Value {
        serde_json::from_slice(&example(name)).unwrap()
    }

    fn plan_of(v: &Value) -> Plan {
        Plan::from_bytes(&serde_json::to_vec(v).unwrap()).expect("parses")
    }

    /// The spike's output lines.
    fn lines(plan: &Plan, mode: Mode) -> Vec<String> {
        check(plan, mode).iter().map(Violation::to_string).collect()
    }

    fn pre(v: &Value) -> Vec<String> {
        lines(&plan_of(v), Mode::Pre)
    }

    fn mutated(base: &str, f: impl FnOnce(&mut Value)) -> Value {
        let mut v = example_json(base);
        f(&mut v);
        v
    }

    fn valid(f: impl FnOnce(&mut Value)) -> Value {
        mutated("plan-valid.json", f)
    }

    #[track_caller]
    fn expect_reject(name: &str, v: &Value, prefix: &str, contains: &str) {
        let out = pre(v);
        assert!(
            out.iter()
                .any(|l| l.starts_with(prefix) && l.contains(contains)),
            "{name}: wanted a `{prefix}` line containing `{contains}`, got {out:#?}"
        );
    }

    #[track_caller]
    fn expect_pass(name: &str, v: &Value) {
        let out = pre(v);
        assert!(out.is_empty(), "{name}: {out:#?}");
    }

    /// plan-approved.json with `approval.plan_hash` set to this module's hash of the plan.
    fn bound_approved() -> Value {
        let mut v = example_json("plan-approved.json");
        let hash = plan_of(&v).hash().to_owned();
        v["approval"]["plan_hash"] = json!(hash);
        v
    }

    fn fb(provider: &str) -> Value {
        json!({"provider": provider, "auth_mode": "subscription"})
    }

    #[test]
    fn valid_example_passes() {
        let valid = Plan::from_bytes(&example("plan-valid.json")).unwrap();
        assert_eq!(lines(&valid, Mode::Pre), Vec::<String>::new());
        assert!(valid.model().is_ok());
        let model = valid.model().unwrap();
        assert_eq!(model.tasks.len(), 4);
        assert_eq!(model.tasks[2].depends_on, ["t1", "t2"]);
        assert!(model.approval.is_none());
        // Approved and correctly bound to this module's hash: passes in both modes. (The hash stored in
        // plan-approved.json is the spike's newline-framed one, so it is rebound here; see the T-116 handoff.)
        let approved = plan_of(&bound_approved());
        assert_eq!(lines(&approved, Mode::Pre), Vec::<String>::new());
        assert!(lines(&approved, Mode::Scheduler).is_empty());
        assert!(approved.model().unwrap().approval.is_some());
        // The stored spike hash does not verify: the mismatch is reported, never accepted.
        let stored = Plan::from_bytes(&example("plan-approved.json")).unwrap();
        assert!(lines(&stored, Mode::Scheduler)
            .iter()
            .any(|l| l.contains("does not match computed plan hash")));
        assert_eq!(model.summary_budget_tokens, 200);
    }

    #[test]
    fn check_rule2() {
        let dup = Plan::from_bytes(&example("plan-dup-fallback.json")).unwrap();
        let out = lines(&dup, Mode::Pre);
        assert!(out.iter().any(|l| l.starts_with("rule 2:")), "{out:#?}");
        assert!(
            out.iter()
                .any(|l| l.starts_with("rule 2:") && l.contains("lists its own provider")),
            "{out:#?}"
        );
        let v = check(&dup, Mode::Pre);
        assert!(v.iter().any(|v| v.rule == 2 && v.task_id.is_some()));

        expect_reject(
            "own provider",
            &valid(|v| v["tasks"][0]["fallback_providers"] = json!([fb("claude")])),
            "rule 2:",
            "lists its own provider",
        );
        expect_reject(
            "repeat",
            &valid(|v| v["tasks"][1]["fallback_providers"] = json!([fb("kimi"), fb("kimi")])),
            "rule 2:",
            "repeats fallback provider kimi",
        );
        for (name, entry) in [
            (
                "case variant",
                json!({"provider": "Gemini", "auth_mode": "api_key"}),
            ),
            (
                "trailing space",
                json!({"provider": "claude ", "auth_mode": "subscription"}),
            ),
            ("null element", Value::Null),
            ("legacy string", json!("codex")),
        ] {
            expect_reject(
                name,
                &valid(|v| v["tasks"][0]["fallback_providers"] = json!([fb("codex"), entry])),
                "rule 2:",
                "",
            );
        }
        expect_reject(
            "case-variant repeat",
            &valid(|v| v["tasks"][1]["fallback_providers"] = json!([fb("kimi"), fb("Kimi")])),
            "rule 2:",
            "",
        );
        for (name, bad) in [
            ("string", json!("codex")),
            ("null", Value::Null),
            ("object", json!({})),
        ] {
            expect_reject(
                name,
                &valid(|v| v["tasks"][0]["fallback_providers"] = bad),
                "rule 2:",
                "fallback_providers must be an array",
            );
        }
        expect_reject(
            "missing",
            &valid(|v| {
                v["tasks"][0]
                    .as_object_mut()
                    .unwrap()
                    .remove("fallback_providers");
            }),
            "rule 2:",
            "",
        );
        expect_reject(
            "extra key in fallback entry",
            &valid(|v| {
                let mut entry = fb("codex");
                entry["max_turns"] = json!(999);
                v["tasks"][0]["fallback_providers"] = json!([entry]);
            }),
            "rule 9:",
            "unknown key",
        );
    }

    #[test]
    fn check_rule7() {
        let gem = Plan::from_bytes(&example("plan-gemini-subscription.json")).unwrap();
        let out = lines(&gem, Mode::Pre);
        assert!(
            out.iter()
                .any(|l| l.starts_with("rule 7:") && l.contains("gemini is api_key only")),
            "{out:#?}"
        );

        expect_reject(
            "gemini lead",
            &valid(|v| v["lead"] = json!({"provider": "gemini", "auth_mode": "subscription"})),
            "rule 7:",
            "lead uses gemini with auth_mode subscription; gemini is api_key only",
        );
        expect_pass(
            "gemini lead on api_key",
            &valid(|v| v["lead"] = json!({"provider": "gemini", "auth_mode": "api_key"})),
        );
        expect_reject(
            "gemini fallback",
            &valid(|v| {
                v["tasks"][0]["fallback_providers"] =
                    json!([{"provider": "gemini", "auth_mode": "subscription"}]);
            }),
            "rule 7:",
            "task t1 has a gemini fallback with auth_mode subscription",
        );
        expect_reject(
            "gemini task",
            &valid(|v| v["tasks"][3]["auth_mode"] = json!("subscription")),
            "rule 7:",
            "task t4 uses gemini with auth_mode subscription",
        );
        // Provider and auth_mode allow-lists are exact.
        for (name, ptr, val) in [
            ("Gemini", "/tasks/3/provider", json!("Gemini")),
            ("gemini space", "/tasks/3/provider", json!("gemini ")),
            ("null", "/tasks/3/provider", Value::Null),
            ("number", "/tasks/0/provider", json!(5)),
            ("unknown", "/tasks/0/provider", json!("other")),
            ("lead Claude", "/lead/provider", json!("Claude")),
            ("API_KEY", "/tasks/3/auth_mode", json!("API_KEY")),
            ("auth null", "/tasks/0/auth_mode", Value::Null),
            ("lead auth", "/lead/auth_mode", json!("key")),
        ] {
            let mut v = valid(|_| {});
            *v.pointer_mut(ptr).unwrap() = val;
            expect_reject(name, &v, "rule 7:", "");
        }
        expect_reject(
            "lead missing",
            &valid(|v| {
                v.as_object_mut().unwrap().remove("lead");
            }),
            "rule 7:",
            "lead must be an object",
        );
        expect_reject(
            "provider missing",
            &valid(|v| {
                v["tasks"][0].as_object_mut().unwrap().remove("provider");
            }),
            "rule 7:",
            "",
        );
        expect_reject(
            "auth_mode missing",
            &valid(|v| {
                v["tasks"][0].as_object_mut().unwrap().remove("auth_mode");
            }),
            "rule 7:",
            "",
        );
        // glm is a provider (flagged for the human in T-005's handoff).
        expect_pass(
            "glm task",
            &valid(|v| v["tasks"][3]["provider"] = json!("glm")),
        );
    }

    #[test]
    fn check_rule1() {
        let over = Plan::from_bytes(&example("plan-over-turns.json")).unwrap();
        let out = lines(&over, Mode::Pre);
        assert!(
            out.iter().any(
                |l| l.starts_with("rule 1:") && l.contains("estimates 41 turns, ceiling is 40")
            ),
            "{out:#?}"
        );
        assert!(check(&over, Mode::Pre)
            .iter()
            .any(|v| v.rule == 1 && v.task_id.is_some()));

        expect_reject(
            "prompts over 30",
            &valid(|v| v["tasks"][0]["estimated_usage"]["prompts"] = json!(31)),
            "rule 1:",
            "ceiling is 30",
        );
        // Exactly the ceilings pass: 40 turns, and 30 summed prompts per provider.
        expect_pass(
            "40 turns",
            &valid(|v| v["tasks"][0]["estimated_usage"]["turns"] = json!(40)),
        );
        expect_pass(
            "30 prompts",
            &valid(|v| v["tasks"][0]["estimated_usage"]["prompts"] = json!(30)),
        );
        // The sum is per provider across tasks.
        expect_reject(
            "summed over two tasks",
            &valid(|v| {
                v["tasks"][2]["provider"] = json!("claude");
                v["tasks"][2]["fallback_providers"] = json!([fb("codex")]);
                v["tasks"][0]["estimated_usage"]["prompts"] = json!(20);
                v["tasks"][2]["estimated_usage"]["prompts"] = json!(11);
            }),
            "rule 1:",
            "subscription provider claude plan estimates 31 prompts",
        );
        // Unusable estimates are rule 1 shape errors, not defaults.
        for (name, val) in [
            ("true", json!(true)),
            ("null", Value::Null),
            ("string", json!("99")),
            ("over cap", json!(1_000_001)),
        ] {
            expect_reject(
                name,
                &valid(|v| v["tasks"][0]["estimated_usage"]["turns"] = val.clone()),
                "rule 1:",
                "estimated_usage.turns must be an integer from 0 to 1000000",
            );
            expect_reject(
                name,
                &valid(|v| v["tasks"][0]["estimated_usage"]["prompts"] = val.clone()),
                "rule 1:",
                "estimated_usage.prompts must be an integer from 0 to 1000000",
            );
        }
        expect_reject(
            "turns missing",
            &valid(|v| {
                v["tasks"][0]["estimated_usage"]
                    .as_object_mut()
                    .unwrap()
                    .remove("turns");
            }),
            "rule 1:",
            "",
        );
        for (name, val) in [
            ("missing", None),
            ("null", Some(Value::Null)),
            ("array", Some(json!([]))),
        ] {
            expect_reject(
                name,
                &valid(|v| match val {
                    Some(x) => v["tasks"][0]["estimated_usage"] = x,
                    None => {
                        v["tasks"][0]
                            .as_object_mut()
                            .unwrap()
                            .remove("estimated_usage");
                    }
                }),
                "rule 1:",
                "estimated_usage must be an object",
            );
        }
        expect_pass(
            "zero usage",
            &valid(|v| v["tasks"][2]["estimated_usage"] = json!({"prompts": 0, "turns": 0})),
        );
    }

    #[test]
    fn api_key_prompts_not_counted() {
        expect_pass(
            "api_key prompts",
            &valid(|v| v["tasks"][3]["estimated_usage"]["prompts"] = json!(500)),
        );
        // Anything that is not exactly api_key is a subscription (and a bad auth_mode is a shape error anyway).
        expect_reject(
            "same provider flipped to subscription",
            &valid(|v| {
                v["tasks"][3]["estimated_usage"]["prompts"] = json!(500);
                v["tasks"][3]["provider"] = json!("claude");
                v["tasks"][3]["auth_mode"] = json!("subscription");
            }),
            "rule 1:",
            "ceiling is 30",
        );
    }

    #[test]
    fn negative_numbers_cannot_hide_an_overrun() {
        // A negative count is refused when parsing, so it can never cancel out a real subscription total.
        let text = String::from_utf8(example("plan-valid.json"))
            .unwrap()
            .replacen("\"prompts\": 12", "\"prompts\": -20", 1);
        assert!(matches!(
            Plan::from_bytes(text.as_bytes()),
            Err(ParseError::NonCanonicalNumber(_))
        ));
    }

    #[test]
    fn check_rule9() {
        // Unused fallback provider.
        expect_reject(
            "unused fallback",
            &valid(|v| v["tasks"][0]["fallback_providers"] = json!([fb("grok")])),
            "rule 9:",
            "not used by any task in the plan",
        );
        // Unknown dependency, self dependency, duplicate dependency, cycle.
        expect_reject(
            "unknown dependency",
            &valid(|v| v["tasks"][0]["depends_on"] = json!(["nope"])),
            "rule 9:",
            "references unknown task \"nope\"",
        );
        expect_reject(
            "self dependency",
            &valid(|v| v["tasks"][0]["depends_on"] = json!(["t1"])),
            "rule 9:",
            "tasks[0] depends on itself",
        );
        expect_reject(
            "duplicate dependency",
            &valid(|v| v["tasks"][2]["depends_on"] = json!(["t1", "t1"])),
            "rule 9:",
            "depends_on lists \"t1\" more than once",
        );
        let cycle = valid(|v| {
            v["tasks"][0]["depends_on"] = json!(["t2"]);
            v["tasks"][1]["depends_on"] = json!(["t1"]);
        });
        let out = pre(&cycle);
        // t3 depends on t1 and t2, so it is blocked downstream of the cycle; t4 depends on t1 as well.
        assert!(
            out.contains(&"rule 9: tasks blocked by a dependency cycle: t1, t2, t3, t4".to_owned()),
            "{out:#?}"
        );
        // Shape violations stop the rule checks: no cycle line is reported for a malformed plan.
        let both = valid(|v| {
            v["tasks"][0]["depends_on"] = json!(["t2"]);
            v["tasks"][1]["depends_on"] = json!(["t1"]);
            v["plan_id"] = json!("");
        });
        assert!(pre(&both).iter().all(|l| !l.contains("cycle")));

        // Task structure.
        expect_reject(
            "duplicate ids",
            &valid(|v| v["tasks"][1]["id"] = json!("t1")),
            "rule 9:",
            "duplicate task id t1",
        );
        for (name, bad) in [
            ("tasks null", Value::Null),
            ("tasks empty", json!([])),
            ("tasks object", json!({})),
            ("tasks string", json!("x")),
        ] {
            expect_reject(
                name,
                &valid(|v| v["tasks"] = bad),
                "rule 9:",
                "tasks must be a non-empty array",
            );
        }
        expect_reject(
            "tasks missing",
            &valid(|v| {
                v.as_object_mut().unwrap().remove("tasks");
            }),
            "rule 9:",
            "tasks must be a non-empty array",
        );
        expect_reject(
            "task string",
            &valid(|v| v["tasks"][0] = json!("x")),
            "rule 9:",
            "tasks[0] is not an object",
        );
        expect_reject(
            "task null",
            &valid(|v| v["tasks"][0] = Value::Null),
            "rule 9:",
            "tasks[0] is not an object",
        );
        expect_reject(
            "depends_on string",
            &valid(|v| v["tasks"][0]["depends_on"] = json!("t2")),
            "rule 9:",
            "tasks[0].depends_on must be an array of strings",
        );
        for id in [
            json!("../x y"),
            json!("t 1"),
            json!(""),
            json!("t1\n"),
            json!(1),
            Value::Null,
        ] {
            expect_reject(
                "bad id",
                &valid(|v| v["tasks"][0]["id"] = id),
                "rule 9:",
                "tasks[0].id must be a string matching",
            );
        }

        // Unknown keys at every level.
        expect_reject(
            "top key",
            &valid(|v| v["ceiling_override"] = json!(1000)),
            "rule 9:",
            "plan has unknown key \"ceiling_override\"",
        );
        expect_reject(
            "lead key",
            &valid(|v| v["lead"]["max_turns"] = json!(1000)),
            "rule 9:",
            "lead has unknown key",
        );
        expect_reject(
            "task key",
            &valid(|v| v["tasks"][0]["max_turns"] = json!(1000)),
            "rule 9:",
            "tasks[0] has unknown key",
        );
        expect_reject(
            "usage key",
            &valid(|v| v["tasks"][0]["estimated_usage"]["hours"] = json!(99)),
            "rule 9:",
            "estimated_usage has unknown key",
        );
        expect_reject(
            "approval key",
            &mutated("plan-approved.json", |v| {
                v["approval"]["scope"] = json!("all")
            }),
            "rule 9:",
            "approval has unknown key",
        );

        // Required fields and types.
        let required: [(&str, &str); 6] = [
            ("format_version", "format_version must be the integer 1"),
            ("plan_id", "plan_id must be a non-empty string"),
            ("created_at", "created_at must be an RFC 3339 timestamp"),
            ("request_summary", "request_summary must be a string"),
            ("summary_budget_tokens", "summary_budget_tokens is required"),
            ("lead", "lead must be an object"),
        ];
        for (key, msg) in required {
            expect_reject(
                key,
                &valid(|v| {
                    v.as_object_mut().unwrap().remove(key);
                }),
                "rule ",
                msg,
            );
        }
        for task_key in [
            "title",
            "role",
            "owned_files",
            "acceptance",
            "depends_on",
            "id",
        ] {
            expect_reject(
                task_key,
                &valid(|v| {
                    v["tasks"][0].as_object_mut().unwrap().remove(task_key);
                }),
                "rule 9:",
                &format!("tasks[0].{task_key} must be"),
            );
        }
        for (name, ptr, val, msg) in [
            ("plan_id number", "/plan_id", json!(5), "plan_id"),
            ("plan_id empty", "/plan_id", json!(""), "plan_id"),
            (
                "created_at text",
                "/created_at",
                json!("yesterday"),
                "created_at",
            ),
            (
                "created_at newline",
                "/created_at",
                json!("2026-10-25T09:00:00Z\n"),
                "created_at",
            ),
            (
                "created_at month",
                "/created_at",
                json!("2026-13-25T09:00:00Z"),
                "created_at",
            ),
            (
                "request_summary number",
                "/request_summary",
                json!(1),
                "request_summary",
            ),
            ("title empty", "/tasks/0/title", json!(""), "tasks[0].title"),
            ("role number", "/tasks/0/role", json!(1), "tasks[0].role"),
            (
                "acceptance string",
                "/tasks/0/acceptance",
                json!("all"),
                "tasks[0].acceptance",
            ),
            (
                "acceptance non-string",
                "/tasks/0/acceptance",
                json!([1]),
                "tasks[0].acceptance",
            ),
            (
                "owned_files string",
                "/tasks/0/owned_files",
                json!("**"),
                "tasks[0].owned_files",
            ),
            (
                "owned_files null item",
                "/tasks/0/owned_files",
                json!([null]),
                "tasks[0].owned_files",
            ),
            (
                "budget 0",
                "/summary_budget_tokens",
                json!(0),
                "summary_budget_tokens",
            ),
            (
                "budget big",
                "/summary_budget_tokens",
                json!(1_000_001),
                "summary_budget_tokens",
            ),
            (
                "budget string",
                "/summary_budget_tokens",
                json!("200"),
                "summary_budget_tokens",
            ),
            (
                "budget bool",
                "/summary_budget_tokens",
                json!(true),
                "summary_budget_tokens",
            ),
            ("format 2", "/format_version", json!(2), "format_version"),
            (
                "format string",
                "/format_version",
                json!("1"),
                "format_version",
            ),
            ("format 0", "/format_version", json!(0), "format_version"),
        ] {
            let mut v = valid(|_| {});
            *v.pointer_mut(ptr).unwrap() = val;
            expect_reject(name, &v, "rule 9:", msg);
        }

        // A non-object document is a plan violation, not an error; the hash is still defined.
        for doc in ["[]", "\"x\"", "5", "null", "true"] {
            let plan = Plan::from_bytes(doc.as_bytes()).unwrap();
            assert_eq!(
                lines(&plan, Mode::Pre),
                ["rule 9: plan must be a JSON object"],
                "{doc}"
            );
            assert_eq!(
                lines(&plan, Mode::Scheduler),
                ["rule 9: plan must be a JSON object"],
                "{doc}"
            );
            assert!(plan.model().is_err());
        }
    }

    #[test]
    fn approval_presence_and_shape() {
        // Scheduler mode needs an approval; pre-approval mode does not.
        let valid_plan = Plan::from_bytes(&example("plan-valid.json")).unwrap();
        assert_eq!(
            lines(&valid_plan, Mode::Scheduler),
            ["rule 9: plan has no approval"]
        );
        assert!(lines(&valid_plan, Mode::Pre).is_empty());
        assert_eq!(
            valid_plan.check(Mode::Scheduler),
            check(&valid_plan, Mode::Scheduler)
        );

        // A stale approval fails in both modes.
        let stale = Plan::from_bytes(&example("plan-stale-approval.json")).unwrap();
        for mode in [Mode::Pre, Mode::Scheduler] {
            let out = lines(&stale, mode);
            assert!(
                out.iter()
                    .any(|l| l.starts_with("rule 9:")
                        && l.contains("does not match computed plan hash")),
                "{out:#?}"
            );
        }
        // Editing an approved plan voids the approval; re-binding to the new hash passes.
        let mut edited = example_json("plan-approved.json");
        edited["tasks"][0]["fallback_providers"] = json!([fb("codex"), fb("kimi")]);
        let edited_plan = plan_of(&edited);
        assert!(lines(&edited_plan, Mode::Scheduler)
            .iter()
            .any(|l| l.contains("does not match computed plan hash")
                && l.contains("plan was edited after approval")));
        edited["approval"]["plan_hash"] = json!(edited_plan.hash());
        assert!(lines(&plan_of(&edited), Mode::Scheduler).is_empty());
        let mut usage = example_json("plan-approved.json");
        usage["tasks"][0]["estimated_usage"]["turns"] = json!(21);
        assert!(lines(&plan_of(&usage), Mode::Scheduler)
            .iter()
            .any(|l| l.contains("does not match")));

        let approved = |f: &dyn Fn(&mut Value)| mutated("plan-approved.json", |v| f(v));
        expect_reject(
            "not ui",
            &approved(&|v| v["approval"]["approved_via"] = json!("cli")),
            "rule 9:",
            "approval approved_via must be \"ui\"",
        );
        expect_reject(
            "no hash",
            &approved(&|v| {
                v["approval"].as_object_mut().unwrap().remove("plan_hash");
            }),
            "rule 9:",
            "approval.plan_hash must be 64 lowercase hex",
        );
        for bad in [
            json!(7),
            json!("abc123"),
            json!("F".repeat(64)),
            json!(format!("{}\n", "a".repeat(63))),
        ] {
            expect_reject(
                "hash shape",
                &approved(&|v| v["approval"]["plan_hash"] = bad.clone()),
                "rule 9:",
                "approval.plan_hash",
            );
        }
        for bad in [json!("abc"), json!(5), Value::Null] {
            expect_reject(
                "nonce",
                &approved(&|v| v["approval"]["nonce"] = bad.clone()),
                "rule 9:",
                "approval.nonce",
            );
        }
        for bad in [json!(""), json!("now"), Value::Null, json!(5)] {
            expect_reject(
                "approved_at",
                &approved(&|v| v["approval"]["approved_at"] = bad.clone()),
                "rule 9:",
                "approval.approved_at",
            );
        }
        expect_reject(
            "approved_via missing",
            &approved(&|v| {
                v["approval"]
                    .as_object_mut()
                    .unwrap()
                    .remove("approved_via");
            }),
            "rule 9:",
            "approval.approved_via must be a string",
        );

        // Present-but-malformed approvals, including null, false, 0 and "", are never "absent".
        for bad in [
            Value::Null,
            json!(false),
            json!(0),
            json!(""),
            json!("yes"),
            json!([]),
            json!(true),
            json!({}),
        ] {
            let v = valid(|v| v["approval"] = bad.clone());
            expect_reject("malformed approval", &v, "rule 9:", "approval");
            let out = lines(&plan_of(&v), Mode::Scheduler);
            assert!(!out.is_empty(), "{bad}");
            assert!(
                !out.contains(&"rule 9: plan has no approval".to_owned()),
                "{bad}: key is present"
            );
        }
        let null_approval = valid(|v| v["approval"] = Value::Null);
        assert!(pre(&null_approval).contains(&"rule 9: approval must be an object".to_owned()));
    }

    #[test]
    fn violations_serialize_for_the_ipc_contract() {
        let v = check(
            &Plan::from_bytes(&example("plan-over-turns.json")).unwrap(),
            Mode::Pre,
        );
        let json = serde_json::to_value(&v).unwrap();
        let first = &json[0];
        assert_eq!(first["rule"], 1);
        assert!(first["message"].as_str().unwrap().starts_with("task "));
        assert!(first["task_id"].is_string());
        let no_task = serde_json::to_value(Violation::new(9, "plan has no approval")).unwrap();
        assert!(no_task.get("task_id").is_none());
    }
}
