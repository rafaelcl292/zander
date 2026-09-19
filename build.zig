const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zander", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe_mod.addImport("zander", mod);
    const exe = b.addExecutable(.{ .name = "zander", .root_module = exe_mod });
    b.installArtifact(exe);
    b.step("run", "Show port status").dependOn(&b.addRunArtifact(exe).step);
    const unit = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    // The C++ oracle is host-only; keep it outside the portable library.
    const cpp = b.addSystemCommand(&.{ "c++", "-std=c++17", "-O2", "-DNDEBUG", "-DIS_64BIT", "-c" });
    cpp.addFileArg(b.path("tests/oracle.cpp"));
    cpp.addArg("-o");
    const obj = cpp.addOutputFileArg("oracle.o");
    const diff_mod = b.createModule(.{ .root_source_file = b.path("tests/differential.zig"), .target = b.graph.host, .optimize = optimize });
    diff_mod.addImport("zander", b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = b.graph.host, .optimize = optimize }));
    diff_mod.addObjectFile(obj);
    const reference_cpp = b.addSystemCommand(&.{ "c++", "-std=c++17", "-O2", "-DNDEBUG", "-DIS_64BIT", "-ffunction-sections", "-fdata-sections" });
    reference_cpp.addFileArg(b.path("tests/position_reference.cpp"));
    reference_cpp.addFileArg(b.path("vendor/stockfish/src/uci.cpp"));
    reference_cpp.addFileArg(b.path("vendor/stockfish/src/tt.cpp"));
    const tt_cpp = b.addSystemCommand(&.{ "c++", "-std=c++17", "-O2", "-DNDEBUG", "-DIS_64BIT", "-ffunction-sections", "-fdata-sections" });
    tt_cpp.addFileArg(b.path("tests/tt_reference.cpp"));
    // Track the pinned source directory, including transitive header includes.
    var upstream = std.Io.Dir.cwd().openDir(b.graph.io, b.pathFromRoot("vendor/stockfish/src"), .{ .iterate = true }) catch @panic("Initialize the Stockfish submodule first");
    defer upstream.close(b.graph.io);
    var walker = upstream.walk(b.allocator) catch @panic("Cannot walk Stockfish sources");
    defer walker.deinit();
    while (walker.next(b.graph.io) catch @panic("Cannot read Stockfish sources")) |entry| {
        if (entry.kind == .file) {
            const input = b.path(b.fmt("vendor/stockfish/src/{s}", .{entry.path}));
            reference_cpp.addFileInput(input);
            tt_cpp.addFileInput(input);
            cpp.addFileInput(input);
        }
    }
    reference_cpp.addArg("-Wl,--gc-sections");
    reference_cpp.addArg("-o");
    const reference_exe = reference_cpp.addOutputFileArg("position-reference");
    const reference_run = std.Build.Step.Run.create(b, "generate position reference");
    reference_run.addFileArg(reference_exe);
    reference_run.addFileArg(b.path("tests/positions.txt"));
    const fixture = reference_run.captureStdOut(.{ .basename = "position_reference.zig" });
    diff_mod.addAnonymousImport("position_reference", .{ .root_source_file = fixture });
    tt_cpp.addArg("-Wl,--gc-sections");
    tt_cpp.addArg("-o");
    const tt_exe = tt_cpp.addOutputFileArg("tt-reference");
    const tt_run = std.Build.Step.Run.create(b, "generate TT reference");
    tt_run.addFileArg(tt_exe);
    diff_mod.addAnonymousImport("tt_reference", .{ .root_source_file = tt_run.captureStdOut(.{ .basename = "tt_reference.zig" }) });
    const diff = b.addTest(.{ .root_module = diff_mod });
    const diff_step = b.step("differential", "Compare with pinned Stockfish C++ (requires host c++)");
    diff_step.dependOn(&b.addRunArtifact(diff).step);
}
