mod ansi;
mod cat;
mod image;
mod kitty;
mod sauce;
mod shm;

use std::io::{self, BufWriter, Write};
use std::process::ExitCode;

use cat::Options;

pub const NAME: &str = "blackcat";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

const USAGE: &str = "\
USAGE: {0} [OPTION]... [FILE]...

Concatenate FILE(s) to standard output.

With no FILE, or when FILE is -, read standard input.

Options:
  -a, --ansi[=WIDTH]        force ANSI terminal rendering mode (default width 80)
  -A, --show-all            equivalent to -vET
  -b, --number-nonblank     number nonempty output lines, overrides -n
  -c, --cp437               force CP437 to Unicode
  -e                        equivalent to -vE
  -E, --show-ends           display $ at end of each line
  -k, --no-image            disable image rendering via Kitty protocol
  -n, --number              number all output lines
  -s, --squeeze-blank       suppress repeated empty output lines
  -t                        equivalent to -vT
  -T, --show-tabs           display TAB characters as ^I
  -v, --show-nonprinting    use ^ and M- notation, except for LFD and TAB
      --help                display this help and exit
      --version             output version information and exit

EXAMPLES
  {0} f - g      Output f's contents, then stdin, then g's contents.
  {0}            Copy stdin to stdout.
";

fn main() -> ExitCode {
    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(cat::STDOUT_BUF, stdout.lock());
    let code = match run(&mut out) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::from(1),
    };
    let _ = out.flush();
    code
}

fn run(out: &mut BufWriter<io::StdoutLock<'static>>) -> io::Result<()> {
    let mut opts = Options::default();
    let mut files: Vec<String> = Vec::new();
    let mut processing_options = true;

    for arg in std::env::args().skip(1) {
        if processing_options {
            if arg == "--" {
                processing_options = false;
                continue;
            }
            if arg == "--help" {
                out.write_all(USAGE.replace("{0}", NAME).as_bytes())?;
                return Ok(());
            }
            if arg == "--version" {
                writeln!(out, "{NAME} {VERSION}")?;
                return Ok(());
            }
            if let Some(width) = arg.strip_prefix("--ansi=") {
                opts.ansi_width = width.parse().unwrap_or(80);
                opts.ansi = true;
                continue;
            }
            if arg == "--ansi" {
                opts.ansi = true;
                opts.ansi_width = 80;
                continue;
            }
            if arg == "--show-all" {
                opts.show_ends = true;
                opts.show_tabs = true;
                opts.show_nonprinting = true;
                continue;
            }
            if arg == "--number-nonblank" {
                opts.number_nonblank = true;
                opts.number = false;
                continue;
            }
            if arg == "--cp437" {
                opts.cp437 = true;
                continue;
            }
            if arg == "--show-ends" {
                opts.show_ends = true;
                continue;
            }
            if arg == "--no-image" {
                opts.no_image = true;
                continue;
            }
            if arg == "--number" {
                if !opts.number_nonblank {
                    opts.number = true;
                }
                continue;
            }
            if arg == "--squeeze-blank" {
                opts.squeeze_blank = true;
                continue;
            }
            if arg == "--show-tabs" {
                opts.show_tabs = true;
                continue;
            }
            if arg == "--show-nonprinting" {
                opts.show_nonprinting = true;
                continue;
            }
            if arg.starts_with('-') && arg.len() > 1 && !arg.starts_with("--") {
                for opt in arg[1..].bytes() {
                    match opt {
                        b'a' => {
                            opts.ansi = true;
                            opts.ansi_width = 80;
                        }
                        b'A' => {
                            opts.show_ends = true;
                            opts.show_tabs = true;
                            opts.show_nonprinting = true;
                        }
                        b'b' => {
                            opts.number_nonblank = true;
                            opts.number = false;
                        }
                        b'c' => opts.cp437 = true,
                        b'e' => {
                            opts.show_ends = true;
                            opts.show_nonprinting = true;
                        }
                        b'E' => opts.show_ends = true,
                        b'k' => opts.no_image = true,
                        b'n' => {
                            if !opts.number_nonblank {
                                opts.number = true;
                            }
                        }
                        b's' => opts.squeeze_blank = true,
                        b't' => {
                            opts.show_tabs = true;
                            opts.show_nonprinting = true;
                        }
                        b'T' => opts.show_tabs = true,
                        b'u' => {}
                        b'v' => opts.show_nonprinting = true,
                        _ => {}
                    }
                }
                continue;
            }
            processing_options = false;
        }
        files.push(arg);
    }

    if files.is_empty() {
        cat::cat_file("-", &opts, out)?;
    } else {
        for file in &files {
            cat::cat_file(file, &opts, out)?;
        }
    }
    Ok(())
}
