//! How recipes and project tools are isolated on each system: sandbox-exec on
//! macOS and escriba-sandbox (Landlock and seccomp) on Linux. Where the system
//! cannot isolate them they run plainly and the interface warns about it.

use std::{ffi::OsString, path::Path};

pub enum Profile<'a> {
    /// A recipe: reads its executable and the system libraries, nothing else.
    Worker,
    /// A project tool: also reads `vendor` and reads and writes `project`;
    /// installing dependencies may also connect out.
    Tool {
        project: &'a Path,
        vendor: &'a Path,
        network: bool,
    },
}

/// The program to start and the arguments that go before the executable's own.
pub struct Wrapped {
    pub program: OsString,
    pub arguments: Vec<OsString>,
}

#[cfg(unix)]
fn plain(executable: &Path) -> Wrapped {
    Wrapped {
        program: executable.into(),
        arguments: Vec::new(),
    }
}

/// How the project launcher (`./escriba` in the project folder) isolates each
/// tool: the value of its tool and install profiles and the shell command that
/// runs `"$executable"` with `"$profile"`, `$ROOT` and `$VENDOR`; its own
/// arguments follow.
#[cfg(unix)]
pub struct Launcher {
    pub tool: String,
    pub install: String,
    pub command: String,
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{plain, Launcher, Profile, Wrapped};
    use std::path::Path;

    const WORKER: &str = include_str!("../../runtime-host/sandbox.sb");
    const TOOL: &str = "(version 1)\n(deny default)\n(allow process-exec (literal (param \"EXECUTABLE\")))\n(allow file-read* (literal \"/\") (literal (param \"EXECUTABLE\")) (subpath (param \"PROJECT\")) (subpath (param \"VENDOR\")) (subpath \"/System/Library\") (subpath \"/usr/lib\") (subpath \"/usr/share/icu\"))\n(allow file-read-metadata (literal \"/var\") (literal \"/tmp\"))\n(allow file-write* (subpath (param \"PROJECT\")))\n(allow sysctl-read)\n";
    const INSTALL_NETWORK: &str = "(allow network-outbound)\n";

    pub fn available() -> bool {
        true
    }

    pub fn wrap(executable: &Path, profile: Profile) -> Wrapped {
        if !available() {
            return plain(executable);
        }
        let mut arguments: Vec<std::ffi::OsString> = vec!["-p".into()];
        match profile {
            Profile::Worker => arguments.extend([WORKER.into()]),
            Profile::Tool {
                project,
                vendor,
                network,
            } => {
                let text = if network {
                    format!("{TOOL}{INSTALL_NETWORK}")
                } else {
                    TOOL.to_owned()
                };
                arguments.extend([
                    text.into(),
                    "-D".into(),
                    format!("PROJECT={}", project.display()).into(),
                    "-D".into(),
                    format!("VENDOR={}", vendor.display()).into(),
                ]);
            }
        }
        arguments.extend([
            "-D".into(),
            format!("EXECUTABLE={}", executable.display()).into(),
            executable.into(),
        ]);
        Wrapped {
            program: "/usr/bin/sandbox-exec".into(),
            arguments,
        }
    }

    pub fn launcher() -> Option<Launcher> {
        Some(Launcher {
            tool: TOOL.to_owned(),
            install: format!("{TOOL}{INSTALL_NETWORK}"),
            command: r#"/usr/bin/sandbox-exec -p "$profile" -D "EXECUTABLE=$executable" -D "PROJECT=$ROOT" -D "VENDOR=$VENDOR" "$executable""#.to_owned(),
        })
    }
}
#[cfg(target_os = "macos")]
pub use macos::{available, launcher, wrap};

#[cfg(target_os = "linux")]
mod linux {
    use super::{plain, Launcher, Profile, Wrapped};
    use std::{path::PathBuf, process::Command, sync::OnceLock};

    fn sandbox() -> Option<PathBuf> {
        crate::native::binary("escriba-sandbox").ok()
    }

    /// Asked once: the kernel either has Landlock 4 and seccomp or it does not.
    pub fn available() -> bool {
        static AVAILABLE: OnceLock<bool> = OnceLock::new();
        *AVAILABLE.get_or_init(|| {
            sandbox().is_some_and(|sandbox| {
                Command::new(sandbox)
                    .arg("--check")
                    .output()
                    .is_ok_and(|output| output.status.success())
            })
        })
    }

    pub fn wrap(executable: &std::path::Path, profile: Profile) -> Wrapped {
        let Some(sandbox) = sandbox().filter(|_| available()) else {
            return plain(executable);
        };
        let mut arguments: Vec<std::ffi::OsString> = match profile {
            Profile::Worker => vec!["worker".into()],
            Profile::Tool {
                project,
                vendor,
                network,
            } => vec![
                if network { "install" } else { "tool" }.into(),
                "--project".into(),
                project.into(),
                "--vendor".into(),
                vendor.into(),
            ],
        };
        arguments.extend(["--executable".into(), executable.into(), "--".into()]);
        Wrapped {
            program: sandbox.into(),
            arguments,
        }
    }

    pub fn launcher() -> Option<Launcher> {
        let sandbox = sandbox().filter(|_| available())?;
        let quoted = crate::project::shell_quote(sandbox.to_str()?);
        Some(Launcher {
            tool: "tool".into(),
            install: "install".into(),
            command: format!(
                r#"{quoted} "$profile" --executable "$executable" --project "$ROOT" --vendor "$VENDOR" --"#
            ),
        })
    }
}
#[cfg(target_os = "linux")]
pub use linux::{available, launcher, wrap};

#[cfg(windows)]
mod windows {
    use super::{Profile, Wrapped};
    use std::{
        path::{Path, PathBuf},
        process::Command,
        sync::OnceLock,
    };
    fn sandbox() -> PathBuf {
        crate::native::binary("escriba-sandbox")
            .unwrap_or_else(|_| PathBuf::from("escriba-sandbox.exe"))
    }
    pub fn available() -> bool {
        static AVAILABLE: OnceLock<bool> = OnceLock::new();
        *AVAILABLE.get_or_init(|| {
            use std::os::windows::process::CommandExt;
            Command::new(sandbox())
                .arg("--check")
                .creation_flags(0x08000000)
                .output()
                .is_ok_and(|output| output.status.success())
        })
    }
    pub fn wrap(executable: &Path, profile: Profile) -> Wrapped {
        let mut arguments: Vec<std::ffi::OsString> = match profile {
            Profile::Worker => vec!["worker".into()],
            Profile::Tool {
                project,
                vendor,
                network,
            } => vec![
                if network { "install" } else { "tool" }.into(),
                "--project".into(),
                project.into(),
                "--vendor".into(),
                vendor.into(),
            ],
        };
        arguments.extend(["--executable".into(), executable.into(), "--".into()]);
        Wrapped {
            program: sandbox().into(),
            arguments,
        }
    }
}
#[cfg(windows)]
pub use windows::{available, wrap};
