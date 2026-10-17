use sha2::{Digest, Sha256};
use std::{
    ffi::{c_void, OsStr},
    mem::{size_of, zeroed},
    os::windows::ffi::OsStrExt,
    path::{Path, PathBuf},
    ptr,
};
use windows_sys::Win32::{
    Foundation::{
        CloseHandle, LocalFree, SetHandleInformation, HANDLE, HANDLE_FLAG_INHERIT,
        INVALID_HANDLE_VALUE,
    },
    Security::{Authorization::*, Isolation::*, *},
    Storage::FileSystem::{DELETE, FILE_GENERIC_EXECUTE, FILE_GENERIC_READ, FILE_GENERIC_WRITE},
    System::{
        Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE},
        JobObjects::*,
        Threading::*,
    },
};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Profile {
    Worker,
    Tool,
    Install,
}
pub struct Request {
    pub profile: Profile,
    pub executable: PathBuf,
    pub project: Option<PathBuf>,
    pub vendor: Option<PathBuf>,
    pub arguments: Vec<String>,
}

fn wide(text: impl AsRef<OsStr>) -> Vec<u16> {
    text.as_ref().encode_wide().chain(Some(0)).collect()
}
fn error() -> String {
    std::io::Error::last_os_error().to_string()
}
fn checked(code: u32) -> Result<(), String> {
    if code == 0 {
        Ok(())
    } else {
        Err(std::io::Error::from_raw_os_error(code as i32).to_string())
    }
}
struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
struct Sid(PSID);
impl Drop for Sid {
    fn drop(&mut self) {
        unsafe {
            FreeSid(self.0);
        }
    }
}

fn profile(name: &str) -> Result<Sid, String> {
    let name = wide(name);
    let mut sid = ptr::null_mut();
    unsafe {
        let result = CreateAppContainerProfile(
            name.as_ptr(),
            name.as_ptr(),
            name.as_ptr(),
            ptr::null(),
            0,
            &mut sid,
        );
        if result < 0 && DeriveAppContainerSidFromAppContainerName(name.as_ptr(), &mut sid) < 0 {
            return Err(format!("No se pudo crear AppContainer: {result:#x}"));
        }
    }
    Ok(Sid(sid))
}

pub fn available() -> Result<(), String> {
    profile("dev.zetesis.escriba.worker").map(|_| ())
}

fn grant(path: &Path, sid: PSID, write: bool) -> Result<(), String> {
    let name = wide(path);
    unsafe {
        let (mut old, mut descriptor) = (ptr::null_mut(), ptr::null_mut());
        checked(GetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            ptr::null_mut(),
            ptr::null_mut(),
            &mut old,
            ptr::null_mut(),
            &mut descriptor,
        ))?;
        let access = EXPLICIT_ACCESS_W {
            grfAccessPermissions: FILE_GENERIC_READ
                | FILE_GENERIC_EXECUTE
                | if write {
                    FILE_GENERIC_WRITE | DELETE
                } else {
                    0
                },
            grfAccessMode: GRANT_ACCESS,
            grfInheritance: if path.is_dir() {
                SUB_CONTAINERS_AND_OBJECTS_INHERIT
            } else {
                0
            },
            Trustee: TRUSTEE_W {
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_UNKNOWN,
                ptstrName: sid.cast(),
                ..zeroed()
            },
        };
        let mut acl = ptr::null_mut();
        let result = checked(SetEntriesInAclW(1, &access, old, &mut acl)).and_then(|_| {
            checked(SetNamedSecurityInfoW(
                name.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                ptr::null_mut(),
                ptr::null_mut(),
                acl,
                ptr::null(),
            ))
        });
        if !acl.is_null() {
            LocalFree(acl.cast());
        }
        LocalFree(descriptor);
        result
    }
}

fn quoted(value: &OsStr) -> String {
    let mut out = String::from("\"");
    let mut slashes = 0;
    for ch in value.to_string_lossy().chars() {
        if ch == '\\' {
            slashes += 1;
            continue;
        }
        out.extend(std::iter::repeat_n(
            '\\',
            if ch == '"' { slashes * 2 + 1 } else { slashes },
        ));
        slashes = 0;
        out.push(ch);
    }
    out.extend(std::iter::repeat_n('\\', slashes * 2));
    out.push('"');
    out
}

fn working_directory(path: &Path) -> PathBuf {
    match path.to_str() {
        Some(value) if value.starts_with(r"\\?\UNC\") => {
            PathBuf::from(format!(r"\\{}", &value[8..]))
        }
        Some(value) if value.starts_with(r"\\?\") => PathBuf::from(&value[4..]),
        _ => path.to_path_buf(),
    }
}

struct Attributes {
    _buffer: Vec<usize>,
    pointer: LPPROC_THREAD_ATTRIBUTE_LIST,
}
impl Attributes {
    fn new(count: u32) -> Result<Self, String> {
        let mut bytes = 0;
        unsafe {
            InitializeProcThreadAttributeList(ptr::null_mut(), count, 0, &mut bytes);
        }
        let mut buffer = vec![0usize; bytes.div_ceil(size_of::<usize>())];
        let pointer = buffer.as_mut_ptr().cast();
        if unsafe { InitializeProcThreadAttributeList(pointer, count, 0, &mut bytes) } == 0 {
            return Err(error());
        }
        Ok(Self {
            _buffer: buffer,
            pointer,
        })
    }
    fn set<T>(&self, key: u32, value: &T) -> Result<(), String> {
        if unsafe {
            UpdateProcThreadAttribute(
                self.pointer,
                0,
                key as usize,
                ptr::from_ref(value).cast::<c_void>(),
                size_of::<T>(),
                ptr::null_mut(),
                ptr::null(),
            )
        } == 0
        {
            Err(error())
        } else {
            Ok(())
        }
    }
}
impl Drop for Attributes {
    fn drop(&mut self) {
        unsafe {
            DeleteProcThreadAttributeList(self.pointer);
        }
    }
}

pub fn run(request: &Request) -> Result<u32, String> {
    let executable = request
        .executable
        .canonicalize()
        .map_err(|e| e.to_string())?;
    let project = request
        .project
        .as_ref()
        .map(|p| p.canonicalize())
        .transpose()
        .map_err(|e| e.to_string())?;
    let vendor = request
        .vendor
        .as_ref()
        .map(|p| p.canonicalize())
        .transpose()
        .map_err(|e| e.to_string())?;
    if !executable.is_file() {
        return Err("Ejecutable inválido".into());
    }
    let name = match &project {
        None => "dev.zetesis.escriba.worker".to_owned(),
        Some(path) => format!(
            "dev.zetesis.escriba.{:?}.{}",
            request.profile,
            &format!("{:x}", Sha256::digest(path.to_string_lossy().as_bytes()))[..32]
        ),
    };
    let sid = profile(&name)?;
    grant(&executable, sid.0, false)?;
    if let Some(path) = &project {
        grant(path, sid.0, true)?;
    }
    if let Some(path) = &vendor {
        grant(path, sid.0, false)?;
    }
    let mut internet = [0u8; SECURITY_MAX_SID_SIZE as usize];
    let mut size = internet.len() as u32;
    let mut capability = SID_AND_ATTRIBUTES {
        Sid: internet.as_mut_ptr().cast(),
        Attributes: 0x00000004,
    };
    if request.profile == Profile::Install
        && unsafe {
            CreateWellKnownSid(
                WinCapabilityInternetClientSid,
                ptr::null_mut(),
                capability.Sid,
                &mut size,
            )
        } == 0
    {
        return Err(error());
    }
    let security = SECURITY_CAPABILITIES {
        AppContainerSid: sid.0,
        Capabilities: if request.profile == Profile::Install {
            &mut capability
        } else {
            ptr::null_mut()
        },
        CapabilityCount: u32::from(request.profile == Profile::Install),
        Reserved: 0,
    };
    let attributes = Attributes::new(2)?;
    attributes.set(PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &security)?;
    let handles = unsafe {
        [
            GetStdHandle(STD_INPUT_HANDLE),
            GetStdHandle(STD_OUTPUT_HANDLE),
            GetStdHandle(STD_ERROR_HANDLE),
        ]
    };
    if handles
        .iter()
        .any(|h| h.is_null() || *h == INVALID_HANDLE_VALUE)
    {
        return Err("Faltan los canales del proceso aislado".into());
    }
    for handle in handles {
        if unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) } == 0 {
            return Err(error());
        }
    }
    attributes.set(PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &handles)?;
    let job = Handle(unsafe { CreateJobObjectW(ptr::null(), ptr::null()) });
    if job.0.is_null() {
        return Err(error());
    }
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { zeroed() };
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        | JOB_OBJECT_LIMIT_ACTIVE_PROCESS
        | JOB_OBJECT_LIMIT_PROCESS_MEMORY;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    limits.ProcessMemoryLimit = if request.profile == Profile::Worker {
        512
    } else {
        2048
    } * 1024
        * 1024;
    if unsafe {
        SetInformationJobObject(
            job.0,
            JobObjectExtendedLimitInformation,
            ptr::from_ref(&limits).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    } == 0
    {
        return Err(error());
    }
    let mut startup: STARTUPINFOEXW = unsafe { zeroed() };
    startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = handles[0];
    startup.StartupInfo.hStdOutput = handles[1];
    startup.StartupInfo.hStdError = handles[2];
    startup.lpAttributeList = attributes.pointer;
    let mut line = quoted(executable.as_os_str());
    for argument in &request.arguments {
        line.push(' ');
        line.push_str(&quoted(OsStr::new(argument)));
    }
    let mut line = wide(line);
    let cwd = wide(working_directory(
        project
            .as_deref()
            .unwrap_or_else(|| Path::new("C:\\Windows\\System32")),
    ));
    let mut info: PROCESS_INFORMATION = unsafe { zeroed() };
    if unsafe {
        CreateProcessW(
            wide(&executable).as_ptr(),
            line.as_mut_ptr(),
            ptr::null(),
            ptr::null(),
            1,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW,
            ptr::null(),
            cwd.as_ptr(),
            &startup.StartupInfo,
            &mut info,
        )
    } == 0
    {
        return Err(error());
    }
    let process = Handle(info.hProcess);
    let thread = Handle(info.hThread);
    if unsafe { AssignProcessToJobObject(job.0, process.0) } == 0 {
        unsafe {
            TerminateProcess(process.0, 1);
        }
        return Err(error());
    }
    if unsafe { ResumeThread(thread.0) } == u32::MAX {
        return Err(error());
    }
    unsafe {
        WaitForSingleObject(process.0, INFINITE);
    }
    let mut code = 1;
    if unsafe { GetExitCodeProcess(process.0, &mut code) } == 0 {
        return Err(error());
    }
    Ok(code)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn comillas_y_barras_no_cambian_los_argumentos() {
        assert_eq!(quoted(OsStr::new("a b")), "\"a b\"");
        assert_eq!(quoted(OsStr::new("a\"b\\")), "\"a\\\"b\\\\\"");
    }

    #[test]
    fn el_directorio_de_trabajo_es_compatible_con_herramientas_nativas() {
        assert_eq!(
            working_directory(Path::new(r"\\?\C:\proyecto ñ")),
            Path::new(r"C:\proyecto ñ")
        );
        assert_eq!(
            working_directory(Path::new(r"\\?\UNC\equipo\proyecto")),
            Path::new(r"\\equipo\proyecto")
        );
    }
}
