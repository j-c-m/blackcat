use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

fn exe() -> &'static str {
    env!("CARGO_BIN_EXE_blackcat")
}

fn zig_bin() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("BLACKCAT_ZIG") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Some(path);
        }
    }
    let sibling =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../blackcat/zig-out/bin/blackcat");
    if sibling.is_file() {
        Some(sibling)
    } else {
        eprintln!("zig blackcat not found; skipping differential tests");
        None
    }
}

struct Tmp(PathBuf);

impl Tmp {
    fn new() -> Self {
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("blackcat-diff-{}-{}", std::process::id(), n));
        fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn write(&self, name: &str, data: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, data).unwrap();
        path
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn assert_same_stdout(zig: &str, args: &[&str], data_name: &str, data: &[u8]) {
    let tmp = Tmp::new();
    let path = tmp.write(data_name, data);
    let path = path.to_str().unwrap();
    let mut full: Vec<&str> = args.to_vec();
    full.push(path);
    let z = Command::new(zig).args(&full).output().unwrap();
    let r = Command::new(exe()).args(&full).output().unwrap();
    assert!(
        z.status.success() && r.status.success(),
        "zig {:?} rust {:?}\nzig err {}\nrust err {}",
        z.status.code(),
        r.status.code(),
        String::from_utf8_lossy(&z.stderr),
        String::from_utf8_lossy(&r.stderr)
    );
    assert_eq!(
        z.stdout,
        r.stdout,
        "stdout mismatch for {args:?} {data_name}\nzig:\n{}\nrust:\n{}",
        String::from_utf8_lossy(&z.stdout),
        String::from_utf8_lossy(&r.stdout)
    );
}

fn sauce_ans(width: u16, body: &[u8]) -> Vec<u8> {
    let mut out = body.to_vec();
    if !out.contains(&0x1a) {
        out.push(0x1a);
    }
    let mut rec = [b' '; 128];
    rec[0..5].copy_from_slice(b"SAUCE");
    rec[5..7].copy_from_slice(b"00");
    rec[7..11].copy_from_slice(b"Diff");
    rec[96..98].copy_from_slice(&width.to_le_bytes());
    rec[104] = 0;
    out.extend_from_slice(&rec);
    out
}

#[test]
fn cp437_ansi_and_sauce_match_zig() {
    let Some(zig) = zig_bin() else { return };
    let zig = zig.to_str().unwrap();

    assert_same_stdout(zig, &[], "cp437.txt", b"Hi \xdb\r\n");
    assert_same_stdout(zig, &[], "raw.txt", b"\x1b[31mred\n");
    assert_same_stdout(zig, &["-a"], "forced.ans", b"\x1b[1;31mRed\n");
    assert_same_stdout(zig, &["-c"], "forced.bin", b"\x01\xdb");

    let wide = sauce_ans(40, &vec![b'A'; 50]);
    assert_same_stdout(zig, &[], "wide.ans", &wide);

    let narrow_body = b"\x1b[31;44mXYZ\r\n";
    assert_same_stdout(zig, &[], "color.ans", &sauce_ans(20, narrow_body));
}
