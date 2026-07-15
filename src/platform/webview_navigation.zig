const std = @import("std");
const types = @import("types.zig");

pub const RawPhase = enum(u8) {
    started,
    redirected,
    finished,
    failed,
    cancelled,
};

pub const RawEvent = struct {
    window_id: types.WindowId,
    label: []const u8,
    engine_id: u64,
    phase: RawPhase,
    url: []const u8,
    failure_class: ?types.WebViewNavigationFailureClass = null,
};

pub const EmitFn = *const fn (context: *anyopaque, event: types.WebViewNavigationEvent) anyerror!void;

const Entry = struct {
    occupied: bool = false,
    active: bool = false,
    window_id: types.WindowId = 0,
    label: [types.max_webview_label_bytes]u8 = undefined,
    label_len: usize = 0,
    engine_id: u64 = 0,
    navigation_id: u64 = 0,
    url: [types.max_webview_url_bytes]u8 = undefined,
    url_len: usize = 0,
    generation: u64 = 0,

    fn labelSlice(self: *const Entry) []const u8 {
        return self.label[0..self.label_len];
    }

    fn urlSlice(self: *const Entry) []const u8 {
        return self.url[0..self.url_len];
    }
};

const EventSnapshot = struct {
    window_id: types.WindowId,
    label: [types.max_webview_label_bytes]u8 = undefined,
    label_len: usize = 0,
    navigation_id: u64,
    phase: types.WebViewNavigationPhase,
    url: [types.max_webview_url_bytes]u8 = undefined,
    url_len: usize = 0,
    failure_class: ?types.WebViewNavigationFailureClass,

    fn init(
        entry: *const Entry,
        phase: types.WebViewNavigationPhase,
        failure_class: ?types.WebViewNavigationFailureClass,
    ) EventSnapshot {
        var snapshot: EventSnapshot = .{
            .window_id = entry.window_id,
            .navigation_id = entry.navigation_id,
            .phase = phase,
            .failure_class = failure_class,
        };
        copyBytes(&snapshot.label, &snapshot.label_len, entry.labelSlice());
        copyBytes(&snapshot.url, &snapshot.url_len, entry.urlSlice());
        return snapshot;
    }

    fn event(self: *const EventSnapshot) types.WebViewNavigationEvent {
        return .{
            .window_id = self.window_id,
            .label = self.label[0..self.label_len],
            .navigation_id = self.navigation_id,
            .phase = self.phase,
            .url = self.url[0..self.url_len],
            .failure_class = self.failure_class,
        };
    }
};

/// Fixed-capacity, allocation-free normalization shared by every WebView
/// backend. Engine callbacks provide correlation keys; the tracker owns the
/// public opaque ids, redirect continuity, supersession ordering, and the
/// exactly-one-terminal rule.
pub const Tracker = struct {
    entries: [types.max_webviews]Entry = [_]Entry{.{}} ** types.max_webviews,
    next_navigation_id: u64 = 1,
    generation: u64 = 0,

    pub fn ingest(self: *Tracker, raw: RawEvent, context: *anyopaque, emit: EmitFn) anyerror!void {
        if (raw.label.len == 0 or raw.label.len > types.max_webview_label_bytes) return error.InvalidWebViewNavigation;
        if (raw.url.len > types.max_webview_url_bytes) return error.InvalidWebViewNavigation;
        if ((raw.phase == .started or raw.phase == .redirected) and raw.url.len == 0) return error.InvalidWebViewNavigation;
        if (raw.engine_id == 0) return error.InvalidWebViewNavigation;
        if (raw.phase == .failed) {
            if (raw.failure_class == null) return error.InvalidWebViewNavigation;
        } else if (raw.failure_class != null) return error.InvalidWebViewNavigation;

        const entry = try self.entryFor(raw.window_id, raw.label, raw.phase == .started);
        if (entry == null) return;
        const current = entry.?;

        switch (raw.phase) {
            .started => {
                if (current.active and current.engine_id == raw.engine_id) return;
                const transition_generation = self.touch(current);
                if (current.active) {
                    var cancelled = EventSnapshot.init(current, .cancelled, null);
                    current.active = false;
                    try emit(context, cancelled.event());
                    // Emission is an application callback and can synchronously
                    // close this renderer or begin a different navigation for
                    // the same label. Only continue the original replacement
                    // when the exact inactive transition we left behind still
                    // owns the slot.
                    if (!current.occupied or
                        current.active or
                        current.generation != transition_generation or
                        current.window_id != raw.window_id or
                        !std.mem.eql(u8, current.labelSlice(), raw.label)) return;
                }
                current.active = true;
                current.engine_id = raw.engine_id;
                current.navigation_id = self.allocateNavigationId();
                copyBytes(&current.url, &current.url_len, raw.url);
                var started = EventSnapshot.init(current, .started, null);
                try emit(context, started.event());
            },
            .redirected => {
                if (!current.active or current.engine_id != raw.engine_id) return;
                _ = self.touch(current);
                copyBytes(&current.url, &current.url_len, raw.url);
                var redirected = EventSnapshot.init(current, .redirected, null);
                try emit(context, redirected.event());
            },
            .finished, .failed, .cancelled => {
                if (!current.active or current.engine_id != raw.engine_id) return;
                _ = self.touch(current);
                if (raw.url.len > 0) copyBytes(&current.url, &current.url_len, raw.url);
                const phase: types.WebViewNavigationPhase = switch (raw.phase) {
                    .finished => .finished,
                    .failed => .failed,
                    .cancelled => .cancelled,
                    else => unreachable,
                };
                var terminal = EventSnapshot.init(current, phase, raw.failure_class);
                current.active = false;
                try emit(context, terminal.event());
            },
        }
    }

    /// Close one renderer-owned lifecycle. An active navigation receives its
    /// terminal cancellation before the slot is made reusable; an already
    /// terminal/unknown renderer is a no-op. Platform close paths call this
    /// only after the host confirms that the WebView was removed.
    pub fn cancelAndRetire(self: *Tracker, window_id: types.WindowId, label: []const u8, context: *anyopaque, emit: EmitFn) anyerror!void {
        const entry = self.find(window_id, label) orelse return;
        try cancelEntry(entry, context, emit);
    }

    /// Close every tracked child WebView owned by a window. This is the
    /// window-teardown twin of `cancelAndRetire`: each active id receives one
    /// cancellation before its fixed-capacity slot is released.
    pub fn cancelAndRetireWindow(self: *Tracker, window_id: types.WindowId, context: *anyopaque, emit: EmitFn) anyerror!void {
        for (&self.entries) |*entry| {
            if (!entry.occupied or entry.window_id != window_id) continue;
            try cancelEntry(entry, context, emit);
        }
    }

    fn entryFor(self: *Tracker, window_id: types.WindowId, label: []const u8, create: bool) !?*Entry {
        if (self.find(window_id, label)) |entry| return entry;
        if (!create) return null;

        var candidate: ?*Entry = null;
        for (&self.entries) |*entry| {
            if (!entry.occupied) {
                candidate = entry;
                break;
            }
            if (!entry.active and (candidate == null or entry.generation < candidate.?.generation)) candidate = entry;
        }
        const entry = candidate orelse return error.WebViewNavigationCapacityExceeded;
        entry.* = .{ .occupied = true, .window_id = window_id };
        copyBytes(&entry.label, &entry.label_len, label);
        return entry;
    }

    fn find(self: *Tracker, window_id: types.WindowId, label: []const u8) ?*Entry {
        for (&self.entries) |*entry| {
            if (entry.occupied and entry.window_id == window_id and std.mem.eql(u8, entry.labelSlice(), label)) return entry;
        }
        return null;
    }

    fn allocateNavigationId(self: *Tracker) u64 {
        const id = self.next_navigation_id;
        self.next_navigation_id +%= 1;
        if (self.next_navigation_id == 0) self.next_navigation_id = 1;
        return id;
    }

    fn touch(self: *Tracker, entry: *Entry) u64 {
        self.generation +%= 1;
        entry.generation = self.generation;
        return entry.generation;
    }
};

fn cancelEntry(entry: *Entry, context: *anyopaque, emit: EmitFn) anyerror!void {
    if (entry.active) {
        var cancelled = EventSnapshot.init(entry, .cancelled, null);
        entry.* = .{};
        try emit(context, cancelled.event());
        return;
    }
    entry.* = .{};
}

fn copyBytes(buffer: []u8, length: *usize, bytes: []const u8) void {
    @memcpy(buffer[0..bytes.len], bytes);
    length.* = bytes.len;
}

const Captured = struct {
    events: [64]struct {
        navigation_id: u64,
        phase: types.WebViewNavigationPhase,
        url: [128]u8,
        url_len: usize,
        failure_class: ?types.WebViewNavigationFailureClass,
    } = undefined,
    len: usize = 0,

    fn emit(context: *anyopaque, event: types.WebViewNavigationEvent) !void {
        const self: *Captured = @ptrCast(@alignCast(context));
        const output = &self.events[self.len];
        output.navigation_id = event.navigation_id;
        output.phase = event.phase;
        output.failure_class = event.failure_class;
        @memcpy(output.url[0..event.url.len], event.url);
        output.url_len = event.url.len;
        self.len += 1;
    }
};

const ReentrantRetireCapture = struct {
    tracker: *Tracker,
    reenter_on: types.WebViewNavigationPhase,
    reentered: bool = false,
    phases: [8]types.WebViewNavigationPhase = undefined,
    len: usize = 0,

    fn emit(context: *anyopaque, event: types.WebViewNavigationEvent) !void {
        const self: *ReentrantRetireCapture = @ptrCast(@alignCast(context));
        self.phases[self.len] = event.phase;
        self.len += 1;
        if (!self.reentered and event.phase == self.reenter_on) {
            self.reentered = true;
            try self.tracker.cancelAndRetire(event.window_id, event.label, self, emit);
        }
    }

    fn terminalCount(self: *const ReentrantRetireCapture) usize {
        var count: usize = 0;
        for (self.phases[0..self.len]) |phase| {
            if (phase == .finished or phase == .failed or phase == .cancelled) count += 1;
        }
        return count;
    }
};

test "redirects keep one id and duplicate terminals are ignored" {
    var tracker: Tracker = .{};
    var captured: Captured = .{};
    const base: RawEvent = .{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .started, .url = "http://example.com/start" };
    try tracker.ingest(base, &captured, Captured.emit);
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .redirected, .url = "https://example.com/final" }, &captured, Captured.emit);
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .finished, .url = "https://example.com/final" }, &captured, Captured.emit);
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .finished, .url = "https://example.com/final" }, &captured, Captured.emit);
    try std.testing.expectEqual(@as(usize, 3), captured.len);
    try std.testing.expectEqual(captured.events[0].navigation_id, captured.events[2].navigation_id);
    try std.testing.expectEqual(types.WebViewNavigationPhase.redirected, captured.events[1].phase);
}

test "supersession cancels the old id before starting the replacement" {
    var tracker: Tracker = .{};
    var captured: Captured = .{};
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .started, .url = "https://example.com/slow" }, &captured, Captured.emit);
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 200, .phase = .started, .url = "https://example.com/next" }, &captured, Captured.emit);
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .failed, .url = "https://example.com/slow", .failure_class = .network }, &captured, Captured.emit);
    try std.testing.expectEqual(@as(usize, 3), captured.len);
    try std.testing.expectEqual(types.WebViewNavigationPhase.cancelled, captured.events[1].phase);
    try std.testing.expectEqual(captured.events[0].navigation_id, captured.events[1].navigation_id);
    try std.testing.expectEqual(types.WebViewNavigationPhase.started, captured.events[2].phase);
    try std.testing.expect(captured.events[2].navigation_id != captured.events[0].navigation_id);
}

test "failed navigation requires a bounded failure class" {
    var tracker: Tracker = .{};
    var captured: Captured = .{};
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .started, .url = "https://example.com/" }, &captured, Captured.emit);
    try std.testing.expectError(error.InvalidWebViewNavigation, tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .failed, .url = "https://example.com/" }, &captured, Captured.emit));
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .failed, .url = "https://example.com/", .failure_class = .tls }, &captured, Captured.emit);
    try std.testing.expectEqual(types.WebViewNavigationFailureClass.tls, captured.events[1].failure_class.?);
}

test "a terminal callback without an engine URL retains the last correlated URL" {
    var tracker: Tracker = .{};
    var captured: Captured = .{};
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .started, .url = "https://example.com/last-known" }, &captured, Captured.emit);
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 100, .phase = .failed, .url = "", .failure_class = .unknown }, &captured, Captured.emit);
    try std.testing.expectEqualStrings("https://example.com/last-known", captured.events[1].url[0..captured.events[1].url_len]);
}

test "active labels are independent and capacity fails loudly" {
    var tracker: Tracker = .{};
    var captured: Captured = .{};
    var labels: [types.max_webviews + 1][16]u8 = undefined;
    var lengths: [types.max_webviews + 1]usize = undefined;
    for (&labels, 0..) |*label, index| {
        lengths[index] = (try std.fmt.bufPrint(label, "page-{d}", .{index})).len;
    }
    for (0..types.max_webviews) |index| {
        try tracker.ingest(.{
            .window_id = 1,
            .label = labels[index][0..lengths[index]],
            .engine_id = index + 1,
            .phase = .started,
            .url = "https://example.com/",
        }, &captured, Captured.emit);
    }
    try std.testing.expectError(error.WebViewNavigationCapacityExceeded, tracker.ingest(.{
        .window_id = 1,
        .label = labels[types.max_webviews][0..lengths[types.max_webviews]],
        .engine_id = 99,
        .phase = .started,
        .url = "https://example.com/",
    }, &captured, Captured.emit));
    try tracker.cancelAndRetire(1, labels[0][0..lengths[0]], &captured, Captured.emit);
    try std.testing.expectEqual(types.WebViewNavigationPhase.cancelled, captured.events[types.max_webviews].phase);
    try tracker.ingest(.{
        .window_id = 2,
        .label = labels[types.max_webviews][0..lengths[types.max_webviews]],
        .engine_id = 100,
        .phase = .started,
        .url = "https://example.com/next",
    }, &captured, Captured.emit);
}

test "close during load emits one terminal and reuses capacity across distinct labels" {
    var tracker: Tracker = .{};
    var captured: Captured = .{};
    var label_buffer: [32]u8 = undefined;
    for (0..types.max_webviews + 1) |index| {
        const label = try std.fmt.bufPrint(&label_buffer, "closing-{d}", .{index});
        try tracker.ingest(.{
            .window_id = 1,
            .label = label,
            .engine_id = index + 1,
            .phase = .started,
            .url = "https://example.com/slow",
        }, &captured, Captured.emit);
        try tracker.cancelAndRetire(1, label, &captured, Captured.emit);
        const started = captured.events[index * 2];
        const cancelled = captured.events[index * 2 + 1];
        try std.testing.expectEqual(started.navigation_id, cancelled.navigation_id);
        try std.testing.expectEqual(types.WebViewNavigationPhase.cancelled, cancelled.phase);
    }
    try std.testing.expectEqual((types.max_webviews + 1) * 2, captured.len);
}

test "window teardown cancels only that window's active navigations" {
    var tracker: Tracker = .{};
    var captured: Captured = .{};
    try tracker.ingest(.{ .window_id = 1, .label = "one", .engine_id = 1, .phase = .started, .url = "https://one.example/" }, &captured, Captured.emit);
    try tracker.ingest(.{ .window_id = 1, .label = "two", .engine_id = 2, .phase = .started, .url = "https://two.example/" }, &captured, Captured.emit);
    try tracker.ingest(.{ .window_id = 2, .label = "other", .engine_id = 3, .phase = .started, .url = "https://other.example/" }, &captured, Captured.emit);
    try tracker.cancelAndRetireWindow(1, &captured, Captured.emit);
    try std.testing.expectEqual(@as(usize, 5), captured.len);
    try std.testing.expectEqual(types.WebViewNavigationPhase.cancelled, captured.events[3].phase);
    try std.testing.expectEqual(types.WebViewNavigationPhase.cancelled, captured.events[4].phase);
    try tracker.ingest(.{ .window_id = 2, .label = "other", .engine_id = 3, .phase = .finished, .url = "https://other.example/" }, &captured, Captured.emit);
    try std.testing.expectEqual(types.WebViewNavigationPhase.finished, captured.events[5].phase);
}

test "terminal emission can synchronously retire its label without a duplicate terminal" {
    var tracker: Tracker = .{};
    var captured: ReentrantRetireCapture = .{ .tracker = &tracker, .reenter_on = .finished };
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 1, .phase = .started, .url = "https://example.com/" }, &captured, ReentrantRetireCapture.emit);
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 1, .phase = .finished, .url = "https://example.com/final" }, &captured, ReentrantRetireCapture.emit);
    try std.testing.expectEqual(@as(usize, 2), captured.len);
    try std.testing.expectEqual(@as(usize, 1), captured.terminalCount());
    try std.testing.expectEqual(types.WebViewNavigationPhase.finished, captured.phases[1]);
    try std.testing.expect(tracker.find(1, "page") == null);
}

test "cancellation emission can synchronously retire its label without a duplicate terminal" {
    var tracker: Tracker = .{};
    var captured: ReentrantRetireCapture = .{ .tracker = &tracker, .reenter_on = .cancelled };
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 1, .phase = .started, .url = "https://example.com/slow" }, &captured, ReentrantRetireCapture.emit);
    try tracker.cancelAndRetire(1, "page", &captured, ReentrantRetireCapture.emit);
    try std.testing.expectEqual(@as(usize, 2), captured.len);
    try std.testing.expectEqual(@as(usize, 1), captured.terminalCount());
    try std.testing.expectEqual(types.WebViewNavigationPhase.cancelled, captured.phases[1]);
    try std.testing.expect(tracker.find(1, "page") == null);
}

test "supersession does not start its replacement after cancellation closes the renderer" {
    var tracker: Tracker = .{};
    var captured: ReentrantRetireCapture = .{ .tracker = &tracker, .reenter_on = .cancelled };
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 1, .phase = .started, .url = "https://example.com/slow" }, &captured, ReentrantRetireCapture.emit);
    try tracker.ingest(.{ .window_id = 1, .label = "page", .engine_id = 2, .phase = .started, .url = "https://example.com/replacement" }, &captured, ReentrantRetireCapture.emit);
    try std.testing.expectEqual(@as(usize, 2), captured.len);
    try std.testing.expectEqual(types.WebViewNavigationPhase.started, captured.phases[0]);
    try std.testing.expectEqual(types.WebViewNavigationPhase.cancelled, captured.phases[1]);
    try std.testing.expectEqual(@as(usize, 1), captured.terminalCount());
    try std.testing.expect(tracker.find(1, "page") == null);
}
