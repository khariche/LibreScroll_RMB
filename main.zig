const Param = @This();
decay: i32 = 3,
sensY: i32 = 9,
sensX: i32 = 0,
stepY: i32 = 1,
stepX: i32 = 1,
flick: i32 = 0,
think: i32 = 0,

var process_mutex: *anyopaque = undefined;
var main_thread_id: u32 = undefined;
var raw_thread_id: u32 = undefined;
var raw_thread_handle: ?*anyopaque = null;
var raw_thread_pending_restart = false;

const Vec2f = @Vector(2, f32);
const Vec2i = @Vector(2, i32);
const Shared = struct {
    const ms = 10;
    var param: Param = .{};
    var vel: Vec2f = @splat(0);
    var acu: Vec2i = @splat(0);
    var rect: [4]i32 = @splat(0);
    var is_scrolling = false;
    var cancel_pending = false;
};

const LIBRE_SCROLL_VERSION_TEXT = "v2.0";
const WM_TRAY = 0x8001;
const WM_RAW_STOPPED = 0x8002;
const WM_RAW_STARTED = 0x8003;
const TRAY_UID = 0x69;

const win = @import("std").os.windows;

pub fn main() void {
    process_mutex = CreateMutexA(null, 1, "LibreScroll") orelse return;
    if (.SUCCESS != win.GetLastError()) return;
    main_thread_id = win.GetCurrentThreadId();

    if (.NULL == SetThreadDpiAwarenessContext(.UNAWARE_GDISCALED)) return;

    const hwndTray = CreateDialogParamA(null, "CFGDLG", null, trayProc, 0) orelse return;

    const ico = ico: {
        const cpl = LoadLibraryA("main.cpl") orelse break :ico null;
        defer win.FreeLibrary(cpl);
        break :ico LoadIconA(cpl, @ptrFromInt(608));
    };

    _ = SendMessageA(hwndTray, 0x0080, 0, @bitCast(@intFromPtr(ico))); // set small icon
    _ = SendMessageA(hwndTray, 0x0080, 1, @bitCast(@intFromPtr(ico))); // set big icon

    var tray_data: NOTIFYICONDATAA = .{
        .hWnd = hwndTray,
        .uID = TRAY_UID,
        .uFlags = 0x8F,
        .uCallbackMessage = WM_TRAY,
        .hIcon = ico,
        .uTimeout = 4,
        .szTip = @splat(0),
        .dwState = 0,
        .dwStateMask = 1,
    };
    tray_data.szTip[0..11].* = "LibreScroll".*;

    if (0 == Shell_NotifyIconA(.ADD, &tray_data)) return;
    if (0 == Shell_NotifyIconA(.SETVERSION, &tray_data)) return;
    defer _ = Shell_NotifyIconA(.DELETE, &tray_data);

    if (!startThread()) return;

    var msg: MSG = undefined;
    while (GetMessageA(&msg, null, 0, 0) > 0) {
        if (null == msg.hWnd) {
            if (WM_RAW_STOPPED == msg.message) {
                tray_data.szTip[11..22].* = " - Inactive".*;
                _ = Shell_NotifyIconA(.MODIFY, &tray_data);
                if (GetDlgItem(hwndTray, 104)) |hPause| {
                    _ = SetWindowTextA(hPause, "Unpause");
                    _ = SetWindowLongA(hPause, -12, 105);
                }
                win.CloseHandle(raw_thread_handle.?);
                raw_thread_handle = null;
                if (raw_thread_pending_restart) {
                    raw_thread_pending_restart = false;
                    _ = startThread(); // non-critical failure
                }
            } else if (WM_RAW_STARTED == msg.message) {
                tray_data.szTip[11..20].* = " - Active".*;
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

fn trayProc(hwnd: win.HWND, uMsg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
    switch (uMsg) {
        else => return 0,
        0x0010 => _ = ShowWindowAsync(hwnd, 0), // hide to tray instead of quitting
        0x0111 => onWmCommand(hwnd, wParam, lParam),
        WM_TRAY => onWmTray(hwnd, wParam, lParam),
    }
    return 1;
}

fn onWmCommand(hwnd: win.HWND, wParam: usize, lParam: isize) void {
    const hCtrl: ?win.HWND = @ptrFromInt(@as(usize, @bitCast(lParam)));
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

fn onWmTray(hwnd: win.HWND, wParam: usize, lParam: isize) void {
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
        0x007B => menu(hwnd, src.uid, pos.x, pos.y), // WM_CONTEXTMENU
        0x0400 => show(hwnd), // WM_USER
    }
}

fn elevate() void {
    var buf: [32767:0]u8 = undefined;
    const len = GetModuleFileNameA(null, &buf, buf.len); // copied `len` characters plus zero sentinel at index `len`
    if (len == 0) return;
    if (len == buf.len and .SUCCESS != win.GetLastError()) return;
    win.CloseHandle(process_mutex);
    _ = ShellExecuteA(null, "runas", &buf, null, null, 0);
    quit();
}

fn quit() void {
    _ = PostQuitMessage(0);
}

fn info(hwnd: win.HWND) void {
    _ = MessageBoxA(hwnd, "Visit https://github.com/EsportToys/LibreScroll for more info.", "About LibreScroll " ++ LIBRE_SCROLL_VERSION_TEXT, 0);
}

fn menu(hwnd: win.HWND, uid: u16, x: i16, y: i16) void {
    const tray_hmenu = LoadMenuA(null, "menu") orelse return;
    defer _ = DestroyMenu(tray_hmenu);
    const hMenu = GetSubMenu(tray_hmenu, IsUserAnAdmin() | @as(i32, if (raw_thread_handle) |_| 2 else 0)) orelse return;
    var rect:[4]i32 = undefined;
    _ = Shell_NotifyIconGetRect(&.{ .hWnd = hwnd, .uID = uid }, &rect);
    _ = SetForegroundWindow(hwnd);
    _ = SetThreadDpiAwarenessContext(.PER_MONITOR_AWARE_V2);
    _ = TrackPopupMenu(hMenu, 0, x, y, 0, hwnd, null);
    _ = SetThreadDpiAwarenessContext(.NULL);
}

fn show(hwnd: win.HWND) void {
    _ = SetDlgItemInt(  hwnd, 0x4001, @bitCast(Shared.param.decay), 0 );
    _ = SetDlgItemInt(  hwnd, 0x4002, @bitCast(Shared.param.sensY), 1 );
    _ = SetDlgItemInt(  hwnd, 0x4003, @bitCast(Shared.param.sensX), 1 );
    _ = SetDlgItemInt(  hwnd, 0x4004, @bitCast(Shared.param.stepY), 0 );
    _ = SetDlgItemInt(  hwnd, 0x4005, @bitCast(Shared.param.stepX), 0 );
    _ = CheckDlgButton( hwnd, 0x4006, @bitCast(Shared.param.flick)    );
    _ = CheckDlgButton( hwnd, 0x4007, @bitCast(Shared.param.think)    );
    if (0 == IsWindowVisible(hwnd)) _ = ShowWindowAsync(hwnd, 5);
    _ = SetForegroundWindow(hwnd);
}

fn save(hwnd: win.HWND) void {
    const ini = "./options.ini";
    const sec = "LibreScroll";
    var buf: [32767:0]u8 = undefined;
    inline for(.{ "decay", "sensY", "sensX", "stepY", "stepX" }, 0x4001..) |key, i| {
        _ = GetDlgItemTextA(hwnd, i, &buf, buf.len);
        _ = WritePrivateProfileStringA(sec, key, &buf, ini);
    }
    _ = WritePrivateProfileStringA(sec, "flick", if (0 == IsDlgButtonChecked(hwnd, 0x4006)) "0" else "1", ini);
    _ = WritePrivateProfileStringA(sec, "think", if (0 == IsDlgButtonChecked(hwnd, 0x4007)) "0" else "1", ini);
}

fn startThread() bool {
    const ini = "./options.ini";
    const sec = "LibreScroll";
    Shared.param.decay = @max( 0 ,           GetPrivateProfileIntA(sec, "decay", Shared.param.decay, ini)   );
    Shared.param.sensY =                     GetPrivateProfileIntA(sec, "sensY", Shared.param.sensY, ini)    ;
    Shared.param.sensX =                     GetPrivateProfileIntA(sec, "sensX", Shared.param.sensX, ini)    ;
    Shared.param.stepY = @max( 0 ,           GetPrivateProfileIntA(sec, "stepY", Shared.param.stepY, ini)   );
    Shared.param.stepX = @max( 0 ,           GetPrivateProfileIntA(sec, "stepX", Shared.param.stepX, ini)   );
    Shared.param.flick = @max( 0 , @min( 1 , GetPrivateProfileIntA(sec, "flick", Shared.param.flick, ini) ) );
    Shared.param.think = @max( 0 , @min( 1 , GetPrivateProfileIntA(sec, "think", Shared.param.think, ini) ) );
    raw_thread_handle = win.kernel32.CreateThread(
        null,
        0,
        &rawMain,
        null,
        0,
        &raw_thread_id,
    ) orelse return false;
    return true;
}

fn rawMain(_: ?*anyopaque) callconv(.winapi) u32 {
    defer _ = PostThreadMessageA(main_thread_id, WM_RAW_STOPPED, 0, 0);
    if (.NULL == SetThreadDpiAwarenessContext(.PER_MONITOR_AWARE_V2)) return 0;
    const HWND_MESSAGE: win.HWND = @ptrFromInt(~@as(usize, 2));
    const hwnd = CreateWindowExA(0, "Message", null, 0, 0, 0, 0, 0, HWND_MESSAGE, null, null, null) orelse return 0;
    defer _ = DestroyWindow(hwnd);

    if (0 == RegisterRawInputDevices(&.{.{
        .usUsagePage = 0x01, // generic desktop
        .usUsage = 0x02, // mouse
        .dwFlags = 0x100, // inputsink
        .hwndTarget = hwnd,
    }}, 1, @sizeOf(RAWINPUTDEVICE))) return 0;

    defer _ = RegisterRawInputDevices(&.{.{
        .usUsagePage = 0x01, // generic desktop
        .usUsage = 0x02, // mouse
        .dwFlags = 0x1, // inputsink
        .hwndTarget = null,
    }}, 1, @sizeOf(RAWINPUTDEVICE));

    _ = PostThreadMessageA(main_thread_id, WM_RAW_STARTED, 0, 0);

    var msg: MSG = undefined;
    var past = win.QueryPerformanceCounter();
    const qpf = win.QueryPerformanceFrequency();
    while (GetMessageA(&msg, null, 0, 0) > 0) {
        if (0xff == msg.message) rawProc(msg.lParam);
        _ = DispatchMessageA(&msg);
        const now = win.QueryPerformanceCounter();
        const dt = now - past;
        if (dt * 1000 < qpf * Shared.ms) continue;
        past = now;
        simulation(dt, qpf);
    }

    return 0;
}

fn rawProc(lParam: isize) void {
    const timer = struct {
        var handle: usize = 0;
    };
    var data: RAWINPUT.MOUSE = undefined;
    var size: u32 = @sizeOf(RAWINPUT.MOUSE);
    if (0 < GetRawInputData(lParam, 0x10000003, &data, &size, @sizeOf(RAWINPUT.HEADER))) {
        _ = data.header.hDevice orelse return;
        const flags = data.data.usButtonFlags;
        if (flags == 0) { // movement only
            Shared.acu += .{ data.data.lLastX, data.data.lLastY };
        } else if (32 == 32 | flags) {
            if (Shared.param.flick == 0) {
                const success = KillTimer(null, timer.handle);
                if (success != 0) timer.handle = 0;
            }
            Shared.is_scrolling = false;
            Shared.cancel_pending = false;
            _ = ClipCursor(null);
        } else if (16 == 16 | flags) {
            if (timer.handle == 0) {
                timer.handle = SetCoalescableTimer(null, 0, Shared.ms, null, 0);
                if (timer.handle == 0) _ = PostThreadMessageA(win.GetCurrentThreadId(), 0x0012, 0, 0);
            }
            Shared.acu = @splat(0);
            Shared.vel = @splat(0);
            Shared.is_scrolling = true;
            Shared.cancel_pending = true;
            _ = GetCursorPos(Shared.rect[0..2]);
            Shared.rect[2] = Shared.rect[0] + 1;
            Shared.rect[3] = Shared.rect[1] + 1;
            _ = ClipCursor(&Shared.rect);
        } else if (Shared.param.flick != 0 and !Shared.is_scrolling) {
            Shared.vel = @splat(0); // in flick mode, any mouse action besides the above should immediately halt
            const success = KillTimer(null, timer.handle);
            if (success != 0) timer.handle = 0;
        }
    }
}

fn simulation(tick: u64, freq: u64) void {
    if (Shared.is_scrolling) {
        var current_rect: [4]i32 = undefined;
        _ = GetClipCursor(&current_rect);
        if (current_rect[0] != Shared.rect[0] or
            current_rect[1] != Shared.rect[1] or
            current_rect[2] != Shared.rect[2] or
            current_rect[3] != Shared.rect[3]) _ = ClipCursor(&Shared.rect);
        var delta: Vec2f = .{
            @floatFromInt(Shared.acu[0]),
            @floatFromInt(Shared.acu[1]),
        };
        delta *= .{ @floatFromInt(Shared.param.sensX), @floatFromInt(Shared.param.sensY) };
        Shared.vel += delta;
    } else if (Shared.param.flick == 0) {
        return;
    }
    defer Shared.acu = @splat(0);
    var dt: f32 = @floatFromInt(tick);
    dt /= @floatFromInt(freq);
    const mu: f32 = @floatFromInt(Shared.param.decay);
    const f0 = @exp(-dt * mu);
    const f1 = (1 - f0) / mu;
    var send = Shared.vel;
    send *= @splat(f1);
    Shared.vel *= @splat(f0);
    if (@reduce(.Add, Shared.vel * Shared.vel) < 1) {
        Shared.vel /= @splat(mu);
        send += Shared.vel;
        Shared.vel = @splat(0);
    }
    sendScroll(send);
}

fn sendScroll(delta: Vec2f) void {
    const static = struct {
        var res: Vec2f = @splat(0);
    };
    static.res += delta;
    const thresh: Vec2f = .{ @floatFromInt(Shared.param.stepX), @floatFromInt(Shared.param.stepY) };
    const batch = @trunc(static.res / thresh);
    var send: Vec2i = @splat(0);
    if (0 != batch[0]) {
        const dx = batch[0] * thresh[0];
        send[0] = @intFromFloat((dx));
        static.res[0] -= dx;
    }
    if (0 != batch[1]) {
        const dy = batch[1] * thresh[1];
        send[1] = @intFromFloat((dy));
        static.res[1] -= dy;
    }
    if (Shared.param.think != 0) {
        if (@abs(send[0]) > @abs(send[1])) {
            send[1] = 0;
            static.res[1] = 0;
        } else {
            send[0] = 0;
            static.res[0] = 0;
        }
    }
    if (0 != send[0] or 0 != send[1]) {
        const buf: [2]INPUT = .{
            .mi(.{ .mouseData = -send[1], .dwFlags = 0x0800 }),
            .mi(.{ .mouseData =  send[0], .dwFlags = 0x1000 }),
        };
        if (Shared.cancel_pending) {
            Shared.cancel_pending = false;
            _ = sendInputs(&.{
                .ki(.{ .dwFlags = 0 }),
                .ki(.{ .dwFlags = 2 }),
            });
        }
        if (send[1] != 0) {
            _ = sendInputs(if (send[0] != 0) &buf else buf[0..1]);
        } else if (send[0] != 0) {
            _ = sendInputs(buf[1..]);
        }
    }
}

fn sendInputs(cmd: []const INPUT) u32 {
    return SendInput(@truncate(cmd.len), cmd.ptr, @sizeOf(INPUT));
}

extern "kernel32" fn CreateMutexA(?*const win.SECURITY_ATTRIBUTES, i32, [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleFileNameA(?win.HMODULE, [*]u8, u32) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.winapi) ?win.HMODULE;
extern "kernel32" fn GetPrivateProfileIntA([*:0]const u8, [*:0]const u8, i32, [*:0]const u8) callconv(.winapi) i32;
extern "kernel32" fn WritePrivateProfileStringA([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.winapi) i32;

extern "user32" fn SetWindowLongA(win.HWND, i32, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowTextA(win.HWND, ?[*:0]const u8) callconv(.winapi) i32;
extern "user32" fn CreateWindowExA(u32, ?[*:0]const u8, ?[*:0]const u8, u32, i32, i32, i32, i32, ?win.HWND, ?win.HMENU, ?win.HMODULE, ?*anyopaque) callconv(.winapi) ?win.HWND;
extern "user32" fn DestroyWindow(win.HWND) callconv(.winapi) i32;
extern "user32" fn ShowWindowAsync(win.HWND, i32) callconv(.winapi) i32;
extern "user32" fn IsWindowVisible(win.HWND) callconv(.winapi) i32;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn PostThreadMessageA(u32, u32, usize, isize) callconv(.winapi) i32;
extern "user32" fn SendMessageA(win.HWND, u32, usize, isize) callconv(.winapi) i32;
extern "user32" fn GetMessageA(*MSG, ?win.HWND, u32, u32) callconv(.winapi) i32;
extern "user32" fn DispatchMessageA(*const MSG) callconv(.winapi) isize;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn RegisterRawInputDevices([*]const RAWINPUTDEVICE, u32, u32) i32;
extern "user32" fn GetRawInputData(isize, u32, ?*anyopaque, *u32, u32) callconv(.winapi) i32;
extern "user32" fn SendInput(cInputs: u32, pInputs: [*]const INPUT, cbSize: i32) callconv(.winapi) u32;
extern "user32" fn LoadIconA(?win.HMODULE, [*:0]const u8) callconv(.winapi) ?win.HICON;
extern "user32" fn LoadMenuA(?win.HMODULE, [*:0]const u8) callconv(.winapi) ?win.HMENU;
extern "user32" fn DestroyMenu(win.HMENU) callconv(.winapi) i32;
extern "user32" fn TrackPopupMenu(win.HMENU, u32, i32, i32, i32, ?win.HWND, ?*const [4]i32) callconv(.winapi) u32;
extern "user32" fn SetForegroundWindow(win.HWND) callconv(.winapi) i32;
extern "user32" fn GetSubMenu(win.HMENU, i32) callconv(.winapi) ?win.HMENU;
extern "user32" fn MessageBoxA(?win.HWND, ?[*:0]const u8, ?[*:0]const u8, u32) callconv(.winapi) i32;
extern "user32" fn SetTimer(?win.HWND, usize, u32, ?TIMERPROC) callconv(.winapi) usize;
extern "user32" fn SetCoalescableTimer(?win.HWND, usize, u32, ?TIMERPROC, u32) callconv(.winapi) usize;
extern "user32" fn KillTimer(?win.HWND, usize) callconv(.winapi) i32;
extern "user32" fn GetClipCursor(*[4]i32) callconv(.winapi) i32;
extern "user32" fn GetCursorPos(*[2]i32) callconv(.winapi) i32;
extern "user32" fn ClipCursor(?*const [4]i32) callconv(.winapi) i32;
extern "user32" fn SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT) callconv(.winapi) DPI_AWARENESS_CONTEXT;
extern "user32" fn CreateDialogParamA(?win.HMODULE, [*:0]const u8, ?win.HWND, ?DLGPROC, isize) callconv(.winapi) ?win.HWND;
extern "user32" fn GetDlgItem(?win.HWND, i32) callconv(.winapi) ?win.HWND;
extern "user32" fn SetDlgItemInt(win.HWND, i32, u32, i32) callconv(.winapi) i32;
extern "user32" fn GetDlgItemInt(win.HWND, i32, ?*i32, i32) callconv(.winapi) u32;
extern "user32" fn GetDlgItemTextA(win.HWND, i32, [*:0]u8, i32) callconv(.winapi) u32;
extern "user32" fn IsDialogMessageA(win.HWND, *MSG) callconv(.winapi) i32;
extern "user32" fn IsDlgButtonChecked(win.HWND, i32) callconv(.winapi) u32;
extern "user32" fn CheckDlgButton(win.HWND, i32, u32) callconv(.winapi) i32;

const DPI_AWARENESS_CONTEXT = enum(isize) {
    NULL = 0,
    UNAWARE = -1,
    SYSTEM_AWARE = -2,
    PER_MONITOR_AWARE = -3,
    PER_MONITOR_AWARE_V2 = -4,
    UNAWARE_GDISCALED = -5,
};

const DLGPROC = *const fn (win.HWND, u32, usize, isize) callconv(.winapi) isize;
const TIMERPROC = *const fn (?win.HWND, u32, usize, u32) callconv(.winapi) void;

const MSG = extern struct {
    hWnd: ?win.HWND,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: [2]i32,
    lPrivate: u32,
};

const RAWINPUTDEVICE = extern struct {
    usUsagePage: u16,
    usUsage: u16,
    dwFlags: u32,
    hwndTarget: ?win.HWND,
};

const RAWINPUT = extern union {
    mi: MOUSE,
    ki: KEYBOARD,
    hi: HID(1),
    pub const HEADER = extern struct {
        dwType: u32,
        dwSize: u32,
        hDevice: ?*anyopaque,
        wParam: usize,
    };
    pub const MOUSE = extern struct {
        header: HEADER,
        data: extern struct {
            usFlags: u16,
            _: u16,
            usButtonFlags: u16,
            usButtonData: i16,
            ulRawButtons: u32,
            lLastX: i32,
            lLastY: i32,
            ulExtraInformation: u32,
        },
    };
    pub const KEYBOARD = extern struct {
        header: HEADER,
        data: extern struct {
            MakeCode: u16,
            Flags: u16,
            Reserved: u16,
            VKey: u16,
            Message: u32,
            ExtraInformation: u32,
        },
    };
    pub fn HID(comptime n: usize) type {
        return extern struct {
            header: HEADER,
            data: extern struct {
                dwSizeHid: u32,
                dwCount: u32,
                bRawData: [n]u8,
            },
        };
    }
};

const INPUT = extern struct {
    type: u32,
    input: extern union {
        mi: MOUSEINPUT,
        ki: KEYBDINPUT,
        hi: HARDWAREINPUT,
    },
    const MOUSEINPUT = extern struct {
        dx: i32 = 0,
        dy: i32 = 0,
        mouseData: i32 = 0,
        dwFlags: u32 = 0,
        time: u32 = 0,
        dwExtraInfo: usize = 0,
    };
    const KEYBDINPUT = extern struct {
        wVK: u16 = 0,
        wScan: u16 = 0,
        dwFlags: u32 = 0,
        time: u32 = 0,
        dwExtraInfo: usize = 0,
    };
    const HARDWAREINPUT = extern struct {
        uMsg: u32 = 0,
        wParamL: u16 = 0,
        wParamH: u16 = 0,
    };
    fn mi(m: MOUSEINPUT) INPUT { return .{ .type = 0, .input = .{.mi = m} }; }
    fn ki(k: KEYBDINPUT) INPUT { return .{ .type = 1, .input = .{.ki = k} }; }
    fn hi(h: HARDWAREINPUT) INPUT { return .{ .type = 2, .input = .{.hi = h} }; }
};

extern "shell32" fn IsUserAnAdmin() callconv(.winapi) i32;
extern "shell32" fn ShellExecuteA(?win.HWND, ?[*:0]const u8, [*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, i32) callconv(.winapi) ?win.HMODULE;
extern "shell32" fn Shell_NotifyIconGetRect(*const NOTIFYICONIDENTIFIER, *[4]i32) callconv(.winapi) i32;
extern "shell32" fn Shell_NotifyIconA(NIM, *const NOTIFYICONDATAA) callconv(.winapi) i32;
const NIM = enum(u32) {
    ADD = 0,
    MODIFY = 1,
    DELETE = 2,
    SETFOCUS = 3,
    SETVERSION = 4,
};

const NOTIFYICONDATAA = extern struct {
    cbSize: u32 = @sizeOf(@This()),
    hWnd: ?win.HWND = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0, // uFlags 1, user defined WM_* message identifier
    hIcon: ?win.HICON = null, // uFlags 2, tray icon
    szTip: [128]u8 = .{0} ** 128, // uFlags 4, hover tooltips, 64 for below win2k
    dwState: u32 = 0, // uFlags 8, set state flags
    dwStateMask: u32 = 0, // uFlags 8, which dwState to change
    szInfo: [256]u8 = .{0} ** 256, // uFlags 16, balloon text
    uTimeout: u32 = 0, // uFlags 16, or uVersion if calling with SETVERSION
    szInfoTitle: [64]u8 = .{0} ** 64, // balloon title
    dwInfoFlags: u32 = 0, // balloon options
    guidItem: win.GUID = @bitCast(@as(u128, 0)), // uFlags 32
    hBalloonIcon: ?win.HICON = null, // custom balloon title icon (require dwInfoFlags 0x4 bit)
};

const NOTIFYICONIDENTIFIER = extern struct {
    cbSize: u32 = @sizeOf(@This()),
    hWnd: win.HWND,
    uID: u32,
    guidItem: win.GUID = @bitCast(@as(u128, 0)),
};
