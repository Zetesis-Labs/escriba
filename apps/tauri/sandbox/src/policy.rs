//! The three profiles, the same as macOS's sandbox-exec ones: a recipe reads its
//! executable and the system libraries; a project tool also reads its vendor
//! folder and reads and writes its project; installing also connects out.

use landlock::{
    path_beneath_rules, Access, AccessFs, AccessNet, CompatLevel, Compatible, Ruleset, RulesetAttr,
    RulesetCreatedAttr, RulesetStatus, Scope, ABI,
};
use seccompiler::{
    BpfProgram, SeccompAction, SeccompCmpArgLen, SeccompCmpOp, SeccompCondition, SeccompFilter,
    SeccompRule, TargetArch,
};
use std::{collections::BTreeMap, path::PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

/// Landlock 4 (Linux 6.7) is the first that also closes TCP.
const MINIMUM_ABI: i64 = 4;

/// What the dynamic loader, libc and Bun read to start: libraries, time zones,
/// memory and CPU settings and randomness. macOS's profile allows the same
/// through `sysctl-read`.
const SYSTEM: [&str; 13] = [
    "/usr/lib",
    "/usr/lib64",
    "/lib",
    "/lib64",
    "/etc/ld.so.cache",
    "/usr/share/zoneinfo",
    "/proc/stat",
    "/proc/sys/vm/overcommit_memory",
    "/proc/sys/vm/mmap_min_addr",
    "/sys/devices/system/cpu",
    "/sys/kernel/mm/transparent_hugepage",
    "/dev/urandom",
    "/dev/random",
];

/// The Landlock ABI of the running kernel, if it is enough and seccomp works.
pub fn available() -> Result<i64, String> {
    let abi = unsafe {
        libc::syscall(
            libc::SYS_landlock_create_ruleset,
            std::ptr::null::<libc::c_void>(),
            0usize,
            1u32,
        )
    };
    let seccomp = unsafe { libc::prctl(libc::PR_GET_SECCOMP) } >= 0;
    enough(abi, seccomp)
}

/// Without Landlock 4 or seccomp recipes run unisolated and the interface warns.
pub fn enough(abi: i64, seccomp: bool) -> Result<i64, String> {
    if abi < MINIMUM_ABI {
        return Err(format!(
            "este equipo no tiene Landlock {MINIMUM_ABI} o posterior (Linux 6.7)"
        ));
    }
    if !seccomp {
        return Err("este equipo no tiene seccomp".into());
    }
    Ok(abi)
}

pub fn confine(request: &Request) -> Result<(), String> {
    landlock(request)?;
    seccomp(request.profile)
}

/// The dynamic loader an ELF executable names (PT_INTERP): the kernel needs to
/// execute it too. Static executables have none.
pub fn interpreter(executable: &std::path::Path) -> Option<PathBuf> {
    let bytes = std::fs::read(executable).ok()?;
    let word = |at: usize, size: usize| -> Option<u64> {
        let slice = bytes.get(at..at + size)?;
        Some(
            slice
                .iter()
                .rev()
                .fold(0, |value, byte| value << 8 | u64::from(*byte)),
        )
    };
    if bytes.get(..4)? != b"\x7fELF" || bytes.get(4)? != &2 || bytes.get(5)? != &1 {
        return None;
    }
    let (table, entry, count) = (word(32, 8)? as usize, word(54, 2)? as usize, word(56, 2)?);
    (0..count as usize).find_map(|index| {
        let header = table + index * entry;
        if word(header, 4)? != 3 {
            return None;
        }
        let (offset, size) = (
            word(header + 8, 8)? as usize,
            word(header + 32, 8)? as usize,
        );
        let raw = bytes.get(offset..offset + size)?;
        let path = std::str::from_utf8(raw.split(|byte| *byte == 0).next()?).ok()?;
        Some(PathBuf::from(path))
    })
}

fn existing(paths: &[&str]) -> Vec<PathBuf> {
    paths
        .iter()
        .map(PathBuf::from)
        .filter(|path| path.exists())
        .collect()
}

fn landlock(request: &Request) -> Result<(), String> {
    let required = ABI::V4;
    let failed = |error: landlock::RulesetError| format!("Landlock: {error}");
    let net = match request.profile {
        Profile::Install => AccessNet::BindTcp.into(),
        _ => AccessNet::from_all(required),
    };
    let mut ruleset = Ruleset::default()
        .set_compatibility(CompatLevel::HardRequirement)
        .handle_access(AccessFs::from_all(required))
        .map_err(failed)?
        .handle_access(net)
        .map_err(failed)?
        .set_compatibility(CompatLevel::BestEffort)
        .scope(Scope::from_all(ABI::V6))
        .map_err(failed)?
        .create()
        .map_err(failed)?
        .add_rules(path_beneath_rules(
            [&request.executable],
            AccessFs::from_read(required),
        ))
        .map_err(failed)?
        .add_rules(path_beneath_rules(
            interpreter(&request.executable).filter(|path| path.exists()),
            AccessFs::Execute | AccessFs::ReadFile,
        ))
        .map_err(failed)?
        .add_rules(path_beneath_rules(
            existing(&SYSTEM),
            AccessFs::ReadFile | AccessFs::ReadDir,
        ))
        .map_err(failed)?
        // Its own /proc entry only: the pid stays the same across exec.
        .add_rules(path_beneath_rules(
            [PathBuf::from(format!("/proc/{}", std::process::id()))],
            AccessFs::from_read(required),
        ))
        .map_err(failed)?
        .add_rules(path_beneath_rules(
            ["/dev/null"],
            AccessFs::ReadFile | AccessFs::WriteFile,
        ))
        .map_err(failed)?;
    if let (Some(project), Some(vendor)) = (&request.project, &request.vendor) {
        ruleset = ruleset
            .add_rules(path_beneath_rules([vendor], AccessFs::from_read(required)))
            .map_err(failed)?
            .add_rules(path_beneath_rules([project], AccessFs::from_all(required)))
            .map_err(failed)?;
    }
    let status = ruleset.restrict_self().map_err(failed)?;
    if status.ruleset == RulesetStatus::NotEnforced || !status.no_new_privs {
        return Err("Landlock no se aplicó".into());
    }
    Ok(())
}

fn arch() -> Result<TargetArch, String> {
    TargetArch::try_from(std::env::consts::ARCH).map_err(|error| format!("seccomp: {error:?}"))
}

fn always(syscalls: &[i64]) -> BTreeMap<i64, Vec<SeccompRule>> {
    syscalls
        .iter()
        .map(|syscall| (*syscall, Vec::new()))
        .collect()
}

fn rule(conditions: Vec<SeccompCondition>) -> Result<SeccompRule, String> {
    SeccompRule::new(conditions).map_err(|error| format!("seccomp: {error:?}"))
}

fn condition(index: u8, operator: SeccompCmpOp, value: u64) -> Result<SeccompCondition, String> {
    SeccompCondition::new(index, SeccompCmpArgLen::Qword, operator, value)
        .map_err(|error| format!("seccomp: {error:?}"))
}

/// Syscalls that would let a recipe leave the sandbox. Reading another
/// process's memory needs ptrace access, which Landlock already refuses
/// outside the sandbox, so Bun may still read its own.
fn denied() -> Vec<i64> {
    let mut syscalls = vec![
        libc::SYS_ptrace,
        libc::SYS_bpf,
        libc::SYS_perf_event_open,
        libc::SYS_mount,
        libc::SYS_umount2,
        libc::SYS_unshare,
        libc::SYS_setns,
        libc::SYS_pivot_root,
        libc::SYS_chroot,
        libc::SYS_keyctl,
        libc::SYS_add_key,
        libc::SYS_request_key,
        libc::SYS_io_uring_setup,
        libc::SYS_io_uring_enter,
        libc::SYS_io_uring_register,
        libc::SYS_userfaultfd,
        libc::SYS_open_by_handle_at,
        libc::SYS_name_to_handle_at,
        libc::SYS_kexec_load,
        libc::SYS_init_module,
        libc::SYS_finit_module,
        libc::SYS_delete_module,
    ];
    #[cfg(target_arch = "x86_64")]
    syscalls.extend([libc::SYS_fork, libc::SYS_vfork]);
    syscalls
}

fn program(rules: BTreeMap<i64, Vec<SeccompRule>>, errno: i32) -> Result<BpfProgram, String> {
    let filter = SeccompFilter::new(
        rules,
        SeccompAction::Allow,
        SeccompAction::Errno(errno as u32),
        arch()?,
    )
    .map_err(|error| format!("seccomp: {error:?}"))?;
    filter
        .try_into()
        .map_err(|error| format!("seccomp: {error:?}"))
}

/// Threads yes, processes no; sockets only to install, and never other families.
fn seccomp(profile: Profile) -> Result<(), String> {
    let mut rules = always(&denied());
    rules.insert(
        libc::SYS_clone,
        vec![rule(vec![condition(
            0,
            SeccompCmpOp::MaskedEq(libc::CLONE_THREAD as u64),
            0,
        )?])?],
    );
    let socket = if profile == Profile::Install {
        let families = [
            libc::AF_UNIX,
            libc::AF_INET,
            libc::AF_INET6,
            libc::AF_NETLINK,
        ];
        let conditions = families
            .iter()
            .map(|family| condition(0, SeccompCmpOp::Ne, *family as u64))
            .collect::<Result<Vec<_>, _>>()?;
        vec![rule(conditions)?]
    } else {
        Vec::new()
    };
    rules.insert(libc::SYS_socket, socket);
    if profile != Profile::Install {
        rules.insert(libc::SYS_socketpair, Vec::new());
    }
    let denied = program(rules, libc::EPERM)?;
    // glibc falls back from clone3 to clone, where the thread check applies.
    let fallback = program(always(&[libc::SYS_clone3]), libc::ENOSYS)?;
    for filter in [&fallback, &denied] {
        seccompiler::apply_filter(filter).map_err(|error| format!("seccomp: {error:?}"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sin_landlock_4_o_sin_seccomp_no_se_aisla() {
        assert_eq!(enough(4, true), Ok(4));
        assert_eq!(enough(7, true), Ok(7));
        assert!(enough(3, true).unwrap_err().contains("Linux 6.7"));
        assert!(enough(-1, true).is_err());
        assert!(enough(6, false).unwrap_err().contains("seccomp"));
    }

    #[test]
    fn el_cargador_dinamico_sale_de_la_cabecera_elf() {
        let own = std::env::current_exe().unwrap();
        let loader = interpreter(&own).unwrap();
        assert!(loader.to_str().unwrap().contains("ld-linux"), "{loader:?}");
        let text = std::env::temp_dir().join("no-es-elf.txt");
        std::fs::write(&text, "hola").unwrap();
        assert_eq!(interpreter(&text), None);
    }
}
