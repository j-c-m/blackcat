use std::io::{self, Write};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use flate2::write::ZlibEncoder;
use flate2::Compression;

pub const CHUNK: usize = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KittyFormat {
    Rgb = 24,
    Rgba = 32,
}

impl KittyFormat {
    fn code(self) -> u8 {
        self as u8
    }
}

pub fn zlib_compress(raw: &[u8]) -> io::Result<Vec<u8>> {
    let mut enc = ZlibEncoder::new(Vec::new(), Compression::fast());
    enc.write_all(raw)?;
    enc.finish()
}

pub fn write_direct_apc(
    out: &mut impl Write,
    compressed: &[u8],
    width: u32,
    height: u32,
    format: KittyFormat,
) -> io::Result<()> {
    if compressed.is_empty() {
        return Ok(());
    }
    let data = STANDARD.encode(compressed);
    let bytes = data.as_bytes();
    let mut start = 0;
    while start < bytes.len() {
        let end = (start + CHUNK).min(bytes.len());
        let chunk = &data[start..end];
        if start == 0 {
            write!(
                out,
                "\x1b_Gf={},o=z,s={width},v={height},a=T,q=2,m=1;{chunk}\x1b\\",
                format.code()
            )?;
        } else {
            write!(out, "\x1b_Gq=2,m=1;{chunk}\x1b\\")?;
        }
        start = end;
    }
    write!(out, "\x1b_Gq=2,m=0;\x1b\\")?;
    Ok(())
}

pub fn write_frame_direct(
    out: &mut impl Write,
    compressed: &[u8],
    width: u32,
    height: u32,
    image_number: u32,
    gap_ms: Option<u32>,
    format: KittyFormat,
) -> io::Result<()> {
    if compressed.is_empty() {
        return Ok(());
    }
    let data = STANDARD.encode(compressed);
    let bytes = data.as_bytes();
    let mut start = 0;
    while start < bytes.len() {
        let end = (start + CHUNK).min(bytes.len());
        let chunk = &data[start..end];
        if start == 0 {
            if let Some(gap) = gap_ms {
                write!(
                    out,
                    "\x1b_Gf={},o=z,s={width},v={height},a=f,I={image_number},z={gap},q=2,m=1;{chunk}\x1b\\",
                    format.code()
                )?;
            } else {
                write!(
                    out,
                    "\x1b_Gf={},o=z,s={width},v={height},a=T,I={image_number},q=2,m=1;{chunk}\x1b\\",
                    format.code()
                )?;
            }
        } else if gap_ms.is_some() {
            write!(out, "\x1b_Ga=f,q=2,m=1;{chunk}\x1b\\")?;
        } else {
            write!(out, "\x1b_Gq=2,m=1;{chunk}\x1b\\")?;
        }
        start = end;
    }
    if gap_ms.is_some() {
        write!(out, "\x1b_Ga=f,q=2,m=0;\x1b\\")?;
    } else {
        write!(out, "\x1b_Gq=2,m=0;\x1b\\")?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_framing() {
        let mut out = Vec::new();
        write_direct_apc(&mut out, b"abc", 2, 3, KittyFormat::Rgba).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.starts_with("\x1b_Gf=32,o=z,s=2,v=3,a=T,q=2,m=1;"));
        assert!(text.ends_with("\x1b_Gq=2,m=0;\x1b\\"));
        assert!(!text.contains("t=s"));
        assert!(!text.contains("\x1b_Gm=1;"));
    }

    #[test]
    fn empty_writes_nothing() {
        let mut out = Vec::new();
        write_direct_apc(&mut out, b"", 1, 1, KittyFormat::Rgba).unwrap();
        assert!(out.is_empty());
    }

    #[test]
    fn chunks_at_4096() {
        let mut out = Vec::new();
        let raw = vec![0xaa; 4000];
        write_direct_apc(&mut out, &raw, 10, 10, KittyFormat::Rgba).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\x1b_Gq=2,m=1;"));
        for frame in text.split("\x1b_").skip(1) {
            let Some(body_end) = frame.find(';') else {
                continue;
            };
            let mut payload = &frame[body_end + 1..];
            if let Some(stripped) = payload.strip_suffix("\x1b\\") {
                payload = stripped;
            }
            assert!(payload.len() <= CHUNK);
        }
    }

    #[test]
    fn frame_commands() {
        let mut out = Vec::new();
        write_frame_direct(&mut out, b"rgba", 2, 2, 7, None, KittyFormat::Rgba).unwrap();
        write_frame_direct(&mut out, b"rgba", 2, 2, 7, Some(40), KittyFormat::Rgba).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("a=T,I=7,q=2,m=1;"));
        assert!(text.contains("a=f,I=7,z=40,q=2,m=1;"));
        assert!(text.contains("\x1b_Ga=f,q=2,m=0;\x1b\\"));
        assert!(!text.contains("t=s"));
    }
}
