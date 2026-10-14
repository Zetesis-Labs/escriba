//! escriba-sandbox: what sandbox-exec is on macOS, for Linux. It confines
//! itself with no_new_privs, Landlock and seccomp and then becomes the program,
//! so recipes and project tools start already isolated.
//!
//! escriba-sandbox --check
//! escriba-sandbox <worker|tool|install> --executable PATH [--project DIR --vendor DIR] -- ARGS...

mod policy;

use std::{os::unix::process::CommandExt, path::PathBuf, process::ExitCode};

fn usage() -> ExitCode {
    eprintln!(
        "uso: escriba-sandbox --check | <worker|tool|install> --executable RUTA [--project CARPETA --vendor CARPETA] -- ARGUMENTOS..."
    );
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--check") {
        return match policy::available() {
            Ok(abi) => {
                println!("landlock {abi}");
                ExitCode::SUCCESS
            }
            Err(reason) => {
                eprintln!("{reason}");
                ExitCode::from(1)
            }
        };
    }
    let Some(request) = parse(&args) else {
        return usage();
    };
    if let Err(reason) = policy::confine(&request) {
        eprintln!("escriba-sandbox: {reason}");
        return ExitCode::from(1);
    }
    let error = std::process::Command::new(&request.executable)
        .args(&request.arguments)
        .exec();
    eprintln!(
        "escriba-sandbox: no se pudo ejecutar {}: {error}",
        request.executable.display()
    );
    ExitCode::from(1)
}

fn parse(args: &[String]) -> Option<policy::Request> {
    let (head, rest) = match args.iter().position(|arg| arg == "--") {
        Some(split) => (&args[..split], args[split + 1..].to_vec()),
        None => (args, Vec::new()),
    };
    let profile = match head.first()?.as_str() {
        "worker" => policy::Profile::Worker,
        "tool" => policy::Profile::Tool,
        "install" => policy::Profile::Install,
        _ => return None,
    };
    let (mut executable, mut project, mut vendor) = (None, None, None);
    let mut options = head[1..].iter();
    while let Some(option) = options.next() {
        let value = PathBuf::from(options.next()?);
        match option.as_str() {
            "--executable" => executable = Some(value),
            "--project" => project = Some(value),
            "--vendor" => vendor = Some(value),
            _ => return None,
        }
    }
    let request = policy::Request {
        profile,
        executable: executable?,
        project,
        vendor,
        arguments: rest,
    };
    let tool = profile != policy::Profile::Worker;
    (tool == (request.project.is_some() && request.vendor.is_some())).then_some(request)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(line: &str) -> Vec<String> {
        line.split(' ').map(str::to_owned).collect()
    }

    #[test]
    fn una_receta_solo_lleva_su_ejecutable_y_una_herramienta_su_proyecto() {
        let worker = parse(&args("worker --executable /opt/run -- --worker")).unwrap();
        assert_eq!(worker.profile, policy::Profile::Worker);
        assert_eq!(worker.arguments, ["--worker"]);
        assert!(parse(&args(
            "worker --executable /opt/run --project /p --vendor /v"
        ))
        .is_none());
        let tool = parse(&args(
            "install --executable /opt/run --project /p --vendor /v -- install",
        ))
        .unwrap();
        assert_eq!(tool.profile, policy::Profile::Install);
        assert_eq!(tool.project, Some(PathBuf::from("/p")));
        assert!(parse(&args("tool --executable /opt/run")).is_none());
        assert!(parse(&args("otro --executable /opt/run")).is_none());
        assert!(parse(&args("worker --executable")).is_none());
    }
}
