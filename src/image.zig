const std = @import("std");
const zigimg = @import("zigimg");

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

pub fn isImageFile(head_buf: []const u8) !bool {
    _ = zigimg.Image.detectFormatFromMemory(head_buf[0..]) catch return false;
    return true;
}

pub fn renderImage(alloc: std.mem.Allocator, io: std.Io, file: *std.Io.File, writer: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var image_buf: [65536]u8 = undefined;
    var img = try zigimg.Image.fromFile(allocator, io, file.*, &image_buf);
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
    const raw_bytes = std.mem.sliceAsBytes(img.pixels.rgba32);
    var byte_data = try std.ArrayList(u8).initCapacity(allocator, raw_bytes.len);
    defer byte_data.deinit(allocator);
    try byte_data.appendSlice(allocator, raw_bytes);

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
