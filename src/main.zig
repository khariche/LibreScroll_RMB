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

pub const LIBRE_SCROLL_VERSION_TEXT = "v1.0.0";
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

    if (SetThreadDpiAwarenessContext(.UNAWARE_GDISCALED) == DPI_AWARENESS_CONTEXT.NULL) return;

    const hwndTray = CreateDialogParamA(null, "CFGDLG", null, @ptrCast(&trayProc), 0) orelse return;

    const hSensY = GetDlgItem(hwndTray, 0x4002) orelse return;
    const hSensX = GetDlgItem(hwndTray, 0x4003) orelse return;
    _ = SetWindowLongPtrA(hSensY, -21, SetWindowLongPtrA(hSensY, -4, @bitCast(@intFromPtr(&inputProc))));
    _ = SetWindowLongPtrA(hSensX, -21, SetWindowLongPtrA(hSensX, -4, @bitCast(@intFromPtr(&inputProc))));

    const ico = ico: {
        const cpl = LoadLibraryA("main.cpl") orelse break :ico null;
        defer _ = FreeLibrary(cpl);
        break :ico LoadIconA(cpl, @ptrFromInt(608));
    };

    _ = SendMessageA(hwndTray, 0x0080, 0, @bitCast(@intFromPtr(ico)));
    _ = SendMessageA(hwndTray, 0x0080, 1, @bitCast(@intFromPtr(ico)));

    var tray_data: NOTIFYICONDATAA = .{
        .hWnd = hwndTray,
        .uID = TRAY_UID,
        .uFlags = 0x8F,
        .uCallbackMessage = WM_TRAY,
        .hIcon = ico,
        .uTimeout = 4,
        .szTip = undefined,
        .dwState = 0,
        .dwStateMask = 1,
    };
    @memset(&tray_data.szTip, 0);
    tray_data.szTip[0..11].* = "LibreScroll".*;

    if (0 == Shell_NotifyIconA(.ADD, &tray_data)) return;
    defer _ = Shell_NotifyIconA(.DELETE, &tray_data);
    if (0 == Shell_NotifyIconA(.SETVERSION, &tray_data)) return;

    if (!startThread()) return;

    var msg: MSG = undefined;
    while (GetMessageA(&msg, null, 0, 0) > 0) {
        if (null == msg.hWnd) {
            if (WM_RAW_STOPPED == msg.message) {
                tray_data.szTip[11..23].* = " - Inactive\x00".*;
                _ = Shell_NotifyIconA(.MODIFY, &tray_data);
                if (GetDlgItem(hwndTray, 104)) |hPause| {
                    _ = SetWindowTextA(hPause, "Unpause");
                    _ = SetWindowLongA(hPause, -12, 105);
                }
                _ = CloseHandle(raw_thread_handle.?);
                raw_thread_handle = null;
                if (raw_thread_pending_restart) {
                    raw_thread_pending_restart = false;
                    _ = startThread();
                }
            } else if (WM_RAW_STARTED == msg.message) {
                tray_data.szTip[11..21].* = " - Active\x00".*;
                _ = Shell_NotifyIconA(.MODIFY, &tray_data);
                if (GetDlgItem(hwndTray, 105)) |hUnpause| {
                    _ = SetWindowTextA(hUnpause, "Pause");
                    _ = SetWindowLongA(hUnpause, -12, 104);
                }
            }
        } else if (0 == IsDialogMessageA(hwndTray, &msg)) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageA(&msg);
        }
    }
}

fn trayProc(hwnd: HWND, uMsg: u32, wParam: usize, lParam: isize) callconv(.C) isize {
    switch (uMsg) {
        else => return 0,
        0x0010 => _ = ShowWindowAsync(hwnd, 0),
        0x0111 => onWmCommand(hwnd, wParam, lParam),
        WM_TRAY => onWmTray(hwnd, wParam, lParam),
    }
    return 1;
}

fn inputProc(hwnd: HWND, uMsg: u32, wParam: usize, lParam: isize) callconv(.C) isize {
    if (uMsg == 0x0102 and wParam >= ' ') {
        switch(wParam) {
            else => if (wParam != '-' or 0 != SendMessageA(hwnd, 0x00B0, 0, 0)) return 0,
            '0'...'9' => {},
        }
    }
    const proc: WNDPROC = @ptrFromInt(@as(usize, @bitCast(GetWindowLongPtrA(hwnd, -21))));
    return CallWindowProcA(proc, hwnd, uMsg, wParam, lParam);
}

fn onWmCommand(hwnd: HWND, wParam: usize, lParam: isize) void {
    const hCtrl: ?HWND = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const id = wParam & 0xFFFF;
    const uMsg = wParam >> 16;
    const is_accel = (null == hCtrl) and (1 == uMsg); _ = is_accel;
    switch (id) {
        else => {},
        100 => quit(),
        101 => show(hwnd),
        102 => info(hwnd),
        103 => elevate(),
        104 => if (raw_thread_handle) |_| {
            raw_thread_pending_restart = false;
            _ = PostThreadMessageA(raw_thread_id, 0x0012, 0, 0);
        },
        105, 106 => {
            if (106 == id) save(hwnd);
            if (raw_thread_handle) |_| {
                raw_thread_pending_restart = true;
                _ = PostThreadMessageA(raw_thread_id, 0x0012, 0, 0);
            } else {
                raw_thread_pending_restart = false;
                if (!startThread()) quit();
            }
        },
    }
}

fn onWmTray(hwnd: HWND, wParam: usize, lParam: isize) void {
    const src: packed struct(usize) {
        msg: u16,
        uid: u16,
        _: if (8 == @sizeOf(usize)) u32 else u0,
    } = @bitCast(lParam);
    const pos: packed struct(usize) {
        x: i16,
        y: i16,
        _: if (8 == @sizeOf(usize)) u32 else u0,
    } = @bitCast(wParam);
    switch (src.msg) {
        else => {},
        0x007B => menu(hwnd, src.uid, pos.x, pos.y),
        0x0400 => show(hwnd),
    }
}

fn elevate() void {
    var buf: [32767:0]u8 = undefined;
    const len = GetModuleFileNameA(null, &buf, buf.len);
    if (len == 0) return;
    if (len == buf.len and 0 != GetLastError()) return;
    _ = CloseHandle(process_mutex);
    _ = ShellExecuteA(null, "runas", &buf, null, null, 0);
    quit();
}

fn quit() void {
    _ = PostQuitMessage(0);
}

fn info(hwnd: HWND) void {
    _ = MessageBoxA(hwnd, "Visit https://github.com/EsportToys/LibreScroll for more info.", "About LibreScroll " ++ LIBRE_SCROLL_VERSION_TEXT, 0);
}

fn menu(hwnd: HWND, uid: u16, x: i16, y: i16) void {
    const tray_hmenu = LoadMenuA(null, "menu") orelse return;
    defer _ = DestroyMenu(tray_hmenu);
    const hMenu = GetSubMenu(tray_hmenu, IsUserAnAdmin() | @as(i32, if (raw_thread_handle) |_| 2 else 0)) orelse return;
    var rect: [4]i32 = undefined;
    _ = Shell_NotifyIconGetRect(&.{ .hWnd = hwnd, .uID = uid }, &rect);
    _ = SetForegroundWindow(hwnd);
    _ = SetThreadDpiAwarenessContext(.PER_MONITOR_AWARE_V2);
    _ = TrackPopupMenu(hMenu, 0, x, y, 0, hwnd, null);
    _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT.NULL);
}

fn show(hwnd: HWND) void {
    _ = SetDlgItemInt(  hwnd, 0x4001, @bitCast(global_config.decay), 0 );
    _ = SetDlgItemInt(  hwnd, 0x4002, @bitCast(global_config.sensY), 1 );
    _ = SetDlgItemInt(  hwnd, 0x4003, @bitCast(global_config.sensX), 1 );
    _ = SetDlgItemInt(  hwnd, 0x4004, @bitCast(global_config.stepY), 0 );
    _ = SetDlgItemInt(  hwnd, 0x4005, @bitCast(global_config.stepX), 0 );
    _ = CheckDlgButton( hwnd, 0x4006, @bitCast(global_config.flick)    );
    _ = CheckDlgButton( hwnd, 0x4007, @bitCast(global_config.think)    );
    if (0 == IsWindowVisible(hwnd)) _ = ShowWindowAsync(hwnd, 5);
    _ = SetForegroundWindow(hwnd);
}

fn save(hwnd: HWND) void {
    const ini = "./options.ini";
    const sec = "LibreScroll";
    var buf: [32767:0]u8 = undefined;
    inline for (.{ "decay", "sensY", "sensX", "stepY", "stepX" }, 0x4001..) |key, i| {
        _ = GetDlgItemTextA(hwnd, i, &buf, buf.len);
        _ = WritePrivateProfileStringA(sec, key, &buf, ini);
    }
    _ = WritePrivateProfileStringA(sec, "flick", if (0 == IsDlgButtonChecked(hwnd, 0x4006)) "0" else "1", ini);
    _ = WritePrivateProfileStringA(sec, "think", if (0 == IsDlgButtonChecked(hwnd, 0x4007)) "0" else "1", ini);
}

fn startThread() bool {
    const ini = "./options.ini";
    const sec = "LibreScroll";
    global_config.decay = @max( 0 ,           GetPrivateProfileIntA(sec, "decay", global_config.decay, ini)   );
    global_config.sensY =                     GetPrivateProfileIntA(sec, "sensY", global_config.sensY, ini)    ;
    global_config.sensX =                     GetPrivateProfileIntA(sec, "sensX", global_config.sensX, ini)    ;
    global_config.stepY = @max( 0 ,           GetPrivateProfileIntA(sec, "stepY", global_config.stepY, ini)   );
    global_config.stepX = @max( 0 ,           GetPrivateProfileIntA(sec, "stepX", global_config.stepX, ini)   );
    global_config.flick = @max( 0 , @min( 1 , GetPrivateProfileIntA(sec, "flick", global_config.flick, ini) ) );
    global_config.think = @max( 0 , @min( 1 , GetPrivateProfileIntA(sec, "think", global_config.think, ini) ) );
    raw_thread_handle = CreateThread(
        null,
        0,
        &rawMain,
        null,
        0,
        &raw_thread_id,
    ) orelse return false;
    return true;
}

fn hookProc(code: i32, wParam: usize, lParam: isize) callconv(.C) isize {
    if (wParam == 0x204 or wParam == 0x205) {
        const inf: *const MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
        const pass: usize = @bitCast(MAGIC_WORD);
        if (pass == inf.dwExtraInfo) {
            return CallNextHookEx(null, code, wParam, lParam);
        }
        return 1;
    }
    return CallNextHookEx(null, code, wParam, lParam);
}

fn hookMain(_: ?*anyopaque) callconv(.C) u32 {
    defer _ = PostThreadMessageA(raw_thread_id, 0x0012, 0, 0);
    const hhook = SetWindowsHookExA(14, hookProc, null, 0) orelse return 0;
    defer _ = UnhookWindowsHookEx(hhook);
    _ = PostThreadMessageA(raw_thread_id, WM_HOOK_STARTED, 0, 0);
    var msg: MSG = undefined;
    while (GetMessageA(&msg, null, 0, 0) > 0) {
        _ = DispatchMessageA(&msg);
    }
    return 0;
}

fn rawMain(_: ?*anyopaque) callconv(.C) u32 {
    defer _ = PostThreadMessageA(main_thread_id, WM_RAW_STOPPED, 0, 0);
    if (SetThreadDpiAwarenessContext(.PER_MONITOR_AWARE_V2) == DPI_AWARENESS_CONTEXT.NULL) return 0;
    const HWND_MESSAGE: HWND = @ptrFromInt(~@as(usize, 2));
    const hwnd = CreateWindowExA(0, "Message", null, 0, 0, 0, 0, 0, HWND_MESSAGE, null, null, null) orelse return 0;
    defer _ = DestroyWindow(hwnd);

    if (0 == RegisterRawInputDevices(&.{.{
        .usUsagePage = 0x01,
        .usUsage = 0x02,
        .dwFlags = 0x100,
        .hwndTarget = hwnd,
    }}, 1, @sizeOf(RAWINPUTDEVICE))) return 0;

    defer _ = RegisterRawInputDevices(&.{.{
        .usUsagePage = 0x01,
        .usUsage = 0x02,
