// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn login_mode(
    arguments: &[String],
) -> Result<Option<harness_core::provider::ProviderId>, &'static str> {
    if let [mode] = arguments {
        let provider = match mode.as_str() {
            "--provider-login=claude" => Some(harness_core::provider::ProviderId::Claude),
            "--provider-login=codex" => Some(harness_core::provider::ProviderId::Codex),
            _ => None,
        };
        if provider.is_some() {
            return Ok(provider);
        }
    }
    if arguments
        .iter()
        .any(|arg| arg.starts_with("--provider-login"))
    {
        return Err("Sign-in accepts only --provider-login=claude or --provider-login=codex, with no extra arguments.");
    }
    Ok(None)
}

fn main() {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    match login_mode(&arguments) {
        Ok(Some(provider)) => match harness_core::status::login_in_terminal(provider) {
            Ok(code) => std::process::exit(if code < 0 { 1 } else { code }),
            Err(message) => {
                eprintln!("Sign-in could not start: {message}");
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
    use harness_core::provider::ProviderId;

    #[test]
    fn login_modes_are_closed_and_reject_extra_arguments_or_unsupported_providers() {
        assert_eq!(
            login_mode(&["--provider-login=claude".into()]),
            Ok(Some(ProviderId::Claude))
        );
        assert_eq!(
            login_mode(&["--provider-login=codex".into()]),
            Ok(Some(ProviderId::Codex))
        );
        assert_eq!(login_mode(&[]), Ok(None));
        for args in [
            vec!["--provider-login=gemini"],
            vec!["--provider-login=claude", "--tools"],
            vec!["--provider-login=claude; command"],
        ] {
            let args: Vec<_> = args.into_iter().map(String::from).collect();
            assert!(login_mode(&args).is_err());
        }
    }
}
