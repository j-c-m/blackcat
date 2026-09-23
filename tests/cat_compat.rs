use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

struct Run {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn exe() -> &'static str {
    env!("CARGO_BIN_EXE_blackcat")
}

fn gnu_cat() -> Option<&'static str> {
    static FOUND: OnceLock<Option<String>> = OnceLock::new();
    FOUND
        .get_or_init(|| {
            for candidate in ["/bin/cat", "gcat"] {
                if is_gnu(candidate) {
                    return Some(candidate.to_string());
                }
            }
            eprintln!("GNU cat not found: need GNU /bin/cat or gcat on PATH");
            None
        })
        .as_deref()
}

fn is_gnu(program: &str) -> bool {
    let Ok(out) = Command::new(program).arg("--version").output() else {
        return false;
    };
    out.status.success() && out.stdout.windows(3).any(|w| w == b"GNU")
}

fn run(program: &str, args: &[String]) -> Run {
    let out = Command::new(program)
        .args(args)
        .output()
        .unwrap_or_else(|err| panic!("run {program}: {err}"));
    finish(out)
}

fn run_stdin(program: &str, args: &[String], input: &[u8]) -> Run {
    let mut child = Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    finish(child.wait_with_output().unwrap())
}

fn finish(out: Output) -> Run {
    Run {
        status: out.status,
        stdout: out.stdout,
        stderr: out.stderr,
    }
}

fn assert_same(reference: &Run, actual: &Run) {
    assert_eq!(
        reference.status.code(),
        actual.status.code(),
        "status\nref stderr: {}\nact stderr: {}",
        String::from_utf8_lossy(&reference.stderr),
        String::from_utf8_lossy(&actual.stderr)
    );
    assert_eq!(reference.stdout, actual.stdout, "stdout");
    assert_eq!(
        reference.stderr,
        actual.stderr,
        "stderr\nref: {}\nact: {}",
        String::from_utf8_lossy(&reference.stderr),
        String::from_utf8_lossy(&actual.stderr)
    );
}

struct Tmp {
    dir: PathBuf,
}

impl Tmp {
    fn new() -> Self {
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("blackcat-rs-{}-{}", std::process::id(), n));
        fs::create_dir_all(&dir).unwrap();
        Self { dir }
    }

    fn write(&self, name: &str, data: &[u8]) -> PathBuf {
        let path = self.dir.join(name);
        fs::write(&path, data).unwrap();
        path
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| (*s).to_string()).collect()
}

fn expect_file(gnu: &str, args: &[&str], name: &str, data: &[u8]) {
    let tmp = Tmp::new();
    let path = tmp.write(name, data);
    let mut full = strings(args);
    full.push(path.display().to_string());
    assert_same(&run(gnu, &full), &run(exe(), &full));
}

fn expect_file_args(gnu: &str, gnu_args: &[&str], our_args: &[&str], name: &str, data: &[u8]) {
    let tmp = Tmp::new();
    let path = tmp.write(name, data);
    let path = path.display().to_string();
    let mut g = strings(gnu_args);
    g.push(path.clone());
    let mut o = strings(our_args);
    o.push(path);
    assert_same(&run(gnu, &g), &run(exe(), &o));
}

fn shell_append_heredoc(program: &str, file: &Path, content: &str) {
    let script = format!("{program} >>\"{}\" <<'EOF'\n{content}EOF", file.display());
    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(&script)
        .status()
        .unwrap();
    assert!(status.success(), "heredoc append failed: {script}");
}

fn shell_append_pipe(program: &str, file: &Path, content: &[u8]) {
    let script = format!("{program} >>\"{}\"", file.display());
    let mut child = Command::new("/bin/sh")
        .arg("-c")
        .arg(&script)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(content).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "pipe append failed");
}

#[test]
fn plain_file_copy_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &[], "plain.txt", b"hello world\nsecond line\n");
}

#[test]
fn empty_file_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &[], "empty.txt", b"");
}

#[test]
fn binary_content_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file_args(
        gnu,
        &[],
        &["-k"],
        "binary.bin",
        &[0, 1, 2, 255, 10, 13, 9, b'x'],
    );
}

#[test]
fn multiple_files_match_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    let tmp = Tmp::new();
    let a = tmp.write("a.txt", b"AAA\n");
    let b = tmp.write("b.txt", b"BBB\n");
    let args = strings(&[a.to_str().unwrap(), b.to_str().unwrap()]);
    assert_same(&run(gnu, &args), &run(exe(), &args));
}

#[test]
fn number_lines_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-n"], "numbered.txt", b"line1\n\nline3\n");
    expect_file(gnu, &["--number"], "numbered.txt", b"line1\n\nline3\n");
}

#[test]
fn number_nonblank_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-b"], "nonblank.txt", b"line1\n\nline3\n");
}

#[test]
fn squeeze_blank_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-s"], "squeeze.txt", b"one\n\n\n\ntwo\n\n");
    expect_file(
        gnu,
        &["--squeeze-blank"],
        "squeeze.txt",
        b"one\n\n\n\ntwo\n\n",
    );
}

#[test]
fn show_ends_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-E"], "ends.txt", b"alpha\nbeta\n");
    expect_file(gnu, &["-E"], "crlf.txt", b"alpha\r\nbeta\r\n");
}

#[test]
fn show_tabs_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-T"], "tabs.txt", b"a\tb\n");
}

#[test]
fn show_all_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-A"], "showall.txt", b"a\tb\n\x01\n");
}

#[test]
fn show_ends_and_nonprinting_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-e"], "ends.txt", b"alpha\nbeta\n");
}

#[test]
fn show_tabs_and_nonprinting_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-t"], "tabs.txt", b"a\tb\n");
}

#[test]
fn show_nonprinting_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-v"], "nonprint.txt", b"hi\x01\n");
}

#[test]
fn stdin_copy_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    let input = b"piped stdin\n";
    assert_same(&run_stdin(gnu, &[], input), &run_stdin(exe(), &[], input));
}

#[test]
fn combined_shorts_and_ignored_u_match_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    expect_file(gnu, &["-bn"], "both.txt", b"line1\n\nline3\n");
    expect_file(gnu, &["-ne"], "both.txt", b"a\nb\n");
    expect_file(gnu, &["-u"], "plain.txt", b"hello\n");
}

#[test]
fn double_dash_stops_options() {
    let tmp = Tmp::new();
    let path = tmp.write("plain.txt", b"hello\n");
    let args = strings(&["--", "-n", path.to_str().unwrap()]);
    let actual = run(exe(), &args);
    assert_eq!(actual.stdout, b"hello\n");
    assert!(actual.status.success());
    let err = String::from_utf8_lossy(&actual.stderr);
    assert!(err.contains("-n"), "{err}");
    assert!(err.contains("No such file or directory"), "{err}");
}

#[test]
fn flag_after_filename_is_a_filename() {
    let tmp = Tmp::new();
    let path = tmp.write("plain.txt", b"hello\n");
    let args = strings(&[path.to_str().unwrap(), "-n"]);
    let actual = run(exe(), &args);
    assert_eq!(actual.stdout, b"hello\n");
    assert!(actual.status.success());
    let err = String::from_utf8_lossy(&actual.stderr);
    assert!(err.contains("No such file or directory"), "{err}");
}

#[test]
fn version_and_help() {
    let version = run(exe(), &strings(&["--version"]));
    assert!(version.status.success());
    assert_eq!(version.stdout, b"blackcat 0.8.3\n");
    let help = run(exe(), &strings(&["--help"]));
    assert!(help.status.success());
    assert!(help.stdout.starts_with(b"USAGE: blackcat "));
    assert!(help.stderr.is_empty());
}

#[test]
fn append_heredoc_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    let tmp = Tmp::new();
    let path = tmp.write("append.txt", b"OLD\n");
    shell_append_heredoc(gnu, &path, "NEW\n");
    let expected = fs::read(&path).unwrap();
    fs::write(&path, b"OLD\n").unwrap();
    shell_append_heredoc(exe(), &path, "NEW\n");
    assert_eq!(fs::read(&path).unwrap(), expected);
}

#[test]
fn append_heredoc_grows_like_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    let tmp = Tmp::new();
    let path = tmp.write("grow.txt", b"AAAA\n");
    let before = fs::read(&path).unwrap().len();
    shell_append_heredoc(gnu, &path, "BB\n");
    let reference = fs::read(&path).unwrap();
    assert!(reference.len() > before);
    fs::write(&path, b"AAAA\n").unwrap();
    shell_append_heredoc(exe(), &path, "BB\n");
    let actual = fs::read(&path).unwrap();
    assert!(actual.len() > before);
    assert_eq!(actual.len(), reference.len());
}

#[test]
fn append_multiple_heredocs_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    let tmp = Tmp::new();
    let path = tmp.write("multi.txt", b"1\n");
    shell_append_heredoc(gnu, &path, "2\n");
    shell_append_heredoc(gnu, &path, "3\n");
    let expected = fs::read(&path).unwrap();
    fs::write(&path, b"1\n").unwrap();
    shell_append_heredoc(exe(), &path, "2\n");
    shell_append_heredoc(exe(), &path, "3\n");
    assert_eq!(fs::read(&path).unwrap(), expected);
}

#[test]
fn append_autoconf_shaped_heredoc_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    let tmp = Tmp::new();
    let initial = b"#! /bin/sh\n# Generated by configure.\n";
    let path = tmp.write("config.status", initial);
    shell_append_heredoc(gnu, &path, "## M4sh Initialization. ##\n");
    let expected = fs::read(&path).unwrap();
    fs::write(&path, initial).unwrap();
    shell_append_heredoc(exe(), &path, "## M4sh Initialization. ##\n");
    let actual = fs::read(&path).unwrap();
    assert_eq!(actual, expected);
    assert!(actual.starts_with(b"#! /bin/sh\n"));
    assert!(actual.ends_with(b"## M4sh Initialization. ##\n"));
}

#[test]
fn append_piped_stdin_matches_gnu_cat() {
    let Some(gnu) = gnu_cat() else { return };
    let tmp = Tmp::new();
    let path = tmp.write("pipe.txt", b"OLD\n");
    shell_append_pipe(gnu, &path, b"NEW\n");
    let expected = fs::read(&path).unwrap();
    fs::write(&path, b"OLD\n").unwrap();
    shell_append_pipe(exe(), &path, b"NEW\n");
    assert_eq!(fs::read(&path).unwrap(), expected);
}
