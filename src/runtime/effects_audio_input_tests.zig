//! Audio-input effect coverage: device snapshots and lifecycle reports use
//! the normal runtime loop, while PCM stays on the application-owned sink.
//! The null platform feeds known samples directly so this suite proves the
//! important boundary without a microphone, permission dialog, or UI bridge.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const platform = @import("../platform/root.zig");

const canvas_label = "audio-input-canvas";
const input_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const input_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Audio Input",
    .width = 400,
    .height = 300,
    .views = &input_views,
}};
const input_scene: app_manifest.ShellConfig = .{ .windows = &input_windows };

const CaptureProbe = struct {
    frame_count: usize = 0,
    last_sequence: u64 = 0,
    last_sample_count: usize = 0,
    last_sample_sum: f32 = 0,
    saw_discontinuity: bool = false,

    fn onFrame(context: ?*anyopaque, frame: platform.AudioInputFrame) void {
        const self: *CaptureProbe = @ptrCast(@alignCast(context.?));
        self.frame_count += 1;
        self.last_sequence = frame.sequence;
        self.last_sample_count = frame.samples.len;
        self.last_sample_sum = 0;
        for (frame.samples) |sample| self.last_sample_sum += sample;
        self.saw_discontinuity = self.saw_discontinuity or frame.discontinuity;
    }
};

const InputModel = struct {
    event_count: usize = 0,
    last_event: ?effects_mod.EffectAudioInput = null,

    fn record(self: *InputModel, event: effects_mod.EffectAudioInput) void {
        self.event_count += 1;
        self.last_event = event;
    }
};

const InputMsg = union(enum) {
    start,
    input_event: effects_mod.EffectAudioInput,
};

const InputApp = ui_app_model.UiApp(InputModel, InputMsg);
const InputEffects = InputApp.Effects;
const input_key: u64 = 73;
var probe: *CaptureProbe = undefined;

fn inputUpdate(model: *InputModel, msg: InputMsg, fx: *InputEffects) void {
    switch (msg) {
        .start => fx.startAudioInput(.{
            .key = input_key,
            .options = .{ .channels = 1 },
            .sink = .{ .context = probe, .on_frame_fn = CaptureProbe.onFrame },
            .on_event = InputEffects.audioInputMsg(.input_event),
        }),
        .input_event => |event| model.record(event),
    }
}

fn inputView(ui: *InputApp.Ui, model: *const InputModel) InputApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} input events", .{model.event_count})),
        ui.button(.{ .on_press = .start }, "Start"),
    });
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *InputApp,
    app: core.App,

    fn create() !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        try harness.null_platform.addAudioInputDevice("builtin", "Built-in Microphone", true);
        const app_state = try std.testing.allocator.create(InputApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = InputApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-audio-input",
            .scene = input_scene,
            .canvas_label = canvas_label,
            .update_fx = inputUpdate,
            .view = inputView,
        });
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    fn drainWakes(self: *Harness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

test "audio input lifecycle is queued but PCM stays on the direct sink" {
    var capture: CaptureProbe = .{};
    probe = &capture;
    var h = try Harness.create();
    defer h.destroy();

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 1), h.harness.null_platform.audio_input_start_count);
    const pending = h.app_state.effects.pendingAudioInput().?;
    try std.testing.expectEqual(input_key, pending.key);
    try std.testing.expectEqual(@as(u8, 1), pending.options.channels);

    const started = h.harness.null_platform.takeAudioInputStarted().?;
    try h.harness.runtime.dispatchPlatformEvent(h.app, started);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
    try std.testing.expectEqual(effects_mod.EffectAudioInput{ .key = input_key, .session_id = pending.session_id, .kind = .started, .format = .{ .sample_rate_hz = 48_000, .channels = 1 }, .device_generation = h.harness.null_platform.audio_input_device_generation }, h.app_state.model.last_event.?);

    // These samples never become a typed app message. They are only
    // observed by the application consumer supplied to `startAudioInput`.
    try h.harness.null_platform.feedAudioInputFrame(4_000_000, &.{ 0.25, -0.5, 0.75 }, true);
    try std.testing.expectEqual(@as(usize, 1), capture.frame_count);
    try std.testing.expectEqual(@as(u64, 1), capture.last_sequence);
    try std.testing.expectEqual(@as(usize, 3), capture.last_sample_count);
    try std.testing.expectEqual(@as(f32, 0.5), capture.last_sample_sum);
    try std.testing.expect(capture.saw_discontinuity);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);

    try h.harness.runtime.dispatchPlatformEvent(h.app, h.harness.null_platform.audioInputEvent(.devices_changed).?);
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.event_count);
    try std.testing.expectEqual(platform.AudioInputEventKind.devices_changed, h.app_state.model.last_event.?.kind);
}

test "stale audio input reports do not reach a replacement session" {
    var capture: CaptureProbe = .{};
    probe = &capture;
    var h = try Harness.create();
    defer h.destroy();
    h.app_state.effects.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const session = h.app_state.effects.pendingAudioInput().?.session_id;
    try h.app_state.effects.feedAudioInputEvent(.{ .session_id = session + 1, .kind = .started });
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.event_count);

    try h.app_state.effects.feedAudioInputEvent(.{ .session_id = session, .kind = .started, .format = .{ .sample_rate_hz = 48_000, .channels = 1 } });
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.event_count);
}
