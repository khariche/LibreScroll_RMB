const LIBRE_SCROLL_VERSION_TEXT = "v2.0";

const std = @import("std");
const win = std.os.windows;

var process_mutex: *anyopaque = undefined;
var main_thread_id: u32 = undefined;
var raw_thread_id: u32 = undefined;
var raw_thread_handle: ?*anyopaque = null;
var raw_thread_pending_restart = false;

const WM_TRAY = 0x8001;
const WM_RAW_STOPPED = 0x8002;
const WM_RAW_STARTED = 0x8003;
const TRAY_UID = 0x69;

pub fn main() void {
    process_mutex = CreateMutexA(null, 1, "LibreScroll") orelse return;
    if (.SUCCESS != win.kernel32.GetLastError()) return;
    main_thread_id = win.GetCurrentThreadId();

    if (.NULL == SetThreadDpiAwarenessContext(.UNAWARE_GDISCALED)) return;

    const style = 0x00C80000;

    var dim: [4]i32 = .{ 0, 0, 215, 210 };
    _ = AdjustWindowRect(@ptrCast(&dim), style, 0);

    const hwndTray = CreateDialogParamA(null, "CFGDLG", null, trayProc, 0) orelse return;

    const ico = ico: {
        const cpl = LoadLibraryA("main.cpl") orelse break :ico null;
        defer _ = FreeLibrary(cpl);
        break :ico LoadIconA(cpl, @ptrFromInt(608));
    };

    _ = SendMessageA(hwndTray, 0x0080, 0, @bitCast(@intFromPtr(ico))); // set small icon
    _ = SendMessageA(hwndTray, 0x0080, 1, @bitCast(@intFromPtr(ico))); // set big icon

    const tray_data: NOTIFYICONDATAA = .{
        .hWnd = hwndTray,
        .uID = TRAY_UID,
        .uFlags = 0x8F,
        .uCallbackMessage = WM_TRAY,
        .hIcon = ico,
        .uTimeout = 4,
        .szTip = "LibreScroll".* ++ .{0} ** (128 - 11),
        .dwState = 0,
        .dwStateMask = 1,
    };

    if (0 == Shell_NotifyIconA(.ADD, &tray_data)) return;
    if (0 == Shell_NotifyIconA(.SETVERSION, &tray_data)) return;
    defer _ = Shell_NotifyIconA(.DELETE, &tray_data);

    if (!startThread()) return;

    var msg: MSG = undefined;
    while (GetMessageA(&msg, null, 0, 0) > 0) {
        msg.hWnd = msg.hWnd orelse hwndTray; // route thread messages to wndproc
        if (0 == IsDialogMessageA(hwndTray, &msg)) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageA(&msg);
        }
    }
}

fn trayProc(hwnd: win.HWND, uMsg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
    switch (uMsg) {
        else => {
            std.debug.print("unknown: {x}\n", .{uMsg});
            return 0;
        },
        0x0000 => { // WM_NULL
            std.debug.print("WM_NULL\n", .{});
        },
        0x0010 => { // WM_CLOSE
            _ = ShowWindowAsync(hwnd, 0); // hide to tray instead of quitting
        },
        0x0110 => { // WM_INITDIALOG
            std.debug.print("init\n", .{});
        },
        0x0111 => { // WM_COMMAND
            onWmCommand(hwnd, wParam, lParam);
        },
        WM_TRAY => {
            onWmTray(hwnd, wParam, lParam);
        },
        WM_RAW_STOPPED => {
            win.CloseHandle(raw_thread_handle.?);
            raw_thread_handle = null;
            std.debug.print("WM_RAW_STOPPED\n", .{});
            _ = Shell_NotifyIconA(.MODIFY, &.{
                .hWnd = hwnd,
                .uID = TRAY_UID,
                .uFlags = 0x84,
                .szTip = "LibreScroll - Inactive".* ++ .{0} ** (128 - 22),
            });
            if (GetDlgItem(hwnd, 104)) |hPause| {
                _ = SetWindowTextA(hPause, "Unpause");
                _ = SetWindowLongPtrA(hPause, -12, 105);
            }
            if (raw_thread_pending_restart) {
                raw_thread_pending_restart = false;
                _ = startThread(); // non-critical failure
            }
        },
        WM_RAW_STARTED => {
            std.debug.print("WM_RAW_STARTED\n", .{});
            _ = Shell_NotifyIconA(.MODIFY, &.{
                .hWnd = hwnd,
                .uID = TRAY_UID,
                .uFlags = 0x84,
                .szTip = "LibreScroll - Active".* ++ .{0} ** (128 - 20),
            });
            if (GetDlgItem(hwnd, 105)) |hUnpause| {
                _ = SetWindowTextA(hUnpause, "Pause");
                _ = SetWindowLongPtrA(hUnpause, -12, 104);
            }
        },
    }
    return 1;
}

fn onWmCommand(hwnd: win.HWND, wParam: usize, lParam: isize) void {
    const hCtrl: ?win.HWND = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const id = wParam & 0xFFFF;
    const uMsg = wParam >> 16;
    const is_accel = (null == hCtrl) and (1 == uMsg); _ = is_accel;
    std.debug.print("{x} ({x})\n", .{id, uMsg});
    switch (id) {
        else => {},
        100 => quit(),
        101 => config(),
        102 => about(hwnd),
        103 => elevate(),
        104 => if (raw_thread_handle) |_| {
            raw_thread_pending_restart = false;
            _ = PostThreadMessageA(raw_thread_id, 0x0012, 0, 0);
        },
        105, 106 => {
            if (106 == id) save(hwnd);
            if (raw_thread_handle) |_| {
                std.debug.print("restart\n", .{});
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
        unused: if (8 == @sizeOf(usize)) u32 else u0,
    } = @bitCast(lParam);
    const pos: packed struct(usize) {
        x: i16,
        y: i16,
        unused: if (8 == @sizeOf(usize)) u32 else u0,
    } = @bitCast(wParam);
    const msg = src.msg;
    const uid = src.uid;
    const x = pos.x;
    const y = pos.y;
    switch (msg) {
        0x007B => { // WM_CONTEXTMENU
            const tray_hmenu = LoadMenuA(null, "menu") orelse return;
            defer _ = DestroyMenu(tray_hmenu);
            const hMenu = GetSubMenu(tray_hmenu, IsUserAnAdmin() | @as(i32, if (raw_thread_handle) |_| 2 else 0)) orelse return;
            var rect: win.RECT = undefined;
            _ = Shell_NotifyIconGetRect(&.{ .hWnd = hwnd, .uID = uid }, &rect);
            std.debug.print("WM_CONTEXTMENU: {d},{d}\n", .{ x, y });
            _ = SetForegroundWindow(hwnd);
            _ = SetThreadDpiAwarenessContext(.PER_MONITOR_AWARE_V2);
            _ = TrackPopupMenu(hMenu, 0, x, y, 0, hwnd, null);
            _ = SetThreadDpiAwarenessContext(.NULL);
        },
        0x0400 => { // WM_USER
            var rect: win.RECT = undefined;
            _ = Shell_NotifyIconGetRect(&.{ .hWnd = hwnd, .uID = TRAY_UID }, &rect);
            const ctr_x, const ctr_y = .{
                @divTrunc(rect.left + rect.right, 2),
                @divTrunc(rect.top + rect.bottom, 2),
            };
            std.debug.print("WM_USER: {d},{d}\n", .{ ctr_x, ctr_y });
            _ = SetDlgItemInt(  hwnd, 0x4001, @bitCast(Shared.param.decay), 0 );
            _ = SetDlgItemInt(  hwnd, 0x4002, @bitCast(Shared.param.sensY), 1 );
            _ = SetDlgItemInt(  hwnd, 0x4003, @bitCast(Shared.param.sensX), 1 );
            _ = SetDlgItemInt(  hwnd, 0x4004, @bitCast(Shared.param.stepY), 0 );
            _ = SetDlgItemInt(  hwnd, 0x4005, @bitCast(Shared.param.stepX), 0 );
            _ = CheckDlgButton( hwnd, 0x4006, @bitCast(Shared.param.flick)    );
            _ = CheckDlgButton( hwnd, 0x4007, @bitCast(Shared.param.think)    );
            if (0 == IsWindowVisible(hwnd)) _ = ShowWindowAsync(hwnd, 5);
            _ = SetForegroundWindow(hwnd);
        },
        0x0200 => std.debug.print("WM_MOUSEMOVE\n", .{}),
        0x0201 => std.debug.print("WM_LBUTTONDOWN\n", .{}),
        0x0202 => std.debug.print("WM_LBUTTONUP\n", .{}),
        0x0203 => std.debug.print("WM_LBUTTONDBLCLICK\n", .{}),
        0x0204 => std.debug.print("WM_RBUTTONDOWN\n", .{}),
        0x0205 => std.debug.print("WM_RBUTTONUP\n", .{}),
        0x0206 => std.debug.print("WM_RBUTTONDBLCLICK\n", .{}),
        0x0207 => std.debug.print("WM_MBUTTONDOWN\n", .{}),
        0x0208 => std.debug.print("WM_MBUTTONUP\n", .{}),
        0x0209 => std.debug.print("WM_MBUTTONDBLCLICK\n", .{}),
        0x020A => std.debug.print("WM_MOUSEWHEEL\n", .{}),
        0x020B => std.debug.print("WM_XBUTTONDOWN\n", .{}),
        0x020C => std.debug.print("WM_XBUTTONUP\n", .{}),
        0x020D => std.debug.print("WM_XBUTTONDBLCLICK\n", .{}),
        0x020E => std.debug.print("WM_MOUSEHWHEEL\n", .{}),
        else => std.debug.print("Unknown: 0x{x}, 0x{x}\n", .{ msg, uid }),
    }
}

fn elevate() void {
    var buf: [32767:0]u8 = undefined;
    const len = GetModuleFileNameA(null, &buf, buf.len); // copied `len` characters plus zero sentinel at index `len`
    if (len == 0) return;
    if (len == buf.len and .SUCCESS != win.kernel32.GetLastError()) return;
    win.CloseHandle(process_mutex);
    _ = ShellExecuteA(null, "runas", &buf, null, null, 0);
    quit();
}

fn config() void {
    _ = PostThreadMessageA(win.GetCurrentThreadId(), WM_TRAY, 0, 0x0400);
}

fn about(hwnd: win.HWND) void {
    _ = MessageBoxA(hwnd, "Visit https://github.com/EsportToys/LibreScroll for more info.", "About LibreScroll " ++ LIBRE_SCROLL_VERSION_TEXT, 0);
}

fn quit() void {
    _ = PostQuitMessage(0);
}

fn save(hwnd: win.HWND) void {
    const ini = "./options.ini";
    const sec = "LibreScroll";

    var buf: [32767:0]u8 = undefined;

    _ = GetDlgItemTextA(hwnd, 0x4001, &buf, buf.len);
    _ = WritePrivateProfileStringA(sec, "decay", &buf, ini);

    _ = GetDlgItemTextA(hwnd, 0x4002, &buf, buf.len);
    _ = WritePrivateProfileStringA(sec, "sensY", &buf, ini);

    _ = GetDlgItemTextA(hwnd, 0x4003, &buf, buf.len);
    _ = WritePrivateProfileStringA(sec, "sensX", &buf, ini);

    _ = GetDlgItemTextA(hwnd, 0x4004, &buf, buf.len);
    _ = WritePrivateProfileStringA(sec, "stepY", &buf, ini);

    _ = GetDlgItemTextA(hwnd, 0x4005, &buf, buf.len);
    _ = WritePrivateProfileStringA(sec, "stepX", &buf, ini);

    _ = WritePrivateProfileStringA(sec, "flick", if (0 == IsDlgButtonChecked(hwnd, 0x4006)) "0" else "1", ini);

    _ = WritePrivateProfileStringA(sec, "think", if (0 == IsDlgButtonChecked(hwnd, 0x4007)) "0" else "1", ini);
}

fn load() [7]i32 {
    const ini = "./options.ini";
    const sec = "LibreScroll";
    return .{
        @max( 0 ,           GetPrivateProfileIntA(sec, "decay", 3, ini)   ),
                            GetPrivateProfileIntA(sec, "sensY", 9, ini)    ,
                            GetPrivateProfileIntA(sec, "sensX", 0, ini)    ,
        @max( 0 ,           GetPrivateProfileIntA(sec, "stepY", 1, ini)   ),
        @max( 0 ,           GetPrivateProfileIntA(sec, "stepX", 1, ini)   ),
        @max( 0 , @min( 1 , GetPrivateProfileIntA(sec, "flick", 0, ini) ) ),
        @max( 0 , @min( 1 , GetPrivateProfileIntA(sec, "think", 0, ini) ) ),
    };
}

fn startThread() bool {
    Shared.param.refresh();
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
    const hwnd = CreateWindowExA(
        0,
        "Message",
        null,
        0,
        0,
        0,
        0,
        0,
        @ptrFromInt(~@as(usize, 2)),
        null,
        null,
        null,
    ) orelse return 0;

    defer _ = DestroyWindow(hwnd);

    _ = SetWindowLongPtrA(hwnd, -4, @bitCast(@intFromPtr(&rawProc)));

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
        _ = DispatchMessageA(&msg);
        const now = win.QueryPerformanceCounter();
        const dt = now - past;
        if (dt * 1000 < qpf * Shared.ms) continue;
        past = now;
        simulation(dt, qpf);
    }

    return 0;
}

const Vec2f = @Vector(2, f32);
const Vec2i = @Vector(2, i32);
const Shared = extern struct {
    decay: i32 = 3,
    sensY: i32 = 9,
    sensX: i32 = 0,
    stepY: i32 = 1,
    stepX: i32 = 1,
    flick: i32 = 0,
    think: i32 = 0,
    fn refresh(this: *@This()) void {
        this.* = @bitCast(load());
    }
    const ms = 10;
    var param: @This() = .{};
    var vel: Vec2f = .{ 0, 0 };
    var acu: Vec2i = .{ 0, 0 };
    var rect: win.RECT = undefined;
    var is_scrolling = false;
    var cancel_pending = false;
};

fn rawProc(hwnd: win.HWND, uMsg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
    const timer = struct {
        var handle: usize = 0;
    };
    if (uMsg != 0xFF) return DefWindowProcA(hwnd, uMsg, wParam, lParam);
    var data: RAWINPUT.MOUSE = undefined;
    var size: u32 = @sizeOf(RAWINPUT.MOUSE);
    if (0 < GetRawInputData(lParam, 0x10000003, &data, &size, @sizeOf(RAWINPUT.HEADER))) {
        _ = data.header.hDevice orelse return 0;
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
            std.debug.print("m3 up\n", .{});
            if (0 == timer.handle) return 0;
        } else if (16 == 16 | flags) {
            if (timer.handle == 0) {
                timer.handle = SetCoalescableTimer(null, 0, Shared.ms, null, 0);
                if (timer.handle == 0) _ = PostThreadMessageA(win.GetCurrentThreadId(), 0x0012, 0, 0);
            }
            Shared.acu = .{ 0, 0 };
            Shared.vel = .{ 0, 0 };
            Shared.is_scrolling = true;
            Shared.cancel_pending = true;
            _ = GetCursorPos(@ptrCast(&Shared.rect));
            Shared.rect.right = Shared.rect.left + 1;
            Shared.rect.bottom = Shared.rect.top + 1;
            _ = ClipCursor(&Shared.rect);
            std.debug.print("m3 down\n", .{});
        } else if (Shared.param.flick != 0 and !Shared.is_scrolling) {
            Shared.vel = .{ 0, 0 }; // in flick mode, any mouse action besides the above should immediately halt
            const success = KillTimer(null, timer.handle);
            if (success != 0) timer.handle = 0;
        }
    }
    return 0;
}

fn simulation(tick: u64, freq: u64) void {
    if (Shared.is_scrolling) {
        var current_rect: win.RECT = undefined;
        _ = GetClipCursor(&current_rect);
        if (current_rect.left != Shared.rect.left or
            current_rect.right != Shared.rect.right or
            current_rect.top != Shared.rect.top or
            current_rect.bottom != Shared.rect.bottom) _ = ClipCursor(&Shared.rect);
        var delta: Vec2f = .{
            @floatFromInt(Shared.acu[0]),
            @floatFromInt(Shared.acu[1]),
        };
        delta *= .{ @floatFromInt(Shared.param.sensX), @floatFromInt(Shared.param.sensY) };
        Shared.vel += delta;
    } else if (Shared.param.flick == 0) {
        return;
    }
    defer Shared.acu = .{ 0, 0 };
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
        Shared.vel = .{ 0, 0 };
    }
    sendScroll(send);
}

fn sendScroll(delta: Vec2f) void {
    const static = struct {
        var res: Vec2f = .{ 0, 0 };
    };
    static.res += delta;
    const thresh: Vec2f = .{ @floatFromInt(Shared.param.stepX), @floatFromInt(Shared.param.stepY) };
    const batch = @trunc(static.res / thresh);
    var send: Vec2i = .{ 0, 0 };
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
        if (Shared.cancel_pending) {
            Shared.cancel_pending = false;
            _ = sendInputs(&.{
                .{
                    .type = 1,
                    .input = .{
                        .ki = .{
                            .dwFlags = 0,
                        },
                    },
                },
                .{
                    .type = 1,
                    .input = .{
                        .ki = .{
                            .dwFlags = 2,
                        },
                    },
                },
            });
        }
        scroll(send);
    }
}

fn scroll(send: [2]i32) void {
    const buf: [2]INPUT = .{
        .{
            .type = 0,
            .input = .{
                .mi = .{
                    .mouseData = -send[1],
                    .dwFlags = 0x0800,
                },
            },
        },
        .{
            .type = 0,
            .input = .{
                .mi = .{
                    .mouseData = send[0],
                    .dwFlags = 0x1000,
                },
            },
        },
    };
    if (send[1] != 0) {
        _ = sendInputs(if (send[0] != 0) &buf else buf[0..1]);
    } else if (send[0] != 0) {
        _ = sendInputs(buf[1..]);
    }
}

fn sendInputs(cmd: []const INPUT) u32 {
    return SendInput(@truncate(cmd.len), cmd.ptr, @sizeOf(INPUT));
}

extern "kernel32" fn CreateMutexA(?*const win.SECURITY_ATTRIBUTES, i32, [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleFileNameA(?*const anyopaque, [*]u8, u32) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetPrivateProfileIntA([*:0]const u8, [*:0]const u8, i32, [*:0]const u8) callconv(.winapi) i32;
extern "kernel32" fn WritePrivateProfileStringA([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.winapi) i32;

extern "user32" fn RegisterClassA(*const WNDCLASSA) callconv(.winapi) u16;
extern "user32" fn SetWindowLongPtrA(win.HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn SetWindowTextA(win.HWND, ?[*:0]const u8) callconv(.winapi) i32;
extern "user32" fn DefWindowProcA(win.HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn CreateWindowExA(u32, *const anyopaque, ?[*:0]const u8, u32, i32, i32, i32, i32, ?win.HWND, ?*const anyopaque, ?win.HINSTANCE, ?*const anyopaque) callconv(.winapi) ?win.HWND;
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
extern "user32" fn LoadIconA(?*const anyopaque, [*:0]const u8) callconv(.winapi) ?win.HICON;
extern "user32" fn LoadCursorA(?*const anyopaque, [*:0]const u8) callconv(.winapi) ?win.HCURSOR;
extern "user32" fn LoadMenuA(?*const anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyMenu(*const anyopaque) callconv(.winapi) i32;
extern "user32" fn TrackPopupMenu(*const anyopaque, u32, i32, i32, i32, ?win.HWND, ?*const [4]i32) callconv(.winapi) u32;
extern "user32" fn GetMessagePos() callconv(.winapi) u32;
extern "user32" fn SetForegroundWindow(win.HWND) callconv(.winapi) i32;
extern "user32" fn GetSubMenu(*const anyopaque, i32) callconv(.winapi) ?*anyopaque;
extern "user32" fn MessageBoxA(?win.HWND, ?[*:0]const u8, ?[*:0]const u8, u32) callconv(.winapi) i32;
extern "user32" fn SetTimer(?win.HWND, usize, u32, ?TIMERPROC) callconv(.winapi) usize;
extern "user32" fn SetCoalescableTimer(?win.HWND, usize, u32, ?TIMERPROC, u32) callconv(.winapi) usize;
extern "user32" fn KillTimer(?win.HWND, usize) callconv(.winapi) i32;
extern "user32" fn AdjustWindowRect(*win.RECT, u32, i32) callconv(.winapi) i32;
extern "user32" fn GetClipCursor(*win.RECT) callconv(.winapi) i32;
extern "user32" fn GetCursorPos(*win.POINT) callconv(.winapi) i32;
extern "user32" fn ClipCursor(?*const win.RECT) callconv(.winapi) i32;
extern "user32" fn GetDlgItem(?win.HWND, i32) callconv(.winapi) ?win.HWND;
extern "user32" fn IsDialogMessageA(win.HWND, *MSG) callconv(.winapi) i32;
extern "user32" fn CheckDlgButton(win.HWND, i32, u32) callconv(.winapi) i32;
extern "user32" fn IsDlgButtonChecked(win.HWND, i32) callconv(.winapi) u32;
extern "user32" fn GetDlgItemTextA(win.HWND, i32, [*:0]u8, i32) callconv(.winapi) u32;
extern "user32" fn GetDlgItemInt(win.HWND, i32, ?*i32, i32) callconv(.winapi) u32;
extern "user32" fn SetDlgItemInt(win.HWND, i32, u32, i32) callconv(.winapi) i32;
extern "user32" fn CreateDialogParamA(?*const anyopaque, [*:0]const u8, ?win.HWND, ?DLGPROC, isize) callconv(.winapi) ?win.HWND;
extern "user32" fn SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT) callconv(.winapi) DPI_AWARENESS_CONTEXT;

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
const WNDPROC = *const fn (win.HWND, u32, usize, isize) callconv(.winapi) isize;
const WNDCLASSA = extern struct {
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtr: i32 = 0,
    hInstance: ?win.HINSTANCE = null,
    hIcon: ?win.HICON = null,
    hCursor: ?win.HCURSOR = null,
    hbrBackground: ?win.HBRUSH = null,
    lpszMenuName: ?win.LPCSTR = null,
    lpszClassName: win.LPCSTR,
};

const MSG = extern struct {
    hWnd: ?win.HWND,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: extern struct {
        x: i32,
        y: i32,
    },
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
        mi: extern struct {
            dx: i32 = 0,
            dy: i32 = 0,
            mouseData: i32 = 0,
            dwFlags: u32 = 0,
            time: u32 = 0,
            dwExtraInfo: usize = 0,
        },
        ki: extern struct {
            wVK: u16 = 0,
            wScan: u16 = 0,
            dwFlags: u32 = 0,
            time: u32 = 0,
            dwExtraInfo: usize = 0,
        },
        hi: extern struct {
            uMsg: u32 = 0,
            wParamL: u16 = 0,
            wParamH: u16 = 0,
        },
    },
};

extern "shell32" fn IsUserAnAdmin() callconv(.winapi) i32;
extern "shell32" fn Shell_NotifyIconA(enum(u32) {
    ADD = 0,
    MODIFY = 1,
    DELETE = 2,
    SETFOCUS = 3,
    SETVERSION = 4,
}, *const NOTIFYICONDATAA) callconv(.winapi) i32;
extern "shell32" fn Shell_NotifyIconGetRect(*const NOTIFYICONIDENTIFIER, *win.RECT) callconv(.winapi) i32;
extern "shell32" fn ShellExecuteA(?win.HWND, ?[*:0]const u8, [*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, i32) callconv(.winapi) ?*anyopaque;

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
