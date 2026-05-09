const std = @import("std");

// SAUCE Documentation: https://www.acid.org/info/sauce/sauce.htm

pub const Sauce = struct {
    metadata: SauceMetadata,
    /// Trimmed comment lines (empty lines preserved).
    comments: [][]u8,

    pub fn deinit(self: Sauce, a: std.mem.Allocator) void {
        if (self.comments.len == 0) return;
        for (self.comments) |line| a.free(line);
        a.free(self.comments);
    }
};

pub const SauceMetadata = struct {
    /// 0x00-0x04: ID ("SAUCE")
    id: [5]u8,
    /// 0x05-0x06: Version ("00")
    version: [2]u8,
    /// 0x07-0x29: Title (35 bytes, space-padded)
    title: [35]u8,
    /// 0x2A-0x3D: Author (20 bytes, space-padded)
    author: [20]u8,
    /// 0x3E-0x51: Group (20 bytes, space-padded)
    group: [20]u8,
    /// 0x52-0x59: Date (CCYYMMDD, 8 bytes)
    date: [8]u8,
    /// 0x5A-0x5D: FileSize (u32 LE, original size excl. SAUCE)
    file_size: u32,
    /// 0x5E: DataType (u8)
    data_type: u8,
    /// 0x5F: FileType (u8)
    file_type: u8,
    /// 0x60-0x61: TInfo1 (u16 LE)
    tinfo1: u16,
    /// 0x62-0x63: TInfo2 (u16 LE)
    tinfo2: u16,
    /// 0x64-0x65: TInfo3 (u16 LE)
    tinfo3: u16,
    /// 0x66-0x67: TInfo4 (u16 LE)
    tinfo4: u16,
    /// 0x68: Comments (u8, num lines)
    comments: u8,
    /// 0x69: TFlags (u8)
    tflags: u8,
    /// 0x6A-0x7F: TInfoS (22-byte Z-string)
    tinfo_s: [22]u8,

    /// Trimmed title.
    pub fn getTitle(self: *const @This()) []const u8 {
        return std.mem.trimEnd(u8, &self.title, " ");
    }

    /// Trimmed author.
    pub fn getAuthor(self: *const @This()) []const u8 {
        return std.mem.trimEnd(u8, &self.author, " ");
    }

    /// Trimmed group.
    pub fn getGroup(self: *const @This()) []const u8 {
        return std.mem.trimEnd(u8, &self.group, " ");
    }

    /// Width from TInfo1 (for character/ANSI files), default 80.
    pub fn getWidth(self: *const @This()) usize {
        const w: usize = self.tinfo1;
        return if (w > 0) w else 80;
    }

    /// Trimmed TInfoS (Z-string).
    pub fn getTInfoS(self: *const @This()) []const u8 {
        const zstr = std.mem.sliceTo(&self.tinfo_s, 0);
        return std.mem.trimRight(u8, zstr, " ");
    }
};

pub fn isSauceCandidate(filename: []const u8) bool {
    const ext = std.fs.path.extension(filename);
    return std.ascii.eqlIgnoreCase(ext, ".ans") or std.ascii.eqlIgnoreCase(ext, ".asc");
}

/// Parse full SAUCE metadata from buffer (little-endian portable).
pub fn parseSauceMetadata(buf: []const u8) ?SauceMetadata {
    if (buf.len < 128) return null;
    if (!std.mem.eql(u8, buf[0..5], "SAUCE")) return null;

    const meta = SauceMetadata{
        .id = buf[0..5].*,
        .version = buf[5..7].*,
        .title = buf[7..42].*,
        .author = buf[42..62].*,
        .group = buf[62..82].*,
        .date = buf[82..90].*,
        .file_size = @as(u32, buf[90]) | (@as(u32, buf[91]) << 8) | (@as(u32, buf[92]) << 16) | (@as(u32, buf[93]) << 24),
        .data_type = buf[94],
        .file_type = buf[95],
        .tinfo1 = @as(u16, buf[96]) | (@as(u16, buf[97]) << 8),
        .tinfo2 = @as(u16, buf[98]) | (@as(u16, buf[99]) << 8),
        .tinfo3 = @as(u16, buf[100]) | (@as(u16, buf[101]) << 8),
        .tinfo4 = @as(u16, buf[102]) | (@as(u16, buf[103]) << 8),
        .comments = buf[104],
        .tflags = buf[105],
        .tinfo_s = buf[106..128].*,
    };
    return meta;
}

/// Parse full SAUCE record (metadata + comments if present).
pub fn getSauce(
    alloc: std.mem.Allocator,
    io: std.Io,
    file: *std.Io.File,
) !?Sauce {
    const sauce_size: usize = 128;
    const comment_size: usize = 64;
    const file_size = try file.length(io);
    if (file_size < sauce_size) return null;
    const sauce_pos = file_size - sauce_size;
    var comments: [][]u8 = &[_][]u8{};

    // Read SAUCE metadata block.
    var sauce: [sauce_size]u8 = undefined;
    const meta_n = try file.readPositionalAll(io, &sauce, sauce_pos);
    if (meta_n != sauce_size) return null;

    const metadata = parseSauceMetadata(&sauce) orelse return null;

    if (metadata.comments > 0) {
        const num_comments: usize = @intCast(metadata.comments);
        var comment_id: [5]u8 = undefined;
        const len = try file.readPositionalAll(io, &comment_id, sauce_pos - (num_comments * comment_size) - 5);
        const has_valid_header = if (len == 5 and std.mem.eql(u8, &comment_id, "COMNT")) true else false;

        if (has_valid_header) {
            comments = try alloc.alloc([]u8, num_comments);
            errdefer for (comments) |line| alloc.free(line);
            errdefer alloc.free(comments);

            for (0..num_comments) |i| {
                var chunk: [comment_size]u8 = undefined;
                const offset = sauce_pos - ((num_comments - i) * comment_size);
                _ = try file.readPositionalAll(io, &chunk, offset);
                const trimmed = std.mem.trimEnd(u8, &chunk, " ");
                comments[i] = try alloc.dupe(u8, trimmed);
            }
        }
    }

    return Sauce{
        .metadata = metadata,
        .comments = comments,
    };
}
