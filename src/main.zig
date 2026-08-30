const std = @import("std");
const Io = std.Io;
const zigimg = @import("zigimg");
const base64 = std.base64;
const build_options = @import("build_options");
const builtin = @import("builtin");

const sauce = @import("sauce.zig");
const ansi = @import("ansi.zig");
const image = @import("image.zig");

test {
    _ = image;
}

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

var catbuf: [65536]u8 = undefined;
var stdoutbuf: [65536]u8 = undefined;
var stdout: *Io.Writer = undefined;

pub fn main(init: std.process.Init) !void {
    const io: Io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();

    var stdoutwriter: Io.File.Writer = .initStreaming(.stdout(), io, &stdoutbuf);
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
        try catFile(io, arg, options);
        has_files = true;
    }

    if (!has_files) {
        try catFile(io, "-", options);
    }
}

fn catFile(
    io: std.Io,
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
        if (try image.isImageFile(&head_buf)) {
            image.renderImage(std.heap.page_allocator, io, &file, stdout) catch |err| {
                std.debug.print("{s}: {s}: {}\n", .{ prog_name, filename, err });
            };
            return;
        }
    }

    if (!is_stdin) {
        if (!options.cp437) detected_cp437 = try ansi.sampleForCp437(&head_buf);
        if (!options.ansi) detected_ansi = try ansi.sampleForAnsi(&head_buf);
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
        fastCat(io, &file, stdout) catch |err| {
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
                    try stdout.print("{d:>6}\t", .{line_num});
                    line_num += 1;
                } else if (options.number_nonblank and ch != '\n') {
                    try stdout.print("{d:>6}\t", .{line_num});
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

fn fastCatPositional(io: std.Io, file: *std.Io.File, writer: *std.Io.Writer) !void {
    var offset: u64 = 0;
    while (file.readPositionalAll(io, &catbuf, offset)) |len| {
        if (len == 0) break;
        try writer.writeAll(catbuf[0..len]);
        try writer.flush();
        offset += len;
    } else |err| {
        if (err != error.EndOfStream) {
            return err;
        }
    }
}

fn fastCatSendfile(io: std.Io, file: *std.Io.File, writer: *std.Io.Writer) !void {
    var file_reader = file.reader(io, &catbuf);
    _ = try writer.sendFileAll(&file_reader, .unlimited);
}

// For some reason sendfileAll is slow on macOS, use readPositionalAll instead
const fastCat = if (builtin.os.tag == .macos)
    fastCatPositional
else
    fastCatSendfile;
