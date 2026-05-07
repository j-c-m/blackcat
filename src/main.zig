const std = @import("std");
const Io = std.Io;
const zigimg = @import("zigimg");
const base64 = std.base64;
const build_options = @import("build_options");

const sauce = @import("sauce.zig");
const ansi = @import("ansi.zig");

const Usage =
    \\USAGE: {0s} [OPTION]... [FILE]...
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
    \\  {0s} f - g      Output f's contents, then stdin, then g's contents.
    \\  {0s}            Copy stdin to stdout.
    \\
;

const version = build_options.version;
const prog_name = build_options.name;

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

var catbuf: [65536]u8 = undefined;
var stdoutbuf: [65536]u8 = undefined;
var stdoutwriter: Io.File.Writer = undefined;
var stdout: *Io.Writer = undefined;
var io: Io = undefined;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();

    io = init.io;
    stdoutwriter = .init(.stdout(), io, &stdoutbuf);
    stdout = &stdoutwriter.interface;
    defer stdout.flush() catch {};

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
    _ = args.next();
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
                try stdout.print("{s} {s}\n", .{ prog_name, version });
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

    if (!has_files) {
        try catFile("-", options);
    }
}

fn catFile(
    filename: []const u8,
    options: Options,
) !void {
    const is_stdin = std.mem.eql(u8, filename, "-");
    var file: std.Io.File = undefined;
    var file_opened = false;

    if (is_stdin) {
        file = std.Io.File.stdin();
    } else {
        file = std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only }) catch {
            std.debug.print("{s}: {s}: No such file or directory\n", .{ prog_name, filename });
            return;
        };
        file_opened = true;
    }
    defer if (file_opened) file.close(io);

    var line_num: usize = 1;

    var detected_cp437: bool = options.cp437;
    var detected_ansi: bool = options.ansi;
    var head_buf: [1024]u8 = undefined;

    if (!is_stdin) {
        const len = file.readPositionalAll(io, &head_buf, 0) catch |err| {
            std.debug.print("{s}: {s}: {}\n", .{ prog_name, filename, err });
            return;
        };
        if (len == 0) {
            return;
        }
    }

    // Image detection (only for files, not stdin)
    if (!is_stdin and !options.kitty) {
        if (try isImageFile(&head_buf)) {
            renderImage(&file, stdout) catch |err| {
                std.debug.print("{s}: {s}: {}\n", .{ prog_name, filename, err });
            };
            return;
        }
    }

    if (!is_stdin) {
        if (!options.cp437) detected_cp437 = try sampleForCp437(&head_buf);
        if (!options.ansi) detected_ansi = try sampleForAnsi(&head_buf);
    }

    var sauce_width = options.ansi_width;
    if (!is_stdin and sauce.isSauceCandidate(filename)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        if (try sauce.getSauce(alloc, io, &file)) |sauce_data| {
            sauce_width = sauce_data.metadata.getWidth();
            detected_ansi = true;
            //std.debug.print("SAUCE: {d} comments\n", .{sauce_data.metadata.comments});
            //for (sauce_data.comments) |line| {
            //    std.debug.print("SAUCE Comment: '{s}'\n", .{line});
            //}
        }
    }

    if (detected_ansi) {
        try ansi.AnsiTerminal.renderFile(std.heap.page_allocator, io, &file, stdout, sauce_width);
        return;
    }

    if (!detected_ansi and !detected_cp437 and !options.show_ends and
        !options.show_tabs and !options.show_nonprinting and
        !options.number and !options.number_nonblank and
        !options.squeeze_blank and !is_stdin)
    {
        fastCat(&file, stdout) catch |err| {
            std.debug.print("{s}: {s}: {}\n", .{ prog_name, filename, err });
        };
        return;
    }

    var prev: u8 = '\n';
    var squeeze: bool = false;

    const iov = [_][]u8{&catbuf};
    while (file.readStreaming(io, &iov)) |len| {
        if (len == 0) return;
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
                    try stdout.print("{d:>6}  ", .{line_num});
                    line_num += 1;
                } else if (options.number_nonblank and ch != '\n') {
                    try stdout.print("{d:>6}  ", .{line_num});
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
                        try stdout.writeAll("^M");
                    }
                    try stdout.writeAll("$");
                }
                if (prev == '\r' and ch != '\n') {
                    try stdout.writeByte('\r');
                }
            }

            if (ch == '\t' and options.show_tabs) {
                try stdout.writeAll("^I");
            } else if (options.show_nonprinting and (std.ascii.isControl(ch) or ch > 127) and ch != '\n' and ch != '\t') {
                var lowch = ch;
                if (ch > 127) {
                    try stdout.writeAll("M-");
                    lowch = ch & 0x7F;
                }
                if (lowch < 32) {
                    try stdout.writeByte('^');
                    try stdout.writeByte(lowch + 64);
                } else if (lowch == 127) {
                    try stdout.writeAll("^?");
                } else {
                    try stdout.writeByte(lowch);
                    continue;
                }
            } else {
                if (detected_cp437 and ch == 0x1A) return;
                if (detected_cp437 and !std.ascii.isControl(ch)) {
                    var cbuf: [4]u8 = undefined;
                    const clen = try std.unicode.utf8Encode(ansi.cp437_to_unicode[ch], &cbuf);
                    try stdout.writeAll(cbuf[0..clen]);
                } else {
                    try stdout.writeByte(ch);
                }
            }
            prev = ch;
        }
        try stdout.flush();
    } else |err| {
        if (err != error.EndOfStream) {
            std.debug.print("{s}: {s}: {}\n", .{ prog_name, filename, err });
            return err;
        }
    }
}

fn fastCat(file: *std.Io.File, writer: *std.Io.Writer) !void {
    const iov = [_][]u8{&catbuf};
    while (file.readStreaming(io, &iov)) |len| {
        if (len == 0) break;
        try writer.writeAll(catbuf[0..len]);
        try writer.flush();
    } else |err| {
        if (err != error.EndOfStream) {
            return err;
        }
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

fn renderImage(file: *std.Io.File, writer: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var img = try zigimg.Image.fromFile(allocator, io, file.*, &catbuf);
    defer img.deinit(allocator);

    const original_width = img.width;
    const original_height = img.height;

    // Get terminal size
    var ws_col: u16 = 80;
    var ws_row: u16 = 24;
    var ws_xpixel: u16 = 10 * ws_col;
    var ws_ypixel: u16 = 20 * ws_row;
    var winsize: Winsize = undefined;
    if (std.posix.system.ioctl(1, std.posix.system.T.IOCGWINSZ, @intFromPtr(&winsize)) == 0) {
        ws_col = winsize.ws_col;
        ws_row = winsize.ws_row;
        ws_xpixel = winsize.ws_xpixel;
        ws_ypixel = winsize.ws_ypixel;
    }

    // Calculate max pixel dimensions
    const max_pixel_w: f32 = @as(f32, @floatFromInt(ws_xpixel - ((ws_xpixel / ws_col) * 6)));
    const max_pixel_h: f32 = @as(f32, @floatFromInt(ws_ypixel - ((ws_ypixel / ws_row) * 3)));

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
    try img.convert(allocator, .rgba32);

    // Resize if needed
    if (new_w < original_width or new_h < original_height) {
        try resizeImage(allocator, &img, new_w, new_h);
    }

    // Prepare byte array for RGBA data
    var byte_data = try std.ArrayList(u8).initCapacity(allocator, img.pixels.rgba32.len * 4);
    defer byte_data.deinit(allocator);
    for (img.pixels.rgba32) |px| {
        try byte_data.append(allocator, px.r);
        try byte_data.append(allocator, px.g);
        try byte_data.append(allocator, px.b);
        try byte_data.append(allocator, px.a);
    }

    // Compress the raw RGBA data using zlib
    if (true) {
        var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, byte_data.items.len);
        defer compressed.deinit();

        var deflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = try std.compress.flate.Compress.init(
            &compressed.writer,
            &deflate_buffer,
            .zlib,
            .fastest,
        );

        try compress.writer.writeAll(byte_data.items);
        try compress.finish();

        const ai = compressed.toArrayList();
        byte_data = ai;
    }

    // Encode RGBA byte data to base64 for kitty
    var encoded = try std.ArrayList(u8).initCapacity(allocator, byte_data.items.len * 4 / 3);
    defer encoded.deinit(allocator);
    const out_len = std.base64.standard.Encoder.calcSize(byte_data.items.len);
    try encoded.resize(allocator, out_len);
    _ = std.base64.standard.Encoder.encode(encoded.items, byte_data.items);

    try writer.print("\n     ", .{});
    // Output Kitty sequence in 4096 byte chunks
    const chunk_size = 4096;
    const data = encoded.items;
    var start: usize = 0;
    if (data.len == 0) {
        // Handle empty image, skip
        return;
    }

    while (start < data.len) {
        const end = @min(start + chunk_size, data.len);
        if (start == 0) {
            // "Header chunk" with m=1
            try writer.print("\x1B_Gf=32,o=z,s={d},v={d},a=T,m=1;{s}\x1B\\", .{ img.width, img.height, data[start..end] });
        } else {
            // "Payload chunk" with m=1
            try writer.print("\x1B_Gm=1;{s}\x1B\\", .{data[start..end]});
        }
        start = end;
    }
    // "End chunk" with m=0
    try writer.print("\x1B_Gm=0;\x1B\\", .{});

    try writer.print("\n\n", .{});
    try writer.flush();
    //std.debug.print("bytes sent: {d}\n", .{data.len});
}

// Bilinear image resizing
fn resizeImage(alloc: std.mem.Allocator, img: *zigimg.Image, new_w: u32, new_h: u32) !void {
    if (img.pixelFormat() != .rgba32) {
        try img.convert(alloc, .rgba32);
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

            new_pixels[y * new_w + x] = .{
                .r = lerp8(p00.r, p01.r, p10.r, p11.r, dx, dy),
                .g = lerp8(p00.g, p01.g, p10.g, p11.g, dx, dy),
                .b = lerp8(p00.b, p01.b, p10.b, p11.b, dx, dy),
                .a = lerp8(p00.a, p01.a, p10.a, p11.a, dx, dy),
            };
        }
    }

    alloc.free(img.pixels.rgba32);
    img.pixels = .{ .rgba32 = new_pixels };
    img.width = new_w;
    img.height = new_h;

    return;
}

inline fn lerp8(v00: u8, v01: u8, v10: u8, v11: u8, dx: f32, dy: f32) u8 {
    const f00 = @as(f32, @floatFromInt(v00));
    const f01 = @as(f32, @floatFromInt(v01));
    const f10 = @as(f32, @floatFromInt(v10));
    const f11 = @as(f32, @floatFromInt(v11));

    const value = (1 - dx) * (1 - dy) * f00 +
        dx * (1 - dy) * f01 +
        (1 - dx) * dy * f10 +
        dx * dy * f11;

    return @intFromFloat(@round(value));
}
