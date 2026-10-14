use std::io::{BufRead, Write};

fn main() {
    let mut host = escriba_native_host::Host::default();
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else {
            break;
        };
        let reply = host.handle_with_progress(&line, &mut |progress| {
            let _ = writeln!(stdout, "{progress}").and_then(|()| stdout.flush());
        });
        if writeln!(stdout, "{reply}")
            .and_then(|()| stdout.flush())
            .is_err()
        {
            eprintln!("EscribaNativeHost: protocol output failed");
            std::process::exit(1);
        }
    }
}
