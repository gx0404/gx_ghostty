//! Launch profiles for the Ghostty GX new-tab menu: the shells detected on
//! the system followed by the user's `gx-launch-profile` entries.
//!
//! Detection is a pure function of an `Environment` (platform, environment
//! variables, executable directory, WSL distributions and a file probe),
//! so both the Windows and the Linux rules are testable on any host. It
//! probes files along `PATH`; a `Cache` keeps the detected shells of an
//! app and adds the custom profiles of the current configuration on every
//! use (`List.appendCustom`).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const i18n = @import("i18n.zig");

/// What a profile runs; apprts use it to pick an icon.
pub const Kind = enum {
    gx_zsh,
    herdr,
    pwsh,
    powershell,
    cmd,
    git_bash,
    msys2,
    nushell,
    wsl,
    login_shell,
    zsh,
    bash,
    fish,
    custom,
};

/// How to start a profile.
pub const Command = union(enum) {
    /// The program (index 0) and its arguments, executed directly.
    argv: []const [:0]const u8,

    /// A command in the syntax of Ghostty's `command` option, including
    /// the `direct:` and `shell:` prefixes (from `gx-launch-profile`).
    command_line: [:0]const u8,
};

pub const Profile = struct {
    /// A stable identifier, e.g. `gx-zsh`, `wsl:Ubuntu-24.04` or
    /// `custom:Python`.
    id: [:0]const u8,

    /// The display name. For detected profiles this is an i18n msgid
    /// (see `displayName`); for custom profiles it is the user's name.
    name: [:0]const u8,

    /// The value of the `{name}` placeholder in `name` (the WSL
    /// distribution), if any.
    name_arg: ?[:0]const u8 = null,

    command: Command,
    kind: Kind,
};

pub const LaunchOrigin = union(enum) {
    unknown,
    ad_hoc,
    profile: []const u8,

    pub fn select(profile_id: ?[]const u8, default_profile_id: ?[]const u8, command_override: bool, initial_command: bool) LaunchOrigin {
        if (initial_command) return .ad_hoc;
        if (profile_id) |id| return .{ .profile = id };
        if (command_override) return .ad_hoc;
        if (default_profile_id) |id| return .{ .profile = id };
        return .unknown;
    }

    pub fn profileId(self: LaunchOrigin) ?[]const u8 {
        return switch (self) {
            .profile => |id| id,
            else => null,
        };
    }

    pub fn clone(self: LaunchOrigin, alloc: Allocator) Allocator.Error!LaunchOrigin {
        return switch (self) {
            .profile => |id| .{ .profile = try alloc.dupe(u8, id) },
            else => self,
        };
    }

    pub fn deinit(self: *LaunchOrigin, alloc: Allocator) void {
        if (self.* == .profile) alloc.free(self.profile);
        self.* = .unknown;
    }
};

/// The detection rules to apply.
pub const Platform = enum {
    windows,
    linux,

    pub const native: Platform = if (builtin.os.tag == .windows) .windows else .linux;

    fn separator(self: Platform) u8 {
        return switch (self) {
            .windows => '\\',
            .linux => '/',
        };
    }

    fn pathListSeparator(self: Platform) u8 {
        return switch (self) {
            .windows => ';',
            .linux => ':',
        };
    }

    fn isAbsolute(self: Platform, path: []const u8) bool {
        return switch (self) {
            .windows => path.len >= 3 and std.ascii.isAlphabetic(path[0]) and
                path[1] == ':' and (path[2] == '\\' or path[2] == '/'),
            .linux => path.len > 0 and path[0] == '/',
        };
    }
};

/// Tells whether a file exists at an absolute path.
pub const Probe = union(enum) {
    /// Checks the file system.
    io: std.Io,

    /// Reports exactly these paths as existing (for tests).
    paths: []const []const u8,

    pub fn exists(self: Probe, path: []const u8) bool {
        switch (self) {
            .io => |io| {
                if (!std.fs.path.isAbsolute(path) or !validNativePath(path)) return false;
                std.Io.Dir.accessAbsolute(io, path, .{
                    .execute = builtin.os.tag != .windows,
                }) catch return false;
                return true;
            },
            .paths => |paths| {
                for (paths) |candidate| {
                    if (std.mem.eql(u8, candidate, path)) return true;
                }
                return false;
            },
        }
    }

    /// Rejects paths that the native file APIs treat as programmer errors
    /// (Windows reserves `<>"|?*` and `:` outside the drive prefix).
    fn validNativePath(path: []const u8) bool {
        for (path, 0..) |c, i| {
            if (c < 0x20) return false;
            if (builtin.os.tag != .windows) continue;
            switch (c) {
                '<', '>', '"', '|', '?', '*' => return false,
                ':' => if (i != 1) return false,
                else => {},
            }
        }
        return true;
    }
};

/// Everything detection depends on.
pub const Environment = struct {
    platform: Platform = .native,

    /// The process environment.
    env: *const std.process.Environ.Map,

    /// The directory of the running Ghostty GX executable, if known.
    exe_dir: ?[]const u8 = null,

    /// Installed WSL distributions, default first (Windows only).
    wsl_distros: []const []const u8 = &.{},

    probe: Probe,
};

/// Detected and custom profiles. All memory is owned by `arena`.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    profiles: []const Profile,

    pub fn deinit(self: *List) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The profile with `id`, if any.
    pub fn find(self: *const List, id: []const u8) ?*const Profile {
        for (self.profiles) |*profile| {
            if (std.mem.eql(u8, profile.id, id)) return profile;
        }
        return null;
    }

    /// The profile that `query` names, as in `gx:new_tab_profile:<query>`
    /// and `gx:new_window_profile:<query>`: the profile with that id, else
    /// the custom profile with that name (so `Python` finds
    /// `custom:Python`), else the profile whose name, in English or in the
    /// current UI language with `{name}` filled in, equals `query` ignoring
    /// ASCII case.
    pub fn resolve(self: *const List, query: []const u8) ?*const Profile {
        if (self.find(query)) |profile| return profile;
        for (self.profiles) |*profile| {
            if (profile.kind == .custom and std.mem.eql(u8, profile.name, query)) return profile;
        }
        for (self.profiles) |*profile| {
            if (nameIs(profile.*, query)) return profile;
        }
        return null;
    }

    /// Appends `custom` profiles (`gx-launch-profile`) in order.
    pub fn appendCustom(self: *List, custom: []const Custom) Allocator.Error!void {
        if (custom.len == 0) return;
        const alloc = self.arena.allocator();
        const profiles = try alloc.alloc(Profile, self.profiles.len + custom.len);
        @memcpy(profiles[0..self.profiles.len], self.profiles);
        for (custom, profiles[self.profiles.len..]) |entry, *profile| {
            profile.* = try customProfile(alloc, entry);
        }
        self.profiles = profiles;
    }

    /// A copy of the list with memory of its own.
    pub fn clone(self: *const List, alloc: Allocator) Allocator.Error!List {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const profiles = try a.alloc(Profile, self.profiles.len);
        for (self.profiles, profiles) |profile, *copy| {
            copy.* = .{
                .id = try a.dupeZ(u8, profile.id),
                .name = try a.dupeZ(u8, profile.name),
                .name_arg = if (profile.name_arg) |arg| try a.dupeZ(u8, arg) else null,
                .command = switch (profile.command) {
                    .argv => |argv| .{ .argv = try dupeArgv(a, argv) },
                    .command_line => |line| .{ .command_line = try a.dupeZ(u8, line) },
                },
                .kind = profile.kind,
            };
        }
        return .{ .arena = arena, .profiles = profiles };
    }
};

/// Whether the name of `profile` equals `query`, ignoring ASCII case: the
/// name of a custom profile, or the English or translated name of a
/// detected one with `{name}` filled in.
fn nameIs(profile: Profile, query: []const u8) bool {
    if (profile.kind == .custom) return std.ascii.eqlIgnoreCase(profile.name, query);
    const arg = profile.name_arg orelse "";
    return filledEql(profile.name, arg, query) or
        filledEql(i18n.trRuntime(profile.name), arg, query);
}

/// Whether `template` with its `{name}` placeholder replaced by `arg`
/// equals `query`, ignoring ASCII case.
fn filledEql(template: []const u8, arg: []const u8, query: []const u8) bool {
    const placeholder = "{name}";
    const at = std.mem.indexOf(u8, template, placeholder) orelse
        return std.ascii.eqlIgnoreCase(template, query);
    const head = template[0..at];
    const tail = template[at + placeholder.len ..];
    if (query.len != head.len + arg.len + tail.len) return false;
    return std.ascii.eqlIgnoreCase(query[0..head.len], head) and
        std.ascii.eqlIgnoreCase(query[head.len..][0..arg.len], arg) and
        std.ascii.eqlIgnoreCase(query[head.len + arg.len ..], tail);
}

fn dupeArgv(alloc: Allocator, argv: []const [:0]const u8) Allocator.Error![]const [:0]const u8 {
    const result = try alloc.alloc([:0]const u8, argv.len);
    for (argv, result) |arg, *out| out.* = try alloc.dupeZ(u8, arg);
    return result;
}

/// A user profile from `gx-launch-profile` (`name=command`).
pub const Custom = struct {
    name: []const u8,
    command: []const u8,
};

fn customProfile(alloc: Allocator, entry: Custom) Allocator.Error!Profile {
    return .{
        .id = try std.fmt.allocPrintSentinel(alloc, "custom:{s}", .{entry.name}, 0),
        .name = try alloc.dupeZ(u8, entry.name),
        .command = .{ .command_line = try alloc.dupeZ(u8, entry.command) },
        .kind = .custom,
    };
}

/// Detects the shells available in `environment` and appends `custom`
/// profiles in order: `detectShells`, then `List.appendCustom`.
pub fn detect(alloc: Allocator, environment: Environment, custom: []const Custom) Allocator.Error!List {
    var list = try detectShells(alloc, environment);
    errdefer list.deinit();
    try list.appendCustom(custom);
    return list;
}

/// Detects the shells available in `environment`, without custom
/// profiles.
///
/// Windows: GX Zsh and herdr (from `<exe dir>\..\bin`,
/// `%LOCALAPPDATA%\Programs\GXShell\bin`,
/// `%LOCALAPPDATA%\Programs\OhMyZshGX\bin`, then `PATH`), PowerShell 7,
/// Windows PowerShell, Command Prompt, Git Bash, MSYS2 UCRT64, Nushell and
/// one profile per WSL distribution. Linux: GX Zsh and herdr (from
/// `/usr/lib/ohmyzsh-gx/bin`, then `PATH`), the login shell (`$SHELL`),
/// then zsh, bash and fish from `PATH`.
pub fn detectShells(alloc: Allocator, environment: Environment) Allocator.Error!List {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    var detector: Detector = .{ .alloc = arena.allocator(), .environment = environment };
    switch (environment.platform) {
        .windows => try detector.windows(),
        .linux => try detector.linux(),
    }
    return .{ .arena = arena, .profiles = detector.profiles.items };
}

const Detector = struct {
    alloc: Allocator,
    environment: Environment,
    profiles: std.ArrayList(Profile) = .empty,

    fn windows(self: *Detector) Allocator.Error!void {
        var gx_dirs: std.ArrayList([]const u8) = .empty;
        if (self.environment.exe_dir) |exe_dir| {
            if (std.fs.path.dirnameWindows(exe_dir)) |parent| {
                try gx_dirs.append(self.alloc, try self.join(&.{ parent, "bin" }));
            }
        }
        if (self.getenv("LOCALAPPDATA")) |local| {
            try gx_dirs.append(self.alloc, try self.join(&.{ local, "Programs", "GXShell", "bin" }));
            try gx_dirs.append(self.alloc, try self.join(&.{ local, "Programs", "OhMyZshGX", "bin" }));
        }

        if (try self.findIn(gx_dirs.items, "gx-zsh.exe") orelse try self.findInPath("gx-zsh.exe")) |path| {
            try self.add("gx-zsh", "GX Zsh", .gx_zsh, &.{path});
        }
        if (try self.findIn(gx_dirs.items, "herdr.exe") orelse try self.findInPath("herdr.exe")) |path| {
            try self.add("herdr", "herdr", .herdr, &.{path});
        }

        const program_files = self.getenv("ProgramFiles");
        const system_root = self.getenv("SystemRoot");

        if (try self.findInPath("pwsh.exe") orelse
            try self.existing(program_files, &.{ "PowerShell", "7", "pwsh.exe" })) |path|
        {
            try self.add("pwsh", "PowerShell 7", .pwsh, &.{path});
        }
        if (try self.existing(system_root, &.{ "System32", "WindowsPowerShell", "v1.0", "powershell.exe" })) |path| {
            try self.add("powershell", "Windows PowerShell", .powershell, &.{path});
        }
        if (try self.existing(self.getenv("ComSpec"), &.{}) orelse
            try self.existing(system_root, &.{ "System32", "cmd.exe" })) |path|
        {
            try self.add("cmd", "Command Prompt", .cmd, &.{path});
        }
        if (try self.existing(program_files, &.{ "Git", "bin", "bash.exe" })) |path| {
            try self.add("git-bash", "Git Bash", .git_bash, &.{ path, "-i", "-l" });
        }
        if (try self.existing("C:\\msys64", &.{"msys2_shell.cmd"})) |path| {
            try self.add("msys2-ucrt64", "MSYS2 UCRT64", .msys2, &.{ path, "-defterm", "-here", "-no-start", "-ucrt64" });
        }
        if (try self.findInPath("nu.exe")) |path| {
            try self.add("nushell", "Nushell", .nushell, &.{path});
        }

        const wsl = try self.existing(system_root, &.{ "System32", "wsl.exe" }) orelse "wsl.exe";
        for (self.environment.wsl_distros) |distro| {
            const name = try self.alloc.dupeZ(u8, distro);
            try self.profiles.append(self.alloc, .{
                .id = try std.fmt.allocPrintSentinel(self.alloc, "wsl:{s}", .{distro}, 0),
                .name = "WSL: {name}",
                .name_arg = name,
                .command = .{ .argv = try self.argv(&.{ wsl, "-d", name }) },
                .kind = .wsl,
            });
        }
    }

    fn linux(self: *Detector) Allocator.Error!void {
        const gx_dir = "/usr/lib/ohmyzsh-gx/bin";
        if (try self.existing(gx_dir, &.{"gx-zsh"}) orelse try self.findInPath("gx-zsh")) |path| {
            try self.add("gx-zsh", "GX Zsh", .gx_zsh, &.{path});
        }
        if (try self.existing(gx_dir, &.{"herdr"}) orelse try self.findInPath("herdr")) |path| {
            try self.add("herdr", "herdr", .herdr, &.{path});
        }

        const login_shell = try self.existing(self.getenv("SHELL"), &.{});
        if (login_shell) |path| try self.add("login-shell", "Login Shell", .login_shell, &.{path});

        const shells = [_]struct { [:0]const u8, [:0]const u8, Kind }{
            .{ "zsh", "Zsh", .zsh },
            .{ "bash", "Bash", .bash },
            .{ "fish", "Fish", .fish },
        };
        for (shells) |shell| {
            const path = try self.findInPath(shell[0]) orelse continue;
            if (login_shell) |login| if (std.mem.eql(u8, login, path)) continue;
            try self.add(shell[0], shell[1], shell[2], &.{path});
        }
    }

    fn add(
        self: *Detector,
        id: [:0]const u8,
        name: [:0]const u8,
        kind: Kind,
        args: []const []const u8,
    ) Allocator.Error!void {
        try self.profiles.append(self.alloc, .{
            .id = id,
            .name = name,
            .command = .{ .argv = try self.argv(args) },
            .kind = kind,
        });
    }

    fn argv(self: *Detector, args: []const []const u8) Allocator.Error![]const [:0]const u8 {
        const result = try self.alloc.alloc([:0]const u8, args.len);
        for (args, result) |arg, *out| out.* = try self.alloc.dupeZ(u8, arg);
        return result;
    }

    fn getenv(self: *Detector, name: []const u8) ?[]const u8 {
        const value = self.environment.env.get(name) orelse return null;
        return if (value.len == 0) null else value;
    }

    /// `base` joined with `parts` if that is an existing absolute path.
    fn existing(self: *Detector, base: ?[]const u8, parts: []const []const u8) Allocator.Error!?[]const u8 {
        const dir = unquote(base orelse return null);
        if (!self.environment.platform.isAbsolute(dir)) return null;
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(self.alloc, dir);
        try all.appendSlice(self.alloc, parts);
        const path = try self.join(all.items);
        return if (self.environment.probe.exists(path)) path else null;
    }

    fn findIn(self: *Detector, dirs: []const []const u8, name: []const u8) Allocator.Error!?[]const u8 {
        for (dirs) |dir| {
            if (try self.existing(dir, &.{name})) |path| return path;
        }
        return null;
    }

    fn findInPath(self: *Detector, name: []const u8) Allocator.Error!?[]const u8 {
        const path_var = self.getenv("PATH") orelse return null;
        var dirs = std.mem.tokenizeScalar(u8, path_var, self.environment.platform.pathListSeparator());
        while (dirs.next()) |dir| {
            if (try self.existing(dir, &.{name})) |path| return path;
        }
        return null;
    }

    fn join(self: *Detector, parts: []const []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (parts, 0..) |part, i| {
            if (i > 0) try out.append(self.alloc, self.environment.platform.separator());
            try out.appendSlice(self.alloc, if (i == 0)
                std.mem.trimEnd(u8, part, "\\/")
            else
                std.mem.trim(u8, part, "\\/"));
        }
        return try out.toOwnedSlice(self.alloc);
    }

    fn unquote(value: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
            return trimmed[1 .. trimmed.len - 1];
        }
        return trimmed;
    }
};

/// The profile new terminals use by default: GX Zsh, then PowerShell 7,
/// Windows PowerShell and Command Prompt on Windows; GX Zsh, then the
/// login shell on Linux. Null if none of these was detected.
pub fn defaultProfile(profiles: []const Profile, platform: Platform) ?*const Profile {
    const order: []const Kind = switch (platform) {
        .windows => &.{ .gx_zsh, .pwsh, .powershell, .cmd },
        .linux => &.{ .gx_zsh, .login_shell },
    };
    for (order) |kind| {
        for (profiles) |*profile| {
            if (profile.kind == kind) return profile;
        }
    }
    return null;
}

/// The name of `profile` in the current UI language, with the `{name}`
/// placeholder filled in. Custom profile names are used as-is. The caller
/// owns the returned string.
pub fn displayName(alloc: Allocator, profile: Profile) Allocator.Error![]u8 {
    if (profile.kind == .custom) return try alloc.dupe(u8, profile.name);
    return try i18n.fill(alloc, i18n.trRuntime(profile.name), .{
        .name = profile.name_arg orelse "",
    });
}

/// Detects the profiles of the running system: `detectSystemShells`, then
/// `custom`.
pub fn detectSystem(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    custom: []const Custom,
) Allocator.Error!List {
    var list = try detectSystemShells(alloc, io, env);
    errdefer list.deinit();
    try list.appendCustom(custom);
    return list;
}

/// Detects the shells of the running system. `env` is the process
/// environment (e.g. from `global.environMap()`); on Windows the WSL
/// distributions come from the registry.
pub fn detectSystemShells(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) Allocator.Error!List {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const exe_dir = std.process.executableDirPathAlloc(io, arena.allocator()) catch null;
    const distros = try wslDistros(arena.allocator());
    return try detectShells(alloc, .{
        .env = env,
        .exe_dir = exe_dir,
        .wsl_distros = distros,
        .probe = .{ .io = io },
    });
}

/// The shells detected on the system, kept so that menus, the command
/// palette, the settings and new terminals do not probe the file system
/// on every use. Detection runs again when the environment variables it
/// reads change (`fingerprint`) or after `invalidate`, which apprts call
/// when the user reloads the configuration, so that shells installed in
/// the meantime show up. Keep one per app, on its UI thread.
pub const Cache = struct {
    shells: ?List = null,

    /// The `fingerprint` of the environment `shells` was detected in.
    key: u64 = 0,

    /// The number of detections, for diagnostics.
    detections: u64 = 0,

    /// The launch profiles of the running system: the detected shells,
    /// then `custom`. The caller owns the returned list.
    pub fn list(
        self: *Cache,
        alloc: Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        custom: []const Custom,
    ) Allocator.Error!List {
        const key = fingerprint(.native, env);
        if (self.shells == null or self.key != key) {
            self.store(try detectSystemShells(alloc, io, env), key);
        }
        return try self.withCustom(alloc, custom);
    }

    /// `list` for the shells of `environment` instead of the running
    /// system. Changes to its executable directory and WSL distributions
    /// also detect again; changes that only its probe sees do not.
    pub fn listFor(
        self: *Cache,
        alloc: Allocator,
        environment: Environment,
        custom: []const Custom,
    ) Allocator.Error!List {
        var hasher: std.hash.Wyhash = .init(fingerprint(environment.platform, environment.env));
        hashValue(&hasher, environment.exe_dir);
        for (environment.wsl_distros) |distro| hashValue(&hasher, distro);
        const key = hasher.final();
        if (self.shells == null or self.key != key) {
            self.store(try detectShells(alloc, environment), key);
        }
        return try self.withCustom(alloc, custom);
    }

    /// Forgets the detected shells; the next `list` detects them again.
    pub fn invalidate(self: *Cache) void {
        if (self.shells) |*shells| shells.deinit();
        self.shells = null;
    }

    pub fn deinit(self: *Cache) void {
        self.invalidate();
        self.* = undefined;
    }

    fn store(self: *Cache, shells: List, key: u64) void {
        self.invalidate();
        self.shells = shells;
        self.key = key;
        self.detections += 1;
    }

    fn withCustom(self: *const Cache, alloc: Allocator, custom: []const Custom) Allocator.Error!List {
        var result = try self.shells.?.clone(alloc);
        errdefer result.deinit();
        try result.appendCustom(custom);
        return result;
    }
};

/// A hash of the environment variables that shell detection reads on
/// `platform`.
pub fn fingerprint(platform: Platform, env: *const std.process.Environ.Map) u64 {
    const names: []const []const u8 = switch (platform) {
        .windows => &.{ "PATH", "LOCALAPPDATA", "ProgramFiles", "SystemRoot", "ComSpec" },
        .linux => &.{ "PATH", "SHELL" },
    };
    var hasher: std.hash.Wyhash = .init(@intFromEnum(platform));
    for (names) |name| hashValue(&hasher, env.get(name));
    return hasher.final();
}

/// Hashes `value` so that a missing value, an empty one and the
/// boundaries between values all differ.
fn hashValue(hasher: *std.hash.Wyhash, value: ?[]const u8) void {
    const bytes = value orelse {
        hasher.update(&.{0});
        return;
    };
    hasher.update(&.{1});
    hasher.update(std.mem.asBytes(&bytes.len));
    hasher.update(bytes);
}

/// Whether the recorded configuration inputs `steps`
/// (`Config._replay_steps`) set `command`, so that the default launch
/// profile does not apply: the last `--command=` value before `-e` (whose
/// arguments are the initial command) is not empty. The loaded value
/// cannot tell, because `Config.finalize` falls back to a default shell.
pub fn commandConfigured(steps: anytype) bool {
    const prefix = "--command=";
    var configured = false;
    for (steps) |step| {
        const arg: []const u8 = switch (step) {
            .@"-e" => break,
            .arg => |arg| arg,
            .conditional_arg => |conditional| conditional.arg,
            else => continue,
        };
        if (std.mem.startsWith(u8, arg, prefix)) {
            configured = std.mem.trim(u8, arg[prefix.len..], " ").len > 0;
        }
    }
    return configured;
}

/// The installed WSL distributions from
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`, default
/// distribution first, skipping the internal ones of container tools
/// (`isUtilityDistro`). Returns an empty list when WSL is not installed
/// or on other platforms.
pub fn wslDistros(alloc: Allocator) Allocator.Error![]const []const u8 {
    if (comptime builtin.os.tag != .windows) return &.{};
    return try registry.wslDistros(alloc);
}

/// Whether the WSL distribution `name` belongs to a container tool
/// (Docker Desktop's `docker-desktop` and `docker-desktop-data`, Rancher
/// Desktop's `rancher-desktop` and `rancher-desktop-data`) rather than
/// being a Linux system to open a shell in.
pub fn isUtilityDistro(name: []const u8) bool {
    const prefixes = [_][]const u8{ "docker-desktop", "rancher-desktop" };
    for (prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(name, prefix)) return true;
    }
    return false;
}

const registry = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;
    const HKEY = win.HKEY;
    const LSTATUS = win.LSTATUS;

    const KEY_READ: win.DWORD = 0x20019;
    const RRF_RT_REG_SZ: win.DWORD = 0x00000002;
    const ERROR_SUCCESS: LSTATUS = 0;
    const max_key_len = 256;

    extern "advapi32" fn RegOpenKeyExW(
        hKey: HKEY,
        lpSubKey: [*:0]const u16,
        ulOptions: win.DWORD,
        samDesired: win.DWORD,
        phkResult: *HKEY,
    ) callconv(.winapi) LSTATUS;
    extern "advapi32" fn RegEnumKeyExW(
        hKey: HKEY,
        dwIndex: win.DWORD,
        lpName: [*]u16,
        lpcchName: *win.DWORD,
        lpReserved: ?*win.DWORD,
        lpClass: ?[*]u16,
        lpcchClass: ?*win.DWORD,
        lpftLastWriteTime: ?*win.FILETIME,
    ) callconv(.winapi) LSTATUS;
    extern "advapi32" fn RegGetValueW(
        hkey: HKEY,
        lpSubKey: ?[*:0]const u16,
        lpValue: ?[*:0]const u16,
        dwFlags: win.DWORD,
        pdwType: ?*win.DWORD,
        pvData: ?*anyopaque,
        pcbData: ?*win.DWORD,
    ) callconv(.winapi) LSTATUS;
    extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) LSTATUS;

    const L = std.unicode.wtf8ToWtf16LeStringLiteral;

    fn wslDistros(alloc: Allocator) Allocator.Error![]const []const u8 {
        var key: HKEY = undefined;
        if (RegOpenKeyExW(
            win.HKEY_CURRENT_USER,
            L("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss"),
            0,
            KEY_READ,
            &key,
        ) != ERROR_SUCCESS) return &.{};
        defer _ = RegCloseKey(key);

        var default_buf: [max_key_len:0]u16 = undefined;
        const default_guid = readString(key, null, L("DefaultDistribution"), &default_buf);

        var result: std.ArrayList([]const u8) = .empty;
        var index: win.DWORD = 0;
        while (true) : (index += 1) {
            var name_buf: [max_key_len:0]u16 = undefined;
            var name_len: win.DWORD = name_buf.len;
            if (RegEnumKeyExW(key, index, &name_buf, &name_len, null, null, null, null) != ERROR_SUCCESS) break;
            name_buf[name_len] = 0;
            const guid = name_buf[0..name_len :0];

            var value_buf: [max_key_len:0]u16 = undefined;
            const distro = readString(key, guid, L("DistributionName"), &value_buf) orelse continue;
            const name = try std.unicode.wtf16LeToWtf8Alloc(alloc, distro);
            if (isUtilityDistro(name)) continue;

            const is_default = if (default_guid) |d| std.ascii.eqlIgnoreCase(
                std.mem.sliceAsBytes(d),
                std.mem.sliceAsBytes(guid),
            ) else false;
            if (is_default) try result.insert(alloc, 0, name) else try result.append(alloc, name);
        }
        return try result.toOwnedSlice(alloc);
    }

    fn readString(
        key: HKEY,
        sub_key: ?[*:0]const u16,
        value: [*:0]const u16,
        buf: *[max_key_len:0]u16,
    ) ?[]const u16 {
        var size: win.DWORD = @sizeOf(@TypeOf(buf.*));
        if (RegGetValueW(key, sub_key, value, RRF_RT_REG_SZ, null, buf, &size) != ERROR_SUCCESS) return null;
        const len = @min(size / 2, buf.len);
        return std.mem.sliceTo(buf[0..len], 0);
    }
} else struct {};

fn testEnv(alloc: Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(alloc);
    errdefer env.deinit();
    for (pairs) |pair| try env.put(pair[0], pair[1]);
    return env;
}

fn expectArgv(expected: []const []const u8, command: Command) !void {
    const testing = std.testing;
    const actual = command.argv;
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "launch origin keeps only an owned stable profile id" {
    const testing = std.testing;
    var id = [_]u8{ 'c', 'm', 'd' };
    var origin = try (LaunchOrigin{ .profile = &id }).clone(testing.allocator);
    defer origin.deinit(testing.allocator);
    id[0] = 'x';
    try testing.expectEqualStrings("cmd", origin.profileId().?);
    try testing.expectEqual(@as(?[]const u8, null), @as(LaunchOrigin, .ad_hoc).profileId());
    try testing.expectEqual(@as(?[]const u8, null), @as(LaunchOrigin, .unknown).profileId());
    try testing.expectError(error.OutOfMemory, origin.clone(std.testing.failing_allocator));
    origin.deinit(testing.allocator);
    try testing.expect(origin == .unknown);
}

test "launch origin does not mislabel an initial or ad hoc command as a profile" {
    const testing = std.testing;
    try testing.expect(LaunchOrigin.select("pwsh", "cmd", true, true) == .ad_hoc);
    try testing.expect(LaunchOrigin.select(null, "cmd", true, false) == .ad_hoc);
    try testing.expect(LaunchOrigin.select(null, null, false, false) == .unknown);
    try testing.expectEqualStrings("pwsh", LaunchOrigin.select("pwsh", "cmd", true, false).profileId().?);
    try testing.expectEqualStrings("cmd", LaunchOrigin.select(null, "cmd", false, false).profileId().?);
    try testing.expectEqualStrings("custom:中文", LaunchOrigin.select("custom:中文", null, true, false).profileId().?);
}

test "detect Windows profiles" {
    const testing = std.testing;
    var env = try testEnv(testing.allocator, &.{
        .{ "LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local" },
        .{ "ProgramFiles", "C:\\Program Files" },
        .{ "SystemRoot", "C:\\Windows" },
        .{ "ComSpec", "C:\\Windows\\system32\\cmd.exe" },
        .{ "PATH", "C:\\Windows\\system32;relative\\dir;;\"C:\\Tools\\nu\\bin\";C:\\Users\\u\\scoop\\shims" },
    });
    defer env.deinit();

    var list = try detect(testing.allocator, .{
        .platform = .windows,
        .env = &env,
        .exe_dir = "D:\\Apps\\GhosttyGX",
        .wsl_distros = &.{ "Ubuntu-24.04", "Debian" },
        .probe = .{ .paths = &.{
            "C:\\Users\\u\\AppData\\Local\\Programs\\GXShell\\bin\\gx-zsh.exe",
            "C:\\Users\\u\\AppData\\Local\\Programs\\OhMyZshGX\\bin\\herdr.exe",
            "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
            "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
            "C:\\Windows\\system32\\cmd.exe",
            "C:\\Program Files\\Git\\bin\\bash.exe",
            "C:\\msys64\\msys2_shell.cmd",
            "C:\\Tools\\nu\\bin\\nu.exe",
            "C:\\Windows\\System32\\wsl.exe",
        } },
    }, &.{
        .{ .name = "Python", .command = "direct:python -i" },
    });
    defer list.deinit();

    const ids = [_][]const u8{
        "gx-zsh",       "herdr",   "pwsh",             "powershell", "cmd",           "git-bash",
        "msys2-ucrt64", "nushell", "wsl:Ubuntu-24.04", "wsl:Debian", "custom:Python",
    };
    try testing.expectEqual(ids.len, list.profiles.len);
    for (ids, list.profiles) |id, profile| try testing.expectEqualStrings(id, profile.id);

    try expectArgv(&.{"C:\\Users\\u\\AppData\\Local\\Programs\\GXShell\\bin\\gx-zsh.exe"}, list.find("gx-zsh").?.command);
    try expectArgv(&.{"C:\\Users\\u\\AppData\\Local\\Programs\\OhMyZshGX\\bin\\herdr.exe"}, list.find("herdr").?.command);
    try expectArgv(&.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"}, list.find("pwsh").?.command);
    try expectArgv(&.{"C:\\Windows\\system32\\cmd.exe"}, list.find("cmd").?.command);
    try expectArgv(&.{ "C:\\Program Files\\Git\\bin\\bash.exe", "-i", "-l" }, list.find("git-bash").?.command);
    try expectArgv(
        &.{ "C:\\msys64\\msys2_shell.cmd", "-defterm", "-here", "-no-start", "-ucrt64" },
        list.find("msys2-ucrt64").?.command,
    );
    try expectArgv(&.{"C:\\Tools\\nu\\bin\\nu.exe"}, list.find("nushell").?.command);
    try expectArgv(&.{ "C:\\Windows\\System32\\wsl.exe", "-d", "Ubuntu-24.04" }, list.find("wsl:Ubuntu-24.04").?.command);

    const wsl = list.find("wsl:Debian").?;
    try testing.expectEqual(Kind.wsl, wsl.kind);
    try testing.expectEqualStrings("WSL: {name}", wsl.name);
    try testing.expectEqualStrings("Debian", wsl.name_arg.?);

    const custom = list.find("custom:Python").?;
    try testing.expectEqual(Kind.custom, custom.kind);
    try testing.expectEqualStrings("direct:python -i", custom.command.command_line);

    try testing.expectEqualStrings("gx-zsh", defaultProfile(list.profiles, .windows).?.id);
}

test "detect Windows GX tools next to the executable and on PATH" {
    const testing = std.testing;
    var env = try testEnv(testing.allocator, &.{
        .{ "PATH", "C:\\bin;C:\\Program Files\\PowerShell\\7" },
    });
    defer env.deinit();

    var list = try detect(testing.allocator, .{
        .platform = .windows,
        .env = &env,
        .exe_dir = "D:\\GXShell\\ghostty\\",
        .probe = .{ .paths = &.{
            "D:\\GXShell\\bin\\gx-zsh.exe",
            "C:\\bin\\herdr.exe",
            "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        } },
    }, &.{});
    defer list.deinit();

    try testing.expectEqual(@as(usize, 3), list.profiles.len);
    try expectArgv(&.{"D:\\GXShell\\bin\\gx-zsh.exe"}, list.find("gx-zsh").?.command);
    try expectArgv(&.{"C:\\bin\\herdr.exe"}, list.find("herdr").?.command);
    try expectArgv(&.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"}, list.find("pwsh").?.command);
}

test "Windows default profile falls back through PowerShell to cmd" {
    const testing = std.testing;
    var env = try testEnv(testing.allocator, &.{
        .{ "SystemRoot", "C:\\Windows" },
    });
    defer env.deinit();

    {
        var list = try detect(testing.allocator, .{
            .platform = .windows,
            .env = &env,
            .probe = .{ .paths = &.{
                "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                "C:\\Windows\\System32\\cmd.exe",
            } },
        }, &.{});
        defer list.deinit();
        try testing.expectEqualStrings("powershell", defaultProfile(list.profiles, .windows).?.id);
    }
    {
        var list = try detect(testing.allocator, .{
            .platform = .windows,
            .env = &env,
            .wsl_distros = &.{"Ubuntu"},
            .probe = .{ .paths = &.{"C:\\Windows\\System32\\cmd.exe"} },
        }, &.{});
        defer list.deinit();
        try testing.expectEqualStrings("cmd", defaultProfile(list.profiles, .windows).?.id);
        try expectArgv(&.{ "wsl.exe", "-d", "Ubuntu" }, list.find("wsl:Ubuntu").?.command);
    }
    {
        var list = try detect(testing.allocator, .{
            .platform = .windows,
            .env = &env,
            .probe = .{ .paths = &.{} },
        }, &.{});
        defer list.deinit();
        try testing.expectEqual(@as(?*const Profile, null), defaultProfile(list.profiles, .windows));
    }
}

test "detect Linux profiles" {
    const testing = std.testing;
    var env = try testEnv(testing.allocator, &.{
        .{ "SHELL", "/usr/bin/zsh" },
        .{ "PATH", "/home/u/.local/bin:relative:/usr/bin:/bin" },
    });
    defer env.deinit();

    var list = try detect(testing.allocator, .{
        .platform = .linux,
        .env = &env,
        .probe = .{ .paths = &.{
            "/usr/lib/ohmyzsh-gx/bin/gx-zsh",
            "/home/u/.local/bin/herdr",
            "/usr/bin/zsh",
            "/usr/bin/bash",
            "/bin/bash",
            "/usr/bin/fish",
        } },
    }, &.{
        .{ .name = "htop", .command = "htop" },
    });
    defer list.deinit();

    const ids = [_][]const u8{ "gx-zsh", "herdr", "login-shell", "bash", "fish", "custom:htop" };
    try testing.expectEqual(ids.len, list.profiles.len);
    for (ids, list.profiles) |id, profile| try testing.expectEqualStrings(id, profile.id);
    try expectArgv(&.{"/usr/lib/ohmyzsh-gx/bin/gx-zsh"}, list.find("gx-zsh").?.command);
    try expectArgv(&.{"/home/u/.local/bin/herdr"}, list.find("herdr").?.command);
    try expectArgv(&.{"/usr/bin/zsh"}, list.find("login-shell").?.command);
    try expectArgv(&.{"/usr/bin/bash"}, list.find("bash").?.command);
    try testing.expectEqualStrings("gx-zsh", defaultProfile(list.profiles, .linux).?.id);
}

test "Linux default profile falls back to the login shell" {
    const testing = std.testing;
    var env = try testEnv(testing.allocator, &.{
        .{ "SHELL", "/bin/bash" },
        .{ "PATH", "/usr/bin" },
    });
    defer env.deinit();

    var list = try detect(testing.allocator, .{
        .platform = .linux,
        .env = &env,
        .probe = .{ .paths = &.{ "/bin/bash", "/usr/bin/gx-zsh-not-this", "/usr/bin/zsh" } },
    }, &.{});
    defer list.deinit();
    try testing.expectEqualStrings("login-shell", defaultProfile(list.profiles, .linux).?.id);
    try testing.expectEqualStrings("zsh", list.profiles[1].id);
}

test "displayName translates detected profiles only" {
    const testing = std.testing;
    const saved = i18n.current();
    defer i18n.setCurrent(saved);

    const cmd: Profile = .{ .id = "cmd", .name = "Command Prompt", .command = .{ .argv = &.{"cmd.exe"} }, .kind = .cmd };
    const wsl: Profile = .{
        .id = "wsl:Ubuntu",
        .name = "WSL: {name}",
        .name_arg = "Ubuntu",
        .command = .{ .argv = &.{ "wsl.exe", "-d", "Ubuntu" } },
        .kind = .wsl,
    };
    const custom: Profile = .{ .id = "custom:Copy", .name = "Copy", .command = .{ .command_line = "x" }, .kind = .custom };

    i18n.setCurrent(.zh_CN);
    inline for (.{ .{ cmd, "命令提示符" }, .{ wsl, "WSL: Ubuntu" }, .{ custom, "Copy" } }) |case| {
        const name = try displayName(testing.allocator, case[0]);
        defer testing.allocator.free(name);
        try testing.expectEqualStrings(case[1], name);
    }

    i18n.setCurrent(.en);
    const name = try displayName(testing.allocator, cmd);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("Command Prompt", name);
}

test "List.resolve finds ids, custom names and display names" {
    const testing = std.testing;
    const saved = i18n.current();
    defer i18n.setCurrent(saved);

    var env = try testEnv(testing.allocator, &.{
        .{ "SystemRoot", "C:\\Windows" },
        .{ "ComSpec", "C:\\Windows\\system32\\cmd.exe" },
    });
    defer env.deinit();
    var list = try detect(testing.allocator, .{
        .platform = .windows,
        .env = &env,
        .wsl_distros = &.{"Ubuntu-24.04"},
        .probe = .{ .paths = &.{"C:\\Windows\\system32\\cmd.exe"} },
    }, &.{
        .{ .name = "Python", .command = "direct:python -i" },
        .{ .name = "cmd", .command = "cmd.exe /k echo custom" },
    });
    defer list.deinit();

    i18n.setCurrent(.zh_CN);
    try testing.expectEqualStrings("cmd", list.resolve("cmd").?.id);
    try testing.expectEqualStrings("custom:cmd", list.resolve("custom:cmd").?.id);
    try testing.expectEqualStrings("custom:Python", list.resolve("Python").?.id);
    try testing.expectEqualStrings("custom:Python", list.resolve("python").?.id);
    try testing.expectEqualStrings("cmd", list.resolve("命令提示符").?.id);
    try testing.expectEqualStrings("cmd", list.resolve("command prompt").?.id);
    try testing.expectEqualStrings("wsl:Ubuntu-24.04", list.resolve("wsl:Ubuntu-24.04").?.id);
    try testing.expectEqualStrings("wsl:Ubuntu-24.04", list.resolve("WSL: ubuntu-24.04").?.id);
    try testing.expectEqual(@as(?*const Profile, null), list.resolve("WSL: Debian"));
    try testing.expectEqual(@as(?*const Profile, null), list.resolve("wsl"));
    try testing.expectEqual(@as(?*const Profile, null), list.resolve(""));
}

test "appendCustom and clone keep the profiles apart" {
    const testing = std.testing;
    var env = try testEnv(testing.allocator, &.{.{ "SHELL", "/bin/bash" }});
    defer env.deinit();
    var shells = try detectShells(testing.allocator, .{
        .platform = .linux,
        .env = &env,
        .probe = .{ .paths = &.{"/bin/bash"} },
    });
    var copy = try shells.clone(testing.allocator);
    defer copy.deinit();
    try shells.appendCustom(&.{});
    try testing.expectEqual(@as(usize, 1), shells.profiles.len);
    shells.deinit();

    try copy.appendCustom(&.{
        .{ .name = "Logs", .command = "tail -f /tmp/x.log" },
        .{ .name = "Top", .command = "htop" },
    });
    const ids = [_][]const u8{ "login-shell", "custom:Logs", "custom:Top" };
    try testing.expectEqual(ids.len, copy.profiles.len);
    for (ids, copy.profiles) |id, profile| try testing.expectEqualStrings(id, profile.id);
    try expectArgv(&.{"/bin/bash"}, copy.profiles[0].command);
    try testing.expectEqualStrings("htop", copy.profiles[2].command.command_line);
}

test "Cache detects again only when the environment changes" {
    const testing = std.testing;
    var env = try testEnv(testing.allocator, &.{
        .{ "SHELL", "/bin/bash" },
        .{ "PATH", "/usr/bin" },
    });
    defer env.deinit();
    const environment: Environment = .{
        .platform = .linux,
        .env = &env,
        .probe = .{ .paths = &.{ "/bin/bash", "/usr/bin/zsh" } },
    };

    var cache: Cache = .{};
    defer cache.deinit();
    {
        var list = try cache.listFor(testing.allocator, environment, &.{});
        defer list.deinit();
        try testing.expectEqual(@as(usize, 2), list.profiles.len);
    }
    {
        // New custom profiles do not need a new detection.
        var list = try cache.listFor(testing.allocator, environment, &.{.{ .name = "Top", .command = "htop" }});
        defer list.deinit();
        try testing.expectEqual(@as(usize, 3), list.profiles.len);
        try testing.expectEqualStrings("custom:Top", list.profiles[2].id);
    }
    try testing.expectEqual(@as(u64, 1), cache.detections);

    // A changed PATH, a forced refresh and new WSL distributions do.
    try env.put("PATH", "/usr/local/bin:/usr/bin");
    var list = try cache.listFor(testing.allocator, environment, &.{});
    list.deinit();
    try testing.expectEqual(@as(u64, 2), cache.detections);
    cache.invalidate();
    list = try cache.listFor(testing.allocator, environment, &.{});
    list.deinit();
    try testing.expectEqual(@as(u64, 3), cache.detections);
    var with_distro = environment;
    with_distro.wsl_distros = &.{"Ubuntu"};
    list = try cache.listFor(testing.allocator, with_distro, &.{});
    list.deinit();
    try testing.expectEqual(@as(u64, 4), cache.detections);
    list = try cache.listFor(testing.allocator, with_distro, &.{});
    list.deinit();
    try testing.expectEqual(@as(u64, 4), cache.detections);
}

test "fingerprint covers the variables detection reads" {
    const testing = std.testing;
    var env = try testEnv(testing.allocator, &.{.{ "PATH", "/usr/bin" }});
    defer env.deinit();
    const base = fingerprint(.linux, &env);
    try testing.expect(base != fingerprint(.windows, &env));

    try env.put("HOME", "/home/u");
    try testing.expectEqual(base, fingerprint(.linux, &env));
    try env.put("SHELL", "");
    const empty_shell = fingerprint(.linux, &env);
    try testing.expect(base != empty_shell);
    try env.put("SHELL", "/bin/zsh");
    try testing.expect(empty_shell != fingerprint(.linux, &env));
    try testing.expectEqual(fingerprint(.windows, &env), fingerprint(.windows, &env));
}

test "isUtilityDistro skips the distributions of container tools" {
    const testing = std.testing;
    try testing.expect(isUtilityDistro("docker-desktop"));
    try testing.expect(isUtilityDistro("docker-desktop-data"));
    try testing.expect(isUtilityDistro("rancher-desktop"));
    try testing.expect(isUtilityDistro("rancher-desktop-data"));
    try testing.expect(isUtilityDistro("Rancher-Desktop"));
    try testing.expect(!isUtilityDistro("Ubuntu-24.04"));
    try testing.expect(!isUtilityDistro("docker"));
    try testing.expect(!isUtilityDistro(""));
}

test "commandConfigured reads the recorded configuration inputs" {
    const testing = std.testing;
    const Config = @import("../config/Config.zig");
    const cli = @import("../cli.zig");

    var config: Config = try .default(testing.allocator);
    defer config.deinit();
    try testing.expect(!commandConfigured(config._replay_steps.items));

    const Load = struct {
        fn lines(cfg: *Config, text: []const u8) !void {
            var reader: std.Io.Reader = .fixed(text);
            var iter: cli.args.LineIterator = .{ .r = &reader, .filepath = "test" };
            try cfg.loadIter(testing.allocator, &iter);
        }
    };
    try Load.lines(&config, "font-size = 13\n");
    try testing.expect(!commandConfigured(config._replay_steps.items));
    try Load.lines(&config, "command = pwsh -NoLogo\n");
    try testing.expect(commandConfigured(config._replay_steps.items));
    // An empty value resets `command` to its default.
    try Load.lines(&config, "command =\n");
    try testing.expect(!commandConfigured(config._replay_steps.items));
    try Load.lines(&config, "command = direct:cmd.exe\n");
    try testing.expect(commandConfigured(config._replay_steps.items));

    // The arguments after `-e` are the initial command, not configuration.
    const Step = std.meta.Elem(@TypeOf(config._replay_steps.items));
    try testing.expect(!commandConfigured(&[_]Step{ .@"-e", .{ .arg = "--command=pwsh" } }));
    try testing.expect(commandConfigured(&[_]Step{ .{ .arg = "--command=pwsh" }, .@"-e", .{ .arg = "--command=" } }));
}

test "wslDistros reads the registry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const distros = try wslDistros(arena.allocator());
    for (distros) |distro| {
        try testing.expect(distro.len > 0);
        try testing.expect(!isUtilityDistro(distro));
    }
}

test "detectSystem finds a shell on the running system" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var env = try std.testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var list = try detectSystem(testing.allocator, testing.io, &env, &.{});
    defer list.deinit();
    for (list.profiles) |profile| {
        try testing.expect(profile.id.len > 0);
        switch (profile.command) {
            .argv => |args| try testing.expect(args.len > 0),
            .command_line => unreachable,
        }
    }
    if (builtin.os.tag == .windows) try testing.expect(list.find("cmd") != null);
}
