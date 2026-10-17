use std::{
    fs,
    net::{SocketAddr, TcpStream},
    path::Path,
    process::Command,
    time::Duration,
};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).is_some_and(|arg| arg == "noop") {
        return;
    }
    let [_, secret, output, vendor, address] = args.as_slice() else {
        std::process::exit(2);
    };
    println!("read={}", fs::read(secret).is_ok());
    println!("write={}", fs::write(output, "synthetic").is_ok());
    println!(
        "vendor={}",
        fs::read(Path::new(vendor).join("package.txt")).is_ok()
    );
    println!(
        "vendor_write={}",
        fs::write(Path::new(vendor).join("new.txt"), "synthetic").is_ok()
    );
    let address: SocketAddr = address.parse().unwrap();
    println!(
        "network={}",
        TcpStream::connect_timeout(&address, Duration::from_secs(2)).is_ok()
    );
    println!(
        "spawn={}",
        Command::new(std::env::current_exe().unwrap())
            .arg("noop")
            .status()
            .is_ok_and(|status| status.success())
    );
}
