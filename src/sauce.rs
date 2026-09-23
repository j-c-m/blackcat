use std::fs::File;
use std::io::{self, ErrorKind};
use std::os::unix::fs::FileExt;
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sauce {
    pub title: String,
    pub author: String,
    pub group: String,
    pub width: usize,
    pub comments: Vec<String>,
}

pub fn is_candidate(filename: &str) -> bool {
    match Path::new(filename).extension().and_then(|ext| ext.to_str()) {
        Some(ext) => ext.eq_ignore_ascii_case("ans") || ext.eq_ignore_ascii_case("asc"),
        None => false,
    }
}

pub fn parse(buf: &[u8]) -> Option<Sauce> {
    if buf.len() < 128 || &buf[0..5] != b"SAUCE" {
        return None;
    }
    let tinfo1 = u16::from_le_bytes([buf[96], buf[97]]);
    Some(Sauce {
        title: trim_pad(&buf[7..42]),
        author: trim_pad(&buf[42..62]),
        group: trim_pad(&buf[62..82]),
        width: if tinfo1 == 0 { 80 } else { tinfo1 as usize },
        comments: Vec::new(),
    })
}

pub fn read(file: &File) -> io::Result<Option<Sauce>> {
    let file_size = file.metadata()?.len();
    if file_size < 128 {
        return Ok(None);
    }
    let sauce_pos = file_size - 128;
    let mut sauce = [0u8; 128];
    if pread_exact(file, &mut sauce, sauce_pos).is_err() {
        return Ok(None);
    }
    let mut meta = match parse(&sauce) {
        Some(meta) => meta,
        None => return Ok(None),
    };
    let n = sauce[104] as u64;
    if n == 0 {
        return Ok(Some(meta));
    }
    let header_at = match sauce_pos.checked_sub(n * 64 + 5) {
        Some(pos) => pos,
        None => return Ok(Some(meta)),
    };
    let mut comment_id = [0u8; 5];
    if pread_exact(file, &mut comment_id, header_at).is_err() || &comment_id != b"COMNT" {
        return Ok(Some(meta));
    }
    for i in 0..n {
        let mut chunk = [0u8; 64];
        let offset = sauce_pos - ((n - i) * 64);
        pread_exact(file, &mut chunk, offset)?;
        meta.comments.push(trim_pad(&chunk));
    }
    Ok(Some(meta))
}

fn trim_pad(bytes: &[u8]) -> String {
    let end = bytes
        .iter()
        .rposition(|b| *b != b' ')
        .map(|i| i + 1)
        .unwrap_or(0);
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn pread_exact(file: &File, buf: &mut [u8], offset: u64) -> io::Result<()> {
    let mut got = 0;
    while got < buf.len() {
        let n = file.read_at(&mut buf[got..], offset + got as u64)?;
        if n == 0 {
            return Err(io::Error::new(ErrorKind::UnexpectedEof, "short read"));
        }
        got += n;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn record(title: &str, tinfo1: u16, comments: u8) -> [u8; 128] {
        let mut buf = [b' '; 128];
        buf[0..5].copy_from_slice(b"SAUCE");
        buf[5..7].copy_from_slice(b"00");
        let title = title.as_bytes();
        buf[7..7 + title.len()].copy_from_slice(title);
        buf[96..98].copy_from_slice(&tinfo1.to_le_bytes());
        buf[104] = comments;
        buf
    }

    #[test]
    fn parses_width_and_title() {
        let sauce = parse(&record("Demo", 0, 0)).unwrap();
        assert_eq!(sauce.title, "Demo");
        assert_eq!(sauce.width, 80);
        let wide = parse(&record("Wide", 132, 0)).unwrap();
        assert_eq!(wide.width, 132);
        assert!(parse(b"nope").is_none());
    }

    #[test]
    fn reads_comnt_lines() {
        let dir = std::env::temp_dir().join(format!("blackcat-sauce-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("art.ans");
        let mut body = b"hi\r\n\x1a".to_vec();
        body.extend_from_slice(b"COMNT");
        let mut line = [b' '; 64];
        line[..5].copy_from_slice(b"hello");
        body.extend_from_slice(&line);
        let mut second = [b' '; 64];
        second[..6].copy_from_slice(b"a line");
        body.extend_from_slice(&second);
        body.extend_from_slice(&record("T", 40, 2));
        {
            let mut f = File::create(&path).unwrap();
            f.write_all(&body).unwrap();
        }
        let f = File::open(&path).unwrap();
        let sauce = read(&f).unwrap().unwrap();
        assert_eq!(sauce.width, 40);
        assert_eq!(
            sauce.comments,
            vec!["hello".to_string(), "a line".to_string()]
        );
        assert!(is_candidate("art.ANS"));
        assert!(is_candidate("x.asc"));
        assert!(!is_candidate("x.txt"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
