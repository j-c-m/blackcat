# blackcat

A modern `cat`, written in Rust. Drop-in behavior for the Zig blackcat: Kitty graphics, ANSI art, and CP437, and GNU cat otherwise.

* Kitty graphics protocol, including POSIX shared memory when the terminal can read it
* ANSI screen rendering, auto-detected
* CP437 to Unicode, auto-detected

PCX, IFF, RAS, SGI, and XBM are copied as bytes.

## Installation

```bash
cargo build --release
# binary: target/release/blackcat
```

Release targets:

* `x86_64-unknown-linux-musl`
* `aarch64-unknown-linux-musl`
* `x86_64-apple-darwin`
* `aarch64-apple-darwin`
* `x86_64-unknown-freebsd`
* `aarch64-unknown-freebsd`

```toml
[profile.release]
opt-level = 3
lto = true
codegen-units = 1
strip = true
panic = "abort"
```

## Usage

```
USAGE: blackcat [OPTION]... [FILE]...

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
  blackcat f - g      Output f's contents, then stdin, then g's contents.
  blackcat            Copy stdin to stdout.
```
