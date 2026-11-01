// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use harness_core::provider::ProviderId;

/// The closed command-line modes. Each runs one official CLI for the human on the current terminal.
#[derive(Debug, PartialEq, Eq)]
enum Mode {
    Login(ProviderId),
    Session(ProviderId),
}

fn closed_mode(arguments: &[String]) -> Result<Option<Mode>, &'static str> {
    if let [mode] = arguments {
        let parsed = match mode.as_str() {
            "--provider-login=claude" => Some(Mode::Login(ProviderId::Claude)),
            "--provider-login=codex" => Some(Mode::Login(ProviderId::Codex)),
            "--provider-session=claude" => Some(Mode::Session(ProviderId::Claude)),
            "--provider-session=codex" => Some(Mode::Session(ProviderId::Codex)),
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
        return Err("Sign-in and sessions accept only claude or codex, with no extra arguments.");
    }
    Ok(None)
}

fn run_session(provider: ProviderId) -> Result<i32, String> {
    let cwd = std::env::current_dir().map_err(|_| "the folder is unavailable".to_owned())?;
    let code = harness_core::status::session_in_terminal(provider, &cwd)?;
    if code < 0 {
        // Killed by a signal. macOS kills an image that fails the launch requirement this way.
        eprintln!("The CLI was stopped (signal {}). macOS stops a CLI that fails its vendor identity check.", -code);
    }
    Ok(code)
}

fn main() {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    match closed_mode(&arguments) {
        Ok(Some(mode)) => {
            let result = match mode {
                Mode::Login(provider) => harness_core::status::login_in_terminal(provider),
                Mode::Session(provider) => run_session(provider),
            };
            match result {
                Ok(code) => std::process::exit(if code < 0 { 1 } else { code }),
                Err(message) => {
                    eprintln!("The CLI could not start: {message}");
                    std::process::exit(1);
                }
            }
        }
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
    fn closed_modes_reject_extra_arguments_or_unsupported_providers() {
        assert_eq!(
            closed_mode(&["--provider-login=claude".into()]),
            Ok(Some(Mode::Login(ProviderId::Claude)))
        );
        assert_eq!(
            closed_mode(&["--provider-login=codex".into()]),
            Ok(Some(Mode::Login(ProviderId::Codex)))
        );
        assert_eq!(
            closed_mode(&["--provider-session=claude".into()]),
            Ok(Some(Mode::Session(ProviderId::Claude)))
        );
        assert_eq!(
            closed_mode(&["--provider-session=codex".into()]),
            Ok(Some(Mode::Session(ProviderId::Codex)))
        );
        assert_eq!(closed_mode(&[]), Ok(None));
        for args in [
            vec!["--provider-login=gemini"],
            vec!["--provider-session=gemini"],
            vec!["--provider-login=claude", "--tools"],
            vec!["--provider-session=claude", "--print"],
            vec!["--provider-login=claude; command"],
            vec!["--provider-session=claude; command"],
        ] {
            let args: Vec<_> = args.into_iter().map(String::from).collect();
            assert!(closed_mode(&args).is_err());
        }
    }
}
