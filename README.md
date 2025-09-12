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
  -u                        (ignored)
  -v, --show-nonprinting    use ^ and M- notation, except for LFD and TAB
      --help                display this help and exit
      --version             output version information and exit

EXAMPLES
  cat f - g      Output f's contents, then stdin, then g's contents.
  cat            Copy stdin to stdout.
```
