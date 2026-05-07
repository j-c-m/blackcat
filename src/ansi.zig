const std = @import("std");

pub const cp437_to_unicode = [_]u21{
    // 0-127
    0,      0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022, 0x25D8, 0x25CB, 0x25D9, 0x2642, 0x2640, 0x266A, 0x266B, 0x263C,
    0x25BA, 0x25C4, 0x2195, 0x203C, 0x00B6, 0x00A7, 0x25AC, 0x21AB, 0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC,
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

pub const AnsiTerminal = struct {
    allocator: std.mem.Allocator,
    screen: std.ArrayList(std.ArrayList(ScreenCell)),
    width: usize,
    cursor_x: usize,
    cursor_y: usize,
    fg: u8,
    bg: u8,
    bold: bool,
    blink: bool,

    pub fn init(allocator: std.mem.Allocator, width: usize) !AnsiTerminal {
        const screen = try std.ArrayList(std.ArrayList(ScreenCell)).initCapacity(allocator, 0);
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
        for (self.screen.items) |*row| row.deinit(self.allocator);
        self.screen.deinit(self.allocator);
    }

    pub fn putChar(self: *AnsiTerminal, ch: u21) !void {
        while (self.cursor_y >= self.screen.items.len) {
            var row = try std.ArrayList(ScreenCell).initCapacity(self.allocator, self.width);
            for (0..self.width) |_| {
                row.append(self.allocator, ScreenCell{ .ch = ' ', .fg = null, .bg = 0, .bold = false, .blink = false }) catch {};
            }
            self.screen.append(self.allocator, row) catch return;
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

    pub fn processEscape(self: *AnsiTerminal, seq: []const u8) !void {
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
            var codes = try std.ArrayList(u8).initCapacity(self.allocator, 0);
            defer codes.deinit(self.allocator);
            while (params.next()) |p| {
                if (p.len > 0) codes.append(self.allocator, std.fmt.parseInt(u8, p, 10) catch 0) catch {};
            }
            if (codes.items.len == 0) codes.append(self.allocator, 0) catch {};
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

    pub fn render(self: *AnsiTerminal, writer: *std.Io.Writer) !void {
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
            try writer.flush();
        }
    }

    pub fn renderFile(alloc: std.mem.Allocator, io: std.Io, file: *std.Io.File, writer: *std.Io.Writer, width: usize) !void {
        var content = try std.ArrayList(u8).initCapacity(alloc, 65536);
        defer content.deinit(alloc);
        var buf: [65536]u8 = undefined;
        const iov = [_][]u8{&buf};
        while (file.readStreaming(io, &iov)) |len| {
            if (len == 0) break;
            try content.appendSlice(alloc, buf[0..len]);
        } else |err| {
            if (err != error.EndOfStream) {
                std.debug.print("Error reading file: {}", .{err});
                return err;
            }
        }
        var term = try AnsiTerminal.init(alloc, width);
        defer term.deinit();
        var i: usize = 0;
        const data = content.items;
        while (i < data.len) {
            if (data[i] == 0x1B and i + 1 < data.len and data[i + 1] == '[') {
                var j = i + 2;
                while (j < data.len and !(data[j] >= 0x40 and data[j] <= 0x7E)) j += 1;
                if (j < data.len) {
                    const seq = data[i .. j + 1];
                    try term.processEscape(seq);
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
            try term.putChar(cp);
            i += 1;
        }
        try term.render(writer);
    }
};
