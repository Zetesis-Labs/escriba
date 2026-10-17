use windows_sys::Win32::{
    Foundation::{CloseHandle, FILETIME},
    System::{
        ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS},
        Threading::{
            GetProcessTimes, OpenProcess, TerminateProcess, PROCESS_QUERY_INFORMATION,
            PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE, PROCESS_VM_READ,
        },
    },
};

pub fn resident_bytes(pid: i32) -> Option<u64> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, 0, pid as u32);
        if process.is_null() {
            return None;
        }
        let mut counters: PROCESS_MEMORY_COUNTERS = std::mem::zeroed();
        let ok = GetProcessMemoryInfo(
            process,
            &mut counters,
            std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32,
        );
        CloseHandle(process);
        (ok != 0).then_some(counters.WorkingSetSize as u64)
    }
}

pub fn process_identity(pid: i32) -> Option<(u64, u64)> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32);
        if process.is_null() {
            return None;
        }
        let mut times = [FILETIME::default(); 4];
        let ok = GetProcessTimes(
            process,
            &mut times[0],
            &mut times[1],
            &mut times[2],
            &mut times[3],
        );
        CloseHandle(process);
        (ok != 0).then_some((
            times[0].dwHighDateTime as u64,
            times[0].dwLowDateTime as u64,
        ))
    }
}

pub fn still_forking(_: i32) -> bool {
    false
}

pub fn terminate(pid: u32) {
    unsafe {
        let process = OpenProcess(PROCESS_TERMINATE, 0, pid);
        if !process.is_null() {
            TerminateProcess(process, 1);
            CloseHandle(process);
        }
    }
}
