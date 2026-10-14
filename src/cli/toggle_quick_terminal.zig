const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
// fork(gx): GX-0040 begin: parse class/help before native IPC.
const args = @import("args.zig");
// fork(gx): GX-0040 end

pub const Options = struct {
    // fork(gx): GX-0040 begin
    _arena: ?std.heap.ArenaAllocator = null,
    // fork(gx): GX-0040 end
    /// If set, connect to a custom instance of Ghostty.
    class: ?[:0]const u8 = null,

    pub fn deinit(self: *Options) void {
        // fork(gx): GX-0040 begin
        if (self._arena) |arena| arena.deinit();
        // fork(gx): GX-0040 end
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

// fork(gx): GX-0040: document authenticated Windows toggle routing.
/// The `+toggle-quick-terminal` command will use native platform IPC to toggle
/// the quick terminal in a running instance of Ghostty.
///
/// If the `--class` flag is not set, the command will try and connect to the
/// default running Ghostty instance. Otherwise it will contact a Ghostty
/// instance configured with the given `class`.
///
/// On GTK, D-Bus activation must be properly configured. Ghostty does not need
/// to be running, as D-Bus will handle launching a new instance if it is not
/// already running.
///
/// Supported on GTK and Ghostty GX for Windows. On Windows the target must
/// already be running in the same user, login, elevation and config directory.
/// Windows requests use authenticated local IPC and return an error when the
/// result is unknown; they never start an extra terminal after a timeout.
///
/// Flags:
///
///   * `--class=<class>`: If set, connect to a custom instance of Ghostty.
///     The class must be a valid GTK application ID.
///
/// Available since: 1.4.0
pub fn run(alloc: Allocator) !u8 {
    // fork(gx): GX-0040 begin
    var opts: Options = .{};
    defer opts.deinit();
    var iter = try args.argsIterator(alloc, global.args());
    defer iter.deinit();
    // fork(gx): GX-0040 end
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buf);
    const stderr = &stderr_writer.interface;
    // fork(gx): GX-0040 begin
    defer stderr.flush() catch {};
    args.parse(Options, alloc, &opts, &iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };
    // fork(gx): GX-0040 end

    if (apprt.App.performIpc(
        alloc,
        // fork(gx): GX-0040 begin
        if (opts.class) |class| .{ .class = class } else .detect,
        // fork(gx): GX-0040 end
        .toggle_quick_terminal,
        {},
    ) catch |err| switch (err) {
        error.IPCFailed => {
            return 1;
        },
        else => {
            try stderr.print("Sending the IPC failed: {}\n", .{err});
            return 1;
        },
    }) return 0;

    try stderr.print("+toggle-quick-terminal is not supported on this platform.\n", .{});
    return 1;
}

// fork(gx): GX-0040 begin
test "toggle quick terminal parses class and help without IPC" {
    var opts: Options = .{};
    defer opts.deinit();
    var iter = args.sliceIterator(&.{"--class=org.example.Ghostty"});
    try args.parse(Options, std.testing.allocator, &opts, &iter);
    try std.testing.expectEqualStrings("org.example.Ghostty", opts.class.?);
    var help = args.sliceIterator(&.{"--help"});
    try std.testing.expectError(error.ActionHelpRequested, args.parse(Options, std.testing.allocator, &opts, &help));
    var invalid = args.sliceIterator(&.{"--unknown-option=true"});
    try std.testing.expectError(error.InvalidField, args.parse(Options, std.testing.allocator, &opts, &invalid));
}
// fork(gx): GX-0040 end
