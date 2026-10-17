//! Speaks protocol v1 (docs/tauri-native-protocol.md) to a native host binary.

#![allow(dead_code)]

use serde_json::{json, Value};
use std::{
    ffi::OsString,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
};

/// `ESCRIBA_NATIVE_HOST` runs the battery against another host, such as the Swift one.
pub fn binary() -> OsString {
    std::env::var_os("ESCRIBA_NATIVE_HOST")
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_EscribaNativeHost").into())
}

pub fn command() -> Command {
    Command::new(binary())
}

pub struct Host {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next: u32,
    pub progress: Vec<f64>,
    _data: Option<tempfile::TempDir>,
}

impl Host {
    pub fn start() -> Self {
        Self::start_with(&[])
    }

    /// Without an explicit XDG_DATA_HOME the host gets a temporary one, so no
    /// test reads or writes the real models folder.
    pub fn start_with(env: &[(&str, &Path)]) -> Self {
        let mut command = command();
        let data = (!env.iter().any(|(key, _)| *key == "XDG_DATA_HOME"))
            .then(|| tempfile::tempdir().unwrap());
        if let Some(data) = &data {
            command.env("XDG_DATA_HOME", data.path());
        }
        #[cfg(windows)]
        if let Some(data) = &data {
            command.env("LOCALAPPDATA", data.path());
        }
        for (key, value) in env {
            #[cfg(windows)]
            if *key == "XDG_DATA_HOME" {
                command.env("LOCALAPPDATA", value);
            }
            command.env(key, value);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        Self {
            child,
            input,
            output,
            next: 0,
            progress: Vec::new(),
            _data: data,
        }
    }

    pub fn line(&mut self, line: &str) -> Value {
        writeln!(self.input, "{line}").unwrap();
        self.input.flush().unwrap();
        self.reply()
    }

    /// The final reply, keeping the progress lines that come before it.
    fn reply(&mut self) -> Value {
        loop {
            let mut line = String::new();
            self.output.read_line(&mut line).unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            match reply.get("progress") {
                Some(progress) => self.progress.push(progress["fraction"].as_f64().unwrap()),
                None => return reply,
            }
        }
    }

    pub fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        let reply = self.line(&json!({"id": id, "method": method, "params": params}).to_string());
        assert_eq!(reply["id"], id.as_str(), "{reply}");
        reply
    }

    pub fn result(&mut self, method: &str, params: Value) -> Value {
        let reply = self.call(method, params);
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"].clone()
    }

    pub fn error(&mut self, method: &str, params: Value) -> Value {
        let reply = self.call(method, params);
        assert!(reply.get("result").is_none(), "{reply}");
        reply["error"].clone()
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

pub fn wait(milliseconds: u64) {
    std::thread::sleep(std::time::Duration::from_millis(milliseconds));
}

pub fn seconds(value: &Value) -> f64 {
    value.as_f64().unwrap()
}

#[cfg(windows)]
pub fn synthesize(folder: &Path, name: &str, second_voice: bool, text: &str) -> PathBuf {
    use std::os::windows::process::CommandExt;
    let raw = folder.join(format!("{name}.pcm"));
    let script = r#"Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.SelectVoice($env:ESCRIBA_TEST_VOICE)
$stream = [System.IO.File]::Create($env:ESCRIBA_TEST_OUTPUT)
$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(22050, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$s.SetOutputToAudioStream($stream, $format)
$s.Speak($env:ESCRIBA_TEST_TEXT)
$s.Dispose()
$stream.Dispose()
"#;
    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .env(
            "ESCRIBA_TEST_VOICE",
            if second_voice {
                "Microsoft Zira Desktop"
            } else {
                "Microsoft Helena Desktop"
            },
        )
        .env("ESCRIBA_TEST_OUTPUT", &raw)
        .env("ESCRIBA_TEST_TEXT", text)
        .creation_flags(0x08000000)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let data = std::fs::read(&raw).unwrap();
    let mut wav = Vec::new();
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&22050u32.to_le_bytes());
    wav.extend_from_slice(&44100u32.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
    wav.extend(data);
    let path = folder.join(format!("{name}.wav"));
    std::fs::write(&path, wav).unwrap();
    path
}
