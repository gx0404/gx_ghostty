//! Owned, bounded remote-view control messages. Pixels use a separate mapping;
//! argv and environment are absent. UI metadata, text snapshots and clipboard
//! contents cross only the authenticated view lease and bounded request paths.
//! Epochs and numeric handles are claims until the native pipe authenticates them.
const std = @import("std");
const refs = @import("ui_ref.zig");
const view = @import("remote_view.zig");
const policy = @import("ipc/policy.zig");
pub const version: u16 = 2;
pub const max_frame_size = 64 * 1024;
pub const max_nodes = 256;
pub const max_leaves = 128;
pub const Ticket = view.Ticket;
pub const Lease = view.InputLease;

pub fn Bounded(comptime T: type, comptime limit: usize) type {
    return struct {
        pub const Element = T;
        pub const capacity = limit;
        len: u16 = 0,
        items: [limit]T = undefined,
        pub fn init(values: []const T) !@This() {
            if (values.len > limit) return error.LimitExceeded;
            var result: @This() = .{ .len = @intCast(values.len) };
            @memcpy(result.items[0..values.len], values);
            return result;
        }
        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }
    };
}
pub const Text = Bounded(u8, 4096);
pub const Title = Bounded(u8, 1024);
pub const ActionText = Bounded(u8, 1024);
pub const SnapshotText = Bounded(u8, 60 * 1024);
pub const max_paste_bytes = 16 * 1024 * 1024;
pub const NativeKey = struct { virtual_key: u16, scan_code: u16, extended: bool = false, control_state: u16 = 0, codepoint: u32 = 0, text: Bounded(u16, 4) = .{}, repeat_count: u16 = 1, dead: bool = false };
pub const PasteParent = struct { transaction: u64, config_generation: u64 };
pub const Paste = struct { transfer: u64, index: u32, last: bool, text: Text, parent: ?PasteParent = null };
pub const DropPoint = struct { x: i32, y: i32 };
pub const Node = union(enum(u16)) {
    leaf: refs.Reference,
    split: struct { axis: enum(u16) { horizontal, vertical }, ratio: f32, first: u16, second: u16 },
};
pub const Tree = struct {
    nodes: Bounded(Node, max_nodes),
    root: u16,
    active: u16,
    zoom: ?u16 = null,
    tab_override: Title = .{},
    window_override: Title = .{},
    drop_point: ?DropPoint = null,
    drop_index: ?u16 = null,
};
pub const Mapping = struct {
    surface: refs.Reference,
    offer_id: u64,
    source: policy.Process,
    target: policy.Process,
    source_epoch: u128,
    target_epoch: u128,
    generation: u64,
    width: u32,
    height: u32,
    stride: u32,
    bytes: u64,
    target_handle: u64,
};
pub const Input = struct {
    surface: refs.Reference,
    lease: Lease,
    sequence: u64,
    event: union(enum(u16)) {
        key: struct { action: enum(u16) { release, press, repeat }, physical: u16, unicode: u32, modifiers: u16, text: Text = .{}, consumed_modifiers: u16 = 0, composing: bool = false, unshifted_codepoint: u32 = 0, native: ?NativeKey = null },
        text: Text,
        composition: struct { phase: enum(u16) { start, update, end }, text: Text = .{} },
        visible: bool,
        mouse: struct { action: enum(u16) { press, release, motion, scroll }, button: enum(u16) { none, left, middle, right, four, five, six, seven, eight, nine, ten, eleven }, x: f32, y: f32, scroll_x: f32, scroll_y: f32, modifiers: u16 },
        focus: bool,
        resize: struct { width: u32, height: u32, dpi: u32 },
        /// Source must apply protected-paste policy and never append Enter.
        paste: Paste,
    },
};
pub const Outcome = enum(u16) { completed, rejected, unavailable, cancelled, unknown };
pub const ActionRequest = struct { surface: refs.Reference, lease: Lease, transaction: u64, config_generation: u64, action: ActionText, all: bool = false, global: bool = false };
pub const ActionResult = struct { surface: refs.Reference, lease: Lease, transaction: u64, config_generation: u64, performed: bool, closed: bool = false };
pub const RuntimeEvent = union(enum(u16)) {
    readonly: bool,
    /// Complete formatted sequence; null ends its hint.
    key_sequence: ?ActionText,
    /// Current top table name; an empty value hides its hint.
    key_table: Title,
    /// OSC 9;4 states: remove, set, error, indeterminate, pause.
    progress: struct { state: u8, progress: ?u8 },
    command_finished: struct { exit_code: ?u8, duration_ns: u64 },
    mouse_over_link: Text,
};
/// Runtime callbacks carry owned values, never borrowed core pointers. Native
/// dispatch is asynchronous; only the matching result commits its effect.
pub const UiEvent = struct {
    surface: refs.Reference,
    lease: Lease,
    transaction: u64,
    config_generation: u64,
    event: union(enum(u16)) {
        open_url: struct { kind: enum(u16) { unknown, text, html, osc8 }, url: SnapshotText },
        desktop_notification: struct { title: Title, body: Text },
        export_terminal_io: SnapshotText,
        start_search: Text,
        runtime: RuntimeEvent,
        present_terminal,
        resize_window: struct { width: u32, height: u32 },
    },
};
pub const InspectorCommand = enum(u16) { open, close, refresh, clear, pause, @"resume", export_io };
pub const InspectorRequest = struct { surface: refs.Reference, lease: Lease, transaction: u64, config_generation: u64, command: InspectorCommand };
pub const InspectorResult = struct { surface: refs.Reference, lease: Lease, transaction: u64, config_generation: u64, command: InspectorCommand, performed: bool, active: bool = false, paused: bool = false, text: SnapshotText = .{}, truncated: bool = false };
pub const SurfaceState = struct { surface: refs.Reference, lease: Lease, path_quoting: @import("path_quote.zig").Style = .windows, title: Title = .{}, pwd: Text = .{}, bell: bool = false, cursor: u16 = 0, mouse_visible: bool = true, confirm_quit: bool = false, exited: bool = false, search_active: bool = false, search_total: ?u64 = null, search_selected: ?u64 = null, search_progress: ?f32 = null, config_generation: u64 = 1, grid_columns: u32 = 0, grid_rows: u32 = 0, selection: bool = false, cursor_x: f64 = 0, cursor_y: f64 = 0, cursor_width: f64 = 1, cursor_height: f64 = 1, cell_width: u32 = 1, cell_height: u32 = 1 };
pub const ConfirmRequest = struct { surface: refs.Reference, lease: Lease, transaction: u64, reason: enum(u16) { close, paste, clipboard_read, clipboard_write }, text: Text = .{} };
pub const ConfirmResult = struct { surface: refs.Reference, lease: Lease, transaction: u64, confirmed: bool };
pub const SnapshotRequest = struct { surface: refs.Reference, lease: Lease, transaction: u64, kind: enum(u16) { selection, screen, scrollback } = .selection };
pub const SnapshotResult = struct { surface: refs.Reference, lease: Lease, transaction: u64, text: SnapshotText = .{}, truncated: bool = false };
/// Text and HTML share one payload budget, so every packet still fits in a
/// single control frame. Presence flags preserve empty-but-valid contents.
pub const ClipboardRequest = struct {
    surface: refs.Reference,
    lease: Lease,
    transaction: u64,
    kind: enum(u16) { read, write, list },
    prompt: bool = false,
    confirmed: bool = false,
    has_text: bool = false,
    has_html: bool = false,
    text_len: u16 = 0,
    data: SnapshotText = .{},

    pub fn plain(self: *const @This()) []const u8 {
        return self.data.slice()[0..self.text_len];
    }
    pub fn html(self: *const @This()) []const u8 {
        return self.data.slice()[self.text_len..];
    }
};
pub const ClipboardResult = struct {
    surface: refs.Reference,
    lease: Lease,
    transaction: u64,
    performed: bool,
    has_text: bool = false,
    has_html: bool = false,
    text_len: u16 = 0,
    data: SnapshotText = .{},

    pub fn plain(self: *const @This()) []const u8 {
        return self.data.slice()[0..self.text_len];
    }
    pub fn html(self: *const @This()) []const u8 {
        return self.data.slice()[self.text_len..];
    }
};
pub const Body = union(enum(u16)) {
    prepare: Tree,
    mapping_offer: Mapping,
    mapping_receipt: struct { offer_id: u64, target_handle: u64 },
    ready,
    commit: Lease,
    target_enabled,
    source_revoked,
    abort,
    query,
    status: view.Status,
    input: Input,
    frame_ready: struct { surface: refs.Reference, generation: u64, sequence: u64 },
    acknowledgement: struct { outcome: Outcome, offer_id: u64 = 0, target_handle: u64 = 0 },
    ui_action: ActionRequest,
    ui_action_result: ActionResult,
    apply_action: ActionRequest,
    apply_action_result: ActionResult,
    surface_state: SurfaceState,
    confirm_request: ConfirmRequest,
    confirm_result: ConfirmResult,
    text_snapshot: SnapshotRequest,
    text_snapshot_result: SnapshotResult,
    keybind_snapshot: SnapshotRequest,
    keybind_snapshot_result: SnapshotResult,
    close_request: struct { surface: refs.Reference, lease: Lease, confirmed: bool = false },
    leaf_closed: struct { surface: refs.Reference },
    clipboard_request: ClipboardRequest,
    clipboard_result: ClipboardResult,
    ui_event: UiEvent,
    ui_event_result: ActionResult,
    inspector_request: InspectorRequest,
    inspector_result: InspectorResult,
};
pub const Packet = struct {
    sender_epoch: u128,
    recipient_epoch: u128,
    request_id: u64,
    ticket: Ticket,
    body: Body,
};
pub const Error = error{ LimitExceeded, InvalidFrame, InvalidVersion, InvalidEnum, InvalidIdentity, InvalidText, InvalidTree, InvalidInput, InvalidMapping, TrailingBytes };

/// Source GUI calls this against its exact input.Key enum before constructing
/// a terminal key event. The wire's u16 bound alone is deliberately insufficient.
pub fn physicalKey(comptime Key: type, value: u16) Error!Key {
    return std.enums.fromInt(Key, value) orelse error.InvalidInput;
}

/// Store with the source terminal, NOT with a pipe connection. Reconnects do
/// not reset it, so an unknown input ACK never permits replaying that event.
pub const InputSequence = struct {
    lease: ?Lease = null,
    sequence: u64 = 0,
    pub fn accept(self: *InputSequence, authority: *const view.SourceAuthority, input: *const Input) !void {
        if (!authority.acceptsInput(input.lease) or input.sequence == 0) return error.InvalidInput;
        if (self.lease) |previous| {
            if (input.lease.generation < previous.generation) return error.InvalidInput;
            if (std.meta.eql(previous, input.lease) and input.sequence <= self.sequence) return error.RepeatedInput;
        }
        self.lease = input.lease;
        self.sequence = input.sequence;
    }
};

fn text(value: anytype) Error!void {
    if (value.len > value.items.len or !std.unicode.utf8ValidateSlice(value.slice()) or std.mem.indexOfScalar(u8, value.slice(), 0) != null) return error.InvalidText;
}
fn reference(value: refs.Reference, epoch: u128) Error!void {
    if (!value.isValid() or value.kind != .surface or value.epoch != epoch) return error.InvalidIdentity;
}
fn validLease(lease: Lease, ticket: Ticket) Error!void {
    if (lease.holder_epoch != ticket.target_epoch or lease.generation != ticket.generation or lease.transaction != ticket.transaction) return error.InvalidIdentity;
}
fn codepoint(value: u32) bool {
    return value <= 0x10ffff and !(value >= 0xd800 and value <= 0xdfff);
}
fn visit(tree: *const Tree, index: u16, depth: usize, visited: *[max_nodes]bool, leaves: *usize, epoch: u128) Error!void {
    if (depth > 32 or index >= tree.nodes.len or visited[index]) return error.InvalidTree;
    visited[index] = true;
    switch (tree.nodes.items[index]) {
        .leaf => |value| {
            try reference(value, epoch);
            leaves.* += 1;
            if (leaves.* > max_leaves) return error.InvalidTree;
            for (tree.nodes.slice()[0..index]) |prior| if (prior == .leaf and prior.leaf.matches(value)) return error.InvalidTree;
        },
        .split => |split| {
            if (!std.math.isFinite(split.ratio) or split.ratio <= 0 or split.ratio >= 1) return error.InvalidTree;
            try visit(tree, split.first, depth + 1, visited, leaves, epoch);
            try visit(tree, split.second, depth + 1, visited, leaves, epoch);
        },
    }
}
pub fn validate(packet: *const Packet) Error!void {
    const ticket = packet.ticket;
    if (packet.sender_epoch == 0 or packet.recipient_epoch == 0 or packet.request_id == 0 or
        ticket.source_epoch == 0 or ticket.target_epoch == 0 or ticket.source_epoch == ticket.target_epoch or
        ticket.transaction == 0 or ticket.generation == 0 or
        !((packet.sender_epoch == ticket.source_epoch and packet.recipient_epoch == ticket.target_epoch) or
            (packet.sender_epoch == ticket.target_epoch and packet.recipient_epoch == ticket.source_epoch))) return error.InvalidIdentity;
    switch (packet.body) {
        .prepare => |*tree| {
            if (packet.sender_epoch != ticket.source_epoch or tree.nodes.len == 0 or tree.nodes.len > max_nodes) return error.InvalidTree;
            var visited = [_]bool{false} ** max_nodes;
            var leaves: usize = 0;
            try visit(tree, tree.root, 0, &visited, &leaves, ticket.source_epoch);
            for (visited[0..tree.nodes.len]) |found| if (!found) return error.InvalidTree;
            if (tree.active >= tree.nodes.len or tree.nodes.items[tree.active] != .leaf) return error.InvalidTree;
            if (tree.zoom) |zoom| if (zoom >= tree.nodes.len or tree.nodes.items[zoom] != .leaf) return error.InvalidTree;
            try text(tree.tab_override);
            try text(tree.window_override);
        },
        .mapping_offer => |mapping| {
            try reference(mapping.surface, ticket.source_epoch);
            if (packet.sender_epoch != ticket.source_epoch or mapping.offer_id == 0 or mapping.source.pid == 0 or mapping.source.birth == 0 or mapping.target.pid == 0 or mapping.target.birth == 0 or
                mapping.source_epoch != ticket.source_epoch or mapping.target_epoch != ticket.target_epoch or mapping.generation == 0 or mapping.target_handle == 0) return error.InvalidMapping;
            const layout = view.Layout.checked(mapping.width, mapping.height, mapping.stride) catch return error.InvalidMapping;
            if (mapping.bytes != layout.total_bytes) return error.InvalidMapping;
        },
        .mapping_receipt => |receipt| {
            if (packet.sender_epoch != ticket.source_epoch or receipt.offer_id == 0 or receipt.target_handle == 0) return error.InvalidMapping;
        },
        .commit => |lease| {
            if (packet.sender_epoch != ticket.source_epoch or lease.holder_epoch != ticket.target_epoch or lease.generation != ticket.generation or lease.transaction != ticket.transaction) return error.InvalidIdentity;
        },
        .input => |*input| {
            try reference(input.surface, ticket.source_epoch);
            if (packet.sender_epoch != ticket.target_epoch or input.sequence == 0 or input.lease.holder_epoch != ticket.target_epoch or input.lease.generation != ticket.generation or input.lease.transaction != ticket.transaction) return error.InvalidInput;
            switch (input.event) {
                .key => |key| {
                    // The authenticated build digest freezes the physical key enum.
                    if (key.physical > 512 or key.modifiers & 0xfc00 != 0 or key.consumed_modifiers & 0xfc00 != 0 or !codepoint(key.unicode) or !codepoint(key.unshifted_codepoint)) return error.InvalidInput;
                    if (key.native) |native| if (native.virtual_key > 255 or native.scan_code > 255 or native.control_state & 0xfe00 != 0 or !codepoint(native.codepoint) or native.text.len > 4 or native.repeat_count == 0) return error.InvalidInput;
                    try text(key.text);
                },
                .text => |value| try text(value),
                .composition => |value| try text(value.text),
                .paste => |value| {
                    // A UTF-8 boundary can leave three unused bytes per chunk.
                    if (value.transfer == 0 or value.index > max_paste_bytes / (Text.capacity - 3) + 1 or (!value.last and value.text.len == 0)) return error.InvalidInput;
                    if (value.parent) |parent| if (parent.transaction == 0 or parent.config_generation == 0) return error.InvalidInput;
                    try text(value.text);
                },
                .mouse => |mouse| {
                    if (!std.math.isFinite(mouse.x) or !std.math.isFinite(mouse.y) or mouse.x < 0 or mouse.x > 1 or mouse.y < 0 or mouse.y > 1 or
                        !std.math.isFinite(mouse.scroll_x) or !std.math.isFinite(mouse.scroll_y) or @abs(mouse.scroll_x) > 1e6 or @abs(mouse.scroll_y) > 1e6 or mouse.modifiers & 0xfc00 != 0) return error.InvalidInput;
                },
                .resize => |size| if (size.width == 0 or size.height == 0 or size.width > view.max_dimension or size.height > view.max_dimension or size.dpi < 48 or size.dpi > 768) return error.InvalidInput,
                .focus, .visible => {},
            }
        },
        .frame_ready => |frame| {
            try reference(frame.surface, ticket.source_epoch);
            if (packet.sender_epoch != ticket.source_epoch or frame.generation == 0 or frame.sequence == 0) return error.InvalidMapping;
        },
        .status => |status| if (!std.meta.eql(status.ticket, ticket) or packet.sender_epoch != ticket.source_epoch) return error.InvalidIdentity,
        .target_enabled => if (packet.sender_epoch != ticket.target_epoch) return error.InvalidIdentity,
        .source_revoked => if (packet.sender_epoch != ticket.source_epoch) return error.InvalidIdentity,
        .ui_action, .apply_action => |request| {
            try reference(request.surface, ticket.source_epoch);
            try validLease(request.lease, ticket);
            if (request.transaction == 0 or request.config_generation == 0 or request.action.len == 0) return error.InvalidInput;
            try text(request.action);
            const source_sent = packet.body == .ui_action;
            if (packet.sender_epoch != (if (source_sent) ticket.source_epoch else ticket.target_epoch)) return error.InvalidIdentity;
        },
        .ui_action_result, .apply_action_result, .ui_event_result => |result| {
            try reference(result.surface, ticket.source_epoch);
            try validLease(result.lease, ticket);
            if (result.transaction == 0 or result.config_generation == 0) return error.InvalidInput;
            const source_sent = packet.body == .apply_action_result;
            if (packet.sender_epoch != (if (source_sent) ticket.source_epoch else ticket.target_epoch)) return error.InvalidIdentity;
        },
        .ui_event => |*request| {
            try reference(request.surface, ticket.source_epoch);
            try validLease(request.lease, ticket);
            if (packet.sender_epoch != ticket.source_epoch or request.transaction == 0 or request.config_generation == 0) return error.InvalidIdentity;
            switch (request.event) {
                .open_url => |*value| {
                    if (value.url.len == 0) return error.InvalidText;
                    try text(value.url);
                },
                .desktop_notification => |*value| {
                    try text(value.title);
                    try text(value.body);
                },
                .start_search => |*value| try text(value.*),
                .runtime => |*event| switch (event.*) {
                    .key_sequence => |value| if (value) |sequence| try text(sequence),
                    .key_table => |value| try text(value),
                    .mouse_over_link => |value| try text(value),
                    .progress => |value| {
                        if (value.state > 4) return error.InvalidInput;
                        if (value.progress) |percent| if (percent > 100) return error.InvalidInput;
                    },
                    .readonly, .command_finished => {},
                },
                .present_terminal => {},
                .resize_window => |value| if (value.width > view.max_dimension or value.height > view.max_dimension) return error.InvalidInput,
                // Terminal IO logs can contain arbitrary bytes (including NUL
                // and invalid UTF-8). They are saved without text conversion.
                .export_terminal_io => |*value| if (value.len > SnapshotText.capacity) return error.InvalidText,
            }
        },
        .inspector_request => |request| {
            try reference(request.surface, ticket.source_epoch);
            try validLease(request.lease, ticket);
            if (packet.sender_epoch != ticket.target_epoch or request.transaction == 0 or request.config_generation == 0) return error.InvalidIdentity;
        },
        .inspector_result => |*result| {
            try reference(result.surface, ticket.source_epoch);
            try validLease(result.lease, ticket);
            if (packet.sender_epoch != ticket.source_epoch or result.transaction == 0 or result.config_generation == 0) return error.InvalidIdentity;
            try text(result.text);
        },
        .surface_state => |state| {
            try reference(state.surface, ticket.source_epoch);
            try validLease(state.lease, ticket);
            if (packet.sender_epoch != ticket.source_epoch) return error.InvalidIdentity;
            try text(state.title);
            try text(state.pwd);
            if (state.search_progress) |progress| if (!std.math.isFinite(progress) or progress < 0 or progress > 1) return error.InvalidInput;
            if (state.config_generation == 0 or !std.math.isFinite(state.cursor_x) or !std.math.isFinite(state.cursor_y) or !std.math.isFinite(state.cursor_width) or !std.math.isFinite(state.cursor_height) or state.cursor_width < 0 or state.cursor_height < 0) return error.InvalidInput;
        },
        .confirm_request => |request| {
            try reference(request.surface, ticket.source_epoch);
            try validLease(request.lease, ticket);
            if (packet.sender_epoch != ticket.source_epoch or request.transaction == 0) return error.InvalidIdentity;
            try text(request.text);
        },
        .confirm_result => |result| {
            try reference(result.surface, ticket.source_epoch);
            try validLease(result.lease, ticket);
            if (packet.sender_epoch != ticket.target_epoch or result.transaction == 0) return error.InvalidIdentity;
        },
        .text_snapshot, .keybind_snapshot => |request| {
            try reference(request.surface, ticket.source_epoch);
            try validLease(request.lease, ticket);
            if (packet.sender_epoch != ticket.target_epoch or request.transaction == 0) return error.InvalidIdentity;
        },
        .text_snapshot_result, .keybind_snapshot_result => |result| {
            try reference(result.surface, ticket.source_epoch);
            try validLease(result.lease, ticket);
            if (packet.sender_epoch != ticket.source_epoch or result.transaction == 0) return error.InvalidIdentity;
            try text(result.text);
        },
        .close_request => |request| {
            try reference(request.surface, ticket.source_epoch);
            try validLease(request.lease, ticket);
            if (packet.sender_epoch != ticket.target_epoch) return error.InvalidIdentity;
        },
        .leaf_closed => |closed| {
            try reference(closed.surface, ticket.source_epoch);
            if (packet.sender_epoch != ticket.source_epoch) return error.InvalidIdentity;
        },
        inline .clipboard_request, .clipboard_result => |*message| {
            try reference(message.surface, ticket.source_epoch);
            try validLease(message.lease, ticket);
            const source_sent = packet.body == .clipboard_request;
            if (packet.sender_epoch != (if (source_sent) ticket.source_epoch else ticket.target_epoch) or message.transaction == 0) return error.InvalidIdentity;
            try text(message.data);
            if (message.text_len > message.data.len or
                (!message.has_text and message.text_len != 0) or
                (!message.has_html and message.text_len != message.data.len)) return error.InvalidText;
            if (!std.unicode.utf8ValidateSlice(message.plain()) or !std.unicode.utf8ValidateSlice(message.html())) return error.InvalidText;
        },
        else => {},
    }
}

const Writer = struct {
    bytes: []u8,
    offset: usize = 0,
    fn putRef(self: *Writer, value: anytype) Error!void {
        const T = @typeInfo(@TypeOf(value)).pointer.child;
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (@hasDecl(T, "capacity")) {
                    if (value.len > T.capacity) return error.LimitExceeded;
                    try self.put(u16, value.len);
                    for (value.slice()) |*item| try self.putRef(item);
                } else inline for (info.fields) |field| try self.putRef(&@field(value.*, field.name));
            },
            .@"union" => {
                try self.put(u16, @intCast(@intFromEnum(value.*)));
                switch (value.*) {
                    inline else => |*payload| try self.putRef(payload),
                }
            },
            .optional => {
                try self.put(bool, value.* != null);
                if (value.*) |*some| try self.putRef(some);
            },
            else => try self.put(T, value.*),
        }
    }
    fn put(self: *Writer, comptime T: type, value: T) Error!void {
        switch (@typeInfo(T)) {
            .int => {
                if (self.offset + @sizeOf(T) > self.bytes.len) return error.LimitExceeded;
                std.mem.writeInt(T, self.bytes[self.offset..][0..@sizeOf(T)], value, .little);
                self.offset += @sizeOf(T);
            },
            .float => |info| try self.put(std.meta.Int(.unsigned, info.bits), @bitCast(value)),
            .bool => try self.put(u8, @intFromBool(value)),
            .void => {},
            .@"enum" => try self.put(u16, @intCast(@intFromEnum(value))),
            .optional => |info| {
                try self.put(bool, value != null);
                if (value) |some| try self.put(info.child, some);
            },
            .@"struct" => |info| {
                if (@hasDecl(T, "capacity")) {
                    if (value.len > T.capacity) return error.LimitExceeded;
                    try self.put(u16, value.len);
                    for (value.slice()) |item| try self.put(T.Element, item);
                } else inline for (info.fields) |field| try self.put(field.type, @field(value, field.name));
            },
            .@"union" => |info| {
                try self.put(u16, @intCast(@intFromEnum(value)));
                switch (value) {
                    inline else => |payload| try self.put(@TypeOf(payload), payload),
                }
                _ = info;
            },
            else => @compileError("Unsupported remote protocol type " ++ @typeName(T)),
        }
    }
};
const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,
    fn getInto(self: *Reader, target: anytype) Error!void {
        const T = @typeInfo(@TypeOf(target)).pointer.child;
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (@hasDecl(T, "capacity")) {
                    target.len = try self.get(u16);
                    if (target.len > T.capacity) return error.LimitExceeded;
                    for (target.items[0..target.len]) |*item| try self.getInto(item);
                } else inline for (info.fields) |field| try self.getInto(&@field(target.*, field.name));
            },
            .@"union" => |info| {
                const tag = std.enums.fromInt(info.tag_type.?, try self.get(u16)) orelse return error.InvalidEnum;
                switch (tag) {
                    inline else => |value| {
                        target.* = @unionInit(T, @tagName(value), undefined);
                        try self.getInto(&@field(target.*, @tagName(value)));
                    },
                }
            },
            .optional => {
                if (try self.get(bool)) {
                    target.* = undefined;
                    target.* = @as(@typeInfo(T).optional.child, undefined);
                    try self.getInto(&target.*.?);
                } else target.* = null;
            },
            else => target.* = try self.get(T),
        }
    }
    fn get(self: *Reader, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .int => {
                if (self.offset + @sizeOf(T) > self.bytes.len) return error.InvalidFrame;
                const value = std.mem.readInt(T, self.bytes[self.offset..][0..@sizeOf(T)], .little);
                self.offset += @sizeOf(T);
                return value;
            },
            .float => |info| return @bitCast(try self.get(std.meta.Int(.unsigned, info.bits))),
            .bool => return switch (try self.get(u8)) {
                0 => false,
                1 => true,
                else => error.InvalidFrame,
            },
            .void => return {},
            .@"enum" => return std.enums.fromInt(T, try self.get(u16)) orelse error.InvalidEnum,
            .optional => |info| return if (try self.get(bool)) try self.get(info.child) else null,
            .@"struct" => |info| {
                var result: T = undefined;
                if (@hasDecl(T, "capacity")) {
                    result.len = try self.get(u16);
                    if (result.len > T.capacity) return error.LimitExceeded;
                    for (result.items[0..result.len]) |*item| item.* = try self.get(T.Element);
                } else inline for (info.fields) |field| @field(result, field.name) = try self.get(field.type);
                return result;
            },
            .@"union" => |info| {
                const tag = std.enums.fromInt(info.tag_type.?, try self.get(u16)) orelse return error.InvalidEnum;
                switch (tag) {
                    inline else => |value| return @unionInit(T, @tagName(value), try self.get(@FieldType(T, @tagName(value)))),
                }
            },
            else => @compileError("Unsupported remote protocol type " ++ @typeName(T)),
        }
    }
};
pub fn encode(buffer: []u8, packet: *const Packet) Error![]const u8 {
    try validate(packet);
    if (buffer.len < 8) return error.LimitExceeded;
    @memcpy(buffer[0..4], "GXRC");
    std.mem.writeInt(u16, buffer[4..6], version, .little);
    @memset(buffer[6..8], 0);
    var writer: Writer = .{ .bytes = buffer[0..@min(buffer.len, max_frame_size)], .offset = 8 };
    try writer.putRef(packet);
    return buffer[0..writer.offset];
}
pub fn decode(bytes: []const u8) Error!Packet {
    var packet: Packet = undefined;
    try decodeInto(bytes, &packet);
    return packet;
}

/// Transport decodes directly into its owned heap packet. This avoids stacking
/// one 60 KiB union temporary at every layer of the recursive reader.
pub fn decodeInto(bytes: []const u8, packet: *Packet) Error!void {
    if (bytes.len < 8 or bytes.len > max_frame_size or !std.mem.eql(u8, bytes[0..4], "GXRC") or bytes[6] != 0 or bytes[7] != 0) return error.InvalidFrame;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidVersion;
    var reader: Reader = .{ .bytes = bytes, .offset = 8 };
    try reader.getInto(packet);
    if (reader.offset != bytes.len) return error.TrailingBytes;
    try validate(packet);
}

test "remote control codec owns bounded trees and rejects cycles foreign references and trailing bytes" {
    var packet: Packet = .{ .sender_epoch = 1, .recipient_epoch = 2, .request_id = 1, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 7, .generation = 9 }, .body = .{ .prepare = .{ .nodes = try Bounded(Node, max_nodes).init(&.{.{ .leaf = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 1 } }}), .root = 0, .active = 0 } } };
    var buffer: [max_frame_size]u8 = undefined;
    const bytes = try encode(&buffer, &packet);
    const parsed = try decode(bytes);
    try std.testing.expect(parsed.body.prepare.nodes.items[0].leaf.matches(packet.body.prepare.nodes.items[0].leaf));
    try std.testing.expectError(error.TrailingBytes, decode(buffer[0 .. bytes.len + 1]));
    packet.body.prepare.nodes.items[0] = .{ .split = .{ .axis = .horizontal, .ratio = 0.5, .first = 0, .second = 0 } };
    try std.testing.expectError(error.InvalidTree, validate(&packet));
}

test "remote input requires exact target lease and checked bounded text" {
    var packet: Packet = .{ .sender_epoch = 2, .recipient_epoch = 1, .request_id = 1, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 7, .generation = 9 }, .body = .{ .input = .{ .surface = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 1 }, .lease = .{ .holder_epoch = 2, .transaction = 7, .generation = 9 }, .sequence = 1, .event = .{ .text = try Text.init("hello") } } } };
    var buffer: [max_frame_size]u8 = undefined;
    const parsed = try decode(try encode(&buffer, &packet));
    try std.testing.expectEqualStrings("hello", parsed.body.input.event.text.slice());
    packet.body.input.lease.generation += 1;
    try std.testing.expectError(error.InvalidInput, validate(&packet));
    packet.body.input.lease.generation -= 1;
    packet.body.input.event = .{ .paste = .{ .transfer = 2, .index = max_paste_bytes / Text.capacity + 1, .last = true, .text = try Text.init("tail") } };
    try validate(&packet);
    packet.body.input.event.paste.index = max_paste_bytes / (Text.capacity - 3) + 2;
    try std.testing.expectError(error.InvalidInput, validate(&packet));
}

test "remote input sequence survives reconnect and key tags require real enum membership" {
    var authority = try view.SourceAuthority.init(1);
    const ticket = try authority.prepare(2, 1);
    try authority.ready(ticket, 1);
    try authority.ready(ticket, 2);
    const lease = try authority.commit(ticket);
    const input: Input = .{ .surface = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 1 }, .lease = lease, .sequence = 1, .event = .{ .focus = true } };
    var sequence: InputSequence = .{};
    try sequence.accept(&authority, &input);
    try std.testing.expectError(error.RepeatedInput, sequence.accept(&authority, &input));
    try authority.disconnect(ticket);
    try std.testing.expectError(error.InvalidInput, sequence.accept(&authority, &input));
    const Sparse = enum(u16) { a = 1, b = 10 };
    try std.testing.expectEqual(Sparse.b, try physicalKey(Sparse, 10));
    try std.testing.expectError(error.InvalidInput, physicalKey(Sparse, 5));
}

test "gx.remote paste codec preserves transfer nine parent ten independent of sequence and boolean flags" {
    const alloc = std.testing.allocator;
    const packet = try alloc.create(Packet);
    defer alloc.destroy(packet);
    const decoded = try alloc.create(Packet);
    defer alloc.destroy(decoded);
    const bytes = try alloc.alloc(u8, max_frame_size);
    defer alloc.free(bytes);
    packet.* = .{ .sender_epoch = 2, .recipient_epoch = 1, .request_id = 127, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 7, .generation = 3 }, .body = .{ .input = .{
        .surface = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 5 },
        .lease = .{ .holder_epoch = 2, .transaction = 7, .generation = 3 },
        .sequence = 41,
        .event = .{ .paste = .{ .transfer = 9, .index = 0, .last = true, .text = try Text.init("owned paste"), .parent = .{ .transaction = 10, .config_generation = 23 } } },
    } } };
    const encoded = try encode(bytes, packet);
    // Inspect the wire scalar separately from decodeInto's nested aggregate
    // writes, so a regression identifies which side corrupts the correlation.
    var reader: Reader = .{ .bytes = encoded, .offset = 8 };
    _ = try reader.get(u128); // sender_epoch
    _ = try reader.get(u128); // recipient_epoch
    _ = try reader.get(u64); // request_id
    _ = try reader.get(Ticket);
    try std.testing.expectEqual(std.meta.Tag(Body).input, try reader.get(std.meta.Tag(Body)));
    _ = try reader.get(refs.Reference);
    _ = try reader.get(Lease);
    try std.testing.expectEqual(@as(u64, 41), try reader.get(u64));
    try std.testing.expectEqual(std.meta.Tag(@FieldType(Input, "event")).paste, try reader.get(std.meta.Tag(@FieldType(Input, "event"))));
    try std.testing.expectEqual(@as(u64, 9), try reader.get(u64));
    try decodeInto(encoded, decoded);
    try std.testing.expectEqual(@as(u64, 9), decoded.body.input.event.paste.transfer);
    try std.testing.expectEqual(@as(u32, 0), decoded.body.input.event.paste.index);
    try std.testing.expect(decoded.body.input.event.paste.last);
    try std.testing.expectEqual(@as(u64, 10), decoded.body.input.event.paste.parent.?.transaction);
    try std.testing.expectEqual(@as(u64, 23), decoded.body.input.event.paste.parent.?.config_generation);
    try std.testing.expectEqualStrings("owned paste", decoded.body.input.event.paste.text.slice());
    const returned = try decode(encoded);
    try std.testing.expectEqual(@as(u64, 9), returned.body.input.event.paste.transfer);
    try std.testing.expectEqual(@as(u64, 10), returned.body.input.event.paste.parent.?.transaction);
    // Reuse the same destination with absent parent and a false last flag.
    packet.body.input.event.paste.parent = null;
    packet.body.input.event.paste.last = false;
    try decodeInto(try encode(bytes, packet), decoded);
    try std.testing.expectEqual(@as(u64, 9), decoded.body.input.event.paste.transfer);
    try std.testing.expect(!decoded.body.input.event.paste.last);
    try std.testing.expect(decoded.body.input.event.paste.parent == null);
}

test "mapping receipt is source owned and binds nonzero offer and handle" {
    var packet: Packet = .{ .sender_epoch = 1, .recipient_epoch = 2, .request_id = 3, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 4, .generation = 5 }, .body = .{ .mapping_receipt = .{ .offer_id = 6, .target_handle = 7 } } };
    var buffer: [max_frame_size]u8 = undefined;
    const parsed = try decode(try encode(&buffer, &packet));
    try std.testing.expectEqual(@as(u64, 7), parsed.body.mapping_receipt.target_handle);
    packet.sender_epoch = 2;
    packet.recipient_epoch = 1;
    try std.testing.expectError(error.InvalidMapping, validate(&packet));
    packet.sender_epoch = 1;
    packet.recipient_epoch = 2;
    packet.body.mapping_receipt.target_handle = 0;
    try std.testing.expectError(error.InvalidMapping, validate(&packet));
}

test "gx.remote clipboard owns one bounded payload and rejects invalid direction and split" {
    var packet: Packet = .{ .sender_epoch = 1, .recipient_epoch = 2, .request_id = 3, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 4, .generation = 5 }, .body = .{ .clipboard_request = .{
        .surface = .{ .epoch = 1, .kind = .surface, .id = 7, .generation = 1 },
        .lease = .{ .holder_epoch = 2, .transaction = 4, .generation = 5 },
        .transaction = 8,
        .kind = .write,
        .has_text = true,
        .has_html = true,
        .text_len = 3,
        .data = try SnapshotText.init("one<b>two</b>"),
    } } };
    var buffer: [max_frame_size]u8 = undefined;
    const decoded = try decode(try encode(&buffer, &packet));
    try std.testing.expectEqualStrings("one", decoded.body.clipboard_request.plain());
    try std.testing.expectEqualStrings("<b>two</b>", decoded.body.clipboard_request.html());
    packet.sender_epoch = 2;
    packet.recipient_epoch = 1;
    try std.testing.expectError(error.InvalidIdentity, validate(&packet));
    packet.sender_epoch = 1;
    packet.recipient_epoch = 2;
    packet.body.clipboard_request.text_len = 65535;
    try std.testing.expectError(error.InvalidText, validate(&packet));
    packet.body.clipboard_request.text_len = SnapshotText.capacity;
    packet.body.clipboard_request.data.len = SnapshotText.capacity;
    @memset(&packet.body.clipboard_request.data.items, 'x');
    try std.testing.expect((try encode(&buffer, &packet)).len <= max_frame_size);
}

test "gx.remote UI callbacks preserve owned bytes and enforce direction lease generation and capacity" {
    const alloc = std.testing.allocator;
    const packet = try alloc.create(Packet);
    defer alloc.destroy(packet);
    const decoded = try alloc.create(Packet);
    defer alloc.destroy(decoded);
    const buffer = try alloc.alloc(u8, max_frame_size);
    defer alloc.free(buffer);
    const surface: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 1 };
    const lease: Lease = .{ .holder_epoch = 2, .transaction = 7, .generation = 9 };
    packet.* = .{ .sender_epoch = 1, .recipient_epoch = 2, .request_id = 1, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 7, .generation = 9 }, .body = .{ .ui_event = .{ .surface = surface, .lease = lease, .transaction = 11, .config_generation = 3, .event = .{ .open_url = .{ .kind = .osc8, .url = try SnapshotText.init("https://example.test/\xe4\xb8\xad") } } } } };
    try decodeInto(try encode(buffer, packet), decoded);
    try std.testing.expectEqualStrings("https://example.test/\xe4\xb8\xad", decoded.body.ui_event.event.open_url.url.slice());
    packet.body.ui_event.lease.generation += 1;
    try std.testing.expectError(error.InvalidIdentity, validate(packet));
    packet.body.ui_event.lease = lease;
    packet.body.ui_event.config_generation = 0;
    try std.testing.expectError(error.InvalidIdentity, validate(packet));
    packet.body.ui_event.config_generation = 3;
    packet.sender_epoch = 2;
    packet.recipient_epoch = 1;
    try std.testing.expectError(error.InvalidIdentity, validate(packet));
    packet.sender_epoch = 1;
    packet.recipient_epoch = 2;
    packet.body.ui_event.event = .{ .export_terminal_io = try SnapshotText.init("a\x00\xffb") };
    try decodeInto(try encode(buffer, packet), decoded);
    try std.testing.expectEqualSlices(u8, "a\x00\xffb", decoded.body.ui_event.event.export_terminal_io.slice());
    packet.body.ui_event.event.export_terminal_io.len = SnapshotText.capacity;
    @memset(&packet.body.ui_event.event.export_terminal_io.items, 0);
    try std.testing.expect((try encode(buffer, packet)).len < max_frame_size);
    packet.body = .{ .surface_state = .{ .surface = surface, .lease = lease, .path_quoting = .wsl } };
    try decodeInto(try encode(buffer, packet), decoded);
    try std.testing.expectEqual(@import("path_quote.zig").Style.wsl, decoded.body.surface_state.path_quoting);
    packet.body.surface_state.lease.transaction += 1;
    try std.testing.expectError(error.InvalidIdentity, validate(packet));
}

test "gx.remote inspector commands and snapshots reject foreign epochs and stale leases" {
    var packet: Packet = .{ .sender_epoch = 2, .recipient_epoch = 1, .request_id = 1, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 7, .generation = 9 }, .body = .{ .inspector_request = .{ .surface = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 1 }, .lease = .{ .holder_epoch = 2, .transaction = 7, .generation = 9 }, .transaction = 11, .config_generation = 3, .command = .pause } } };
    var buffer: [max_frame_size]u8 = undefined;
    const parsed = try decode(try encode(&buffer, &packet));
    try std.testing.expectEqual(InspectorCommand.pause, parsed.body.inspector_request.command);
    packet.body.inspector_request.surface.epoch = 2;
    try std.testing.expectError(error.InvalidIdentity, validate(&packet));
    packet.body.inspector_request.surface.epoch = 1;
    packet.body.inspector_request.lease.transaction += 1;
    try std.testing.expectError(error.InvalidIdentity, validate(&packet));
}
