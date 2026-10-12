//! Value-only identities for GUI-owned windows, tabs and core surfaces.
//! Resolve them against live GUI records before acting; identity values do
//! not prove liveness or authenticate an IPC peer. These are not wire layouts.
//! Object lifetimes remain stable across moves; view attachments do not.
const std = @import("std");

pub const HostEpoch = u128;
pub const Kind = enum(u8) { window = 1, tab = 2, surface = 3 };
pub const Error = error{ InvalidEpoch, InvalidKind, InvalidId, InvalidReference, InvalidOwner, ForeignEpoch, Exhausted };

pub const Reference = struct {
    epoch: HostEpoch = 0,
    kind: Kind = .window,
    id: u64 = 0,
    generation: u64 = 0,

    pub fn isValid(self: Reference) bool {
        return self.epoch != 0 and self.id != 0 and self.generation != 0;
    }

    /// Compares with the identity stored on a live object, not a saved pointer.
    pub fn matches(self: Reference, live: Reference) bool {
        return self.isValid() and live.isValid() and std.meta.eql(self, live);
    }
};

pub const Attachment = struct {
    object: Reference = .{},
    owner: Reference = .{},
    revision: u64 = 0,

    pub fn isValid(self: Attachment) bool {
        return self.object.isValid() and self.owner.isValid() and self.owner.kind == .window and
            self.object.epoch == self.owner.epoch and self.revision != 0;
    }

    /// A move away and back, or a hide/reopen, must publish a fresh attachment.
    pub fn matches(self: Attachment, live: Attachment) bool {
        return self.isValid() and live.isValid() and std.meta.eql(self, live);
    }
};

/// GUI-thread issuer. Use a fresh nonzero host epoch for every app lifetime;
/// do not copy an issuer or restore its serial/epoch from session state.
pub const Issuer = struct {
    epoch: HostEpoch,
    serial: u64 = 0,

    pub fn init(epoch: HostEpoch) Error!Issuer {
        if (epoch == 0) return error.InvalidEpoch;
        return .{ .epoch = epoch };
    }

    pub fn create(self: *Issuer, kind: Kind) Error!Reference {
        if (kind == .surface) return error.InvalidKind;
        const serial = try self.next();
        return .{ .epoch = self.epoch, .kind = kind, .id = serial, .generation = serial };
    }

    /// Preserve the existing core Surface ID, with a fresh lifetime generation.
    pub fn surface(self: *Issuer, core_id: u64) Error!Reference {
        if (core_id == 0) return error.InvalidId;
        return .{ .epoch = self.epoch, .kind = .surface, .id = core_id, .generation = try self.next() };
    }

    /// Reserve before mutating widget ownership; failure leaves the model alone.
    pub fn attach(self: *Issuer, object: Reference, owner: Reference) Error!Attachment {
        if (!object.isValid() or !owner.isValid()) return error.InvalidReference;
        if (owner.kind != .window) return error.InvalidOwner;
        if (object.epoch != self.epoch or owner.epoch != self.epoch) return error.ForeignEpoch;
        return .{ .object = object, .owner = owner, .revision = try self.next() };
    }

    fn next(self: *Issuer) Error!u64 {
        if (self.epoch == 0) return error.InvalidEpoch;
        const serial = std.math.add(u64, self.serial, 1) catch return error.Exhausted;
        self.serial = serial;
        return serial;
    }
};

test "empty and partial references never match" {
    const empty: Reference = .{};
    try std.testing.expect(!empty.matches(empty));
    const partial = [_]Reference{
        .{ .epoch = 1, .id = 1 },
        .{ .epoch = 1, .generation = 1 },
        .{ .id = 1, .generation = 1 },
    };
    for (partial) |reference| {
        try std.testing.expect(!reference.isValid());
        try std.testing.expect(!reference.matches(reference));
    }
    const detached: Attachment = .{};
    try std.testing.expect(!detached.matches(detached));
}

test "references distinguish host kind id and lifetime generation" {
    var issuer = try Issuer.init(1234);
    const reference = try issuer.create(.window);
    try std.testing.expect(reference.matches(reference));
    var changed = reference;
    changed.epoch += 1;
    try std.testing.expect(!reference.matches(changed));
    changed = reference;
    changed.kind = .tab;
    try std.testing.expect(!reference.matches(changed));
    changed = reference;
    changed.id += 1;
    try std.testing.expect(!reference.matches(changed));
    changed = reference;
    changed.generation += 1;
    try std.testing.expect(!reference.matches(changed));
    const tab = try issuer.create(.tab);
    try std.testing.expect(tab.id != reference.id);
    try std.testing.expectEqual(Kind.tab, tab.kind);
}

test "surface references retain core ids but reject reused lifetimes" {
    var issuer = try Issuer.init(1);
    const first = try issuer.surface(42);
    const replacement = try issuer.surface(42);
    try std.testing.expectEqual(@as(u64, 42), first.id);
    try std.testing.expectEqual(@as(u64, 42), replacement.id);
    try std.testing.expectEqual(Kind.surface, first.kind);
    try std.testing.expect(first.generation != replacement.generation);
    try std.testing.expect(!first.matches(replacement));
    const serial = issuer.serial;
    try std.testing.expectError(error.InvalidKind, issuer.create(.surface));
    try std.testing.expectError(error.InvalidId, issuer.surface(0));
    try std.testing.expectEqual(serial, issuer.serial);
}

test "reattaching invalidates old views without changing the terminal identity" {
    var issuer = try Issuer.init(1);
    const left = try issuer.create(.window);
    const right = try issuer.create(.window);
    const terminal = try issuer.surface(42);
    const original = try issuer.attach(terminal, left);
    const moved = try issuer.attach(terminal, right);
    const returned = try issuer.attach(terminal, left);
    try std.testing.expect(original.object.matches(moved.object));
    try std.testing.expect(original.object.matches(returned.object));
    try std.testing.expect(original.owner.matches(returned.owner));
    try std.testing.expect(original.matches(original));
    try std.testing.expect(!original.matches(moved));
    try std.testing.expect(!original.matches(returned));
    try std.testing.expect(original.revision < moved.revision);
    try std.testing.expect(moved.revision < returned.revision);
}

test "invalid and foreign attachments do not consume identity serials" {
    try std.testing.expectError(error.InvalidEpoch, Issuer.init(0));
    var issuer = try Issuer.init(1);
    var other = try Issuer.init(2);
    const owner = try issuer.create(.window);
    const terminal = try issuer.surface(42);
    const foreign_owner = try other.create(.window);
    const serial = issuer.serial;
    try std.testing.expectError(error.InvalidReference, issuer.attach(.{}, owner));
    try std.testing.expectError(error.InvalidReference, issuer.attach(terminal, .{}));
    try std.testing.expectError(error.InvalidOwner, issuer.attach(terminal, terminal));
    try std.testing.expectError(error.ForeignEpoch, issuer.attach(terminal, foreign_owner));
    try std.testing.expectError(error.ForeignEpoch, other.attach(terminal, foreign_owner));
    try std.testing.expectEqual(serial, issuer.serial);
    const bad: Attachment = .{ .object = terminal, .owner = foreign_owner, .revision = 1 };
    try std.testing.expect(!bad.isValid());
    try std.testing.expect(!bad.matches(bad));
}

test "identity exhaustion fails closed without wrapping or reusing a generation" {
    var issuer = try Issuer.init(1);
    issuer.serial = std.math.maxInt(u64) - 1;
    const last = try issuer.create(.window);
    try std.testing.expectEqual(std.math.maxInt(u64), last.id);
    try std.testing.expectEqual(std.math.maxInt(u64), last.generation);
    try std.testing.expectError(error.Exhausted, issuer.create(.tab));
    try std.testing.expectError(error.Exhausted, issuer.surface(42));
    try std.testing.expectError(error.Exhausted, issuer.attach(last, last));
    try std.testing.expectEqual(std.math.maxInt(u64), issuer.serial);
}
