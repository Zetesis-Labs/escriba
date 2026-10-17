//! Memory and identity of a running process, read the way each system offers them.
#[cfg(windows)]
pub use crate::process_windows::{process_identity, resident_bytes, still_forking};

#[cfg(target_os = "macos")]
mod macos {
    pub fn resident_bytes(pid: i32) -> Option<u64> {
        let mut info = std::mem::MaybeUninit::<libc::proc_taskinfo>::uninit();
        let size = std::mem::size_of::<libc::proc_taskinfo>();
        let returned = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTASKINFO,
                0,
                info.as_mut_ptr().cast(),
                size as i32,
            )
        };
        if returned == size as i32 {
            Some(unsafe { info.assume_init().pti_resident_size })
        } else {
            None
        }
    }
    pub fn process_identity(pid: i32) -> Option<(u64, u64)> {
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
        let size = std::mem::size_of::<libc::proc_bsdinfo>();
        let returned = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                info.as_mut_ptr().cast(),
                size as i32,
            )
        };
        if returned == size as i32 {
            let info = unsafe { info.assume_init() };
            Some((info.pbi_start_tvsec, info.pbi_start_tvusec))
        } else {
            None
        }
    }

    pub fn still_forking(_: i32) -> bool {
        false
    }
}
#[cfg(target_os = "macos")]
pub use macos::{process_identity, resident_bytes, still_forking};

#[cfg(target_os = "linux")]
mod linux {
    pub fn resident_bytes(pid: i32) -> Option<u64> {
        let statm = std::fs::read_to_string(format!("/proc/{pid}/statm")).ok()?;
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        super::statm_resident_bytes(&statm, u64::try_from(page).ok()?)
    }
    pub fn process_identity(pid: i32) -> Option<(u64, u64)> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        super::stat_start_ticks(&stat).map(|ticks| (ticks, 0))
    }
    // Between fork and exec Linux shows a copy of this process, with its memory.
    pub fn still_forking(pid: i32) -> bool {
        match (
            std::fs::read_link(format!("/proc/{pid}/exe")),
            std::env::current_exe(),
        ) {
            (Ok(child), Ok(own)) => child == own,
            _ => false,
        }
    }
}
#[cfg(target_os = "linux")]
pub use linux::{process_identity, resident_bytes, still_forking};

#[cfg(any(target_os = "linux", test))]
fn statm_resident_bytes(statm: &str, page: u64) -> Option<u64> {
    let pages: u64 = statm.split_whitespace().nth(1)?.parse().ok()?;
    pages.checked_mul(page)
}
// The command name in field 2 may contain spaces and parentheses.
#[cfg(any(target_os = "linux", test))]
fn stat_start_ticks(stat: &str) -> Option<u64> {
    let (_, fields) = stat.rsplit_once(") ")?;
    fields.split_whitespace().nth(19)?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memoria_residente_sale_de_la_segunda_columna_de_statm() {
        assert_eq!(
            statm_resident_bytes("5000 1200 300 10 0 900 0\n", 4096),
            Some(1200 * 4096)
        );
        assert_eq!(statm_resident_bytes("5000\n", 4096), None);
        assert_eq!(statm_resident_bytes("", 4096), None);
    }

    #[test]
    fn inicio_del_proceso_ignora_parentesis_en_el_nombre() {
        let stat = "4242 (bun (worker) x) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 4 0 987654 1000 300";
        assert_eq!(stat_start_ticks(stat), Some(987654));
        assert_eq!(stat_start_ticks("4242 (bun) S 1"), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn en_linux_el_propio_proceso_tiene_memoria_e_identidad_estable() {
        let pid = std::process::id() as i32;
        assert!(resident_bytes(pid).is_some_and(|bytes| bytes > 0));
        let identity = process_identity(pid).unwrap();
        assert_eq!(process_identity(pid), Some(identity));
        assert_eq!(resident_bytes(i32::MAX), None);
        assert_eq!(process_identity(i32::MAX), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn en_linux_no_se_mide_la_memoria_de_una_copia_previa_al_exec() {
        assert!(still_forking(std::process::id() as i32));
        let mut other = std::process::Command::new("sleep")
            .arg("5")
            .spawn()
            .unwrap();
        while std::fs::read_link(format!("/proc/{}/exe", other.id())).ok()
            == std::env::current_exe().ok()
        {
            std::thread::yield_now();
        }
        assert!(!still_forking(other.id() as i32));
        other.kill().unwrap();
        other.wait().unwrap();
        assert!(!still_forking(i32::MAX));
    }
}
