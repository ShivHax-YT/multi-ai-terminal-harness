//! A deterministic sample-project workflow. No provider adapter or PTY is reachable from here.
use std::sync::Mutex;

use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::worktree::{run_sample, SampleResult};

#[derive(Clone, Debug, Serialize)]
pub struct SimPlan {
    pub id: String,
    pub project_id: String,
    pub task: String,
    pub hash: String,
    pub status: String,
    pub result: Option<SampleResult>,
    pub error: Option<String>,
}

struct Record {
    plan: SimPlan,
    token: Option<String>,
}

#[derive(Default)]
pub struct Simulation {
    records: Mutex<Vec<Record>>,
}

impl Simulation {
    pub fn snapshot(&self) -> Result<Vec<SimPlan>, String> {
        Ok(self
            .records
            .lock()
            .map_err(|_| "Simulation state unavailable")?
            .iter()
            .map(|r| r.plan.clone())
            .collect())
    }

    pub fn submit(&self, project_id: &str, task: &str) -> Result<SimPlan, String> {
        if project_id != "sample" || task.trim().is_empty() || task.len() > 4000 {
            return Err("Select the sample project and enter a task of 1–4000 bytes".into());
        }
        let mut records = self
            .records
            .lock()
            .map_err(|_| "Simulation state unavailable")?;
        if records.len() >= 50 {
            return Err("Simulation limit reached; restart the app for a new demo session".into());
        }
        let id = format!("sim-{}", records.len() + 1);
        // Bind approval to scope, project, task and worker identity, not just the displayed task.
        let scope = (
            "sample-workflow-v1",
            &id,
            project_id,
            task,
            "simulated",
            "README.md",
        );
        let hash = hex::encode(Sha256::digest(
            serde_json::to_vec(&scope).map_err(|_| "Invalid plan")?,
        ));
        let plan = SimPlan {
            id,
            project_id: project_id.into(),
            task: task.into(),
            hash,
            status: "pending".into(),
            result: None,
            error: None,
        };
        records.push(Record {
            plan: plan.clone(),
            token: None,
        });
        Ok(plan)
    }

    /// Called only through the UI approval port; never by the worker or plan generator.
    pub fn approve(&self, id: &str, hash: &str) -> Result<String, String> {
        let mut records = self
            .records
            .lock()
            .map_err(|_| "Simulation state unavailable")?;
        let r = records
            .iter_mut()
            .find(|r| r.plan.id == id)
            .ok_or("Plan not found")?;
        if r.plan.hash != hash || r.plan.status != "pending" {
            return Err("Plan changed or is no longer awaiting approval".into());
        }
        let mut bytes = [0; 32];
        getrandom::fill(&mut bytes).map_err(|_| "Approval randomness unavailable")?;
        let token = hex::encode(bytes);
        r.token = Some(token.clone());
        r.plan.status = "approved".into();
        Ok(token)
    }

    pub fn run(&self, id: &str, hash: &str, token: &str) -> Result<SimPlan, String> {
        let task = {
            let mut records = self
                .records
                .lock()
                .map_err(|_| "Simulation state unavailable")?;
            let r = records
                .iter_mut()
                .find(|r| r.plan.id == id)
                .ok_or("Plan not found")?;
            if r.plan.status != "approved"
                || r.plan.hash != hash
                || r.token.as_deref() != Some(token)
            {
                return Err("A matching, unused UI approval is required".into());
            }
            r.token = None; // Consume before any filesystem or child-process work. Retries cannot dispatch twice.
            r.plan.status = "running".into();
            r.plan.task.clone()
        };
        let outcome = run_sample(&task);
        let mut records = self
            .records
            .lock()
            .map_err(|_| "Simulation state unavailable")?;
        let r = records
            .iter_mut()
            .find(|r| r.plan.id == id)
            .ok_or("Plan not found")?;
        match outcome {
            Ok(result) => {
                r.plan.result = Some(result);
                r.plan.status = "completed".into();
            }
            Err(error) => {
                r.plan.status = "failed".into();
                r.plan.error = Some(error);
            }
        }
        Ok(r.plan.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn approval_is_bound_to_scope_hash_and_is_single_use() {
        let sim = Simulation::default();
        assert!(sim.submit("arbitrary-project", "task").is_err());
        assert!(sim.submit("sample", " ").is_err());
        assert!(sim.submit("sample", &"x".repeat(4001)).is_err());
        let p = sim.submit("sample", "Write a sample result").unwrap();
        assert!(sim.run(&p.id, &p.hash, "forged").is_err());
        assert!(sim.approve(&p.id, "edited-hash").is_err());
        let token = sim.approve(&p.id, &p.hash).unwrap();
        assert!(sim.run(&p.id, "edited-hash", &token).is_err());
        assert!(sim.run(&p.id, &p.hash, "forged").is_err());
        let other = sim.submit("sample", "Another task").unwrap();
        assert!(sim.run(&other.id, &other.hash, &token).is_err());
        let done = sim.run(&p.id, &p.hash, &token).unwrap();
        assert_eq!(done.status, "failed");
        assert!(done.result.is_none());
        assert!(done
            .error
            .unwrap()
            .contains("No files were changed and no worker was started"));
        assert!(sim.run(&p.id, &p.hash, &token).is_err());
        assert!(sim.approve(&p.id, &p.hash).is_err());
        assert!(!serde_json::to_string(&sim.snapshot().unwrap())
            .unwrap()
            .contains(&token));
    }
}
