const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const webview = @import("webview_app");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const http_env = "NATIVE_SDK_NAVIGATION_HTTP_ORIGIN";
const https_env = "NATIVE_SDK_NAVIGATION_HTTPS_ORIGIN";

const OriginError = error{
    MissingOrigin,
    InvalidOrigin,
};

fn validatedLoopbackOrigin(value: ?[]const u8, scheme: []const u8) OriginError![]const u8 {
    const origin = value orelse return error.MissingOrigin;
    const prefix = if (std.mem.eql(u8, scheme, "http")) "http://127.0.0.1:" else if (std.mem.eql(u8, scheme, "https")) "https://127.0.0.1:" else return error.InvalidOrigin;
    if (!std.mem.startsWith(u8, origin, prefix)) return error.InvalidOrigin;
    const port_text = origin[prefix.len..];
    if (port_text.len == 0) return error.InvalidOrigin;
    for (port_text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidOrigin;
    }
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidOrigin;
    if (port == 0) return error.InvalidOrigin;
    return origin;
}

pub fn main(init: std.process.Init) !void {
    const http_origin = try validatedLoopbackOrigin(init.environ_map.get(http_env), "http");
    const https_origin = try validatedLoopbackOrigin(init.environ_map.get(https_env), "https");
    const allowed_origins = [_][]const u8{
        "zero://inline",
        "zero://app",
        "https://example.com",
        http_origin,
        https_origin,
    };

    var app = webview.WebViewApp{ .env_map = init.environ_map };
    try runner.runWithOptions(app.app(), .{
        .app_name = "webview-navigation-smoke",
        .window_title = "Native SDK WebView Navigation Smoke",
        .bundle_id = "dev.native_sdk.webview.navigation-smoke",
        .bridge = app.bridge(),
        .builtin_bridge = .{ .enabled = true, .commands = &webview.builtin_policies },
        .security = .{
            .permissions = &webview.app_permissions,
            .navigation = .{ .allowed_origins = &allowed_origins },
        },
    }, init);
}

test "navigation smoke accepts only exact dynamic loopback origins" {
    try std.testing.expectEqualStrings("http://127.0.0.1:1", try validatedLoopbackOrigin("http://127.0.0.1:1", "http"));
    try std.testing.expectEqualStrings("https://127.0.0.1:65535", try validatedLoopbackOrigin("https://127.0.0.1:65535", "https"));

    const invalid = [_]?[]const u8{
        null,
        "",
        "http://127.0.0.1",
        "http://127.0.0.1:0",
        "http://127.0.0.1:65536",
        "http://127.0.0.1:80/path",
        "http://127.0.0.1:80?query",
        "http://127.0.0.1:80#fragment",
        "http://localhost:80",
        "http://0.0.0.0:80",
        "http://127.0.0.2:80",
        "https://127.0.0.1:80",
        "http://127.0.0.1:80@evil.invalid",
        "http://127.0.0.1: 80",
        "http://127.0.0.1:+80",
    };
    for (invalid) |value| {
        try std.testing.expectError(if (value == null) error.MissingOrigin else error.InvalidOrigin, validatedLoopbackOrigin(value, "http"));
    }
}
