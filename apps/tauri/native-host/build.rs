// sherpa-onnx is linked as a shared library: its onnxruntime and whisper.cpp
// each bring their own std::regex, and statically they overwrite each other.
// Next to the binary in development, one level up for test binaries, and
// /usr/lib/Escriba/native once installed from the package.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!(
            "cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN:$ORIGIN/..:$ORIGIN/../lib/Escriba/native"
        );
    }
}
