const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const test_options = @import("test_options");

const blackcat_exe = test_options.blackcat_exe;

var reference_cat_cache: ?[]const u8 = null;

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

fn isGnuCat(allocator: std.mem.Allocator, io: std.Io, program: []const u8) !bool {
    const result = run(allocator, io, program, &.{"--version"}, .inherit) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) return false;
    return std.mem.indexOf(u8, result.stdout, "GNU") != null;
}

/// Returns `/bin/cat` when it is GNU coreutils, otherwise `gcat` from PATH.
fn referenceCat(allocator: std.mem.Allocator, io: std.Io) error{GnuCatNotFound}![]const u8 {
    if (reference_cat_cache) |cached| return cached;

    if (builtin.os.tag != .windows) {
        if (try isGnuCat(allocator, io, "/bin/cat")) {
            reference_cat_cache = "/bin/cat";
            return "/bin/cat";
        }
    }

    if (try isGnuCat(allocator, io, "gcat")) {
        reference_cat_cache = "gcat";
        return "gcat";
    }

    std.debug.print("GNU cat not found: need GNU /bin/cat or gcat on PATH\n", .{});
    return error.GnuCatNotFound;
}

fn makeArgv(allocator: std.mem.Allocator, program: []const u8, args: []const []const u8) ![]const []const u8 {
    var argv = try allocator.alloc([]const u8, args.len + 1);
    argv[0] = program;
    @memcpy(argv[1..], args);
    return argv;
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    program: []const u8,
    args: []const []const u8,
    cwd: std.process.Child.Cwd,
) !RunResult {
    const argv = try makeArgv(allocator, program, args);
    defer allocator.free(argv);

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

fn writeFixture(tmp: *testing.TmpDir, name: []const u8, data: []const u8) !void {
    var file = try tmp.dir.createFile(testing.io, name, .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, data);
}

fn fixturePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name });
}

fn expectSameOutput(reference: RunResult, actual: RunResult) !void {
    try testing.expectEqual(reference.term, actual.term);
    try testing.expectEqualSlices(u8, reference.stdout, actual.stdout);
    try testing.expectEqualSlices(u8, reference.stderr, actual.stderr);
}

fn expectSameAsReference(
    allocator: std.mem.Allocator,
    io: std.Io,
    reference_cat: []const u8,
    tmp: *testing.TmpDir,
    args: []const []const u8,
    fixture_name: []const u8,
    fixture_data: []const u8,
) !void {
    try writeFixture(tmp, fixture_name, fixture_data);
    const fixture_path = try fixturePath(allocator, tmp, fixture_name);
    defer allocator.free(fixture_path);

    var file_args = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(file_args);
    @memcpy(file_args[0..args.len], args);
    file_args[args.len] = fixture_path;

    const reference = try run(allocator, io, reference_cat, file_args, .inherit);
    defer allocator.free(reference.stdout);
    defer allocator.free(reference.stderr);

    const actual = try run(allocator, io, blackcat_exe, file_args, .inherit);
    defer allocator.free(actual.stdout);
    defer allocator.free(actual.stderr);

    try expectSameOutput(reference, actual);
}

fn expectSameAsReferenceWithArgs(
    allocator: std.mem.Allocator,
    io: std.Io,
    reference_cat: []const u8,
    reference_args: []const []const u8,
    blackcat_args: []const []const u8,
    tmp: *testing.TmpDir,
    fixture_name: []const u8,
    fixture_data: []const u8,
) !void {
    try writeFixture(tmp, fixture_name, fixture_data);
    const fixture_path = try fixturePath(allocator, tmp, fixture_name);
    defer allocator.free(fixture_path);

    var reference_file_args = try allocator.alloc([]const u8, reference_args.len + 1);
    defer allocator.free(reference_file_args);
    @memcpy(reference_file_args[0..reference_args.len], reference_args);
    reference_file_args[reference_args.len] = fixture_path;

    var blackcat_file_args = try allocator.alloc([]const u8, blackcat_args.len + 1);
    defer allocator.free(blackcat_file_args);
    @memcpy(blackcat_file_args[0..blackcat_args.len], blackcat_args);
    blackcat_file_args[blackcat_args.len] = fixture_path;

    const reference = try run(allocator, io, reference_cat, reference_file_args, .inherit);
    defer allocator.free(reference.stdout);
    defer allocator.free(reference.stderr);

    const actual = try run(allocator, io, blackcat_exe, blackcat_file_args, .inherit);
    defer allocator.free(actual.stdout);
    defer allocator.free(actual.stderr);

    try expectSameOutput(reference, actual);
}

fn readPipe(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]u8 {
    var file_reader: std.Io.File.Reader = .initStreaming(file, io, &.{});
    return file_reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        else => |e| return e,
    };
}

fn readFixtureFile(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    var file = try tmp.dir.openFile(testing.io, name, .{});
    defer file.close(testing.io);

    var file_reader: std.Io.File.Reader = .initStreaming(file, testing.io, &.{});
    return file_reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        else => |e| return e,
    };
}

fn shellAppendHeredoc(
    allocator: std.mem.Allocator,
    io: std.Io,
    program: []const u8,
    file_path: []const u8,
    append_content: []const u8,
) !void {
    const script = try std.fmt.allocPrint(allocator, "{s} >>\"{s}\" <<'EOF'\n{s}EOF", .{
        program, file_path, append_content,
    });
    defer allocator.free(script);

    const result = try run(allocator, io, "/bin/sh", &.{ "-c", script }, .inherit);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    try testing.expect(exited_ok);
}

fn shellAppendPipe(
    allocator: std.mem.Allocator,
    io: std.Io,
    program: []const u8,
    file_path: []const u8,
    stdin_content: []const u8,
) !void {
    const script = try std.fmt.allocPrint(allocator, "{s} >>\"{s}\"", .{ program, file_path });
    defer allocator.free(script);

    const argv = [_][]const u8{ "/bin/sh", "-c", script };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(io);

    {
        var stdin_writer = child.stdin.?.writer(io, &.{});
        try stdin_writer.interface.writeAll(stdin_content);
        child.stdin.?.close(io);
        child.stdin = null;
    }

    if (child.stderr) |stderr_file| {
        stderr_file.close(io);
        child.stderr = null;
    }

    const term = try child.wait(io);
    const exited_ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    try testing.expect(exited_ok);
}

fn expectAppendMatchesReference(
    allocator: std.mem.Allocator,
    io: std.Io,
    reference_cat: []const u8,
    tmp: *testing.TmpDir,
    file_name: []const u8,
    initial_content: []const u8,
    append_content: []const u8,
) !void {
    const file_path = try fixturePath(allocator, tmp, file_name);
    defer allocator.free(file_path);

    try writeFixture(tmp, file_name, initial_content);
    try shellAppendHeredoc(allocator, io, reference_cat, file_path, append_content);
    const expected = try readFixtureFile(allocator, tmp, file_name);
    defer allocator.free(expected);

    try writeFixture(tmp, file_name, initial_content);
    try shellAppendHeredoc(allocator, io, blackcat_exe, file_path, append_content);
    const actual = try readFixtureFile(allocator, tmp, file_name);
    defer allocator.free(actual);

    try testing.expectEqualSlices(u8, expected, actual);
}

fn expectPipeAppendMatchesReference(
    allocator: std.mem.Allocator,
    io: std.Io,
    reference_cat: []const u8,
    tmp: *testing.TmpDir,
    file_name: []const u8,
    initial_content: []const u8,
    append_content: []const u8,
) !void {
    const file_path = try fixturePath(allocator, tmp, file_name);
    defer allocator.free(file_path);

    try writeFixture(tmp, file_name, initial_content);
    try shellAppendPipe(allocator, io, reference_cat, file_path, append_content);
    const expected = try readFixtureFile(allocator, tmp, file_name);
    defer allocator.free(expected);

    try writeFixture(tmp, file_name, initial_content);
    try shellAppendPipe(allocator, io, blackcat_exe, file_path, append_content);
    const actual = try readFixtureFile(allocator, tmp, file_name);
    defer allocator.free(actual);

    try testing.expectEqualSlices(u8, expected, actual);
}

fn runStdin(allocator: std.mem.Allocator, io: std.Io, program: []const u8, input: []const u8) !RunResult {
    const argv = try makeArgv(allocator, program, &.{});
    defer allocator.free(argv);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var stdout_task = try io.concurrent(readPipe, .{ allocator, io, child.stdout.? });
    var stderr_task = try io.concurrent(readPipe, .{ allocator, io, child.stderr.? });

    {
        var stdin_writer = child.stdin.?.writer(io, &.{});
        try stdin_writer.interface.writeAll(input);
        child.stdin.?.close(io);
        child.stdin = null;
    }

    const stdout = try stdout_task.await(io);
    const stderr = try stderr_task.await(io);
    const term = try child.wait(io);

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .term = term,
    };
}

test "plain file copy matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{},
        "plain.txt",
        "hello world\nsecond line\n",
    );
}

test "empty file matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(testing.allocator, testing.io, reference_cat, &tmp, &.{}, "empty.txt", "");
}

test "binary content matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = &[_]u8{ 0, 1, 2, 255, 10, 13, 9, 'x' };
    try expectSameAsReferenceWithArgs(
        testing.allocator,
        testing.io,
        reference_cat,
        &.{},
        &.{"-k"},
        &tmp,
        "binary.bin",
        data,
    );
}

test "multiple files matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFixture(&tmp, "a.txt", "AAA\n");
    try writeFixture(&tmp, "b.txt", "BBB\n");

    const path_a = try fixturePath(testing.allocator, &tmp, "a.txt");
    defer testing.allocator.free(path_a);
    const path_b = try fixturePath(testing.allocator, &tmp, "b.txt");
    defer testing.allocator.free(path_b);

    const args = [_][]const u8{ path_a, path_b };

    const reference = try run(testing.allocator, testing.io, reference_cat, &args, .inherit);
    defer testing.allocator.free(reference.stdout);
    defer testing.allocator.free(reference.stderr);

    const actual = try run(testing.allocator, testing.io, blackcat_exe, &args, .inherit);
    defer testing.allocator.free(actual.stdout);
    defer testing.allocator.free(actual.stderr);

    try expectSameOutput(reference, actual);
}

test "-n number lines matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"-n"},
        "numbered.txt",
        "line1\n\nline3\n",
    );
}

test "-b number nonblank lines matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"-b"},
        "nonblank.txt",
        "line1\n\nline3\n",
    );
}

test "-s squeeze blank lines matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"-s"},
        "squeeze.txt",
        "one\n\n\n\ntwo\n\n",
    );
}

test "-E show ends matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"-E"},
        "ends.txt",
        "alpha\nbeta\n",
    );
}

test "-T show tabs matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"-T"},
        "tabs.txt",
        "a\tb\n",
    );
}

test "-A show all matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"-A"},
        "showall.txt",
        "a\tb\n\x01\n",
    );
}

test "-e show ends and nonprinting matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"-e"},
        "ends.txt",
        "alpha\nbeta\n",
    );
}

test "-t show tabs and nonprinting matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"-t"},
        "tabs.txt",
        "a\tb\n",
    );
}

test "-v show nonprinting matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"-v"},
        "nonprint.txt",
        &[_]u8{ 'h', 'i', 1, '\n' },
    );
}

test "--number matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"--number"},
        "numbered.txt",
        "line1\n\nline3\n",
    );
}

test "--squeeze-blank matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectSameAsReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        &.{"--squeeze-blank"},
        "squeeze.txt",
        "one\n\n\n\ntwo\n\n",
    );
}

test "stdin copy matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    const input = "piped stdin\n";

    const reference = try runStdin(testing.allocator, testing.io, reference_cat, input);
    defer testing.allocator.free(reference.stdout);
    defer testing.allocator.free(reference.stderr);

    const actual = try runStdin(testing.allocator, testing.io, blackcat_exe, input);
    defer testing.allocator.free(actual.stdout);
    defer testing.allocator.free(actual.stderr);

    try expectSameOutput(reference, actual);
}

test ">> append with heredoc stdin matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectAppendMatchesReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        "append.txt",
        "OLD\n",
        "NEW\n",
    );
}

test ">> append with heredoc grows file like GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial = "AAAA\n";
    const append = "BB\n";
    try writeFixture(&tmp, "grow.txt", initial);

    const before_bytes = try readFixtureFile(testing.allocator, &tmp, "grow.txt");
    defer testing.allocator.free(before_bytes);
    const before = before_bytes.len;

    const file_path = try fixturePath(testing.allocator, &tmp, "grow.txt");
    defer testing.allocator.free(file_path);

    try shellAppendHeredoc(testing.allocator, testing.io, reference_cat, file_path, append);
    const reference = try readFixtureFile(testing.allocator, &tmp, "grow.txt");
    defer testing.allocator.free(reference);
    try testing.expect(reference.len > before);

    try writeFixture(&tmp, "grow.txt", initial);
    try shellAppendHeredoc(testing.allocator, testing.io, blackcat_exe, file_path, append);
    const actual = try readFixtureFile(testing.allocator, &tmp, "grow.txt");
    defer testing.allocator.free(actual);
    try testing.expect(actual.len > before);
    try testing.expectEqual(reference.len, actual.len);
}

test ">> append multiple heredocs matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = try fixturePath(testing.allocator, &tmp, "multi.txt");
    defer testing.allocator.free(file_path);

    try writeFixture(&tmp, "multi.txt", "1\n");
    try shellAppendHeredoc(testing.allocator, testing.io, reference_cat, file_path, "2\n");
    try shellAppendHeredoc(testing.allocator, testing.io, reference_cat, file_path, "3\n");
    const expected = try readFixtureFile(testing.allocator, &tmp, "multi.txt");
    defer testing.allocator.free(expected);

    try writeFixture(&tmp, "multi.txt", "1\n");
    try shellAppendHeredoc(testing.allocator, testing.io, blackcat_exe, file_path, "2\n");
    try shellAppendHeredoc(testing.allocator, testing.io, blackcat_exe, file_path, "3\n");
    const actual = try readFixtureFile(testing.allocator, &tmp, "multi.txt");
    defer testing.allocator.free(actual);

    try testing.expectEqualSlices(u8, expected, actual);
}

test ">> append autoconf-shaped heredoc matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectAppendMatchesReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        "config.status",
        "#! /bin/sh\n# Generated by configure.\n",
        "## M4sh Initialization. ##\n",
    );

    const content = try readFixtureFile(testing.allocator, &tmp, "config.status");
    defer testing.allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "#! /bin/sh\n"));
    try testing.expect(std.mem.endsWith(u8, content, "## M4sh Initialization. ##\n"));
}

test ">> append with piped stdin matches GNU cat" {
    const reference_cat = try referenceCat(testing.allocator, testing.io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectPipeAppendMatchesReference(
        testing.allocator,
        testing.io,
        reference_cat,
        &tmp,
        "pipe.txt",
        "OLD\n",
        "NEW\n",
    );
}
