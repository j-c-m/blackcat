const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    // Release packaging options
    const release = b.option(bool, "package_release", "Build all release targets") orelse false;
    //const strip = b.option(bool, "strip", "Disable debug information (default: no)");
    const pie = b.option(bool, "pie", "Produce an executable with position independent code (default: none)");

    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit tests");

    if (release) {
        build_release(b, run_step, test_step, pie);
    } else {
        build_development(b, run_step, test_step, pie);
    }
}

fn build_development(
    b: *std.Build,
    run_step: *std.Build.Step,
    test_step: *std.Build.Step,
    //strip: ?bool,
    pie: ?bool,
) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    build_exe(
        b,
        run_step,
        test_step,
        target,
        optimize,
        .{},
        //strip orelse false,
        pie,
    );
}

fn build_release(
    b: *std.Build,
    run_step: *std.Build.Step,
    test_step: *std.Build.Step,
    //strip: ?bool,
    pie: ?bool,
) void {
    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
        .{ .cpu_arch = .aarch64, .os_tag = .freebsd },
    };
    const optimize = .ReleaseSmall;

    for (targets) |t| {
        const target = b.resolveTargetQuery(t);
        var triple = std.mem.splitScalar(u8, t.zigTriple(b.allocator) catch unreachable, '-');
        const arch = triple.next() orelse unreachable;
        const os = triple.next() orelse unreachable;
        const target_path = std.mem.join(b.allocator, "-", &[_][]const u8{ os, arch }) catch unreachable;

        build_exe(
            b,
            run_step,
            test_step,
            target,
            optimize,
            .{ .dest_dir = .{ .override = .{ .custom = target_path } } },
            //strip orelse true,
            pie,
        );
    }
}

fn build_exe(
    b: *std.Build,
    run_step: *std.Build.Step,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_install_options: std.Build.Step.InstallArtifact.Options,
    //strip: bool,
    pie: ?bool,
) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Fix: Do NOT pass target/optimize to addExecutable when using root_module!
    const exe = b.addExecutable(.{
        .name = "blackcat",
        .root_module = exe_mod,
        //.strip = strip,
    });
    if (pie) |value| exe.pie = value;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);
    build_options.addOption([]const u8, "name", @tagName(zon.name));
    exe.root_module.addOptions("build_options", build_options);

    const zigimg_dependency = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zigimg", zigimg_dependency.module("zigimg"));

    const exe_install = b.addInstallArtifact(exe, exe_install_options);
    b.getInstallStep().dependOn(&exe_install.step);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Test step (always included)
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);
}
