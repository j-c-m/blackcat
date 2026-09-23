const std = @import("std");
const builtin = @import("builtin");
const zigimg = @import("zigimg");

const kitty_chunk_size = 4096;
const animation_rgba_cap: usize = 320 << 20;
const zero_delay_gap_ms: u32 = 100;
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

// f=24 is packed RGB. f=32 is packed RGBA. Opaque pixels use f=24.
const KittyFormat = enum(u8) {
    rgb = 24,
    rgba = 32,
};

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

    const fit = fitToWindow(img.width, img.height);
    const placed = placedSize(img.width, img.height, fit);

    try writer.print("\n     ", .{});
    if (img.animation.frames.items.len > 1 and animationFits(placed.width, placed.height, img.animation.frames.items.len)) {
        try transmitAnimation(allocator, io, writer, &img, placed, eligible);
    } else {
        try transmitStill(allocator, io, writer, &img, fit, eligible);
    }
    try writer.print("\n\n", .{});
    try writer.flush();
}

const Fit = struct {
    width: u32,
    height: u32,
};

const Placed = struct {
    width: u32,
    height: u32,
    shrink: bool,
};

// fitToWindow is the largest size that fits. Images smaller than that stay
// at their native size, matching the still-image path.
fn placedSize(src_w: usize, src_h: usize, fit: Fit) Placed {
    const shrink = fit.width < src_w or fit.height < src_h;
    if (!shrink) {
        return .{
            .width = std.math.cast(u32, src_w) orelse 0,
            .height = std.math.cast(u32, src_h) orelse 0,
            .shrink = false,
        };
    }
    return .{ .width = fit.width, .height = fit.height, .shrink = true };
}

fn fitToWindow(original_width: usize, original_height: usize) Fit {
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
    const scale: f32 = @min(max_pixel_w / img_w, max_pixel_h / img_h);

    return .{
        .width = @intFromFloat(scale * img_w),
        .height = @intFromFloat(scale * img_h),
    };
}

fn animationFits(width: u32, height: u32, frame_count: usize) bool {
    if (frame_count < 2 or width == 0 or height == 0) return false;
    const pixels = std.math.mul(usize, width, height) catch return false;
    const frame_bytes = std.math.mul(usize, pixels, 4) catch return false;
    if (frame_bytes == 0) return false;
    return frame_count <= animation_rgba_cap / frame_bytes;
}

// Kitty treats a gap of 0 as unset. A GIF delay of 0 is shown for 100 ms.
fn gapMs(duration_s: f32) u32 {
    if (!(duration_s > 0)) return zero_delay_gap_ms;
    const ms = @round(duration_s * 1000.0);
    if (ms < 1) return 1;
    const max: f32 = @floatFromInt(std.math.maxInt(u32));
    if (ms > max) return std.math.maxInt(u32);
    return @intFromFloat(ms);
}

// v=1 loops forever. Any other v plays v-1 loops.
fn kittyLoopCount(loop_count: i32) u32 {
    if (loop_count < 0) return 1;
    if (loop_count == 0) return 2;
    return @as(u32, @intCast(loop_count)) + 1;
}

const WirePixels = union(KittyFormat) {
    rgb: []zigimg.color.Rgb24,
    rgba: []zigimg.color.Rgba32,
};

const PreparedFrame = struct {
    pixels: WirePixels,
    owned: bool,
    gap_ms: u32,

    fn bytes(self: PreparedFrame) []const u8 {
        return switch (self.pixels) {
            .rgb => |p| std.mem.sliceAsBytes(p),
            .rgba => |p| std.mem.sliceAsBytes(p),
        };
    }

    fn free(self: PreparedFrame, alloc: std.mem.Allocator) void {
        switch (self.pixels) {
            .rgb => |p| alloc.free(p),
            .rgba => |p| alloc.free(p),
        }
    }
};

fn prepareFrames(
    alloc: std.mem.Allocator,
    img: *const zigimg.Image,
    placed: Placed,
) ![]PreparedFrame {
    const frames = img.animation.frames.items;
    var format: KittyFormat = .rgb;
    for (frames) |frame| {
        if (try storageNeedsAlpha(alloc, frame.pixels, img.width, img.height)) {
            format = .rgba;
            break;
        }
    }

    const prepared = try alloc.alloc(PreparedFrame, frames.len);
    errdefer alloc.free(prepared);
    var filled: usize = 0;
    errdefer {
        for (prepared[0..filled]) |frame| {
            if (frame.owned) frame.free(alloc);
        }
    }

    for (frames) |frame| {
        const wire = try frameWire(alloc, frame.pixels, img.width, img.height, placed, format);
        prepared[filled] = .{
            .pixels = wire.pixels,
            .owned = wire.owned,
            .gap_ms = gapMs(frame.duration),
        };
        filled += 1;
    }
    return prepared;
}

fn frameRgba(
    alloc: std.mem.Allocator,
    storage: zigimg.color.PixelStorage,
    width: usize,
    height: usize,
) !struct { pixels: []zigimg.color.Rgba32, owned: bool } {
    const expected = std.math.mul(usize, width, height) catch return error.InvalidData;
    if (storage == .rgba32) {
        if (storage.rgba32.len != expected) return error.InvalidData;
        return .{ .pixels = storage.rgba32, .owned = false };
    }

    var converted = zigimg.PixelFormatConverter.convert(alloc, &storage, .rgba32) catch return error.InvalidData;
    if (converted != .rgba32 or converted.rgba32.len != expected) {
        converted.deinit(alloc);
        return error.InvalidData;
    }
    const pixels = converted.rgba32;
    converted = .{ .invalid = {} };
    return .{ .pixels = pixels, .owned = true };
}

fn frameRgb(
    alloc: std.mem.Allocator,
    storage: zigimg.color.PixelStorage,
    width: usize,
    height: usize,
) !struct { pixels: []zigimg.color.Rgb24, owned: bool } {
    const expected = std.math.mul(usize, width, height) catch return error.InvalidData;
    switch (storage) {
        .rgb24 => |px| {
            if (px.len != expected) return error.InvalidData;
            return .{ .pixels = px, .owned = false };
        },
        .rgba32 => |px| {
            if (px.len != expected or !allOpaque(px)) return error.InvalidData;
            return .{ .pixels = try packRgb(alloc, px), .owned = true };
        },
        else => {
            var converted = zigimg.PixelFormatConverter.convert(alloc, &storage, .rgba32) catch return error.InvalidData;
            defer converted.deinit(alloc);
            if (converted != .rgba32 or converted.rgba32.len != expected or !allOpaque(converted.rgba32)) {
                return error.InvalidData;
            }
            return .{ .pixels = try packRgb(alloc, converted.rgba32), .owned = true };
        },
    }
}

fn frameWire(
    alloc: std.mem.Allocator,
    storage: zigimg.color.PixelStorage,
    width: usize,
    height: usize,
    placed: Placed,
    format: KittyFormat,
) !struct { pixels: WirePixels, owned: bool } {
    switch (format) {
        .rgba => {
            const source = try frameRgba(alloc, storage, width, height);
            errdefer if (source.owned) alloc.free(source.pixels);
            if (!placed.shrink) return .{ .pixels = .{ .rgba = source.pixels }, .owned = source.owned };
            const scaled = try resizeChannels(alloc, zigimg.color.Rgba32, source.pixels, width, height, placed.width, placed.height);
            if (source.owned) alloc.free(source.pixels);
            return .{ .pixels = .{ .rgba = scaled }, .owned = true };
        },
        .rgb => {
            const source = try frameRgb(alloc, storage, width, height);
            errdefer if (source.owned) alloc.free(source.pixels);
            if (!placed.shrink) return .{ .pixels = .{ .rgb = source.pixels }, .owned = source.owned };
            const scaled = try resizeChannels(alloc, zigimg.color.Rgb24, source.pixels, width, height, placed.width, placed.height);
            if (source.owned) alloc.free(source.pixels);
            return .{ .pixels = .{ .rgb = scaled }, .owned = true };
        },
    }
}

fn storageNeedsAlpha(
    alloc: std.mem.Allocator,
    storage: zigimg.color.PixelStorage,
    width: usize,
    height: usize,
) !bool {
    const expected = std.math.mul(usize, width, height) catch return error.InvalidData;
    switch (storage) {
        .rgb24 => |px| {
            if (px.len != expected) return error.InvalidData;
            return false;
        },
        .rgba32 => |px| {
            if (px.len != expected) return error.InvalidData;
            return !allOpaque(px);
        },
        else => {
            var converted = zigimg.PixelFormatConverter.convert(alloc, &storage, .rgba32) catch return error.InvalidData;
            defer converted.deinit(alloc);
            if (converted != .rgba32 or converted.rgba32.len != expected) return error.InvalidData;
            return !allOpaque(converted.rgba32);
        },
    }
}

fn allOpaque(pixels: []const zigimg.color.Rgba32) bool {
    for (pixels) |px| {
        if (px.a != 255) return false;
    }
    return true;
}

fn packRgb(alloc: std.mem.Allocator, src: []const zigimg.color.Rgba32) ![]zigimg.color.Rgb24 {
    const dst = try alloc.alloc(zigimg.color.Rgb24, src.len);
    for (src, dst) |px, *out| {
        out.* = .{ .r = px.r, .g = px.g, .b = px.b };
    }
    return dst;
}

fn selectWireFormat(alloc: std.mem.Allocator, img: *zigimg.Image) !KittyFormat {
    const expected = std.math.mul(usize, img.width, img.height) catch return error.InvalidData;
    switch (img.pixelFormat()) {
        .rgb24 => {
            if (img.pixels.rgb24.len != expected) return error.InvalidData;
            return .rgb;
        },
        .rgba32 => return rgbaWireFormat(alloc, img, expected),
        else => {
            try img.convert(alloc, .rgba32);
            return rgbaWireFormat(alloc, img, expected);
        },
    }
}

fn rgbaWireFormat(alloc: std.mem.Allocator, img: *zigimg.Image, expected: usize) !KittyFormat {
    if (img.pixelFormat() != .rgba32 or img.pixels.rgba32.len != expected) return error.InvalidData;
    if (!allOpaque(img.pixels.rgba32)) return .rgba;
    const rgb = try packRgb(alloc, img.pixels.rgba32);
    alloc.free(img.pixels.rgba32);
    img.pixels = .{ .rgb24 = rgb };
    return .rgb;
}

fn transmitStill(
    alloc: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    img: *zigimg.Image,
    fit: Fit,
    eligible: bool,
) !void {
    const format = try selectWireFormat(alloc, img);

    if (fit.width < img.width or fit.height < img.height) {
        try resizeImage(alloc, img, fit.width, fit.height);
    }

    const raw_bytes = switch (format) {
        .rgb => std.mem.sliceAsBytes(img.pixels.rgb24),
        .rgba => std.mem.sliceAsBytes(img.pixels.rgba32),
    };
    if (raw_bytes.len == 0) return;

    var used_shm = false;
    if (eligible and shm_support == .yes) {
        used_shm = switch (try transmitShm(io, writer, raw_bytes, img.width, img.height, format)) {
            .sent => true,
            .local_fail => false,
        };
    }
    if (!used_shm) {
        var compressed = try compressZlib(alloc, raw_bytes);
        defer compressed.deinit(alloc);
        try writeDirectApc(alloc, writer, compressed.items, img.width, img.height, format);
    }
}

fn transmitAnimation(
    alloc: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    img: *const zigimg.Image,
    placed: Placed,
    eligible: bool,
) !void {
    const prepared = try prepareFrames(alloc, img, placed);
    defer {
        for (prepared) |frame| {
            if (frame.owned) frame.free(alloc);
        }
        alloc.free(prepared);
    }
    if (prepared.len == 0) return;

    const image_number = randomImageId(io);
    const loops = kittyLoopCount(img.animation.loop_count);
    const use_shm = eligible and shm_support == .yes;

    const format = std.meta.activeTag(prepared[0].pixels);
    for (prepared, 0..) |frame, index| {
        const raw_bytes = frame.bytes();
        const root = index == 0;
        var used_shm = false;
        if (use_shm) {
            used_shm = switch (try transmitFrameShm(io, writer, raw_bytes, placed.width, placed.height, image_number, if (root) null else frame.gap_ms, format)) {
                .sent => true,
                .local_fail => false,
            };
        }
        if (!used_shm) {
            var compressed = try compressZlib(alloc, raw_bytes);
            defer compressed.deinit(alloc);
            try writeFrameDirect(alloc, writer, compressed.items, placed.width, placed.height, image_number, if (root) null else frame.gap_ms, format);
        }

        if (index == 0) {
            try writer.print(
                "\x1B_Ga=a,I={d},r=1,z={d},v={d},q=2;\x1B\\",
                .{ image_number, frame.gap_ms, loops },
            );
        } else if (index == 1) {
            try writer.print("\x1B_Ga=a,I={d},s=2,q=2;\x1B\\", .{image_number});
        }
    }
    try writer.print("\x1B_Ga=a,I={d},s=3,q=2;\x1B\\", .{image_number});
}

fn compressZlib(allocator: std.mem.Allocator, raw: []const u8) !std.ArrayList(u8) {
    // flate.Compress requires the output buffer to be longer than 8 bytes.
    var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, @max(raw.len, 16));
    errdefer compressed.deinit();

    var deflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(
        &compressed.writer,
        &deflate_buffer,
        .zlib,
        .fastest,
    );

    try compress.writer.writeAll(raw);
    try compress.finish();
    return compressed.toArrayList();
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
    format: KittyFormat,
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
            try writer.print("\x1B_Gf={d},o=z,s={d},v={d},a=T,q=2,m=1;{s}\x1B\\", .{ @intFromEnum(format), width, height, data[start..end] });
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
    format: KittyFormat,
) !void {
    var b64_buf: [64]u8 = undefined;
    const b64 = encodeNameB64(posix_name, &b64_buf);
    try writer.print(
        "\x1B_Gf={d},s={d},v={d},a=T,q=2,t=s,S={d};{s}\x1B\\",
        .{ @intFromEnum(format), width, height, data_size, b64 },
    );
}

fn writeFrameDirect(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    compressed: []const u8,
    width: u32,
    height: u32,
    image_number: u32,
    gap_ms: ?u32,
    format: KittyFormat,
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
            if (gap_ms) |gap| {
                try writer.print(
                    "\x1B_Gf={d},o=z,s={d},v={d},a=f,I={d},z={d},q=2,m=1;{s}\x1B\\",
                    .{ @intFromEnum(format), width, height, image_number, gap, data[start..end] },
                );
            } else {
                try writer.print(
                    "\x1B_Gf={d},o=z,s={d},v={d},a=T,I={d},q=2,m=1;{s}\x1B\\",
                    .{ @intFromEnum(format), width, height, image_number, data[start..end] },
                );
            }
        } else if (gap_ms != null) {
            try writer.print("\x1B_Ga=f,q=2,m=1;{s}\x1B\\", .{data[start..end]});
        } else {
            try writer.print("\x1B_Gq=2,m=1;{s}\x1B\\", .{data[start..end]});
        }
        start = end;
    }
    if (gap_ms != null) {
        try writer.print("\x1B_Ga=f,q=2,m=0;\x1B\\", .{});
    } else {
        try writer.print("\x1B_Gq=2,m=0;\x1B\\", .{});
    }
}

fn transmitFrameShm(
    io: std.Io,
    writer: *std.Io.Writer,
    pixels: []const u8,
    width: u32,
    height: u32,
    image_number: u32,
    gap_ms: ?u32,
    format: KittyFormat,
) !TransmitShm {
    var obj = createShm(io, pixels) catch return .local_fail;
    obj.unmap();
    obj.closeFd(io);
    errdefer obj.unlink(io);

    var b64_buf: [64]u8 = undefined;
    const b64 = encodeNameB64(obj.posixName(), &b64_buf);
    if (gap_ms) |gap| {
        try writer.print(
            "\x1B_Gf={d},s={d},v={d},a=f,I={d},z={d},q=2,t=s,S={d};{s}\x1B\\",
            .{ @intFromEnum(format), width, height, image_number, gap, pixels.len, b64 },
        );
    } else {
        try writer.print(
            "\x1B_Gf={d},s={d},v={d},a=T,I={d},q=2,t=s,S={d};{s}\x1B\\",
            .{ @intFromEnum(format), width, height, image_number, pixels.len, b64 },
        );
    }
    try writer.flush();
    return .sent;
}

fn transmitShm(
    io: std.Io,
    writer: *std.Io.Writer,
    pixels: []const u8,
    width: usize,
    height: usize,
    format: KittyFormat,
) !TransmitShm {
    var obj = createShm(io, pixels) catch return .local_fail;
    obj.unmap();
    obj.closeFd(io);
    errdefer obj.unlink(io);

    try writeShmApc(writer, obj.posixName(), pixels.len, width, height, format);
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
    if (new_w == img.width and new_h == img.height) return;

    switch (img.pixelFormat()) {
        .rgb24 => {
            const scaled = try resizeChannels(alloc, zigimg.color.Rgb24, img.pixels.rgb24, img.width, img.height, new_w, new_h);
            alloc.free(img.pixels.rgb24);
            img.pixels = .{ .rgb24 = scaled };
        },
        .rgba32 => {
            const scaled = try resizeChannels(alloc, zigimg.color.Rgba32, img.pixels.rgba32, img.width, img.height, new_w, new_h);
            alloc.free(img.pixels.rgba32);
            img.pixels = .{ .rgba32 = scaled };
        },
        else => return error.InvalidData,
    }
    img.width = new_w;
    img.height = new_h;
}

fn resizeChannels(
    alloc: std.mem.Allocator,
    comptime Pixel: type,
    src: []const Pixel,
    src_w: usize,
    src_h: usize,
    new_w: u32,
    new_h: u32,
) ![]Pixel {
    const img_w_f: f32 = @floatFromInt(src_w);
    const img_h_f: f32 = @floatFromInt(src_h);
    const new_w_f: f32 = @floatFromInt(new_w);
    const new_h_f: f32 = @floatFromInt(new_h);

    const new_pixels = try alloc.alloc(Pixel, @as(usize, new_w) * @as(usize, new_h));

    for (0..new_h) |y| {
        const sy = @as(f32, @floatFromInt(y)) * img_h_f / new_h_f;
        const y0: usize = @intFromFloat(@floor(sy));
        const y1 = @min(y0 + 1, src_h - 1);
        const dy = sy - @floor(sy);

        for (0..new_w) |x| {
            const sx = @as(f32, @floatFromInt(x)) * img_w_f / new_w_f;
            const x0: usize = @intFromFloat(@floor(sx));
            const x1 = @min(x0 + 1, src_w - 1);
            const dx = sx - @floor(sx);

            const p00 = src[y0 * src_w + x0];
            const p01 = src[y0 * src_w + x1];
            const p10 = src[y1 * src_w + x0];
            const p11 = src[y1 * src_w + x1];

            var px: Pixel = .{
                .r = lerp8(p00.r, p01.r, p10.r, p11.r, dx, dy),
                .g = lerp8(p00.g, p01.g, p10.g, p11.g, dx, dy),
                .b = lerp8(p00.b, p01.b, p10.b, p11.b, dx, dy),
            };
            if (@hasField(Pixel, "a")) {
                px.a = lerp8(p00.a, p01.a, p10.a, p11.a, dx, dy);
            }
            new_pixels[y * new_w + x] = px;
        }
    }

    return new_pixels;
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
    try writeDirectApc(std.testing.allocator, &aw.writer, payload, 2, 3, .rgba);
    const out = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b_Gf=32,o=z,s=2,v=3,a=T,q=2,m=1;"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b_Gq=2,m=0;\x1b\\"));
    try std.testing.expect(std.mem.indexOf(u8, out, "t=s") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gm=1;") == null);
}

test "writeDirectApc empty writes nothing" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeDirectApc(std.testing.allocator, &aw.writer, &.{}, 1, 1, .rgba);
    try std.testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "writeDirectApc chunks at 4096" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const raw = [_]u8{0xaa} ** 4000;
    try writeDirectApc(std.testing.allocator, &aw.writer, &raw, 10, 10, .rgba);
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
    try writeShmApc(&aw.writer, name, 12, 4, 5, .rgba);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "t=s") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "o=z") == null);
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
    try std.testing.expectEqual(TransmitShm.local_fail, try transmitShm(io, undefined, "zlib", 1, 1, .rgba));

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeDirectApc(std.testing.allocator, &aw.writer, "zlib", 1, 1, .rgba);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "t=s") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a=T") != null);
}

test "write-fail does not fall back to direct" {
    resetShmSupportForTest();
    if (!shmAvailable()) return error.SkipZigTest;

    var failing: std.Io.Writer = .failing;
    const result = transmitShm(std.testing.io, &failing, "zlib-bytes", 2, 2, .rgba);
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
    try writeShmApc(&aw.writer, obj.posixName(), payload.len, 1, 1, .rgba);
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

test "jpeg 4:2:0 restart interval" {
    const bytes = @embedFile("fixtures/restart-420.jpg");
    var img = try zigimg.Image.fromMemory(std.testing.allocator, bytes);
    defer img.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 32), img.width);
    try std.testing.expectEqual(@as(usize, 32), img.height);
    try img.convert(std.testing.allocator, .rgba32);

    const px = img.pixels.rgba32;
    try expectRgb(px[4 * img.width + 4], 254, 0, 0);
    try expectRgb(px[4 * img.width + 20], 0, 255, 1);
    try expectRgb(px[20 * img.width + 4], 0, 0, 254);
    try expectRgb(px[20 * img.width + 20], 255, 255, 255);
}

test "animation gap and loop" {
    try std.testing.expectEqual(@as(u32, 100), gapMs(0));
    try std.testing.expectEqual(@as(u32, 100), gapMs(-1));
    try std.testing.expectEqual(@as(u32, 40), gapMs(0.04));
    try std.testing.expectEqual(@as(u32, 50), gapMs(0.05));
    try std.testing.expectEqual(@as(u32, 1), kittyLoopCount(-1));
    try std.testing.expectEqual(@as(u32, 2), kittyLoopCount(0));
    try std.testing.expectEqual(@as(u32, 4), kittyLoopCount(3));
}

test "animation does not scale up" {
    const fit = Fit{ .width = 560, .height = 420 };
    const placed = placedSize(200, 150, fit);
    try std.testing.expectEqual(@as(u32, 200), placed.width);
    try std.testing.expectEqual(@as(u32, 150), placed.height);
    try std.testing.expect(!placed.shrink);

    const shrunk = placedSize(800, 600, Fit{ .width = 400, .height = 300 });
    try std.testing.expect(shrunk.shrink);
    try std.testing.expectEqual(@as(u32, 400), shrunk.width);
    try std.testing.expectEqual(@as(u32, 300), shrunk.height);
}

test "animation byte cap" {
    try std.testing.expect(animationFits(800, 335, 115));
    try std.testing.expect(!animationFits(800, 335, 400));
    try std.testing.expect(!animationFits(0, 10, 2));
    try std.testing.expect(!animationFits(10, 10, 1));
}

test "animation frame commands" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeFrameDirect(std.testing.allocator, &aw.writer, "rgba", 2, 2, 7, null, .rgba);
    try writeFrameDirect(std.testing.allocator, &aw.writer, "rgba", 2, 2, 7, 40, .rgba);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "a=T,I=7,q=2,m=1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a=f,I=7,z=40,q=2,m=1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Ga=f,q=2,m=0;\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "t=s") == null);
}

test "two-frame gif keeps both frames" {
    const bytes = @embedFile("fixtures/anim-2x2.gif");
    var img = try zigimg.Image.fromMemory(std.testing.allocator, bytes);
    defer img.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), img.width);
    try std.testing.expectEqual(@as(usize, 2), img.height);
    try std.testing.expectEqual(@as(usize, 2), img.animation.frames.items.len);
    try std.testing.expectEqual(@as(i32, -1), img.animation.loop_count);
    try std.testing.expectEqual(@as(u32, 40), gapMs(img.animation.frames.items[0].duration));
    try std.testing.expectEqual(@as(u32, 40), gapMs(img.animation.frames.items[1].duration));
}

fn expectRgb(pixel: zigimg.color.Rgba32, r: u8, g: u8, b: u8) !void {
    try std.testing.expectEqual(r, pixel.r);
    try std.testing.expectEqual(g, pixel.g);
    try std.testing.expectEqual(b, pixel.b);
    try std.testing.expectEqual(@as(u8, 255), pixel.a);
}

const no_shrink = Fit{ .width = 4000, .height = 4000 };

fn directPixelPayloads(text: []const u8) ![][]u8 {
    const alloc = std.testing.allocator;
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| alloc.free(item);
        list.deinit(alloc);
    }

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "\x1b_G")) |pos| {
        const semi = std.mem.indexOfScalarPos(u8, text, pos, ';') orelse break;
        const end = std.mem.indexOfPos(u8, text, semi, "\x1b\\") orelse break;
        const control = text[pos..semi];
        const encoded = text[semi + 1 .. end];
        i = end + 2;
        if (encoded.len == 0) continue;
        if (std.mem.indexOf(u8, control, "o=z") == null) continue;
        const compressed = try decodeB64Slice(encoded);
        defer alloc.free(compressed);
        try list.append(alloc, try inflateZlib(compressed));
    }
    return list.toOwnedSlice(alloc);
}

fn freePayloads(payloads: [][]u8) void {
    for (payloads) |item| std.testing.allocator.free(item);
    std.testing.allocator.free(payloads);
}

fn decodeB64Slice(encoded: []const u8) ![]u8 {
    const out_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const out = try std.testing.allocator.alloc(u8, out_len);
    errdefer std.testing.allocator.free(out);
    try std.base64.standard.Decoder.decode(out, encoded);
    return out;
}

fn inflateZlib(compressed: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    return decompress.reader.allocRemaining(std.testing.allocator, .limited(8 << 20));
}

fn countLiteral(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| {
        n += 1;
        i = pos + needle.len;
    }
    return n;
}

test "opaque rgb sends f=24" {
    const alloc = std.testing.allocator;
    var img = try zigimg.Image.create(alloc, 2, 2, .rgb24);
    defer img.deinit(alloc);
    const px = [_]zigimg.color.Rgb24{
        .{ .r = 10, .g = 20, .b = 30 },
        .{ .r = 40, .g = 50, .b = 60 },
        .{ .r = 70, .g = 80, .b = 90 },
        .{ .r = 1, .g = 2, .b = 3 },
    };
    @memcpy(img.pixels.rgb24, &px);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try transmitStill(alloc, std.testing.io, &aw.writer, &img, no_shrink, false);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gf=24,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gf=32,") == null);

    const payloads = try directPixelPayloads(out);
    defer freePayloads(payloads);
    try std.testing.expectEqual(@as(usize, 1), payloads.len);
    try std.testing.expectEqual(@as(usize, 12), payloads[0].len);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&px), payloads[0]);
}

test "opaque rgba sends f=24" {
    const alloc = std.testing.allocator;
    var img = try zigimg.Image.create(alloc, 2, 2, .rgba32);
    defer img.deinit(alloc);
    const px = [_]zigimg.color.Rgba32{
        .{ .r = 10, .g = 20, .b = 30, .a = 255 },
        .{ .r = 40, .g = 50, .b = 60, .a = 255 },
        .{ .r = 70, .g = 80, .b = 90, .a = 255 },
        .{ .r = 1, .g = 2, .b = 3, .a = 255 },
    };
    @memcpy(img.pixels.rgba32, &px);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try transmitStill(alloc, std.testing.io, &aw.writer, &img, no_shrink, false);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gf=24,") != null);

    const payloads = try directPixelPayloads(out);
    defer freePayloads(payloads);
    try std.testing.expectEqual(@as(usize, 12), payloads[0].len);
    const expect = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 1, 2, 3 };
    try std.testing.expectEqualSlices(u8, &expect, payloads[0]);
}

test "partial alpha sends f=32" {
    const alloc = std.testing.allocator;
    var img = try zigimg.Image.create(alloc, 2, 2, .rgba32);
    defer img.deinit(alloc);
    @memset(img.pixels.rgba32, .{ .r = 1, .g = 2, .b = 3, .a = 255 });
    img.pixels.rgba32[0].a = 0;
    img.pixels.rgba32[3].a = 128;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try transmitStill(alloc, std.testing.io, &aw.writer, &img, no_shrink, false);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gf=32,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gf=24,") == null);

    const payloads = try directPixelPayloads(out);
    defer freePayloads(payloads);
    try std.testing.expectEqual(@as(usize, 16), payloads[0].len);
    try std.testing.expectEqual(@as(u8, 0), payloads[0][3]);
    try std.testing.expectEqual(@as(u8, 128), payloads[0][15]);
}

test "grayscale sends f=24" {
    const alloc = std.testing.allocator;
    var img = try zigimg.Image.create(alloc, 1, 1, .grayscale8);
    defer img.deinit(alloc);
    img.pixels.grayscale8[0] = .{ .value = 40 };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try transmitStill(alloc, std.testing.io, &aw.writer, &img, no_shrink, false);
    const payloads = try directPixelPayloads(aw.written());
    defer freePayloads(payloads);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b_Gf=24,") != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 40, 40, 40 }, payloads[0]);
}

test "resized opaque image sends f=24" {
    const alloc = std.testing.allocator;
    var img = try zigimg.Image.create(alloc, 4, 4, .rgb24);
    defer img.deinit(alloc);
    @memset(img.pixels.rgb24, .{ .r = 11, .g = 22, .b = 33 });

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try transmitStill(alloc, std.testing.io, &aw.writer, &img, .{ .width = 2, .height = 2 }, false);
    const payloads = try directPixelPayloads(aw.written());
    defer freePayloads(payloads);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b_Gf=24,") != null);
    try std.testing.expectEqual(@as(usize, 12), payloads[0].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 11, 22, 33 }, payloads[0][0..3]);
}

test "jpeg restart fixture sends f=24" {
    const alloc = std.testing.allocator;
    const bytes = @embedFile("fixtures/restart-420.jpg");
    var img = try zigimg.Image.fromMemory(alloc, bytes);
    defer img.deinit(alloc);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try transmitStill(alloc, std.testing.io, &aw.writer, &img, no_shrink, false);
    const payloads = try directPixelPayloads(aw.written());
    defer freePayloads(payloads);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b_Gf=24,") != null);
    try std.testing.expectEqual(@as(usize, 32 * 32 * 3), payloads[0].len);
}

test "opaque animation sends f=24" {
    const alloc = std.testing.allocator;
    var img = try zigimg.Image.create(alloc, 2, 2, .rgba32);
    defer img.deinit(alloc);
    @memset(img.pixels.rgba32, .{ .r = 5, .g = 6, .b = 7, .a = 255 });

    const second = try zigimg.color.PixelStorage.init(alloc, .rgba32, 4);
    @memset(second.rgba32, .{ .r = 8, .g = 9, .b = 10, .a = 255 });
    img.animation.frames = try .initCapacity(alloc, 2);
    try img.animation.frames.append(alloc, .{ .pixels = img.pixels, .duration = 0.04 });
    try img.animation.frames.append(alloc, .{ .pixels = second, .duration = 0.04 });

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const placed = placedSize(img.width, img.height, no_shrink);
    try transmitAnimation(alloc, std.testing.io, &aw.writer, &img, placed, false);
    const out = aw.written();
    try std.testing.expectEqual(@as(usize, 2), countLiteral(out, "\x1b_Gf=24,"));
    try std.testing.expectEqual(@as(usize, 0), countLiteral(out, "\x1b_Gf=32,"));

    const payloads = try directPixelPayloads(out);
    defer freePayloads(payloads);
    try std.testing.expectEqual(@as(usize, 2), payloads.len);
    try std.testing.expectEqual(@as(usize, 12), payloads[0].len);
    try std.testing.expectEqual(@as(usize, 12), payloads[1].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 5, 6, 7 }, payloads[0][0..3]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 9, 10 }, payloads[1][0..3]);
}

test "animation with one transparent frame sends f=32" {
    const alloc = std.testing.allocator;
    var img = try zigimg.Image.create(alloc, 2, 2, .rgb24);
    defer img.deinit(alloc);
    @memset(img.pixels.rgb24, .{ .r = 1, .g = 2, .b = 3 });

    const second = try zigimg.color.PixelStorage.init(alloc, .rgba32, 4);
    @memset(second.rgba32, .{ .r = 4, .g = 5, .b = 6, .a = 255 });
    second.rgba32[0].a = 0;
    img.animation.frames = try .initCapacity(alloc, 2);
    try img.animation.frames.append(alloc, .{ .pixels = img.pixels, .duration = 0.04 });
    try img.animation.frames.append(alloc, .{ .pixels = second, .duration = 0.04 });

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const placed = placedSize(img.width, img.height, no_shrink);
    try transmitAnimation(alloc, std.testing.io, &aw.writer, &img, placed, false);
    const out = aw.written();
    try std.testing.expectEqual(@as(usize, 2), countLiteral(out, "\x1b_Gf=32,"));
    try std.testing.expectEqual(@as(usize, 0), countLiteral(out, "\x1b_Gf=24,"));

    const payloads = try directPixelPayloads(out);
    defer freePayloads(payloads);
    try std.testing.expectEqual(@as(usize, 16), payloads[0].len);
    try std.testing.expectEqual(@as(usize, 16), payloads[1].len);
    try std.testing.expectEqual(@as(u8, 255), payloads[0][3]);
    try std.testing.expectEqual(@as(u8, 0), payloads[1][3]);
    try std.testing.expectEqual(@as(u8, 4), payloads[1][0]);
}

test "shm size follows wire format" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeShmApc(&aw.writer, "/bc0000000100000002", 12, 2, 2, .rgb);
    try writeShmApc(&aw.writer, "/bc0000000100000002", 16, 2, 2, .rgba);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "f=24,s=2,v=2,a=T,q=2,t=s,S=12;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "f=32,s=2,v=2,a=T,q=2,t=s,S=16;") != null);
}
