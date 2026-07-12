//! voice-notes: the smallest useful real-time audio-input app.
//!
//! Select either the system default or a discovered device, start a capture,
//! and stop it to write `voice-note.wav`. The input sink receives borrowed f32
//! PCM directly on the audio callback path; it copies into an app-owned fixed
//! buffer and never posts raw audio through the UI/effects event queue.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const wav_writer = @import("wav_writer.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "voice-notes-canvas";
pub const window_width: f32 = 620;
pub const window_height: f32 = 540;
pub const capture_key: u64 = 1;
pub const write_key: u64 = 2;
pub const output_path = "voice-note.wav";

/// The file effect caps one write at 1 MiB. Keep the complete note inside that
/// limit: at 48 kHz this is about 10.9 s mono or 5.4 s stereo as PCM-16.
pub const max_wav_bytes = native_sdk.max_effect_file_bytes;
pub const max_capture_samples = (max_wav_bytes - wav_writer.header_bytes) / @sizeOf(i16);

const app_permissions = [_][]const u8{ "view", "microphone" };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Voice notes canvas", .accessibility_label = "Voice notes", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Voice Notes",
    .width = window_width,
    .height = window_height,
    .min_width = 460,
    .min_height = 420,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

/// Storage owned by the application, not the model. `onFrame` is the only
/// realtime callback: it performs bounded copies into already-allocated
/// memory, publishes counters atomically, and returns. UI state changes and
/// WAV serialization happen later on the app loop after `stopAudioInput` has
/// stopped the host callback.
pub const CaptureStore = struct {
    allocator: std.mem.Allocator,
    samples: []f32,
    wav: []u8,
    write_cursor: usize = 0,
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sample_rate_hz: std.atomic.Value(u32) = std.atomic.Value(u32).init(48_000),
    channel_count: std.atomic.Value(u8) = std.atomic.Value(u8).init(1),
    published_samples: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    frame_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropped_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overflowed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn create(allocator: std.mem.Allocator) !*CaptureStore {
        const store = try allocator.create(CaptureStore);
        errdefer allocator.destroy(store);
        const samples = try allocator.alloc(f32, max_capture_samples);
        errdefer allocator.free(samples);
        const wav = try allocator.alloc(u8, max_wav_bytes);
        store.* = .{
            .allocator = allocator,
            .samples = samples,
            .wav = wav,
        };
        return store;
    }

    pub fn destroy(self: *CaptureStore) void {
        self.allocator.free(self.samples);
        self.allocator.free(self.wav);
        self.allocator.destroy(self);
    }

    pub fn sink(self: *CaptureStore) native_sdk.AudioInputSink {
        return .{ .context = self, .on_frame_fn = onFrame };
    }

    pub fn begin(self: *CaptureStore, requested_format: native_sdk.AudioInputFormat) void {
        self.active.store(false, .release);
        self.write_cursor = 0;
        self.sample_rate_hz.store(requested_format.sample_rate_hz, .release);
        self.channel_count.store(requested_format.channels, .release);
        self.published_samples.store(0, .release);
        self.frame_count.store(0, .release);
        self.dropped_frames.store(0, .release);
        self.overflowed.store(false, .release);
        self.active.store(true, .release);
    }

    pub fn stop(self: *CaptureStore) void {
        self.active.store(false, .release);
    }

    pub fn sampleCount(self: *const CaptureStore) usize {
        return self.published_samples.load(.acquire);
    }

    pub fn frames(self: *const CaptureStore) u64 {
        return self.frame_count.load(.acquire);
    }

    pub fn dropped(self: *const CaptureStore) u64 {
        return self.dropped_frames.load(.acquire);
    }

    pub fn isOverflowed(self: *const CaptureStore) bool {
        return self.overflowed.load(.acquire);
    }

    pub fn durationMs(self: *const CaptureStore) u64 {
        const capture_format = self.format();
        const channels = capture_format.channels;
        const rate = capture_format.sample_rate_hz;
        if (channels == 0 or rate == 0) return 0;
        return @intCast((self.sampleCount() / channels) * 1000 / rate);
    }

    pub fn format(self: *const CaptureStore) native_sdk.AudioInputFormat {
        return .{
            .sample_rate_hz = self.sample_rate_hz.load(.acquire),
            .channels = self.channel_count.load(.acquire),
        };
    }

    /// Safe after `stopAudioInput` returns: the platform has stopped invoking
    /// the sink, so the single audio callback writer and this loop-side read
    /// no longer overlap.
    pub fn encodeWav(self: *CaptureStore) wav_writer.Error![]const u8 {
        std.debug.assert(!self.active.load(.acquire));
        return wav_writer.encodePcm16(self.samples[0..self.sampleCount()], self.format(), self.wav);
    }

    fn onFrame(context: ?*anyopaque, frame: native_sdk.AudioInputFrame) void {
        const context_ptr = context orelse return;
        const self: *CaptureStore = @ptrCast(@alignCast(context_ptr));
        if (!self.active.load(.acquire)) return;

        // Native capture invokes one sink serially. `write_cursor` is therefore
        // callback-owned; the atomic published length is the only value the UI
        // reads, and it is stored after the sample copy completes.
        if (frame.format.sample_rate_hz != 0 and frame.format.channels != 0) {
            self.sample_rate_hz.store(frame.format.sample_rate_hz, .release);
            self.channel_count.store(frame.format.channels, .release);
        }
        const remaining = self.samples.len - self.write_cursor;
        const count = @min(remaining, frame.samples.len);
        @memcpy(self.samples[self.write_cursor..][0..count], frame.samples[0..count]);
        self.write_cursor += count;
        self.published_samples.store(self.write_cursor, .release);
        _ = self.frame_count.fetchAdd(1, .release);
        self.dropped_frames.store(frame.dropped_frames, .release);
        if (count != frame.samples.len) self.overflowed.store(true, .release);
    }
};

pub const CapturePhase = enum { idle, requesting, capturing, writing };

pub const DeviceRow = struct {
    index: usize,
    device: *const native_sdk.AudioInputDevice,
    selected: bool,
    disabled: bool,
};

pub const Model = struct {
    capture: *CaptureStore,
    devices: [native_sdk.max_audio_input_devices]native_sdk.AudioInputDevice = undefined,
    device_count: usize = 0,
    selected_device: ?usize = null,
    device_generation: u64 = 0,
    phase: CapturePhase = .idle,
    format: native_sdk.AudioInputFormat = .{ .sample_rate_hz = 48_000, .channels = 1 },
    saved_notes: u32 = 0,
    status_storage: [160]u8 = [_]u8{0} ** 160,
    status_len: usize = 0,

    pub fn init(capture: *CaptureStore) Model {
        var model: Model = .{ .capture = capture };
        model.setStatus("Choose an input, then start a short voice note.", .{});
        return model;
    }

    pub fn status(self: *const Model) []const u8 {
        return self.status_storage[0..self.status_len];
    }

    pub fn selectedDeviceId(self: *const Model) []const u8 {
        const index = self.selected_device orelse return "";
        if (index >= self.device_count) return "";
        return self.devices[index].id();
    }

    pub fn deviceRows(self: *const Model, arena: std.mem.Allocator) []const DeviceRow {
        const rows = arena.alloc(DeviceRow, self.device_count) catch return &.{};
        for (rows, 0..) |*row, index| row.* = .{
            .index = index,
            .device = &self.devices[index],
            .selected = self.selected_device != null and self.selected_device.? == index,
            .disabled = self.phase != .idle,
        };
        return rows;
    }

    pub fn isCapturing(self: *const Model) bool {
        return self.phase == .capturing or self.phase == .requesting;
    }

    pub fn setStatus(self: *Model, comptime format_string: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_storage, format_string, args) catch "status unavailable";
        self.status_len = text.len;
    }

    fn copyDevices(self: *Model, source: []const native_sdk.AudioInputDevice, generation: u64) void {
        const previous_id = self.selectedDeviceId();
        var previous_id_storage: [native_sdk.platform.max_audio_input_device_id_bytes]u8 = undefined;
        @memcpy(previous_id_storage[0..previous_id.len], previous_id);
        const previous_len = previous_id.len;

        self.device_count = @min(source.len, self.devices.len);
        for (source[0..self.device_count], 0..) |device, index| self.devices[index] = device;
        self.device_generation = generation;
        self.selected_device = null;
        for (self.devices[0..self.device_count], 0..) |device, index| {
            if (std.mem.eql(u8, device.id(), previous_id_storage[0..previous_len])) {
                self.selected_device = index;
                break;
            }
        }
    }
};

pub const Msg = union(enum) {
    refresh_devices,
    select_system_default,
    select_device: usize,
    start,
    stop,
    input_event: native_sdk.EffectAudioInput,
    file_done: native_sdk.EffectFileResult,
};

pub const VoiceNotesApp = native_sdk.UiApp(Model, Msg);
pub const Effects = VoiceNotesApp.Effects;

pub fn boot(model: *Model, fx: *Effects) void {
    refreshDevices(model, fx);
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .refresh_devices => refreshDevices(model, fx),
        .select_system_default => {
            if (model.phase == .idle) model.selected_device = null;
        },
        .select_device => |index| {
            if (model.phase == .idle and index < model.device_count) model.selected_device = index;
        },
        .start => startCapture(model, fx),
        .stop => stopCapture(model, fx),
        .input_event => |event| handleInputEvent(model, event, fx),
        .file_done => |result| {
            if (result.key != write_key) return;
            model.phase = .idle;
            if (result.outcome == .ok) {
                model.saved_notes += 1;
                model.setStatus("Saved {s} ({d} ms).", .{ output_path, model.capture.durationMs() });
            } else {
                model.setStatus("Could not save the note: {s}.", .{@tagName(result.outcome)});
            }
        },
    }
}

fn refreshDevices(model: *Model, fx: *Effects) void {
    const result = fx.listAudioInputDevices(&model.devices) catch {
        model.device_count = 0;
        model.selected_device = null;
        model.setStatus("Input list unavailable; system default can still be requested.", .{});
        return;
    };
    // The platform filled our exact storage; copy through a local view only to
    // preserve a selection if device enumeration reordered.
    const snapshot = model.devices[0..@min(result.count, model.devices.len)];
    model.copyDevices(snapshot, result.generation);
    model.setStatus("{d} input device{s} available.", .{ model.device_count, if (model.device_count == 1) "" else "s" });
}

fn startCapture(model: *Model, fx: *Effects) void {
    if (model.phase != .idle) return;
    model.capture.begin(.{ .sample_rate_hz = 48_000, .channels = 1 });
    model.format = .{ .sample_rate_hz = 48_000, .channels = 1 };
    model.phase = .requesting;
    model.setStatus("Requesting microphone access…", .{});
    fx.startAudioInput(.{
        .key = capture_key,
        .options = .{
            .device_id = model.selectedDeviceId(),
            .sample_rate_hz = model.format.sample_rate_hz,
            .channels = model.format.channels,
        },
        .sink = model.capture.sink(),
        .on_event = Effects.audioInputMsg(.input_event),
    });
}

fn stopCapture(model: *Model, fx: *Effects) void {
    if (!model.isCapturing()) return;
    // Stop the host first, then mark our store inactive. The sink's documented
    // lifecycle makes `stopAudioInput` the handoff point after which serializing
    // the app-owned buffer is safe.
    fx.stopAudioInput();
    model.capture.stop();
    if (model.capture.sampleCount() == 0) {
        model.phase = .idle;
        model.setStatus("No audio frames reached the app.", .{});
        return;
    }
    const wav = model.capture.encodeWav() catch {
        model.phase = .idle;
        model.setStatus("The captured format could not be written as WAV.", .{});
        return;
    };
    model.phase = .writing;
    model.setStatus("Writing {s}…", .{output_path});
    fx.writeFile(.{
        .key = write_key,
        .path = output_path,
        .bytes = wav,
        .on_result = Effects.fileMsg(.file_done),
    });
}

fn handleInputEvent(model: *Model, event: native_sdk.EffectAudioInput, fx: *Effects) void {
    if (event.format.sample_rate_hz != 0) model.format = event.format;
    switch (event.kind) {
        .started => {
            model.phase = .capturing;
            model.setStatus("Capturing {d} Hz / {d} channel{s}.", .{ model.format.sample_rate_hz, model.format.channels, if (model.format.channels == 1) "" else "s" });
        },
        .devices_changed => {
            refreshDevices(model, fx);
            model.setStatus("Input devices changed; choose again if needed.", .{});
        },
        .source_changed => model.setStatus("Input source changed.", .{}),
        .format_changed => {
            // A PCM WAV has one header format. Rather than silently place two
            // incompatible frame formats in one note, this minimal recorder
            // ends the capture and asks the user to start a fresh note.
            if (model.isCapturing()) {
                fx.stopAudioInput();
                model.capture.stop();
                model.phase = .idle;
                model.setStatus("Input format changed; start a fresh note.", .{});
            } else {
                model.setStatus("Input format is {d} Hz / {d} channels.", .{ model.format.sample_rate_hz, model.format.channels });
            }
        },
        .interrupted => model.setStatus("Capture interrupted; stop or retry when ready.", .{}),
        .device_lost, .permission_denied, .failed, .stopped => {
            model.capture.stop();
            model.phase = .idle;
            model.setStatus("Capture ended: {s}.", .{@tagName(event.kind)});
        },
    }
}

pub const VoiceNotesUi = canvas.Ui(Msg);

pub fn view(ui: *VoiceNotesUi, model: *const Model) VoiceNotesUi.Node {
    const rows = model.deviceRows(ui.arena);
    return ui.column(.{ .gap = 14, .padding = 18, .style_tokens = .{ .background = .background } }, .{
        ui.column(.{ .gap = 4 }, .{
            ui.text(.{ .size = .heading }, "Voice Notes"),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Real-time PCM input stays off the UI event queue."),
        }),
        ui.panel(.{ .padding = 12, .style_tokens = .{ .background = .surface } }, .{
            ui.column(.{ .gap = 8 }, .{
                ui.text(.{}, "Input"),
                ui.button(.{ .on_press = .select_system_default, .selected = model.selected_device == null, .disabled = model.phase != .idle }, "System default"),
                ui.column(.{ .gap = 4 }, ui.each(rows, deviceRowKey, deviceRowView)),
                ui.row(.{ .gap = 8 }, .{
                    ui.button(.{ .on_press = .refresh_devices, .disabled = model.phase != .idle }, "Refresh devices"),
                    ui.spacer(1),
                    ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("Generation {d}", .{model.device_generation})),
                }),
            }),
        }),
        ui.panel(.{ .padding = 12, .style_tokens = .{ .background = .surface } }, .{
            ui.column(.{ .gap = 10 }, .{
                ui.row(.{ .gap = 8, .cross = .center }, .{
                    ui.button(.{ .variant = .primary, .on_press = .start, .disabled = model.phase != .idle }, "Start recording"),
                    ui.button(.{ .variant = .destructive, .on_press = .stop, .disabled = !model.isCapturing() }, "Stop and save"),
                    ui.spacer(1),
                    ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, phaseLabel(model.phase)),
                }),
                ui.text(.{}, ui.fmt("{d} frames · {d} ms · {d} dropped", .{ model.capture.frames(), model.capture.durationMs(), model.capture.dropped() })),
                ui.text(.{ .style_tokens = if (model.capture.isOverflowed()) .{ .foreground = .destructive } else .{ .foreground = .text_muted } }, if (model.capture.isOverflowed()) "Capture buffer full: stop to save the bounded note." else "A note is bounded to one asynchronous 1 MiB WAV write."),
            }),
        }),
        ui.spacer(1),
        ui.statusBar(.{}, ui.fmt("{s}  ·  {d} saved", .{ model.status(), model.saved_notes })),
    });
}

fn phaseLabel(phase: CapturePhase) []const u8 {
    return switch (phase) {
        .idle => "Ready",
        .requesting => "Requesting",
        .capturing => "Recording",
        .writing => "Saving",
    };
}

fn deviceRowKey(row: *const DeviceRow) canvas.UiKey {
    return canvas.uiKey(row.device.id());
}

fn deviceRowView(ui: *VoiceNotesUi, row: *const DeviceRow) VoiceNotesUi.Node {
    const label = if (row.device.is_default) ui.fmt("{s} (default)", .{row.device.label()}) else row.device.label();
    return ui.button(.{ .on_press = Msg{ .select_device = row.index }, .selected = row.selected, .disabled = row.disabled }, label);
}

pub fn main(init: std.process.Init) !void {
    const capture = try CaptureStore.create(std.heap.page_allocator);
    defer capture.destroy();

    const app_state = try std.heap.page_allocator.create(VoiceNotesApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = VoiceNotesApp.init(std.heap.page_allocator, Model.init(capture), .{
        .name = "voice-notes",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .view = view,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "voice-notes",
        .window_title = "Voice Notes",
        .bundle_id = "dev.native_sdk.voice_notes",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
