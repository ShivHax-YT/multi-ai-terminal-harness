//! The plan model (T-116): strict parser, RFC 8785 canonical form, hash and rule checker.
//!
//! Pure: bytes in, value, hash and violations out. Nothing here reads a file, spawns a process or touches a provider.
//! `Plan::from_bytes` is the one read of one buffer; the hash, the checker and the typed model all come from that single
//! parse, and dispatch must use that same value (hard rule 9). The approval token itself is T-117's.
//!
//! `simulation` is the browser sample flow added by T-132/T-133. It keeps its own hash and is not part of this model;
//! folding it into the JCS hash is a later lead decision.

pub mod check;
pub mod hash;
pub mod jcs;
pub mod model;
pub mod parse;
mod shape;
pub mod simulation;

pub use check::{check, Mode, Violation};
pub use model::{
    Approval, AuthMode, EstimatedUsage, PlanModel, ProviderChoice, Task, Value, MAX_SAFE_INT,
};
pub use parse::ParseError;

/// A plan parsed once from a byte buffer. Holds the strict value, its hash and the shape-validation outcome, all
/// computed from that one parse.
#[derive(Debug, Clone)]
pub struct Plan {
    value: Value,
    hash: String,
    model: Result<PlanModel, Vec<Violation>>,
}

impl Plan {
    /// Parse exactly one JSON document. Duplicate keys, invalid UTF-8, lone surrogates, extra documents and any number
    /// that is not a canonical integer are errors. A parsed plan may still be malformed; [`Plan::model`] and [`check`]
    /// report that as violations.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, ParseError> {
        let value = parse::parse(bytes)?;
        let hash = hash::plan_hash(&value);
        let model = shape::validate(&value);
        Ok(Self { value, hash, model })
    }

    /// The parsed document.
    pub fn value(&self) -> &Value {
        &self.value
    }

    /// `lowercase_hex(sha256(jcs(plan without "approval")))`.
    pub fn hash(&self) -> &str {
        &self.hash
    }

    /// The RFC 8785 bytes that were hashed (the plan without `approval`).
    pub fn canonical_bytes(&self) -> Vec<u8> {
        hash::canonical_without_approval(&self.value)
    }

    /// The typed plan, or the shape violations when the document does not match the schema exactly.
    pub fn model(&self) -> Result<&PlanModel, &Vec<Violation>> {
        self.model.as_ref()
    }

    /// Shorthand for [`check`] on this plan.
    pub fn check(&self, mode: Mode) -> Vec<Violation> {
        check::check(self, mode)
    }
}
