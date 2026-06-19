decay: i32 = 3,
sensY: i32 = 18,
sensX: i32 = 0,
stepY: i32 = 1,
stepX: i32 = 1,
flick: i32 = 0,
think: i32 = 0,

var global_config: @This() = .{};
var process_mutex: *anyopaque = undefined;
var main_thread_id: u32 = undefined;
var raw_thread_id: u32 = undefined;
var raw_thread_handle: ?*anyopaque = null;
var raw_thread_pending_restart = false;

const Vec2f = @Vector(2, f32);
const Vec2i = @Vector(2, i32);

pub const LIBRE_SCROLL_VERSION_TEXT = "v" ++ @import("build.zig.zon").version;
const MAGIC_WORD: [8]u8 = "PASS\x00\x00\x00\x00".*;
const WM_TRAY = 0x8001;
const WM_RAW_STOPPED = 0x8002;
const WM_RAW_STARTED = 0x8003;
const WM_HOOK_STOPPED = 0x8004;
const WM_HOOK_STARTED = 0x8005;
const TRAY_UID = 0x69;

pub fn main() void {
    process_mutex = CreateMutexA(null, 1, "LibreScroll") orelse return;
    if (0 != GetLastError()) return;
    main_thread_id = GetCurrentThreadId();

    if (.NULL == SetThreadDpiAwarenessContext(.UNAWARE_GDISCALED)) return;

    const hwndTray = CreateDialogParamA(null, "CFGDLG", null, trayProc, 0) orelse return;

    const hSensY = GetDlgItem(hwndTray, 0x4002) orelse return;
    const hSensX = GetDlgItem(hwndTray, 0x4003) orelse return;
    _ = SetWindowLongPtrA(hSensY, -21, SetWindowLongPtrA(hSensY, -4, @bitCast(@intFromPtr(&inputProc))));
    _ = SetWindowLongPtrA(hSensX, -21, SetWindowLong
