use std::fs::File;
use std::io::{self, BufWriter, Read, Write};
use std::os::unix::fs::FileExt;

use crate::NAME;

pub const STDOUT_BUF: usize = 65536;
const READ_BUF: usize = 65536;

#[derive(Clone, Debug)]
pub struct Options {
    pub show_ends: bool,
    pub show_tabs: bool,
    pub show_nonprinting: bool,
    pub number: bool,
    pub number_nonblank: bool,
    pub squeeze_blank: bool,
    pub cp437: bool,
    pub ansi: bool,
    pub ansi_width: usize,
    pub no_image: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            show_ends: false,
            show_tabs: false,
            show_nonprinting: false,
            number: false,
            number_nonblank: false,
            squeeze_blank: false,
            cp437: false,
            ansi: false,
            ansi_width: 80,
            no_image: false,
        }
    }
}

impl Options {
    fn transforms(&self) -> bool {
        self.show_ends
            || self.show_tabs
            || self.show_nonprinting
            || self.number
            || self.number_nonblank
            || self.squeeze_blank
    }
}

pub fn cat_file(
    name: &str,
    opts: &Options,
    out: &mut BufWriter<io::StdoutLock<'_>>,
) -> io::Result<()> {
    if name == "-" {
        let stdin = io::stdin();
        return copy_reader(name, &mut stdin.lock(), opts, out, opts.cp437);
    }

    let mut file = match File::open(name) {
        Ok(file) => file,
        Err(_) => {
            eprintln!("{NAME}: {name}: No such file or directory");
            return Ok(());
        }
    };

    let mut head_buf = [0u8; 1024];
    let n = file.read_at(&mut head_buf, 0)?;
    if n == 0 {
        return Ok(());
    }
    let head = &head_buf[..n];

    if !opts.no_image && crate::image::is_image(head) {
        if let Err(err) = crate::image::render(&mut file, out) {
            eprintln!("{NAME}: {name}: {err}");
        }
        return Ok(());
    }

    let detected_cp437 = opts.cp437 || crate::ansi::sample_cp437(head);
    let mut detected_ansi = opts.ansi || crate::ansi::sample_ansi(head);
    let mut width = opts.ansi_width;
    if crate::sauce::is_candidate(name) {
        match crate::sauce::read(&file) {
            Ok(Some(sauce)) => {
                width = sauce.width;
                detected_ansi = true;
            }
            Ok(None) => {}
            Err(err) => {
                eprintln!("{NAME}: {name}: {err}");
                return Err(err);
            }
        }
    }

    if detected_ansi {
        return crate::ansi::render_file(&mut file, out, width);
    }
    if !detected_cp437 && !opts.transforms() {
        return fast_cat(name, &file, out);
    }
    copy_reader(name, &mut file, opts, out, detected_cp437)
}

fn fast_cat(name: &str, file: &File, out: &mut BufWriter<io::StdoutLock<'_>>) -> io::Result<()> {
    if let Err(err) = fast_cat_inner(file, out) {
        eprintln!("{NAME}: {name}: {err}");
    }
    Ok(())
}

fn fast_cat_inner(file: &File, out: &mut BufWriter<io::StdoutLock<'_>>) -> io::Result<()> {
    out.flush()?;
    #[cfg(target_os = "linux")]
    {
        return sendfile_linux(file, out);
    }
    #[cfg(target_os = "freebsd")]
    {
        return sendfile_freebsd(file, out);
    }
    #[cfg(not(any(target_os = "linux", target_os = "freebsd")))]
    {
        pread_copy(file, out)
    }
}

#[cfg(target_os = "linux")]
fn sendfile_linux(file: &File, out: &mut BufWriter<io::StdoutLock<'_>>) -> io::Result<()> {
    // Linux rejects counts above 0x7ffff000.
    const CHUNK: usize = 0x7fff_f000;
    let mut offset = 0u64;
    loop {
        match rustix::fs::sendfile(out.get_ref(), file, Some(&mut offset), CHUNK) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(err) if err == rustix::io::Errno::INTR => {}
            Err(_) if offset == 0 => return pread_copy(file, out),
            Err(err) => return Err(io::Error::from(err)),
        }
    }
}

#[cfg(target_os = "freebsd")]
fn sendfile_freebsd(file: &File, out: &mut BufWriter<io::StdoutLock<'_>>) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let in_fd = file.as_raw_fd();
    let out_fd = out.get_ref().as_raw_fd();
    let mut offset: libc::off_t = 0;
    loop {
        let mut sent: libc::off_t = 0;
        let rc = unsafe {
            libc::sendfile(
                in_fd,
                out_fd,
                offset,
                READ_BUF,
                std::ptr::null_mut(),
                &mut sent,
                0,
            )
        };
        if sent > 0 {
            offset += sent;
        }
        if rc == 0 {
            if sent == 0 {
                return Ok(());
            }
            continue;
        }
        let err = io::Error::last_os_error();
        if err.kind() == io::ErrorKind::Interrupted {
            continue;
        }
        if offset == 0 {
            return pread_copy(file, out);
        }
        return Err(err);
    }
}

fn pread_copy(file: &File, out: &mut impl Write) -> io::Result<()> {
    let mut buf = [0u8; READ_BUF];
    let mut offset = 0u64;
    loop {
        let n = file.read_at(&mut buf, offset)?;
        if n == 0 {
            return Ok(());
        }
        out.write_all(&buf[..n])?;
        out.flush()?;
        offset += n as u64;
    }
}

pub fn copy_reader<R: Read>(
    name: &str,
    reader: &mut R,
    opts: &Options,
    out: &mut impl Write,
    cp437: bool,
) -> io::Result<()> {
    let mut buf = [0u8; READ_BUF];
    let mut prev = b'\n';
    let mut squeeze = false;
    let mut line_num: usize = 1;

    loop {
        let len = match reader.read(&mut buf) {
            Ok(0) => return Ok(()),
            Ok(n) => n,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => {
                eprintln!("{NAME}: {name}: {err}");
                return Err(err);
            }
        };

        for &ch in &buf[..len] {
            if prev == b'\n' {
                if opts.squeeze_blank {
                    if ch == b'\n' {
                        if squeeze {
                            continue;
                        }
                        squeeze = true;
                    } else {
                        squeeze = false;
                    }
                }

                if opts.number && !opts.number_nonblank {
                    write!(out, "{line_num:>6}\t")?;
                    line_num += 1;
                } else if opts.number_nonblank && ch != b'\n' {
                    write!(out, "{line_num:>6}\t")?;
                    line_num += 1;
                }
            }

            if opts.show_ends {
                if ch == b'\r' {
                    prev = ch;
                    continue;
                }
                if ch == b'\n' {
                    if prev == b'\r' {
                        out.write_all(b"^M")?;
                    }
                    out.write_all(b"$")?;
                }
                if prev == b'\r' && ch != b'\n' {
                    out.write_all(b"\r")?;
                }
            }

            if ch == b'\t' && opts.show_tabs {
                out.write_all(b"^I")?;
            } else if opts.show_nonprinting
                && (is_control(ch) || ch > 127)
                && ch != b'\n'
                && ch != b'\t'
            {
                let mut low = ch;
                if ch > 127 {
                    out.write_all(b"M-")?;
                    low &= 0x7f;
                }
                if low < 32 {
                    out.write_all(&[b'^', low + 64])?;
                } else if low == 127 {
                    out.write_all(b"^?")?;
                } else {
                    out.write_all(&[low])?;
                    continue;
                }
            } else if cp437 && ch == 0x1a {
                out.flush()?;
                return Ok(());
            } else if cp437 && !is_control(ch) {
                let mut encoded = [0u8; 4];
                let s = char::from_u32(crate::ansi::CP437[ch as usize])
                    .unwrap_or('\u{FFFD}')
                    .encode_utf8(&mut encoded);
                out.write_all(s.as_bytes())?;
            } else {
                out.write_all(&[ch])?;
            }
            prev = ch;
        }
        out.flush()?;
    }
}

fn is_control(ch: u8) -> bool {
    ch < 32 || ch == 127
}
