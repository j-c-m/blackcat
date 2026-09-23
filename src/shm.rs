use std::cell::Cell;
use std::fs::File;
use std::io::{self, IsTerminal, Read, Write};
use std::os::fd::AsRawFd;
use std::ptr::null_mut;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use rustix::fd::OwnedFd;
use rustix::fs::{ftruncate, Mode};
use rustix::mm::{mmap, munmap, MapFlags, ProtFlags};

use crate::kitty::KittyFormat;

const NAME_MAX: usize = 31;
const CREATE_RETRIES: u8 = 16;
const PROBE_MS: u64 = 100;
const DUMMY: &[u8] = &[1, 2, 3];

thread_local! {
    static FORCE_CREATE_ERROR: Cell<bool> = const { Cell::new(false) };
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Support {
    Unknown,
    Yes,
    No,
}

static SUPPORT: Mutex<Support> = Mutex::new(Support::Unknown);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShmSend {
    Sent,
    LocalFail,
}

pub fn format_shm_name(pid: u32, rand: u32) -> String {
    format!("/bc{pid:08x}{rand:08x}")
}

pub fn shm_ready() -> bool {
    if !shm_os() {
        return false;
    }
    if !io::stdout().is_terminal() {
        return false;
    }
    let mut support = SUPPORT.lock().unwrap_or_else(|err| err.into_inner());
    if *support == Support::Unknown {
        *support = if probe() { Support::Yes } else { Support::No };
    }
    *support == Support::Yes
}

fn shm_os() -> bool {
    cfg!(any(
        target_os = "linux",
        target_os = "macos",
        target_os = "freebsd"
    ))
}

pub fn create_shm(data: &[u8]) -> io::Result<String> {
    if FORCE_CREATE_ERROR.with(Cell::get) {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "forced shm failure",
        ));
    }
    if data.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid size"));
    }
    if !shm_os() {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "shm unsupported",
        ));
    }
    let pid = std::process::id();
    for _ in 0..CREATE_RETRIES {
        let name = format_shm_name(pid, random_u32());
        if name.len() > NAME_MAX {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "shm name too long",
            ));
        }
        match rustix::shm::open(
            &name,
            rustix::shm::OFlags::CREATE | rustix::shm::OFlags::EXCL | rustix::shm::OFlags::RDWR,
            Mode::RUSR | Mode::WUSR,
        ) {
            Err(err) if err == rustix::io::Errno::EXIST => continue,
            Err(err) => return Err(io::Error::from(err)),
            Ok(fd) => {
                if let Err(err) = fill_shm(&fd, &name, data) {
                    let _ = rustix::shm::unlink(&name);
                    return Err(err);
                }
                return Ok(name);
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "shm name collision",
    ))
}

fn fill_shm(fd: &OwnedFd, name: &str, data: &[u8]) -> io::Result<()> {
    ftruncate(fd, data.len() as u64).map_err(io::Error::from)?;
    let ptr = unsafe {
        mmap(
            null_mut(),
            data.len(),
            ProtFlags::READ | ProtFlags::WRITE,
            MapFlags::SHARED,
            fd,
            0,
        )
        .map_err(io::Error::from)?
    };
    unsafe {
        std::ptr::copy_nonoverlapping(data.as_ptr(), ptr.cast(), data.len());
        munmap(ptr, data.len()).map_err(io::Error::from)?;
    }
    let _ = name;
    Ok(())
}

pub fn transmit_shm(
    out: &mut impl Write,
    pixels: &[u8],
    width: u32,
    height: u32,
    format: KittyFormat,
) -> io::Result<ShmSend> {
    let name = match create_shm(pixels) {
        Ok(name) => name,
        Err(_) => return Ok(ShmSend::LocalFail),
    };
    let write = (|| {
        write_shm_apc(out, &name, pixels.len(), width, height, format)?;
        out.flush()?;
        Ok(())
    })();
    match write {
        Ok(()) => Ok(ShmSend::Sent),
        Err(err) => {
            let _ = rustix::shm::unlink(&name);
            Err(err)
        }
    }
}

pub fn transmit_frame_shm(
    out: &mut impl Write,
    pixels: &[u8],
    width: u32,
    height: u32,
    image_number: u32,
    gap_ms: Option<u32>,
    format: KittyFormat,
) -> io::Result<ShmSend> {
    let name = match create_shm(pixels) {
        Ok(name) => name,
        Err(_) => return Ok(ShmSend::LocalFail),
    };
    let b64 = STANDARD.encode(name.as_bytes());
    let write = (|| {
        if let Some(gap) = gap_ms {
            write!(
                out,
                "\x1b_Gf={},s={width},v={height},a=f,I={image_number},z={gap},q=2,t=s,S={};{b64}\x1b\\",
                format as u8,
                pixels.len()
            )?;
        } else {
            write!(
                out,
                "\x1b_Gf={},s={width},v={height},a=T,I={image_number},q=2,t=s,S={};{b64}\x1b\\",
                format as u8,
                pixels.len()
            )?;
        }
        out.flush()?;
        Ok(())
    })();
    match write {
        Ok(()) => Ok(ShmSend::Sent),
        Err(err) => {
            let _ = rustix::shm::unlink(&name);
            Err(err)
        }
    }
}

pub fn write_shm_apc(
    out: &mut impl Write,
    name: &str,
    data_size: usize,
    width: u32,
    height: u32,
    format: KittyFormat,
) -> io::Result<()> {
    let b64 = STANDARD.encode(name.as_bytes());
    write!(
        out,
        "\x1b_Gf={},s={width},v={height},a=T,q=2,t=s,S={data_size};{b64}\x1b\\",
        format as u8
    )
}

fn random_u32() -> u32 {
    let mut buf = [0u8; 4];
    if let Ok(mut file) = File::open("/dev/urandom") {
        if file.read_exact(&mut buf).is_ok() {
            return u32::from_le_bytes(buf);
        }
    }
    1
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProbeParse {
    NeedMore,
    Ok,
    Fail,
    Da1,
}

pub struct ProbeParser {
    want_id: u32,
    buf: [u8; 1024],
    len: usize,
    pub saw_ok: bool,
    pub saw_fail: bool,
    pub saw_da1: bool,
}

impl ProbeParser {
    pub fn new(want_id: u32) -> Self {
        Self {
            want_id,
            buf: [0; 1024],
            len: 0,
            saw_ok: false,
            saw_fail: false,
            saw_da1: false,
        }
    }

    fn status(&self) -> ProbeParse {
        if self.saw_ok {
            ProbeParse::Ok
        } else if self.saw_fail {
            ProbeParse::Fail
        } else if self.saw_da1 {
            ProbeParse::Da1
        } else {
            ProbeParse::NeedMore
        }
    }

    pub fn feed(&mut self, chunk: &[u8]) -> ProbeParse {
        append_buf(&mut self.buf, &mut self.len, chunk);
        let mut i = 0;
        while i < self.len {
            if self.buf[i] != 0x1b {
                i += 1;
                continue;
            }
            if i + 1 >= self.len {
                break;
            }
            if self.buf[i + 1] == b'_' {
                let Some(parsed) = parse_apc(&self.buf[i..self.len]) else {
                    break;
                };
                if parsed.id == Some(self.want_id) {
                    if parsed.ok {
                        self.saw_ok = true;
                    } else {
                        self.saw_fail = true;
                    }
                }
                i += parsed.len;
                continue;
            }
            if self.buf[i + 1] == b'[' {
                if let Some(n) = parse_da1(&self.buf[i..self.len]) {
                    self.saw_da1 = true;
                    i += n;
                    continue;
                }
            }
            i += 1;
        }
        if i > 0 {
            let remain = self.len - i;
            self.buf.copy_within(i..self.len, 0);
            self.len = remain;
        }
        self.status()
    }
}

struct ApcParse {
    len: usize,
    id: Option<u32>,
    ok: bool,
}

fn append_buf(buf: &mut [u8; 1024], len: &mut usize, chunk: &[u8]) {
    if *len + chunk.len() <= buf.len() {
        buf[*len..*len + chunk.len()].copy_from_slice(chunk);
        *len += chunk.len();
        return;
    }
    let keep = buf.len() / 2;
    if *len > keep {
        buf.copy_within(*len - keep..*len, 0);
        *len = keep;
    }
    let room = buf.len() - *len;
    let take = chunk.len().min(room);
    let start = chunk.len() - take;
    buf[*len..*len + take].copy_from_slice(&chunk[start..]);
    *len += take;
}

fn parse_i(control: &[u8]) -> Option<u32> {
    let mut rest = control;
    while !rest.is_empty() {
        if rest.len() >= 2 && rest[0] == b'i' && rest[1] == b'=' {
            rest = &rest[2..];
            let mut val: u32 = 0;
            let mut any = false;
            while !rest.is_empty() && rest[0].is_ascii_digit() {
                any = true;
                val = val.wrapping_mul(10).wrapping_add((rest[0] - b'0') as u32);
                rest = &rest[1..];
            }
            return any.then_some(val);
        }
        if let Some(idx) = rest.iter().position(|b| *b == b',') {
            rest = &rest[idx + 1..];
        } else {
            break;
        }
    }
    None
}

fn parse_apc(bytes: &[u8]) -> Option<ApcParse> {
    if bytes.len() < 3 || bytes[0] != 0x1b || bytes[1] != b'_' || bytes[2] != b'G' {
        return None;
    }
    let semi = bytes[3..].iter().position(|b| *b == b';')? + 3;
    let mut end = semi + 1;
    while end < bytes.len() {
        if bytes[end] == 0x07 {
            let payload = &bytes[semi + 1..end];
            return Some(ApcParse {
                len: end + 1,
                id: parse_i(&bytes[3..semi]),
                ok: payload == b"OK",
            });
        }
        if bytes[end] == 0x1b {
            if end + 1 >= bytes.len() {
                return None;
            }
            if bytes[end + 1] == b'\\' {
                let payload = &bytes[semi + 1..end];
                return Some(ApcParse {
                    len: end + 2,
                    id: parse_i(&bytes[3..semi]),
                    ok: payload == b"OK",
                });
            }
        }
        end += 1;
    }
    None
}

fn parse_da1(bytes: &[u8]) -> Option<usize> {
    if bytes.len() < 4 || bytes[0] != 0x1b || bytes[1] != b'[' || bytes[2] != b'?' {
        return None;
    }
    for (i, c) in bytes.iter().enumerate().skip(3) {
        if *c == b'c' {
            return Some(i + 1);
        }
        let is_param = c.is_ascii_digit() || *c == b';';
        if !is_param {
            return None;
        }
    }
    None
}

struct ProbeGuard {
    fd: i32,
    saved: libc::termios,
    name: String,
    unlink_dummy: bool,
    signals: bool,
}

impl Drop for ProbeGuard {
    fn drop(&mut self) {
        unsafe {
            if self.signals {
                libc::sigaction(libc::SIGINT, &raw const PROBE_OLD_INT, std::ptr::null_mut());
                libc::sigaction(
                    libc::SIGTERM,
                    &raw const PROBE_OLD_TERM,
                    std::ptr::null_mut(),
                );
                PROBE_ARMED = false;
            }
            if self.fd >= 0 {
                libc::tcsetattr(self.fd, libc::TCSAFLUSH, &self.saved);
            }
        }
        if self.unlink_dummy {
            let _ = rustix::shm::unlink(&self.name);
        }
    }
}

static mut PROBE_OLD_INT: libc::sigaction = unsafe { std::mem::zeroed() };
static mut PROBE_OLD_TERM: libc::sigaction = unsafe { std::mem::zeroed() };
static mut PROBE_FD: i32 = -1;
static mut PROBE_SAVED: libc::termios = unsafe { std::mem::zeroed() };
static mut PROBE_PATH: [u8; 96] = [0; 96];
static mut PROBE_ARMED: bool = false;

unsafe extern "C" fn on_probe_signal(sig: i32) {
    unsafe {
        if PROBE_FD >= 0 {
            libc::tcsetattr(PROBE_FD, libc::TCSAFLUSH, &raw const PROBE_SAVED);
        }
        if PROBE_ARMED {
            unlink_probe_object();
        }
        let old = if sig == libc::SIGINT {
            &raw const PROBE_OLD_INT
        } else {
            &raw const PROBE_OLD_TERM
        };
        libc::sigaction(sig, old, std::ptr::null_mut());
        libc::raise(sig);
    }
}

unsafe fn unlink_probe_object() {
    let path = (&raw const PROBE_PATH).cast::<libc::c_char>();
    if unsafe { *path } == 0 {
        return;
    }
    #[cfg(target_os = "linux")]
    unsafe {
        libc::unlink(path);
    }
    #[cfg(not(target_os = "linux"))]
    unsafe {
        libc::shm_unlink(path);
    }
}

fn install_probe_signals(fd: i32, saved: libc::termios, name: &str) -> io::Result<()> {
    let path = linux_shm_path(name);
    unsafe {
        PROBE_FD = fd;
        PROBE_SAVED = saved;
        let bytes = path.as_bytes();
        let n = bytes.len().min(95);
        let dst = (&raw mut PROBE_PATH).cast::<u8>();
        std::ptr::write_bytes(dst, 0, 96);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), dst, n);
        PROBE_ARMED = true;

        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_probe_signal as *const () as usize;
        action.sa_flags = 0;
        libc::sigemptyset(&mut action.sa_mask);
        if libc::sigaction(libc::SIGINT, &action, &raw mut PROBE_OLD_INT) != 0 {
            return Err(io::Error::last_os_error());
        }
        if libc::sigaction(libc::SIGTERM, &action, &raw mut PROBE_OLD_TERM) != 0 {
            libc::sigaction(libc::SIGINT, &raw const PROBE_OLD_INT, std::ptr::null_mut());
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

fn linux_shm_path(name: &str) -> String {
    if cfg!(target_os = "linux") {
        format!("/dev/shm{}", name)
    } else {
        name.to_string()
    }
}

fn probe() -> bool {
    let Ok(name) = create_shm(DUMMY) else {
        return false;
    };
    let Ok(tty) = File::options().read(true).write(true).open("/dev/tty") else {
        let _ = rustix::shm::unlink(&name);
        return false;
    };
    let fd = tty.as_raw_fd();
    let mut saved: libc::termios = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(fd, &mut saved) } != 0 {
        let _ = rustix::shm::unlink(&name);
        return false;
    }
    let mut term = saved;
    term.c_lflag &= !(libc::ICANON | libc::ECHO);
    term.c_cc[libc::VMIN] = 0;
    term.c_cc[libc::VTIME] = 0;
    if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &term) } != 0 {
        let _ = rustix::shm::unlink(&name);
        return false;
    }
    if install_probe_signals(fd, saved, &name).is_err() {
        unsafe { libc::tcsetattr(fd, libc::TCSAFLUSH, &saved) };
        let _ = rustix::shm::unlink(&name);
        return false;
    }
    let mut guard = ProbeGuard {
        fd,
        saved,
        name: name.clone(),
        unlink_dummy: true,
        signals: true,
    };

    let image_id = random_u32().max(1);
    let b64 = STANDARD.encode(name.as_bytes());
    let msg = format!("\x1b_Gi={image_id},s=1,v=1,a=q,t=s,f=24,S=3;{b64}\x1b\\\x1b[c");
    if tty_write(&tty, msg.as_bytes()).is_err() {
        return false;
    }

    let mut parser = ProbeParser::new(image_id);
    let deadline = Instant::now() + Duration::from_millis(PROBE_MS);
    while !parser.saw_da1 {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        let rem = deadline.saturating_duration_since(now);
        let ts = rustix::event::Timespec {
            tv_sec: rem.as_secs() as i64,
            tv_nsec: rem.subsec_nanos() as rustix::event::Nsecs,
        };
        let mut fds = [rustix::event::PollFd::new(
            &tty,
            rustix::event::PollFlags::IN,
        )];
        let _ = rustix::event::poll(&mut fds, Some(&ts));
        if !feed_tty(&tty, &mut parser) {
            continue;
        }
        while feed_tty(&tty, &mut parser) {}
    }
    while feed_tty(&tty, &mut parser) {}
    if parser.saw_ok {
        guard.unlink_dummy = false;
        unsafe { PROBE_ARMED = false };
        true
    } else {
        false
    }
}

fn tty_write(tty: &File, bytes: &[u8]) -> io::Result<()> {
    let mut left = bytes;
    while !left.is_empty() {
        let n = rustix::io::write(tty, left).map_err(io::Error::from)?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "tty write"));
        }
        left = &left[n..];
    }
    Ok(())
}

fn feed_tty(tty: &File, parser: &mut ProbeParser) -> bool {
    let mut tmp = [0u8; 256];
    match rustix::io::read(tty, &mut tmp) {
        Ok(0) | Err(_) => false,
        Ok(n) => {
            parser.feed(&tmp[..n]);
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn decode_name(apc: &str) -> String {
        let semi = apc.rfind(';').unwrap();
        let mut end = apc.len();
        if apc.as_bytes().ends_with(b"\x1b\\") {
            end -= 2;
        }
        let decoded = STANDARD.decode(&apc[semi + 1..end]).unwrap();
        String::from_utf8(decoded).unwrap()
    }

    #[test]
    fn shm_name_darwin_limit() {
        let name = format_shm_name(0x0000_1a2b, 0x3c4d_5e6f);
        assert_eq!(name.len(), 19);
        assert!(name.len() <= 31);
        assert!(name.starts_with('/'));
        assert!(!name[1..].contains('/'));
        assert_eq!(name, "/bc00001a2b3c4d5e6f");
    }

    #[test]
    fn shm_apc_framing() {
        let mut out = Vec::new();
        write_shm_apc(&mut out, "/bc0000000100000002", 12, 4, 5, KittyFormat::Rgba).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("t=s"));
        assert!(!text.contains("o=z"));
        assert!(text.contains("S=12"));
        assert!(!text.contains("m="));
        assert_eq!(decode_name(&text), "/bc0000000100000002");
    }

    #[test]
    fn shm_size_follows_wire_format() {
        let mut out = Vec::new();
        write_shm_apc(&mut out, "/bc0000000100000002", 12, 2, 2, KittyFormat::Rgb).unwrap();
        write_shm_apc(&mut out, "/bc0000000100000002", 16, 2, 2, KittyFormat::Rgba).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("f=24,s=2,v=2,a=T,q=2,t=s,S=12;"));
        assert!(text.contains("f=32,s=2,v=2,a=T,q=2,t=s,S=16;"));
    }

    #[test]
    fn parser_ok_fail_da1_and_splits() {
        let mut p = ProbeParser::new(31);
        assert_eq!(p.feed(b"\x1b_Gi=31;OK\x1b\\"), ProbeParse::Ok);
        let mut p = ProbeParser::new(31);
        assert_eq!(
            p.feed(b"\x1b_Gi=31;EINVAL: invalid data\x1b\\"),
            ProbeParse::Fail
        );
        let mut p = ProbeParser::new(1);
        assert_eq!(p.feed(b"\x1b[?1;0c"), ProbeParse::Da1);
        let mut p = ProbeParser::new(7);
        assert_eq!(p.feed(b"\x1b_Gi=7;O"), ProbeParse::NeedMore);
        assert_eq!(p.feed(b"K\x1b\\"), ProbeParse::Ok);
        let mut p = ProbeParser::new(2);
        assert_eq!(p.feed(b"\x1b_Gi=99;OK\x1b\\"), ProbeParse::NeedMore);
        assert_eq!(p.feed(b"\x1b_Gi=2;OK\x1b\\"), ProbeParse::Ok);
        let mut p = ProbeParser::new(4);
        assert_eq!(p.feed(b"\x1b_Gi=4;OK\x07"), ProbeParse::Ok);
        let mut p = ProbeParser::new(3073211871);
        p.feed(b"\x1b_Gi=3073211871;OK\x1b\\\x1b[?62;22;52c");
        assert!(p.saw_ok && p.saw_da1);
    }

    #[test]
    fn empty_create_is_invalid_size() {
        let err = create_shm(b"").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn create_fail_is_local_fail() {
        FORCE_CREATE_ERROR.with(|flag| flag.set(true));
        let result = transmit_shm(&mut Vec::new(), b"zlib", 1, 1, KittyFormat::Rgba).unwrap();
        FORCE_CREATE_ERROR.with(|flag| flag.set(false));
        assert_eq!(result, ShmSend::LocalFail);
    }

    struct FailWrite;
    impl Write for FailWrite {
        fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
            Err(io::Error::other("write failed"))
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn write_fail_does_not_fall_back() {
        if !shm_os() {
            return;
        }
        let err = transmit_shm(&mut FailWrite, b"zlib-bytes", 2, 2, KittyFormat::Rgba);
        assert!(err.is_err());
    }

    #[test]
    fn local_round_trip() {
        if !shm_os() {
            return;
        }
        let payload = b"hello-shm-payload";
        let name = match create_shm(payload) {
            Ok(name) => name,
            Err(_) => return,
        };
        let fd = rustix::shm::open(&name, rustix::shm::OFlags::RDONLY, Mode::empty()).unwrap();
        let ptr = unsafe {
            mmap(
                null_mut(),
                payload.len(),
                ProtFlags::READ,
                MapFlags::SHARED,
                &fd,
                0,
            )
            .unwrap()
        };
        let got = unsafe { std::slice::from_raw_parts(ptr.cast::<u8>(), payload.len()) };
        assert_eq!(got, payload);
        unsafe { munmap(ptr, payload.len()).unwrap() };
        rustix::shm::unlink(&name).unwrap();
    }
}
