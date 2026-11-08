//! The plan's value type and the typed model built from a shape-valid plan.
//!
//! [`Value`] is deliberately smaller than JSON: its only number is a canonical unsigned integer up to 2^53-1, so a
//! float, a negative number or an exponent cannot even be represented (the parser refuses them). Objects keep their
//! parse order and are guaranteed to have unique keys.

use crate::provider::ProviderId;

/// Largest integer a double holds exactly (2^53-1). Plans never contain a larger number.
pub const MAX_SAFE_INT: u64 = 9_007_199_254_740_991;

/// One parsed JSON value of the plan subset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Null,
    Bool(bool),
    /// A canonical integer: `0` or `[1-9][0-9]*`, at most [`MAX_SAFE_INT`].
    Int(u64),
    String(String),
    Array(Vec<Value>),
    /// Entries in document order. Keys are unique (the parser rejects duplicates).
    Object(Vec<(String, Value)>),
}

impl Value {
    /// The entry for `key` when this is an object.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Self::Object(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_int(&self) -> Option<u64> {
        match self {
            Self::Int(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Self::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_object(&self) -> Option<&[(String, Value)]> {
        match self {
            Self::Object(entries) => Some(entries),
            _ => None,
        }
    }
}

/// `subscription` or `api_key`, exactly (no case folding).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AuthMode {
    Subscription,
    ApiKey,
}

impl AuthMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Subscription => "subscription",
            Self::ApiKey => "api_key",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "subscription" => Some(Self::Subscription),
            "api_key" => Some(Self::ApiKey),
            _ => None,
        }
    }
}

/// A provider with the auth mode a session would use (the plan's `lead` and each fallback entry).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderChoice {
    pub provider: ProviderId,
    pub auth_mode: AuthMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EstimatedUsage {
    pub prompts: u32,
    pub turns: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Task {
    pub id: String,
    pub title: String,
    pub role: String,
    pub provider: ProviderId,
    pub auth_mode: AuthMode,
    pub owned_files: Vec<String>,
    pub acceptance: Vec<String>,
    pub depends_on: Vec<String>,
    pub estimated_usage: EstimatedUsage,
    pub fallback_providers: Vec<ProviderChoice>,
}

/// The approval object as written in the plan. Only its presence and shape are validated here; binding it to the hash
/// and the signature are T-117's job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Approval {
    pub plan_hash: String,
    pub approved_at: String,
    pub approved_via: String,
    pub nonce: String,
}

/// A plan whose shape passed validation. Nothing was defaulted: every field was present in the document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanModel {
    pub format_version: u32,
    pub plan_id: String,
    pub created_at: String,
    pub lead: ProviderChoice,
    pub request_summary: String,
    pub summary_budget_tokens: u32,
    pub tasks: Vec<Task>,
    pub approval: Option<Approval>,
}
