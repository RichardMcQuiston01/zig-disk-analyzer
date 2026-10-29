//! Minimal raylib binding via the stable C ABI.
//!
//! We declare only the raylib functions this app uses, as `extern` C
//! functions, rather than depending on a third-party Zig binding. raylib's C
//! ABI is very stable across versions, so this decouples the app from Zig
//! binding-version churn. Struct layouts match raylib 5.5's `raylib.h`. The
//! library itself is linked by `build.zig`.

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const Vector2 = extern struct {
    x: f32,
    y: f32,
};

pub const Rectangle = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Image = extern struct {
    data: ?*anyopaque,
    width: c_int,
    height: c_int,
    mipmaps: c_int,
    format: c_int,
};

pub const Texture = extern struct {
    id: c_uint,
    width: c_int,
    height: c_int,
    mipmaps: c_int,
    format: c_int,
};

pub const GlyphInfo = extern struct {
    value: c_int,
    offset_x: c_int,
    offset_y: c_int,
    advance_x: c_int,
    image: Image,
};

pub const Font = extern struct {
    base_size: c_int,
    glyph_count: c_int,
    glyph_padding: c_int,
    texture: Texture,
    recs: ?[*]Rectangle,
    glyphs: ?[*]GlyphInfo,
};

// ConfigFlags bit values (raylib 4.x/5.x, stable).
pub const flag_vsync_hint: c_uint = 0x00000040;
pub const flag_window_resizable: c_uint = 0x00000004;
pub const flag_msaa_4x_hint: c_uint = 0x00000020;
pub const flag_window_highdpi: c_uint = 0x00002000;

pub const mouse_button_left: c_int = 0;
pub const mouse_button_right: c_int = 1;
pub const key_null: c_int = 0;
pub const key_escape: c_int = 256;

pub const texture_filter_point: c_int = 0;
pub const texture_filter_bilinear: c_int = 1;

// --- extern C declarations ---------------------------------------------------

extern fn InitWindow(width: c_int, height: c_int, title: [*:0]const u8) void;
extern fn CloseWindow() void;
extern fn WindowShouldClose() bool;
extern fn SetTargetFPS(fps: c_int) void;
extern fn SetConfigFlags(flags: c_uint) void;
extern fn SetExitKey(key: c_int) void;
extern fn SetWindowMinSize(width: c_int, height: c_int) void;

extern fn BeginDrawing() void;
extern fn EndDrawing() void;
extern fn ClearBackground(color: Color) void;
extern fn GetScreenWidth() c_int;
extern fn GetScreenHeight() c_int;
extern fn GetTime() f64;

extern fn DrawRectangle(x: c_int, y: c_int, w: c_int, h: c_int, color: Color) void;
extern fn DrawRectangleRec(rec: Rectangle, color: Color) void;
extern fn DrawRectangleLinesEx(rec: Rectangle, thick: f32, color: Color) void;
extern fn DrawRectangleRounded(rec: Rectangle, roundness: f32, segments: c_int, color: Color) void;
extern fn DrawLineEx(start: Vector2, end: Vector2, thick: f32, color: Color) void;

extern fn GetFontDefault() Font;
extern fn LoadFontEx(file_name: [*:0]const u8, font_size: c_int, codepoints: ?[*]c_int, codepoint_count: c_int) Font;
extern fn IsFontValid(font: Font) bool;
extern fn UnloadFont(font: Font) void;
extern fn DrawTextEx(font: Font, text: [*:0]const u8, position: Vector2, font_size: f32, spacing: f32, tint: Color) void;
extern fn MeasureTextEx(font: Font, text: [*:0]const u8, font_size: f32, spacing: f32) Vector2;
extern fn SetTextureFilter(texture: Texture, filter: c_int) void;

extern fn GetMousePosition() Vector2;
extern fn IsMouseButtonPressed(button: c_int) bool;
extern fn IsMouseButtonDown(button: c_int) bool;
extern fn GetMouseWheelMove() f32;
extern fn IsKeyPressed(key: c_int) bool;
extern fn CheckCollisionPointRec(point: Vector2, rec: Rectangle) bool;

extern fn BeginScissorMode(x: c_int, y: c_int, w: c_int, h: c_int) void;
extern fn EndScissorMode() void;
extern fn Fade(color: Color, alpha: f32) Color;

extern fn GetWindowHandle() ?*anyopaque;
extern fn OpenURL(url: [*:0]const u8) void;
extern fn FileExists(file_name: [*:0]const u8) bool;
extern fn GetApplicationDirectory() [*:0]const u8;
extern fn LoadFileText(file_name: [*:0]const u8) ?[*:0]u8;
extern fn UnloadFileText(text: [*:0]u8) void;
extern fn SaveFileText(file_name: [*:0]const u8, text: [*:0]u8) bool;

// --- ergonomic Zig wrappers --------------------------------------------------

pub fn initWindow(width: i32, height: i32, title: [*:0]const u8) void {
    InitWindow(@intCast(width), @intCast(height), title);
}
pub fn closeWindow() void {
    CloseWindow();
}
pub fn windowShouldClose() bool {
    return WindowShouldClose();
}
pub fn setTargetFps(fps: i32) void {
    SetTargetFPS(@intCast(fps));
}
pub fn setConfigFlags(flags: c_uint) void {
    SetConfigFlags(flags);
}
pub fn setExitKey(key: c_int) void {
    SetExitKey(key);
}
pub fn setWindowMinSize(width: i32, height: i32) void {
    SetWindowMinSize(@intCast(width), @intCast(height));
}

pub fn beginDrawing() void {
    BeginDrawing();
}
pub fn endDrawing() void {
    EndDrawing();
}
pub fn clearBackground(color: Color) void {
    ClearBackground(color);
}
pub fn screenWidth() i32 {
    return @intCast(GetScreenWidth());
}
pub fn screenHeight() i32 {
    return @intCast(GetScreenHeight());
}
/// Seconds since the window was opened.
pub fn time() f64 {
    return GetTime();
}

pub fn drawRectangle(x: i32, y: i32, w: i32, h: i32, color: Color) void {
    DrawRectangle(@intCast(x), @intCast(y), @intCast(w), @intCast(h), color);
}
pub fn drawRectangleRec(rec: Rectangle, color: Color) void {
    DrawRectangleRec(rec, color);
}
pub fn drawRectangleLines(rec: Rectangle, thick: f32, color: Color) void {
    DrawRectangleLinesEx(rec, thick, color);
}
pub fn drawRectangleRounded(rec: Rectangle, roundness: f32, segments: i32, color: Color) void {
    DrawRectangleRounded(rec, roundness, @intCast(segments), color);
}
pub fn drawLine(start: Vector2, end: Vector2, thick: f32, color: Color) void {
    DrawLineEx(start, end, thick, color);
}

pub fn fontDefault() Font {
    return GetFontDefault();
}
/// Load a TTF/OTF at an exact pixel size with the given code points.
pub fn loadFontEx(file_name: [*:0]const u8, pixel_size: i32, codepoints: []c_int) Font {
    return LoadFontEx(file_name, @intCast(pixel_size), codepoints.ptr, @intCast(codepoints.len));
}
pub fn isFontValid(font: Font) bool {
    return IsFontValid(font);
}
pub fn unloadFont(font: Font) void {
    UnloadFont(font);
}
pub fn drawTextEx(font: Font, text: [*:0]const u8, position: Vector2, font_size: f32, spacing: f32, tint: Color) void {
    DrawTextEx(font, text, position, font_size, spacing, tint);
}
pub fn measureTextEx(font: Font, text: [*:0]const u8, font_size: f32, spacing: f32) Vector2 {
    return MeasureTextEx(font, text, font_size, spacing);
}
pub fn setTextureFilter(texture: Texture, filter: c_int) void {
    SetTextureFilter(texture, filter);
}

pub fn mousePosition() Vector2 {
    return GetMousePosition();
}
pub fn mousePressedLeft() bool {
    return IsMouseButtonPressed(mouse_button_left);
}
pub fn mouseDownLeft() bool {
    return IsMouseButtonDown(mouse_button_left);
}
pub fn mouseWheel() f32 {
    return GetMouseWheelMove();
}
pub fn keyPressed(key: c_int) bool {
    return IsKeyPressed(key);
}
pub fn pointInRect(point: Vector2, rec: Rectangle) bool {
    return CheckCollisionPointRec(point, rec);
}

pub fn beginScissor(x: i32, y: i32, w: i32, h: i32) void {
    BeginScissorMode(@intCast(x), @intCast(y), @intCast(w), @intCast(h));
}
pub fn endScissor() void {
    EndScissorMode();
}
pub fn fade(color: Color, alpha: f32) Color {
    return Fade(color, alpha);
}

pub fn mousePressedRight() bool {
    return IsMouseButtonPressed(mouse_button_right);
}
/// Native window handle (HWND on Windows).
pub fn windowHandle() ?*anyopaque {
    return GetWindowHandle();
}
/// Open a URL or path with the system's default handler.
pub fn openUrl(url: [*:0]const u8) void {
    OpenURL(url);
}

pub fn fileExists(file_name: [*:0]const u8) bool {
    return FileExists(file_name);
}
/// Directory of the running executable, with a trailing path separator.
pub fn applicationDirectory() [*:0]const u8 {
    return GetApplicationDirectory();
}
/// Read a text file. Free the result with `unloadFileText`.
pub fn loadFileText(file_name: [*:0]const u8) ?[*:0]u8 {
    return LoadFileText(file_name);
}
pub fn unloadFileText(text: [*:0]u8) void {
    UnloadFileText(text);
}
pub fn saveFileText(file_name: [*:0]const u8, text: [:0]u8) bool {
    return SaveFileText(file_name, text.ptr);
}

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}
