const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const wav_writer = @import("wav_writer.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

fn drain(model: *main.Model, fx: *main.Effects) void {
    while (fx.takeMsg()) |msg| main.update(model, msg, fx);
}

test "NullPlatform supplies the selected device and sends PCM only to the app sink" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(main.window_width, main.window_height) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    try harness.null_platform.addAudioInputDevice("built-in", "Built-in microphone", true);
    try harness.null_platform.addAudioInputDevice("usb-mic", "USB microphone", false);

    const capture = try main.CaptureStore.create(testing.allocator);
    defer capture.destroy();
    const app_state = try testing.allocator.create(main.VoiceNotesApp);
    defer testing.allocator.destroy(app_state);
    app_state.* = main.VoiceNotesApp.init(std.heap.page_allocator, main.Model.init(capture), .{
        .name = "voice-notes",
        .scene = main.shell_scene,
        .canvas_label = main.canvas_label,
        .update_fx = main.update,
        .init_fx = main.boot,
        .view = main.view,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = geometry.SizeF.init(main.window_width, main.window_height),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });

    // Boot enumerates through PlatformServices. Selecting by index pins the
    // opaque USB id, rather than asking the Null host for its default.
    try testing.expectEqual(@as(usize, 2), app_state.model.device_count);
    try app_state.dispatch(&harness.runtime, 1, .{ .select_device = 1 });
    try app_state.dispatch(&harness.runtime, 1, .start);
    const started = harness.null_platform.takeAudioInputStarted().?;
    try harness.runtime.dispatchPlatformEvent(app, started);
    try testing.expectEqual(main.CapturePhase.capturing, app_state.model.phase);

    const samples = [_]f32{ -0.5, 0.0, 0.5 };
    try harness.null_platform.feedAudioInputFrame(2_000_000, &samples, false);
    try testing.expectEqual(@as(usize, samples.len), capture.sampleCount());
    try testing.expectEqual(@as(u64, 1), capture.frames());
    // The Null host invokes the sink directly. No raw frame was queued as an
    // effect/UI message for the app loop to drain.
    try testing.expect(!app_state.effects.hasPending());

    app_state.effects.stopAudioInput();
    capture.stop();
}

test "a selected input starts a direct PCM sink and saves a WAV through effects" {
    const capture = try main.CaptureStore.create(testing.allocator);
    defer capture.destroy();

    var model = main.Model.init(capture);
    try model.devices[0].set("usb-mic", "USB microphone", true);
    model.device_count = 1;
    model.selected_device = 0;

    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .start, &fx);
    const request = fx.pendingAudioInput().?;
    try testing.expectEqual(main.capture_key, request.key);
    try testing.expectEqualStrings("usb-mic", request.options.device_id);
    try testing.expectEqual(@as(u32, 48_000), request.options.sample_rate_hz);

    // The fake executor records lifecycle controls only; PCM still goes to
    // the app-owned sink instead of becoming a Msg.
    const samples = [_]f32{ -1.0, -0.25, 0.0, 0.25, 1.0 };
    capture.sink().onFrame(.{
        .sequence = 1,
        .timestamp_ns = 1_000_000,
        .format = .{ .sample_rate_hz = 48_000, .channels = 1 },
        .samples = &samples,
    });
    try testing.expectEqual(@as(usize, samples.len), capture.sampleCount());
    try testing.expectEqual(@as(u64, 1), capture.frames());

    try fx.feedAudioInputEvent(.{
        .session_id = request.session_id,
        .kind = .started,
        .format = .{ .sample_rate_hz = 48_000, .channels = 1 },
    });
    drain(&model, &fx);
    try testing.expectEqual(main.CapturePhase.capturing, model.phase);

    main.update(&model, .stop, &fx);
    try testing.expectEqual(main.CapturePhase.writing, model.phase);
    const file = fx.pendingFileAt(0).?;
    try testing.expectEqual(main.write_key, file.key);
    try testing.expectEqual(native_sdk.EffectFileOp.write, file.op);
    try testing.expectEqualStrings(main.output_path, file.path);
    try testing.expectEqualStrings("RIFF", file.bytes[0..4]);
    try testing.expectEqualStrings("WAVE", file.bytes[8..12]);
    try testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, file.bytes[wav_writer.header_bytes..][0..2], .little));

    try fx.feedFileResult(main.write_key, .ok, "");
    drain(&model, &fx);
    try testing.expectEqual(main.CapturePhase.idle, model.phase);
    try testing.expectEqual(@as(u32, 1), model.saved_notes);
}

test "a stale lifecycle event cannot end the replacement capture" {
    const capture = try main.CaptureStore.create(testing.allocator);
    defer capture.destroy();
    var model = main.Model.init(capture);
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&model, .start, &fx);
    const first = fx.pendingAudioInput().?;
    main.update(&model, .stop, &fx);
    // No frames were captured, so the sample returns to idle without a file.
    try testing.expectEqual(main.CapturePhase.idle, model.phase);

    main.update(&model, .start, &fx);
    const second = fx.pendingAudioInput().?;
    try testing.expect(second.session_id != first.session_id);
    try fx.feedAudioInputEvent(.{ .session_id = first.session_id, .kind = .failed });
    drain(&model, &fx);
    try testing.expectEqual(main.CapturePhase.requesting, model.phase);
}

test "the view exposes default selection, device selection, and recording controls" {
    const capture = try main.CaptureStore.create(testing.allocator);
    defer capture.destroy();
    var model = main.Model.init(capture);
    try model.devices[0].set("built-in", "Built-in microphone", true);
    model.device_count = 1;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.VoiceNotesUi.init(arena_state.allocator());
    const tree = try ui.finalize(main.view(&ui, &model));
    var nodes: [128]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, main.window_width, main.window_height), &nodes);
    try testing.expect(layout.nodes.len > 0);
    try testing.expect(findByText(tree.root, .button, "System default") != null);
    try testing.expect(findByText(tree.root, .button, "Built-in microphone (default)") != null);
    try testing.expect(findByText(tree.root, .button, "Start recording") != null);
    try testing.expect(findByText(tree.root, .button, "Stop and save").?.state.disabled);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}
