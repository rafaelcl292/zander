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
    const cpp = b.addSystemCommand(&.{ "c++", "-std=c++17", "-O2", "-DNDEBUG", "-c" });
    cpp.addFileArg(b.path("tests/oracle.cpp"));
    cpp.addArg("-o");
    const obj = cpp.addOutputFileArg("oracle.o");
    const diff_mod = b.createModule(.{ .root_source_file = b.path("tests/differential.zig"), .target = b.graph.host, .optimize = optimize });
    diff_mod.addImport("zander", b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = b.graph.host, .optimize = optimize }));
    diff_mod.addObjectFile(obj);
    const diff = b.addTest(.{ .root_module = diff_mod });
    const diff_step = b.step("differential", "Compare with pinned Stockfish C++ (requires host c++)");
    diff_step.dependOn(&b.addRunArtifact(diff).step);
}
