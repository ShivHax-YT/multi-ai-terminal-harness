// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use harness_core::provider::ProviderId;

/// Only a documented human-owned login command can be invoked from an existing terminal.
fn closed_login(arguments: &[String]) -> Result<Option<ProviderId>, &'static str> {
    if let [mode] = arguments {
        let parsed = match mode.as_str() {
            "--provider-login=claude" => Some(ProviderId::Claude),
            "--provider-login=codex" => Some(ProviderId::Codex),
            _ => None,
        };
        if parsed.is_some() {
            return Ok(parsed);
        }
    }
    if arguments
        .iter()
        .any(|arg| arg.starts_with("--provider-login") || arg.starts_with("--provider-session"))
    {
        return Err(
            "Only provider sign-in for claude or codex is available here, with no extra arguments.",
        );
    }
    Ok(None)
}

fn main() {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    match closed_login(&arguments) {
        Ok(Some(provider)) => match harness_core::status::login_in_terminal(provider) {
            Ok(code) if code < 0 => {
                eprintln!("The CLI was stopped (signal {}).", -code);
                std::process::exit(128 - code);
            }
            Ok(code) => std::process::exit(code),
            Err(message) => {
                eprintln!("The CLI could not start: {message}");
                std::process::exit(1);
            }
        },
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
        Ok(None) => {}
    }
    app_lib::run();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn closed_logins_reject_extra_arguments_or_unsupported_providers() {
        assert_eq!(
            closed_login(&["--provider-login=claude".into()]),
            Ok(Some(ProviderId::Claude))
        );
        assert_eq!(
            closed_login(&["--provider-login=codex".into()]),
            Ok(Some(ProviderId::Codex))
        );
        assert_eq!(closed_login(&[]), Ok(None));
        for args in [
            vec!["--provider-login=gemini"],
            vec!["--provider-session=gemini"],
            vec!["--provider-session=claude"],
            vec!["--provider-session=codex"],
            vec!["--provider-login=claude", "--tools"],
            vec!["--provider-session=claude", "--print"],
            vec!["--provider-login=claude; command"],
            vec!["--provider-session=claude; command"],
        ] {
            let args: Vec<_> = args.into_iter().map(String::from).collect();
            assert!(closed_login(&args).is_err());
        }
    }
}
