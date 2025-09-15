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
    \\  -v, --show-nonprinting    use ^ and M- notation, except for LFD and TAB
    \\      --help                display this help and exit
    \\      --version             output version information and exit
    \\
    \\EXAMPLES
    \\  cat f - g      Output f's contents, then stdin, then g's contents.
    \\  cat            Copy stdin to stdout.
    \\
;

const Version = "0.2.5";

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
    0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
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
    [3]u8{ 0x00, 0x00, 0x00 }, // Black
    [3]u8{ 0xC4, 0x00, 0x00 }, // Red
    [3]u8{ 0x00, 0xC4, 0x00 }, // Green
    [3]u8{ 0xC4, 0x7E, 0x00 }, // Yellow
    [3]u8{ 0x00, 0x00, 0xC4 }, // Blue
    [3]u8{ 0xC4, 0x00, 0xC4 }, // Magenta
    [3]u8{ 0x00, 0xC4, 0xC4 }, // Cyan
    [3]u8{ 0xC4, 0xC4, 0xC4 }, // White
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
                row.append(ScreenCell{ .ch = ' ', .fg = null, .bg = 0, .bold = false, .blink = false }) catch {};
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
                            const effective_fg = if (cell.fg.? < 8 and cell.bold) cell.fg.? + 8 else cell.fg.?;
                            const fg: u8 = effective_fg;
                            const rgb = ColorMap[fg];
                            try writer.print("\x1B[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
                        }
                        if (cell.bg != null) {
                            const effective_bg = if (cell.bg.? < 8 and cell.blink) cell.bg.? + 8 else cell.bg.?;
                            const bg: u8 = effective_bg;
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
        while (true) {
            const len = try reader.read(&catbuf);
            if (len == 0) break;
            try content.appendSlice(catbuf[0..len]);
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

// --- CRLF detection helper ---
fn has_crlf(lbuf: []const u8) bool {
    var last_was_cr = false;
    for (lbuf) |b| {
        if (last_was_cr and b == '\n') {
            return true;
        } else if (b == '\r') {
            last_was_cr = true;
        } else {
            last_was_cr = false;
        }
    }
    return false;
}

// --- ANSI detection helper ---
fn sampleForAnsi(head_buf: []const u8) !bool {
    var has_ansi = false;
    var i: usize = 0;
    while (i < head_buf.len) : (i += 1) {
        const b = head_buf[i];
        if (i + 1 < head_buf.len and b == 0x1B and head_buf[i + 1] == '[') {
            has_ansi = true;
            break;
        }
    }
    return has_ansi and has_crlf(head_buf[0..]);
}

fn sampleForCp437(head_buf: []const u8) !bool {
    var has_high_byte = false;
    for (head_buf[0..]) |b| {
        if (b >= 128) {
            has_high_byte = true;
            break;
        }
    }
    return has_high_byte and has_crlf(head_buf[0..]);
}

var catbuf: [131072]u8 = undefined;

pub fn main() !void {
    var stdout = std.io.getStdOut().writer();

    var args = std.process.args();
    const prog_name = std.fs.path.basename(args.next() orelse "unknown");

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

    var has_files = false;

    var processing_options = true;
    while (args.next()) |arg| {
        if (processing_options) {
            if (std.mem.eql(u8, arg, "--")) {
                processing_options = false;
                continue;
            }
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
            }
            if (std.mem.eql(u8, arg, "--ansi")) {
                options.ansi = true;
                options.ansi_width = 80;
                continue;
            }
            if (std.mem.eql(u8, arg, "--show-all")) {
                options.show_ends = true;
                options.show_tabs = true;
                options.show_nonprinting = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--number-nonblank")) {
                options.number_nonblank = true;
                options.number = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--cp437")) {
                options.cp437 = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--show-ends")) {
                options.show_ends = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-image")) {
                options.kitty = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--number")) {
                if (!options.number_nonblank) options.number = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--squeeze-blank")) {
                options.squeeze_blank = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--show-tabs")) {
                options.show_tabs = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--show-nonprinting")) {
                options.show_nonprinting = true;
                continue;
            }
            // Combined short options
            if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and arg[1] != '-') {
                const shorts = arg[1..];
                for (shorts) |opt| {
                    switch (opt) {
                        'a' => {
                            options.ansi = true;
                            options.ansi_width = 80;
                        },
                        'A' => {
                            options.show_ends = true;
                            options.show_tabs = true;
                            options.show_nonprinting = true;
                        },
                        'b' => {
                            options.number_nonblank = true;
                            options.number = false;
                        },
                        'c' => {
                            options.cp437 = true;
                        },
                        'e' => {
                            options.show_ends = true;
                            options.show_nonprinting = true;
                        },
                        'E' => {
                            options.show_ends = true;
                        },
                        'k' => {
                            options.kitty = true;
                        },
                        'n' => {
                            if (!options.number_nonblank) options.number = true;
                        },
                        's' => {
                            options.squeeze_blank = true;
                        },
                        't' => {
                            options.show_tabs = true;
                            options.show_nonprinting = true;
                        },
                        'T' => {
                            options.show_tabs = true;
                        },
                        'u' => {}, // ignored
                        'v' => {
                            options.show_nonprinting = true;
                        },
                        else => {},
                    }
                }
                continue;
            }
            // If we reach here, it's not an option, so stop processing options and treat as file
            processing_options = false;
        }
        // treat as file
        try catFile(arg, options);
        has_files = true;
    }

    if(!has_files) {
        try catFile("-", options);
    }
}

fn catFile(
    filename: []const u8,
    options: Options,
) !void {
    const is_stdin = std.mem.eql(u8, filename, "-");
    var reader: std.fs.File.Reader = undefined;
    var file: std.fs.File = undefined;
    var file_opened = false;
    const stderr = std.io.getStdErr().writer();
    const writer = std.io.getStdOut().writer();

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

    var line_num: usize = 1;

    var detected_cp437: bool = options.cp437;
    var detected_ansi: bool = options.ansi;
    var head_buf: [1024]u8 = undefined;

    if (!is_stdin) {
        const len = try reader.read(&head_buf);
        if (len == 0) {
            return;
        }
        try file.seekTo(0);
    }

    if (!is_stdin) {
        if (!options.cp437) detected_cp437 = try sampleForCp437(&head_buf);
        if (!options.ansi) detected_ansi = try sampleForAnsi(&head_buf);
    }

    // Image detection (only for files, not stdin)
    if (!is_stdin and !options.kitty) {
        if (try isImageFile(&head_buf)) {
            try renderImage(&file, writer);
            return;
        }
    }

    if (detected_ansi) {
        try AnsiTerminal.renderReader(std.heap.page_allocator, reader, writer, options.ansi_width);
        return;
    }

    if (!detected_ansi and !detected_cp437 and !options.show_ends and
        !options.show_tabs and !options.show_nonprinting and
        !options.number and !options.number_nonblank and
        !options.squeeze_blank and !is_stdin)
    {
        try fastCat(&file, writer);
        return;
    }

    var prev: u8 = '\n';
    var squeeze: bool = false;

    while (true) {
        const len = try reader.read(&catbuf);
        if (len == 0) break;
        for (catbuf[0..len]) |ch| {
            if (prev == '\n') {
                if (options.squeeze_blank) {
                    if (ch == '\n') {
                        if (squeeze) {
                            continue;
                        }
                        squeeze = true;
                    } else squeeze = false;
                }

                if (options.number and !options.number_nonblank) {
                    try writer.print("{d:>6}  ", .{line_num});
                    line_num += 1;
                } else if (options.number_nonblank and ch != '\n') {
                    try writer.print("{d:>6}  ", .{line_num});
                    line_num += 1;
                }
            }

            if (options.show_ends) {
                if (ch == '\r') {
                    prev = ch;
                    continue;
                }
                if (ch == '\n') {
                    if (prev == '\r') {
                        try writer.writeAll("^M");
                    }
                    try writer.writeAll("$");
                }
                if (prev == '\r' and ch != '\n') {
                    try writer.writeByte('\r');
                }
            }

            if (ch == '\t' and options.show_tabs) {
                try writer.writeAll("^I");
            } else if (options.show_nonprinting and (std.ascii.isControl(ch) or ch > 127) and ch != '\n' and ch != '\t') {
                var lowch = ch;
                if (ch > 127) {
                    try writer.writeAll("M-");
                    lowch = ch & 0x7F;
                }
                if (lowch < 32) {
                    try writer.writeByte('^');
                    try writer.writeByte(lowch + 64);
                } else if (lowch == 127) {
                    try writer.writeAll("^?");
                } else {
                    try writer.writeByte(lowch);
                    continue;
                }
            } else {
                if (detected_cp437 and ch == 0x1A) return;
                if (detected_cp437 and !std.ascii.isControl(ch)) {
                    var cbuf: [4]u8 = undefined;
                    const clen = try std.unicode.utf8Encode(cp437_to_unicode[ch], &cbuf);
                    try writer.writeAll(cbuf[0..clen]);
                } else {
                    try writer.writeByte(ch);
                }
            }
            prev = ch;
        }
    }
}

fn fastCat(file: *std.fs.File, writer: anytype) !void {
    var reader = file.reader();
    while (true) {
        const len = try reader.read(&catbuf);
        if (len == 0) break;
        try writer.writeAll(catbuf[0..len]);
    }
}

fn isImageFile(head_buf: []const u8) !bool {
    _ = zigimg.Image.detectFormatFromMemory(head_buf[0..]) catch return false;
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

    const original_width = img.width;
    const original_height = img.height;

    // Get terminal size
    var term_cols: u16 = 80;
    var term_rows: u16 = 24;
    var winsize: Winsize = undefined;
    if (std.posix.system.ioctl(1, std.posix.system.T.IOCGWINSZ, @intFromPtr(&winsize)) == 0) {
        term_cols = winsize.ws_col;
        term_rows = winsize.ws_row;
    }

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
    const scale: f32 = @min(scale_x, scale_y);

    // New dimensions
    const new_w: u32 = @intFromFloat(scale * img_w);
    const new_h: u32 = @intFromFloat(scale * img_h);

    // Convert to RGBA (kitty f=32)
    try img.convert(.rgba32);

    // Resize if needed
    if (new_w < original_width or new_h < original_height) {
        try resizeImage(allocator, &img, new_w, new_h);
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

    // Encode RGBA byte data to base64 for kitty
    var encoded = std.ArrayList(u8).init(allocator);
    defer encoded.deinit();
    const out_len = std.base64.standard.Encoder.calcSize(byte_data.items.len);
    try encoded.resize(out_len);
    _ = std.base64.standard.Encoder.encode(encoded.items, byte_data.items);

    try writer.print("\n     ", .{});
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
            try writer.print("\x1B_Gm=1;{s}\x1B\\", .{data[start..end]});
            start = end;
        }
        // Last chunk with m=0
        if (start < data.len) {
            try writer.print("\x1B_Gm=0;{s}\x1B\\", .{data[start..]});
        }
    }
    try writer.print("\n\n", .{});
}

// Bilinear image resizing
fn resizeImage(alloc: std.mem.Allocator, img: *zigimg.Image, new_w: u32, new_h: u32) !void {
    if (img.pixelFormat() != .rgba32) {
        try img.convert(.rgba32);
    }

    const original_width = img.width;
    const original_height = img.height;

    if (new_w == original_width and new_h == original_height) {
        return;
    }

    const img_w_f = @as(f32, @floatFromInt(original_width));
    const img_h_f = @as(f32, @floatFromInt(original_height));
    const new_w_f = @as(f32, @floatFromInt(new_w));
    const new_h_f = @as(f32, @floatFromInt(new_h));

    var new_pixels = try alloc.alloc(zigimg.color.Rgba32, new_w * new_h);

    for (0..new_h) |y| {
        const sy = @as(f32, @floatFromInt(y)) * img_h_f / new_h_f;
        const y0 = @as(usize, @intFromFloat(@floor(sy)));
        const y1 = @min(y0 + 1, original_height - 1);
        const dy = sy - @floor(sy);

        for (0..new_w) |x| {
            const sx = @as(f32, @floatFromInt(x)) * img_w_f / new_w_f;
            const x0 = @as(usize, @intFromFloat(@floor(sx)));
            const x1 = @min(x0 + 1, original_width - 1);
            const dx = sx - @floor(sx);

            const p00 = img.pixels.rgba32[@as(usize, y0) * original_width + x0];
            const p01 = img.pixels.rgba32[@as(usize, y0) * original_width + x1];
            const p10 = img.pixels.rgba32[@as(usize, y1) * original_width + x0];
            const p11 = img.pixels.rgba32[@as(usize, y1) * original_width + x1];

            const r = (1 - dx) * (1 - dy) * @as(f32, @floatFromInt(p00.r)) + dx * (1 - dy) * @as(f32, @floatFromInt(p01.r)) + (1 - dx) * dy * @as(f32, @floatFromInt(p10.r)) + dx * dy * @as(f32, @floatFromInt(p11.r));
            const g = (1 - dx) * (1 - dy) * @as(f32, @floatFromInt(p00.g)) + dx * (1 - dy) * @as(f32, @floatFromInt(p01.g)) + (1 - dx) * dy * @as(f32, @floatFromInt(p10.g)) + dx * dy * @as(f32, @floatFromInt(p11.g));
            const b = (1 - dx) * (1 - dy) * @as(f32, @floatFromInt(p00.b)) + dx * (1 - dy) * @as(f32, @floatFromInt(p01.b)) + (1 - dx) * dy * @as(f32, @floatFromInt(p10.b)) + dx * dy * @as(f32, @floatFromInt(p11.b));
            const a = (1 - dx) * (1 - dy) * @as(f32, @floatFromInt(p00.a)) + dx * (1 - dy) * @as(f32, @floatFromInt(p01.a)) + (1 - dx) * dy * @as(f32, @floatFromInt(p10.a)) + dx * dy * @as(f32, @floatFromInt(p11.a));

            new_pixels[y * new_w + x] = .{
                .r = @intFromFloat(@round(r)),
                .g = @intFromFloat(@round(g)),
                .b = @intFromFloat(@round(b)),
                .a = @intFromFloat(@round(a)),
            };
        }
    }

    alloc.free(img.pixels.rgba32);
    img.pixels = .{ .rgba32 = new_pixels };
    img.width = new_w;
    img.height = new_h;

    return;
}
