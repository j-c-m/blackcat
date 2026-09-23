use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};

pub const CP437: [u32; 256] = [
    0, 0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022, 0x25D8, 0x25CB, 0x25D9, 0x2642,
    0x2640, 0x266A, 0x266B, 0x263C, 0x25BA, 0x25C4, 0x2195, 0x203C, 0x00B6, 0x00A7, 0x25AC, 0x21AB,
    0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC, 32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87,
    88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108,
    109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127,
    0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF,
    0x00EE, 0x00EC, 0x00C4, 0x00C5, 0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
    0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192, 0x00E1, 0x00ED, 0x00F3, 0x00FA,
    0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557,
    0x255D, 0x255C, 0x255B, 0x2510, 0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
    0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567, 0x2568, 0x2564, 0x2565, 0x2559,
    0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
    0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4,
    0x221E, 0x03C6, 0x03B5, 0x2229, 0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
    0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
];

const COLOR_MAP: [[u8; 3]; 16] = [
    [0x00, 0x00, 0x00],
    [0xC4, 0x00, 0x00],
    [0x00, 0xC4, 0x00],
    [0xC4, 0x7E, 0x00],
    [0x00, 0x00, 0xC4],
    [0xC4, 0x00, 0xC4],
    [0x00, 0xC4, 0xC4],
    [0xC4, 0xC4, 0xC4],
    [0x4E, 0x4E, 0x4E],
    [0xDC, 0x4E, 0x4E],
    [0x4E, 0xDC, 0x4E],
    [0xF3, 0xF3, 0x4E],
    [0x4E, 0x4E, 0xDC],
    [0xF3, 0x4E, 0xF3],
    [0x4E, 0xF3, 0xF3],
    [0xFF, 0xFF, 0xFF],
];

#[derive(Clone, Copy)]
struct Cell {
    ch: char,
    fg: Option<u8>,
    bg: Option<u8>,
    bold: bool,
    blink: bool,
}

impl Cell {
    fn blank() -> Self {
        Self {
            ch: ' ',
            fg: None,
            bg: Some(0),
            bold: false,
            blink: false,
        }
    }
}

pub struct AnsiTerminal {
    screen: Vec<Vec<Cell>>,
    width: usize,
    cursor_x: usize,
    cursor_y: usize,
    fg: u8,
    bg: u8,
    bold: bool,
    blink: bool,
}

impl AnsiTerminal {
    pub fn new(width: usize) -> Self {
        Self {
            screen: Vec::new(),
            width,
            cursor_x: 0,
            cursor_y: 0,
            fg: 7,
            bg: 0,
            bold: false,
            blink: false,
        }
    }

    pub fn put_char(&mut self, ch: char) {
        while self.cursor_y >= self.screen.len() {
            self.screen.push(vec![Cell::blank(); self.width.max(0)]);
        }
        if self.cursor_x >= self.width {
            return;
        }
        self.screen[self.cursor_y][self.cursor_x] = Cell {
            ch,
            fg: Some(self.fg),
            bg: Some(self.bg),
            bold: self.bold,
            blink: self.blink,
        };
        self.cursor_x += 1;
        if self.cursor_x >= self.width {
            self.cursor_x = 0;
            self.cursor_y += 1;
        }
    }

    pub fn process_escape(&mut self, seq: &[u8]) {
        if seq.len() < 3 || seq[0] != 0x1b || seq[1] != b'[' {
            return;
        }
        let command = seq[seq.len() - 1];
        let params = &seq[2..seq.len() - 1];
        let mut parts = split_params(params);

        match command {
            b'A' => {
                let n = next_u8(&mut parts, 1) as usize;
                self.cursor_y = self.cursor_y.saturating_sub(n);
            }
            b'B' => {
                let n = next_u8(&mut parts, 1) as usize;
                self.cursor_y += n;
            }
            b'C' => {
                let n = next_u8(&mut parts, 1) as usize;
                let max = self.width.saturating_sub(1);
                self.cursor_x = self.cursor_x.saturating_add(n).min(max);
            }
            b'D' => {
                let n = next_u8(&mut parts, 1) as usize;
                self.cursor_x = self.cursor_x.saturating_sub(n);
            }
            b'H' => {
                let row = next_u8(&mut parts, 1);
                let col = next_u8(&mut parts, 1);
                self.cursor_y = if row > 0 { (row - 1) as usize } else { 0 };
                self.cursor_x = if col > 0 { (col - 1) as usize } else { 0 };
            }
            b'm' => {
                let mut codes = Vec::new();
                for part in parts {
                    if !part.is_empty() {
                        codes.push(parse_u8(part, 0));
                    }
                }
                if codes.is_empty() {
                    codes.push(0);
                }
                for code in codes {
                    match code {
                        0 => {
                            self.fg = 7;
                            self.bg = 0;
                            self.bold = false;
                            self.blink = false;
                        }
                        1 => self.bold = true,
                        5 => self.blink = true,
                        30..=37 => self.fg = code - 30,
                        40..=47 => self.bg = code - 40,
                        90..=97 => self.fg = code - 90 + 8,
                        100..=107 => self.bg = code - 100 + 8,
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    pub fn render(&self, out: &mut impl Write) -> io::Result<()> {
        for row in &self.screen {
            let mut current_fg: Option<u8> = None;
            let mut current_bg: Option<u8> = None;
            let mut current_bold = false;
            let mut current_blink = false;
            for cell in row {
                if cell.fg != current_fg
                    || cell.bg != current_bg
                    || cell.bold != current_bold
                    || cell.blink != current_blink
                {
                    if cell.fg.is_none() && cell.bg.is_none() && !cell.bold && !cell.blink {
                        out.write_all(b"\x1b[0m")?;
                    } else {
                        if let Some(fg) = cell.fg {
                            let fg = if fg < 8 && cell.bold { fg + 8 } else { fg };
                            let rgb = COLOR_MAP[fg as usize];
                            write!(out, "\x1b[38;2;{};{};{}m", rgb[0], rgb[1], rgb[2])?;
                        }
                        if let Some(bg) = cell.bg {
                            let bg = if bg < 8 && cell.blink { bg + 8 } else { bg };
                            let rgb = COLOR_MAP[bg as usize];
                            write!(out, "\x1b[48;2;{};{};{}m", rgb[0], rgb[1], rgb[2])?;
                        }
                    }
                    current_fg = cell.fg;
                    current_bg = cell.bg;
                    current_bold = cell.bold;
                    current_blink = cell.blink;
                }
                let mut encoded = [0u8; 4];
                out.write_all(cell.ch.encode_utf8(&mut encoded).as_bytes())?;
            }
            out.write_all(b"\x1b[0m\n")?;
            out.flush()?;
        }
        Ok(())
    }
}

pub fn render_file(file: &mut File, out: &mut impl Write, width: usize) -> io::Result<()> {
    file.seek(SeekFrom::Start(0))?;
    let mut data = Vec::new();
    if let Err(err) = file.read_to_end(&mut data) {
        eprint!("Error reading file: {err}");
        return Err(err);
    }
    render_bytes(&data, out, width)
}

pub fn render_bytes(data: &[u8], out: &mut impl Write, width: usize) -> io::Result<()> {
    let mut term = AnsiTerminal::new(width);
    let mut i = 0;
    while i < data.len() {
        if data[i] == 0x1b && i + 1 < data.len() && data[i + 1] == b'[' {
            let mut j = i + 2;
            while j < data.len() && !(0x40..=0x7e).contains(&data[j]) {
                j += 1;
            }
            if j < data.len() {
                term.process_escape(&data[i..=j]);
                i = j + 1;
                continue;
            }
        }
        match data[i] {
            b'\n' => {
                term.cursor_y += 1;
                term.cursor_x = 0;
                i += 1;
                continue;
            }
            b'\r' => {
                term.cursor_x = 0;
                i += 1;
                continue;
            }
            0x1a => break,
            b => {
                term.put_char(cp437_char(b));
                i += 1;
            }
        }
    }
    term.render(out)
}

pub fn cp437_char(b: u8) -> char {
    char::from_u32(CP437[b as usize]).unwrap_or('\u{FFFD}')
}

pub fn has_crlf(buf: &[u8]) -> bool {
    let mut last_was_cr = false;
    for &b in buf {
        if last_was_cr && b == b'\n' {
            return true;
        }
        last_was_cr = b == b'\r';
    }
    false
}

pub fn sample_ansi(buf: &[u8]) -> bool {
    let has_ansi = buf.windows(2).any(|w| w == b"\x1b[");
    has_ansi && has_crlf(buf)
}

pub fn sample_cp437(buf: &[u8]) -> bool {
    buf.iter().any(|b| *b >= 128) && has_crlf(buf)
}

fn split_params(params: &[u8]) -> Vec<&[u8]> {
    if params.is_empty() {
        return Vec::new();
    }
    params.split(|b| *b == b';').collect()
}

fn next_u8(parts: &mut Vec<&[u8]>, default: u8) -> u8 {
    if parts.is_empty() {
        return default;
    }
    let part = parts.remove(0);
    parse_u8(part, default)
}

fn parse_u8(part: &[u8], default: u8) -> u8 {
    if part.is_empty() {
        return default;
    }
    let text = std::str::from_utf8(part).unwrap_or("");
    text.parse::<u8>().unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crlf_and_samples() {
        assert!(!has_crlf(b"a\nb\r"));
        assert!(has_crlf(b"a\r\nb"));
        assert!(!sample_ansi(b"\x1b[31mno-crlf\n"));
        assert!(sample_ansi(b"\x1b[31m\r\n"));
        assert!(!sample_cp437(b"\x80\n"));
        assert!(sample_cp437(b"\x80\r\n"));
        assert!(!sample_cp437(b"plain\r\n"));
    }

    #[test]
    fn bold_red_uses_bright_truecolor() {
        let mut out = Vec::new();
        render_bytes(b"\x1b[1;31mA", &mut out, 80).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\x1b[38;2;220;78;78m"));
        assert!(text.contains('A'));
        assert!(text.ends_with("\x1b[0m\n"));
    }

    #[test]
    fn wraps_at_width_and_stops_at_sub() {
        let mut out = Vec::new();
        render_bytes(b"ABCD\x1aZZ", &mut out, 2).unwrap();
        let text = String::from_utf8(out).unwrap();
        let lines: Vec<&str> = text.split_inclusive('\n').collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("AB"));
        assert!(lines[1].contains("CD"));
        assert!(!text.contains('Z'));
    }

    #[test]
    fn cup_places_character() {
        let mut term = AnsiTerminal::new(10);
        term.process_escape(b"\x1b[2;3H");
        term.put_char('Q');
        assert_eq!(term.screen.len(), 2);
        assert_eq!(term.screen[1][2].ch, 'Q');
        assert_eq!(term.screen[1][1].ch, ' ');
    }
}
