use std::{
    ffi::OsStr,
    path::{Path, PathBuf},
    process::ExitStatus,
};

pub struct DesktopCommand {
    target: std::ffi::OsString,
    arguments: Option<std::ffi::OsString>,
    problem: Option<&'static str>,
}

impl DesktopCommand {
    pub fn status(&mut self) -> std::io::Result<ExitStatus> {
        if let Some(problem) = self.problem {
            return Err(std::io::Error::other(problem));
        }
        use std::{
            os::windows::{ffi::OsStrExt, process::ExitStatusExt},
            ptr,
        };
        use windows_sys::Win32::UI::{
            Shell::{ShellExecuteExW, SEE_MASK_FLAG_NO_UI, SHELLEXECUTEINFOW},
            WindowsAndMessaging::SW_SHOWNORMAL,
        };
        let target: Vec<u16> = self.target.encode_wide().chain(Some(0)).collect();
        let arguments: Option<Vec<u16>> = self
            .arguments
            .as_ref()
            .map(|value| value.encode_wide().chain(Some(0)).collect());
        let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
        info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
        info.fMask = SEE_MASK_FLAG_NO_UI;
        info.lpFile = target.as_ptr();
        info.lpParameters = arguments
            .as_ref()
            .map_or(ptr::null(), |value| value.as_ptr());
        info.nShow = SW_SHOWNORMAL;
        if unsafe { ShellExecuteExW(&mut info) } == 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(ExitStatus::from_raw(0))
        }
    }
}

pub fn models_root() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .map(|path| path.join("escriba/models"))
}

pub fn native_library_path(path: &Path) -> PathBuf {
    dunce::simplified(path).to_path_buf()
}

pub fn is_models_root(root: &Path) -> bool {
    models_root().is_some_and(|expected| expected == root)
}

pub fn open(target: &OsStr) -> DesktopCommand {
    DesktopCommand {
        target: target.to_owned(),
        arguments: None,
        problem: None,
    }
}

pub fn reveal(path: &Path) -> DesktopCommand {
    DesktopCommand {
        target: "explorer.exe".into(),
        arguments: Some(format!("/select,\"{}\"", path.display()).into()),
        problem: None,
    }
}

pub fn open_vscode(path: &Path) -> DesktopCommand {
    match url::Url::from_file_path(path) {
        Ok(uri) => open(OsStr::new(&format!("vscode://file{}", uri.path()))),
        Err(()) => DesktopCommand {
            target: path.into(),
            arguments: None,
            problem: Some("Ruta del proyecto inválida"),
        },
    }
}

pub fn privacy_settings(pane: Option<&str>) -> Result<DesktopCommand, String> {
    Ok(open(OsStr::new(match pane {
        Some("microphone") => "ms-settings:privacy-microphone",
        _ => "ms-settings:privacy",
    })))
}

pub fn folder_authorization() -> bool {
    false
}
pub fn file_flags(_: &std::fs::Metadata) -> u32 {
    0
}
pub const REVEAL_FAILED: &str = "No se pudo abrir el Explorador de archivos";
pub const RECORDING_EXTENSION: &str = "ogg";
