const std = @import("std");
const builtin = @import("builtin");
const zigimg = @import("zigimg");

const kitty_chunk_size = 4096;
const shm_probe_timeout_ms: i32 = 100;
const shm_name_max = 31;
const shm_create_retries = 16;
const shm_dummy_rgb = [_]u8{ 1, 2, 3 };

const ShmSupport = enum { unknown, yes, no };
var shm_support: ShmSupport = .unknown;
var test_force_shm_create_error: ?anyerror = null;

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const TransmitShm = enum { sent, local_fail };

const ProbeParse = enum { need_more, ok, fail, da1 };

const ProbeParser = struct {
    want_id: u32,
    buf: [1024]u8 = undefined,
    len: usize = 0,
    saw_ok: bool = false,
    saw_fail: bool = false,
    saw_da1: bool = false,

    fn result(self: ProbeParser) ProbeParse {
        if (self.saw_ok) return .ok;
        if (self.saw_fail) return .fail;
        if (self.saw_da1) return .da1;
        return .need_more;
    }

    fn feed(self: *ProbeParser, chunk: []const u8) ProbeParse {
        appendBuf(&self.buf, &self.len, chunk);
        var i: usize = 0;
        while (i < self.len) {
            if (self.buf[i] != 0x1b) {
                i += 1;
                continue;
            }
            if (i + 1 >= self.len) break;
            if (self.buf[i + 1] == '_') {
                const parsed = parseApc(self.buf[i..self.len]) orelse break;
                if (parsed.id) |id| {
                    if (id == self.want_id) {
                        if (parsed.ok) self.saw_ok = true else self.saw_fail = true;
                    }
                }
                i += parsed.len;
                continue;
            }
            if (self.buf[i + 1] == '[') {
                if (parseDa1(self.buf[i..self.len])) |n| {
                    self.saw_da1 = true;
                    i += n;
                    continue;
                }
            }
            i += 1;
        }
        if (i > 0) {
            const remain = self.len - i;
            std.mem.copyForwards(u8, self.buf[0..remain], self.buf[i..self.len]);
            self.len = remain;
        }
        return self.result();
    }
};

const ApcParse = struct {
    len: usize,
    id: ?u32,
    ok: bool,
};

const ShmObject = struct {
    name_buf: [shm_name_max + 1:0]u8 = [_:0]u8{0} ** (shm_name_max + 1),
    name_len: usize = 0,
    file: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } },
    map: ?[]align(std.heap.page_size_min) u8 = null,
    fd_open: bool = false,

    fn posixName(self: *const ShmObject) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn posixNameZ(self: *const ShmObject) [:0]const u8 {
        return self.name_buf[0..self.name_len :0];
    }

    fn unmap(self: *ShmObject) void {
        if (self.map) |m| {
            std.posix.munmap(m);
            self.map = null;
        }
    }

    fn closeFd(self: *ShmObject, io: std.Io) void {
        if (self.fd_open) {
            self.file.close(io);
            self.fd_open = false;
            self.file.handle = -1;
        }
    }

    fn unlink(self: *const ShmObject, io: std.Io) void {
        shmUnlinkName(io, self.posixNameZ().ptr);
    }

    fn destroy(self: *ShmObject, io: std.Io) void {
        self.unmap();
        self.closeFd(io);
        self.unlink(io);
    }
};

pub fn isImageFile(head_buf: []const u8) !bool {
    _ = zigimg.Image.detectFormatFromMemory(head_buf[0..]) catch return false;
    return true;
}

pub fn renderImage(alloc: std.mem.Allocator, io: std.Io, file: *std.Io.File, writer: *std.Io.Writer) !void {
    const stdout_tty = std.Io.File.stdout().isTty(io) catch false;
    const eligible = stdout_tty and shmAvailable();
    if (eligible and shm_support == .unknown) {
        probeShmSupport(io);
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var image_buf: [65536]u8 = undefined;
    var img = try zigimg.Image.fromFile(allocator, io, file.*, &image_buf);
    defer img.deinit(allocator);

    const original_width = img.width;
    const original_height = img.height;

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

    const max_pixel_w: f32 = @as(f32, @floatFromInt(ws_xpixel - ((ws_xpixel / ws_col) * 6)));
    const max_pixel_h: f32 = @as(f32, @floatFromInt(ws_ypixel - ((ws_ypixel / ws_row) * 3)));

    const img_w: f32 = @floatFromInt(original_width);
    const img_h: f32 = @floatFromInt(original_height);
    const scale_x: f32 = max_pixel_w / img_w;
    const scale_y: f32 = max_pixel_h / img_h;
    const scale: f32 = @min(scale_x, scale_y);

    const new_w: u32 = @intFromFloat(scale * img_w);
    const new_h: u32 = @intFromFloat(scale * img_h);

    try img.convert(allocator, .rgba32);

    if (new_w < original_width or new_h < original_height) {
        try resizeImage(allocator, &img, new_w, new_h);
    }

    const raw_bytes = std.mem.sliceAsBytes(img.pixels.rgba32);
    var byte_data = try std.ArrayList(u8).initCapacity(allocator, raw_bytes.len);
    defer byte_data.deinit(allocator);
    try byte_data.appendSlice(allocator, raw_bytes);

    {
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

    try writer.print("\n     ", .{});
    if (byte_data.items.len == 0) return;

    if (eligible and shm_support == .yes) {
        switch (try transmitShm(io, writer, byte_data.items, img.width, img.height)) {
            .sent => {},
            .local_fail => try writeDirectApc(allocator, writer, byte_data.items, img.width, img.height),
        }
    } else {
        try writeDirectApc(allocator, writer, byte_data.items, img.width, img.height);
    }
    try writer.print("\n\n", .{});
    try writer.flush();
}

fn shmAvailable() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd => true,
        else => false,
    };
}

fn resetShmSupportForTest() void {
    shm_support = .unknown;
    test_force_shm_create_error = null;
}

fn currentPid() u32 {
    return @intCast(std.posix.system.getpid());
}

fn formatShmName(buf: *[shm_name_max + 1:0]u8, pid: u32, rand: u32) [:0]u8 {
    const printed = std.fmt.bufPrintZ(buf, "/bc{x:0>8}{x:0>8}", .{ pid, rand }) catch unreachable;
    return printed;
}

fn linuxShmPath(posix_name: []const u8, path_buf: *[64]u8) ?[]const u8 {
    if (posix_name.len < 2 or posix_name[0] != '/') return null;
    return std.fmt.bufPrint(path_buf, "/dev/shm/{s}", .{posix_name[1..]}) catch null;
}

fn exclusiveCreate(name_z: [*:0]const u8) !std.posix.fd_t {
    switch (builtin.os.tag) {
        .linux => {
            var path_buf: [64]u8 = undefined;
            const path = linuxShmPath(std.mem.span(name_z), &path_buf) orelse return error.NameTooLong;
            return std.posix.openat(std.posix.AT.FDCWD, path, .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .EXCL = true,
                .CLOEXEC = true,
            }, 0o600);
        },
        .macos, .freebsd => {
            const flags: std.posix.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true };
            const rc = std.c.shm_open(name_z, @bitCast(flags), @as(std.c.mode_t, 0o600));
            if (rc < 0) {
                return switch (std.posix.errno(rc)) {
                    .EXIST => error.PathAlreadyExists,
                    .NOENT => error.FileNotFound,
                    .ACCES => error.AccessDenied,
                    else => error.ShmOpenFailed,
                };
            }
            return rc;
        },
        else => return error.ShmUnsupported,
    }
}

fn shmUnlinkName(io: std.Io, posix_name_z: [*:0]const u8) void {
    switch (builtin.os.tag) {
        .linux => {
            var path_buf: [64]u8 = undefined;
            const path = linuxShmPath(std.mem.span(posix_name_z), &path_buf) orelse return;
            std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        },
        .macos, .freebsd => {
            _ = std.c.shm_unlink(posix_name_z);
        },
        else => {},
    }
}

fn createShm(io: std.Io, data: []const u8) !ShmObject {
    if (builtin.is_test) {
        if (test_force_shm_create_error) |e| return e;
    }
    if (data.len == 0) return error.InvalidSize;
    if (!shmAvailable()) return error.ShmUnsupported;

    const pid = currentPid();
    var attempt: u8 = 0;
    while (attempt < shm_create_retries) : (attempt += 1) {
        var rand_buf: [4]u8 = undefined;
        io.random(&rand_buf);
        const rand = std.mem.readInt(u32, &rand_buf, .little);

        var name_buf: [shm_name_max + 1:0]u8 = [_:0]u8{0} ** (shm_name_max + 1);
        const name_z = formatShmName(&name_buf, pid, rand);

        const fd = exclusiveCreate(name_z.ptr) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };

        var obj = ShmObject{
            .name_buf = name_buf,
            .name_len = name_z.len,
            .file = .{ .handle = fd, .flags = .{ .nonblocking = false } },
            .fd_open = true,
        };
        errdefer obj.destroy(io);

        try obj.file.setLength(io, data.len);
        const map = try std.posix.mmap(
            null,
            data.len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        obj.map = map;
        @memcpy(map[0..data.len], data);
        return obj;
    }
    return error.PathAlreadyExists;
}

fn encodeNameB64(posix_name: []const u8, b64_buf: *[64]u8) []const u8 {
    const n = std.base64.standard.Encoder.calcSize(posix_name.len);
    std.debug.assert(n <= b64_buf.len);
    return std.base64.standard.Encoder.encode(b64_buf[0..n], posix_name);
}

fn writeDirectApc(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    compressed: []const u8,
    width: usize,
    height: usize,
) !void {
    if (compressed.len == 0) return;

    const out_len = std.base64.standard.Encoder.calcSize(compressed.len);
    var encoded = try std.ArrayList(u8).initCapacity(allocator, out_len);
    defer encoded.deinit(allocator);
    try encoded.resize(allocator, out_len);
    _ = std.base64.standard.Encoder.encode(encoded.items, compressed);

    const data = encoded.items;
    var start: usize = 0;
    while (start < data.len) {
        const end = @min(start + kitty_chunk_size, data.len);
        if (start == 0) {
            try writer.print("\x1B_Gf=32,o=z,s={d},v={d},a=T,q=2,m=1;{s}\x1B\\", .{ width, height, data[start..end] });
        } else {
            try writer.print("\x1B_Gq=2,m=1;{s}\x1B\\", .{data[start..end]});
        }
        start = end;
    }
    try writer.print("\x1B_Gq=2,m=0;\x1B\\", .{});
}

fn writeShmApc(
    writer: *std.Io.Writer,
    posix_name: []const u8,
    data_size: usize,
    width: usize,
    height: usize,
) !void {
    var b64_buf: [64]u8 = undefined;
    const b64 = encodeNameB64(posix_name, &b64_buf);
    try writer.print(
        "\x1B_Gf=32,o=z,s={d},v={d},a=T,q=2,t=s,S={d};{s}\x1B\\",
        .{ width, height, data_size, b64 },
    );
}

fn transmitShm(
    io: std.Io,
    writer: *std.Io.Writer,
    compressed: []const u8,
    width: usize,
    height: usize,
) !TransmitShm {
    var obj = createShm(io, compressed) catch return .local_fail;
    obj.unmap();
    obj.closeFd(io);
    errdefer obj.unlink(io);

    try writeShmApc(writer, obj.posixName(), compressed.len, width, height);
    try writer.flush();
    return .sent;
}

fn randomImageId(io: std.Io) u32 {
    while (true) {
        var buf: [4]u8 = undefined;
        io.random(&buf);
        const id = std.mem.readInt(u32, &buf, .little);
        if (id != 0) return id;
    }
}

fn feedTtyRead(fd: std.posix.fd_t, parser: *ProbeParser) bool {
    var tmp: [256]u8 = undefined;
    const n = std.posix.read(fd, &tmp) catch return false;
    if (n == 0) return false;
    _ = parser.feed(tmp[0..n]);
    return true;
}

/// icat DetectSupport: query on the controlling tty, wait for DA1, restore with TCSAFLUSH.
fn probeShmSupport(io: std.Io) void {
    shm_support = .no;
    if (!shmAvailable()) return;

    var dummy = createShm(io, &shm_dummy_rgb) catch return;
    dummy.unmap();
    dummy.closeFd(io);
    defer if (shm_support != .yes) dummy.unlink(io);

    const tty = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch return;
    defer tty.close(io);

    const saved = std.posix.tcgetattr(tty.handle) catch return;
    var term = saved;
    term.lflag.ICANON = false;
    term.lflag.ECHO = false;
    term.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    term.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(tty.handle, .NOW, term) catch return;
    defer std.posix.tcsetattr(tty.handle, .FLUSH, saved) catch {};

    const image_id = randomImageId(io);
    var b64_buf: [64]u8 = undefined;
    const b64 = encodeNameB64(dummy.posixName(), &b64_buf);
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "\x1b_Gi={d},s=1,v=1,a=q,t=s,f=24,S=3;{s}\x1b\\\x1b[c",
        .{ image_id, b64 },
    ) catch return;
    tty.writeStreamingAll(io, msg) catch return;

    var parser = ProbeParser{ .want_id = image_id };
    const timeout: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(shm_probe_timeout_ms),
        .clock = .awake,
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io, timeout);

    while (!parser.saw_da1) {
        const rem_ms = deadline.durationFromNow(io).raw.toMilliseconds();
        if (rem_ms <= 0) break;
        const poll_ms: i32 = @intCast(@min(rem_ms, @as(i64, shm_probe_timeout_ms)));
        var fds = [_]std.posix.pollfd{.{
            .fd = tty.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&fds, poll_ms) catch break;
        if (!feedTtyRead(tty.handle, &parser)) continue;
        while (feedTtyRead(tty.handle, &parser)) {}
    }
    while (feedTtyRead(tty.handle, &parser)) {}

    if (parser.saw_ok) shm_support = .yes;
}

fn appendBuf(buf: *[1024]u8, len: *usize, chunk: []const u8) void {
    if (len.* + chunk.len <= buf.len) {
        @memcpy(buf[len.*..][0..chunk.len], chunk);
        len.* += chunk.len;
        return;
    }
    const keep = buf.len / 2;
    if (len.* > keep) {
        std.mem.copyForwards(u8, buf[0..keep], buf[len.* - keep .. len.*]);
        len.* = keep;
    }
    const room = buf.len - len.*;
    const take = @min(chunk.len, room);
    @memcpy(buf[len.*..][0..take], chunk[chunk.len - take ..]);
    len.* += take;
}

fn parseI(control: []const u8) ?u32 {
    var rest = control;
    while (rest.len > 0) {
        if (rest.len >= 2 and rest[0] == 'i' and rest[1] == '=') {
            rest = rest[2..];
            var val: u32 = 0;
            var any = false;
            while (rest.len > 0 and rest[0] >= '0' and rest[0] <= '9') {
                any = true;
                val = val *% 10 + (rest[0] - '0');
                rest = rest[1..];
            }
            if (any) return val;
            return null;
        }
        if (std.mem.indexOfScalar(u8, rest, ',')) |idx| {
            rest = rest[idx + 1 ..];
        } else break;
    }
    return null;
}

fn parseApc(bytes: []const u8) ?ApcParse {
    if (bytes.len < 3) return null;
    if (bytes[0] != 0x1b or bytes[1] != '_' or bytes[2] != 'G') return null;
    const semi = std.mem.indexOfScalarPos(u8, bytes, 3, ';') orelse return null;
    var end: usize = semi + 1;
    while (end < bytes.len) : (end += 1) {
        if (bytes[end] == 0x07) {
            const payload = bytes[semi + 1 .. end];
            return .{
                .len = end + 1,
                .id = parseI(bytes[3..semi]),
                .ok = std.mem.eql(u8, payload, "OK"),
            };
        }
        if (bytes[end] == 0x1b) {
            if (end + 1 >= bytes.len) return null;
            if (bytes[end + 1] == '\\') {
                const payload = bytes[semi + 1 .. end];
                return .{
                    .len = end + 2,
                    .id = parseI(bytes[3..semi]),
                    .ok = std.mem.eql(u8, payload, "OK"),
                };
            }
        }
    }
    return null;
}

fn parseDa1(bytes: []const u8) ?usize {
    // icat: CSI payload starts with '?' and ends with 'c' (e.g. ?62;22;52c)
    if (bytes.len < 4) return null;
    if (bytes[0] != 0x1b or bytes[1] != '[' or bytes[2] != '?') return null;
    var i: usize = 3;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == 'c') return i + 1;
        const is_param = (c >= '0' and c <= '9') or c == ';';
        if (!is_param) return null;
    }
    return null;
}

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

fn decodeB64Payload(apc: []const u8) ![]u8 {
    const semi = std.mem.lastIndexOfScalar(u8, apc, ';') orelse return error.NoPayload;
    var end = apc.len;
    if (end >= 2 and apc[end - 2] == 0x1b and apc[end - 1] == '\\') {
        end -= 2;
    } else if (end >= 1 and apc[end - 1] == 0x07) {
        end -= 1;
    }
    const encoded = apc[semi + 1 .. end];
    const out_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const out = try std.testing.allocator.alloc(u8, out_len);
    try std.base64.standard.Decoder.decode(out, encoded);
    return out;
}

test "formatShmName Darwin limit" {
    var buf: [shm_name_max + 1:0]u8 = [_:0]u8{0} ** (shm_name_max + 1);
    const name = formatShmName(&buf, 0x00001a2b, 0x3c4d5e6f);
    try std.testing.expectEqual(@as(usize, 19), name.len);
    try std.testing.expect(name.len <= 31);
    try std.testing.expectEqual(@as(u8, '/'), name[0]);
    try std.testing.expect(std.mem.indexOfScalar(u8, name[1..], '/') == null);
    try std.testing.expectEqualStrings("/bc00001a2b3c4d5e6f", name);
}

test "writeDirectApc framing" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const payload = "abc";
    try writeDirectApc(std.testing.allocator, &aw.writer, payload, 2, 3);
    const out = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b_Gf=32,o=z,s=2,v=3,a=T,q=2,m=1;"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b_Gq=2,m=0;\x1b\\"));
    try std.testing.expect(std.mem.indexOf(u8, out, "t=s") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gm=1;") == null);
}

test "writeDirectApc empty writes nothing" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeDirectApc(std.testing.allocator, &aw.writer, &.{}, 1, 1);
    try std.testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "writeDirectApc chunks at 4096" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const raw = [_]u8{0xaa} ** 4000;
    try writeDirectApc(std.testing.allocator, &aw.writer, &raw, 10, 10);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gq=2,m=1;") != null);
    var it = std.mem.splitSequence(u8, out, "\x1b_");
    _ = it.next();
    while (it.next()) |frame| {
        const body_end = std.mem.indexOfScalar(u8, frame, ';') orelse continue;
        const payload = frame[body_end + 1 ..];
        const payload_only = if (payload.len >= 2 and payload[payload.len - 2] == 0x1b)
            payload[0 .. payload.len - 2]
        else
            payload;
        try std.testing.expect(payload_only.len <= kitty_chunk_size);
    }
}

test "writeShmApc framing" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const name = "/bc0000000100000002";
    try writeShmApc(&aw.writer, name, 12, 4, 5);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "t=s") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "o=z") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "S=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "m=") == null);
    const decoded = try decodeB64Payload(out);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(name, decoded);
}

test "probe parser OK APC" {
    var p = ProbeParser{ .want_id = 31 };
    try std.testing.expectEqual(ProbeParse.ok, p.feed("\x1b_Gi=31;OK\x1b\\"));
}

test "probe parser fail APC" {
    var p = ProbeParser{ .want_id = 31 };
    try std.testing.expectEqual(ProbeParse.fail, p.feed("\x1b_Gi=31;EINVAL: invalid data\x1b\\"));
}

test "probe parser DA1" {
    var p = ProbeParser{ .want_id = 1 };
    try std.testing.expectEqual(ProbeParse.da1, p.feed("\x1b[?1;0c"));
}

test "probe parser split frames" {
    var p = ProbeParser{ .want_id = 7 };
    try std.testing.expectEqual(ProbeParse.need_more, p.feed("\x1b_Gi=7;O"));
    try std.testing.expectEqual(ProbeParse.ok, p.feed("K\x1b\\"));
}

test "probe parser ignores unmatched i=" {
    var p = ProbeParser{ .want_id = 2 };
    try std.testing.expectEqual(ProbeParse.need_more, p.feed("\x1b_Gi=99;OK\x1b\\"));
    try std.testing.expectEqual(ProbeParse.ok, p.feed("\x1b_Gi=2;OK\x1b\\"));
}

test "probe parser BEL terminator" {
    var p = ProbeParser{ .want_id = 4 };
    try std.testing.expectEqual(ProbeParse.ok, p.feed("\x1b_Gi=4;OK\x07"));
}

test "probe parser kitty OK plus DA1" {
    var p = ProbeParser{ .want_id = 3073211871 };
    _ = p.feed("\x1b_Gi=3073211871;OK\x1b\\\x1b[?62;22;52c");
    try std.testing.expect(p.saw_ok);
    try std.testing.expect(p.saw_da1);
}

test "createShm empty is InvalidSize" {
    resetShmSupportForTest();
    try std.testing.expectError(error.InvalidSize, createShm(std.testing.io, &.{}));
}

test "create-fail returns local_fail then direct" {
    resetShmSupportForTest();
    test_force_shm_create_error = error.FileNotFound;
    defer resetShmSupportForTest();

    const io = std.testing.io;
    try std.testing.expectEqual(TransmitShm.local_fail, try transmitShm(io, undefined, "zlib", 1, 1));

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeDirectApc(std.testing.allocator, &aw.writer, "zlib", 1, 1);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "t=s") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a=T") != null);
}

test "write-fail does not fall back to direct" {
    resetShmSupportForTest();
    if (!shmAvailable()) return error.SkipZigTest;

    var failing: std.Io.Writer = .failing;
    const result = transmitShm(std.testing.io, &failing, "zlib-bytes", 2, 2);
    try std.testing.expectError(error.WriteFailed, result);
}

test "local shm round-trip" {
    resetShmSupportForTest();
    if (!shmAvailable()) return error.SkipZigTest;

    const io = std.testing.io;
    const payload = "hello-shm-payload";
    var obj = createShm(io, payload) catch return error.SkipZigTest;
    defer obj.destroy(io);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeShmApc(&aw.writer, obj.posixName(), payload.len, 1, 1);
    const decoded_name = try decodeB64Payload(aw.written());
    defer std.testing.allocator.free(decoded_name);
    try std.testing.expectEqualStrings(obj.posixName(), decoded_name);

    obj.unmap();
    const map = try std.posix.mmap(
        null,
        payload.len,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        obj.file.handle,
        0,
    );
    defer std.posix.munmap(map);
    try std.testing.expectEqualStrings(payload, map[0..payload.len]);
}
