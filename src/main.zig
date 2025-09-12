const std = @import("std");
const zigimg = @import("zigimg");
const base64 = std.base64;

const Usage =
    \\USAGE: {s} [OPTION]... [FILE]...
    \\
    \\Concatenate FILE(s) to standard output.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\Options:
    \\  -a, --ansi[=WIDTH]        force ANSI terminal rendering mode (default width 80)
    \\  -A, --show-all            equivalent to -vET
    \\  -b, --number-nonblank     number nonempty output lines, overrides -n
    \\  -c, --cp437               force CP437 to Unicode
    \\  -e                        equivalent to -vE
    \\  -E, --show-ends           display $ at end of each line
    \\  -k, --no-image            disable image rendering via Kitty protocol
    \\  -n, --number              number all output lines
    \\  -s, --squeeze-blank       suppress repeated empty output lines
    \\  -t                        equivalent to -vT
    \\  -T, --show-tabs           display TAB characters as ^I
    \\  -u                        (ignored)
    \\  -v, --show-nonprinting    use ^ and M- notation, except for LFD and TAB
    \\      --help                display this help and exit
    \\      --version             output version information and exit
    \\
    \\EXAMPLES
    \\  cat f - g      Output f's contents, then stdin, then g's contents.
    \\  cat            Copy stdin to stdout.
    \\
;

const Version = "0.1.0";

const cp437_to_unicode = [_]u21{
    // 0-127
    0,      1,      2,      3,      4,      5,      6,      7,      8,      9,      10,     11,     12,     13,     14,     15,
    16,     17,     18,     19,     20,     21,     22,     23,     24,     25,     26,     27,     28,     29,     30,     31,
    32,     33,     34,     35,     36,     37,     38,     39,     40,     41,     42,     43,     44,     45,     46,     47,
    48,     49,     50,     51,     52,     53,     54,     55,     56,     57,     58,     59,     60,     61,     62,     63,
    64,     65,     66,     67,     68,     69,     70,     71,     72,     73,     74,     75,     76,     77,     78,     79,
    80,     81,     82,     83,     84,     85,     86,     87,     88,     89,     90,     91,     92,     93,     94,     95,
    96,     97,     98,     99,     100,    101,    102,    103,    104,    105,    106,    107,    108,    109,    110,    111,
    112,    113,    114,    115,    116,    117,    118,    119,    120,    121,    122,    123,    124,    125,    126,    127,
    // 128-255
    0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
    0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
    0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
    0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
    0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
    0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x220F, 0x2211, 0x2202, 0x221A, 0x222B, 0x00AA, 0x00BA, 0x03A0, 0x2219, 0x221F, 0x2205,
};

// Options struct
const Options = struct {
    show_ends: bool,
    show_tabs: bool,
    show_nonprinting: bool,
    number: bool,
    number_nonblank: bool,
    squeeze_blank: bool,
    cp437: bool,
    ansi: bool,
    ansi_width: usize,
    kitty: bool,
};

// --- CP437+ANSI Terminal Emulation Types ---
const ScreenCell = struct {
    ch: u21,
    fg: ?u8,
    bg: ?u8,
    bold: bool,
    blink: bool,
};

const ColorMap = [_][3]u8{
    [3]u8{ 0x26, 0x26, 0x26 }, // Black
    [3]u8{ 0xDB, 0x33, 0x33 }, // Red
    [3]u8{ 0x33, 0xDB, 0x33 }, // Green
    [3]u8{ 0xDB, 0x98, 0x33 }, // Yellow
    [3]u8{ 0x33, 0x33, 0xDB }, // Blue
    [3]u8{ 0xDB, 0x33, 0xDB }, // Magenta
    [3]u8{ 0x33, 0xDB, 0xDB }, // Cyan
    [3]u8{ 0xD6, 0xD6, 0xD6 }, // White
    [3]u8{ 0x4E, 0x4E, 0x4E }, // Bright Black
    [3]u8{ 0xDC, 0x4E, 0x4E }, // Bright Red
    [3]u8{ 0x4E, 0xDC, 0x4E }, // Bright Green
    [3]u8{ 0xF3, 0xF3, 0x4E }, // Bright Yellow
    [3]u8{ 0x4E, 0x4E, 0xDC }, // Bright Blue
    [3]u8{ 0xF3, 0x4E, 0xF3 }, // Bright Magenta
    [3]u8{ 0x4E, 0xF3, 0xF3 }, // Bright Cyan
    [3]u8{ 0xFF, 0xFF, 0xFF }, // Bright White
};

const AnsiTerminal = struct {
    allocator: std.mem.Allocator,
    screen: std.ArrayList(std.ArrayList(ScreenCell)),
    width: usize,
    cursor_x: usize,
    cursor_y: usize,
    fg: u8,
    bg: u8,
    bold: bool,
    blink: bool,

    pub fn init(allocator: std.mem.Allocator, width: usize) AnsiTerminal {
        const screen = std.ArrayList(std.ArrayList(ScreenCell)).init(allocator);
        return AnsiTerminal{
            .allocator = allocator,
            .screen = screen,
            .width = width,
            .cursor_x = 0,
            .cursor_y = 0,
            .fg = 7,
            .bg = 0,
            .bold = false,
            .blink = false,
        };
    }

    pub fn deinit(self: *AnsiTerminal) void {
        for (self.screen.items) |*row| row.deinit();
        self.screen.deinit();
    }

    pub fn putChar(self: *AnsiTerminal, ch: u21) void {
        while (self.cursor_y >= self.screen.items.len) {
            var row = std.ArrayList(ScreenCell).init(self.allocator);
            for (0..self.width) |_| {
                row.append(ScreenCell{ .ch = ' ', .fg = null, .bg = null, .bold = false, .blink = false }) catch {};
            }
            self.screen.append(row) catch return;
        }
        if (self.cursor_x >= self.width) return;
        self.screen.items[self.cursor_y].items[self.cursor_x] = ScreenCell{
            .ch = ch,
            .fg = self.fg,
            .bg = self.bg,
            .bold = self.bold,
            .blink = self.blink,
        };
        self.cursor_x += 1;
        if (self.cursor_x >= self.width) {
            self.cursor_x = 0;
            self.cursor_y += 1;
        }
    }

    pub fn processEscape(self: *AnsiTerminal, seq: []const u8) void {
        if (seq.len < 3 or seq[0] != 0x1B or seq[1] != '[') return;
        const command = seq[seq.len - 1];
        const params_str = seq[2 .. seq.len - 1];
        var params = std.mem.splitScalar(u8, params_str, ';');

        if (command == 'A') { // Cursor up
            const n = if (params.next()) |p| std.fmt.parseInt(u8, p, 10) catch 1 else 1;
            self.cursor_y = if (self.cursor_y >= n) self.cursor_y - n else 0;
        } else if (command == 'B') { // Cursor down
            const n = if (params.next()) |p| std.fmt.parseInt(u8, p, 10) catch 1 else 1;
            self.cursor_y += n;
        } else if (command == 'C') { // Cursor right
            const n = if (params.next()) |p| std.fmt.parseInt(u8, p, 10) catch 1 else 1;
            self.cursor_x = @min(self.cursor_x + n, self.width - 1);
        } else if (command == 'D') { // Cursor left
            const n = if (params.next()) |p| std.fmt.parseInt(u8, p, 10) catch 1 else 1;
            self.cursor_x = if (self.cursor_x >= n) self.cursor_x - n else 0;
        } else if (command == 'H') { // Cursor position
            const row = if (params.next()) |p| std.fmt.parseInt(u8, p, 10) catch 1 else 1;
            const col = if (params.next()) |p| std.fmt.parseInt(u8, p, 10) catch 1 else 1;
            self.cursor_y = if (row > 0) row - 1 else 0;
            self.cursor_x = if (col > 0) col - 1 else 0;
        } else if (command == 'm') { // SGR (color/style)
            var codes = std.ArrayList(u8).init(self.allocator);
            defer codes.deinit();
            while (params.next()) |p| {
                if (p.len > 0) codes.append(std.fmt.parseInt(u8, p, 10) catch 0) catch {};
            }
            if (codes.items.len == 0) codes.append(0) catch {};
            for (codes.items) |code| {
                switch (code) {
                    0 => {
                        self.fg = 7;
                        self.bg = 0;
                        self.bold = false;
                        self.blink = false;
                    },
                    1 => self.bold = true,
                    5 => self.blink = true,
                    30...37 => self.fg = code - 30,
                    40...47 => self.bg = code - 40,
                    90...97 => self.fg = code - 90 + 8,
                    100...107 => self.bg = code - 100 + 8,
                    else => {},
                }
            }
        }
        // Ignore other commands for now
    }

    pub fn render(self: *AnsiTerminal, writer: anytype) !void {
        for (self.screen.items) |row| {
            var current_fg: ?u8 = null;
            var current_bg: ?u8 = null;
            var current_bold = false;
            var current_blink = false;
            for (row.items) |cell| {
                if (cell.fg != current_fg or cell.bg != current_bg or cell.bold != current_bold or cell.blink != current_blink) {
                    if (cell.fg == null and cell.bg == null and !cell.bold and !cell.blink) {
                        try writer.writeAll("\x1B[0m");
                    } else {
                        if (cell.fg != null) {
                            const fg: u8 = if (cell.bold) cell.fg.? + 8 else cell.fg.?;
                            const rgb = ColorMap[fg];
                            try writer.print("\x1B[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
                        }
                        if (cell.bg != null) {
                            const bg: u8 = if (cell.blink) cell.bg.? + 8 else cell.bg.?;
                            const rgb = ColorMap[bg];
                            try writer.print("\x1B[48;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
                        }
                    }
                    current_fg = cell.fg;
                    current_bg = cell.bg;
                    current_bold = cell.bold;
                    current_blink = cell.blink;
                }
                var cbuf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(cell.ch, &cbuf);
                try writer.writeAll(cbuf[0..len]);
            }
            try writer.writeAll("\x1B[0m\n");
        }
    }

    pub fn renderReader(allocator: std.mem.Allocator, reader: anytype, writer: anytype, width: usize) !void {
        var content = std.ArrayList(u8).init(allocator);
        defer content.deinit();
        var buf: [4096]u8 = undefined;
        while (true) {
            const len = try reader.read(&buf);
            if (len == 0) break;
            try content.appendSlice(buf[0..len]);
        }
        var term = AnsiTerminal.init(allocator, width);
        defer term.deinit();
        var i: usize = 0;
        const data = content.items;
        while (i < data.len) {
            if (data[i] == 0x1B and i + 1 < data.len and data[i + 1] == '[') {
                var j = i + 2;
                while (j < data.len and !(data[j] >= 0x40 and data[j] <= 0x7E)) j += 1;
                if (j < data.len) {
                    const seq = data[i .. j + 1];
                    term.processEscape(seq);
                    i = j + 1;
                    continue;
                }
            }
            if (data[i] == 0x0A) { // \n
                term.cursor_y += 1;
                term.cursor_x = 0;
                i += 1;
                continue;
            }
            if (data[i] == 0x0D) { // \r
                term.cursor_x = 0;
                i += 1;
                continue;
            }
            if (data[i] == 0x1A) { // SUB
                break;
            }
            const cp = cp437_to_unicode[data[i]];
            term.putChar(cp);
            i += 1;
        }
        try term.render(writer);
    }
};

// --- ANSI detection helper ---
fn sampleForAnsi(reader: anytype, options_ansi: bool) !bool {
    var sample_buf: [4096]u8 = undefined;
    const sample_len = try reader.read(sample_buf[0..]);
    if (sample_len == 0) {
        _ = reader.context.seekTo(0) catch {};
        return options_ansi;
    }

    var i: usize = 0;
    while (i + 1 < sample_len) : (i += 1) {
        if (sample_buf[i] == 0x1B and sample_buf[i + 1] == '[') {
            _ = reader.context.seekTo(0) catch {};
            return true;
        }
    }
    _ = reader.context.seekTo(0) catch {};
    return options_ansi;
}

fn sampleForCp437(reader: anytype, options_cp437: bool) !bool {
    var sample_buf: [4096]u8 = undefined;
    const sample_len = try reader.read(sample_buf[0..]);
    if (sample_len == 0) {
        _ = reader.context.seekTo(0) catch {};
        return options_cp437;
    }

    var has_crlf = false;
    var has_high_byte = false;
    var last_was_cr = false;
    for (sample_buf[0..sample_len]) |b| {
        if (b >= 128) has_high_byte = true;
        if (last_was_cr and b == '\n') {
            has_crlf = true;
            if (has_crlf and has_high_byte) break;
        } else if (b == '\r') {
            last_was_cr = true;
        } else {
            last_was_cr = false;
        }
    }
    _ = reader.context.seekTo(0) catch {};
    return options_cp437 or (has_crlf and has_high_byte);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var args = std.process.args();
    const prog_name = std.fs.path.basename(args.next() orelse "unknown");

    const stdout = std.io.getStdOut().writer();

    var options: Options = .{
        .show_ends = false,
        .show_tabs = false,
        .show_nonprinting = false,
        .number = false,
        .number_nonblank = false,
        .squeeze_blank = false,
        .cp437 = false,
        .ansi = false,
        .ansi_width = 80,
        .kitty = false,
    };

    var files = std.ArrayList([]const u8).init(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try stdout.print(Usage, .{prog_name});
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            try stdout.print("blackcat {s}\n", .{Version});
            return;
        }
        if (std.mem.startsWith(u8, arg, "--ansi=")) {
            const width_str = arg[7..];
            options.ansi_width = std.fmt.parseInt(usize, width_str, 10) catch 80;
            options.ansi = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--ansi")) {
            options.ansi = true;
            options.ansi_width = 80;
            continue;
        }
        if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--show-all")) {
            options.show_ends = true;
            options.show_tabs = true;
            options.show_nonprinting = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--number-nonblank")) {
            options.number_nonblank = true;
            options.number = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cp437")) {
            options.cp437 = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-e")) {
            options.show_ends = true;
            options.show_nonprinting = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--show-ends")) {
            options.show_ends = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--no-images")) {
            options.kitty = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--number")) {
            if (!options.number_nonblank) options.number = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--squeeze-blank")) {
            options.squeeze_blank = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-t")) {
            options.show_tabs = true;
            options.show_nonprinting = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-T") or std.mem.eql(u8, arg, "--show-tabs")) {
            options.show_tabs = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-u")) {
            // ignored
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--show-nonprinting")) {
            options.show_nonprinting = true;
            continue;
        }
        // treat as file
        try files.append(arg);
    }

    if (files.items.len == 0) {
        try catFile("-", stdout, options);
    } else {
        for (files.items) |filename| {
            try catFile(filename, stdout, options);
        }
    }
}

fn catFile(
    filename: []const u8,
    writer: anytype,
    options: Options,
) !void {
    const is_stdin = std.mem.eql(u8, filename, "-");
    var reader: std.fs.File.Reader = undefined;
    var file: std.fs.File = undefined;
    var file_opened = false;
    const stderr = std.io.getStdErr().writer();

    if (is_stdin) {
        reader = std.io.getStdIn().reader();
    } else {
        file = std.fs.cwd().openFile(filename, .{ .mode = .read_only }) catch {
            try stderr.print("blackcat: {s}: No such file or directory\n", .{filename});
            return;
        };
        file_opened = true;
        reader = file.reader();
    }
    defer if (file_opened) file.close();

    var buf: [65535]u8 = undefined;
    var line_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer line_buf.deinit();

    var line_num: usize = 1;
    var prev_blank = false;

    var detected_cp437: bool = options.cp437;
    var detected_ansi: bool = options.ansi;
    if (!is_stdin) {
        detected_cp437 = try sampleForCp437(reader, options.cp437);
        if (detected_cp437) detected_ansi = try sampleForAnsi(reader, options.ansi);
    }

    // Image detection (only for files, not stdin)
    if (!is_stdin and !options.kitty) {
        if (try isImageFile(reader)) {
            try renderImage(&file, writer);
            return;
        }
    }

    while (true) {
        if (detected_ansi) {
            try AnsiTerminal.renderReader(std.heap.page_allocator, reader, writer, options.ansi_width);
            return;
        }
        const slice = try reader.readUntilDelimiterOrEof(buf[0..], '\n');
        if (slice == null) break;
        const s = slice.?;
        try line_buf.appendSlice(s);
        if (s.len > 0 and s[s.len - 1] == '\r') _ = line_buf.pop();
        const line = line_buf.items;
        const is_blank = line.len == 0;

        if (options.squeeze_blank) {
            if (is_blank and prev_blank) {
                try line_buf.resize(0);
                continue;
            }
            prev_blank = is_blank;
        }

        if (options.number) {
            try writer.print("{d:>6}  ", .{line_num});
            line_num += 1;
        } else if (options.number_nonblank and !is_blank) {
            try writer.print("{d:>6}  ", .{line_num});
            line_num += 1;
        }

        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == '\t' and options.show_tabs) {
                try writer.writeAll("^I");
            } else if (options.show_nonprinting and (c < 32 or c == 127) and c != '\n' and c != '\t') {
                if (c < 32) {
                    try writer.writeByte('^');
                    try writer.writeByte(c + 64);
                } else if (c == 127) {
                    try writer.writeAll("^?");
                }
            } else {
                if (detected_cp437) {
                    if (c == 0x1A) return;
                    var cbuf: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(cp437_to_unicode[c], &cbuf);
                    try writer.writeAll(cbuf[0..len]);
                } else {
                    try writer.writeByte(c);
                }
            }
        }
        if (options.show_ends) {
            try writer.writeByte('$');
        }
        try writer.writeByte('\n');
        try line_buf.resize(0);
    }
}

fn isImageFile(reader: anytype) !bool {
    var buf: [512]u8 = undefined;
    const len = try reader.read(&buf);
    if (len == 0) return false;
    // Seek back for later use
    _ = reader.context.seekTo(0) catch {};
    _ = zigimg.Image.detectFormatFromMemory(buf[0..len]) catch return false;
    return true;
}

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

fn renderImage(file: *std.fs.File, writer: anytype) !void {
    const allocator = std.heap.page_allocator;
    var img = try zigimg.Image.fromFile(allocator, file);
    defer img.deinit();

    // Seek to start if needed, assuming file is seekable
    _ = file.seekTo(0) catch {};

    // Get original dimensions
    const original_width = img.width;
    const original_height = img.height;

    // Get terminal size
    var term_cols: u16 = 80;
    var term_rows: u16 = 24;
    var winsize: Winsize = undefined;
    if (std.posix.system.ioctl(1, std.posix.system.T.IOCGWINSZ, &winsize) == 0) {
        term_cols = winsize.ws_col;
        term_rows = winsize.ws_row;
    }

    // Constants
    const CELL_WIDTH: f32 = 8.0;
    const CELL_HEIGHT: f32 = 16.0;

    // Calculate max pixel dimensions
    const max_pixel_w: f32 = @as(f32, @floatFromInt(term_cols)) * CELL_WIDTH;
    const max_pixel_h: f32 = @as(f32, @floatFromInt(term_rows)) * CELL_HEIGHT;

    // Calculate scale
    const img_w: f32 = @floatFromInt(original_width);
    const img_h: f32 = @floatFromInt(original_height);
    const scale_x: f32 = max_pixel_w / img_w;
    const scale_y: f32 = max_pixel_h / img_h;
    const scale: f32 = @min(scale_x, scale_y, 1.0);

    // New dimensions
    const new_w: u32 = @intFromFloat(scale * img_w);
    const new_h: u32 = @intFromFloat(scale * img_h);

    // Convert to RGBA
    try img.convert(.rgba32);

    // Resize if needed
    if (new_w != original_width or new_h != original_height) {
        const pixel_count = new_w * new_h;
        var new_pixels = try allocator.alloc(zigimg.color.Rgba32, pixel_count);
        var idx: usize = 0;
        for (0..new_h) |y| {
            for (0..new_w) |x| {
                const src_x = (x * @as(usize, original_width)) / @as(usize, new_w);
                const src_y = (y * @as(usize, original_height)) / @as(usize, new_h);
                const pixel = img.pixels.rgba32[src_y * original_width + src_x];
                new_pixels[idx] = pixel;
                idx += 1;
            }
        }
        allocator.free(img.pixels.rgba32);
        img.pixels = .{ .rgba32 = new_pixels };
        img.width = new_w;
        img.height = new_h;
    }

    // Prepare byte array for RGBA data
    var byte_data = std.ArrayList(u8).init(allocator);
    defer byte_data.deinit();
    for (img.pixels.rgba32) |px| {
        try byte_data.append(px.r);
        try byte_data.append(px.g);
        try byte_data.append(px.b);
        try byte_data.append(px.a);
    }

    // Encode RGBA byte data to base64
    var encoded = std.ArrayList(u8).init(allocator);
    defer encoded.deinit();
    const out_len = std.base64.standard.Encoder.calcSize(byte_data.items.len);
    try encoded.resize(out_len);
    _ = std.base64.standard.Encoder.encode(encoded.items, byte_data.items);

    try writer.print("\n", .{});
    // Output Kitty sequence in 4096 byte chunks
    const chunk_size = 4096;
    const data = encoded.items;
    var start: usize = 0;
    if (data.len == 0) {
        // Handle empty image, perhaps skip
    } else if (data.len <= chunk_size) {
        try writer.print("\x1B_Gf=32,s={d},v={d},a=T;{s}\x1B\\", .{ img.width, img.height, data });
    } else {
        // First chunk with m=1
        const end1 = start + chunk_size;
        try writer.print("\x1B_Gf=32,s={d},v={d},a=T,m=1;{s}\x1B\\", .{ img.width, img.height, data[start..end1] });
        start = end1;
        // Middle chunks with m=1
        while (start + chunk_size < data.len) {
            const end = start + chunk_size;
            try writer.print("\x1B_Gm=1;{s}\x1B\\", .{ data[start..end] });
            start = end;
        }
        // Last chunk with m=0
        if (start < data.len) {
            try writer.print("\x1B_Gm=0;{s}\x1B\\", .{ data[start..] });
        }
    }
    try writer.print("\n\n", .{});
}
