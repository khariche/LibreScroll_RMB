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

    if (SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT.UNAWARE_GDISCALED) == DPI_AWARENESS_CONTEXT.NULL) return;

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
    
    _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT.PER_MONITOR_AWARE_V2);
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
    
    if (SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT.PER_MONITOR_AWARE_V2) == DPI_AWARENESS_CONTEXT.NULL) return 0;
    const HWND_MESSAGE: HWND = @ptrFromInt(~@as(usize, 2));
    const hwnd = CreateWindowExA(0, "Message", null, 0, 0, 0, 0, 0, HWND_MESSAGE, null, null, null) orelse return 0;
    defer _ = DestroyWindow(hwnd);

    const dev_active = [1]RAWINPUTDEVICE{.{
        .usUsagePage = 0x01,
        .usUsage = 0x02,
        .dwFlags = 0x100,
        .hwndTarget = hwnd,
    }};
    if (0 == RegisterRawInputDevices(&dev_active, 1, @sizeOf(RAWINPUTDEVICE))) return 0;

    const dev_inactive = [1]RAWINPUTDEVICE{.{
        .usUsagePage = 0x01,
        .usUsage = 0x02,
        .dwFlags = 0x1,
        .hwndTarget = null,
    }};
    defer _ = RegisterRawInputDevices(&dev_inactive, 1, @sizeOf(RAWINPUTDEVICE));

    var hook_active = false;
    var hook_thread_id: u32 = undefined;
    const hook_thread_handle = CreateThread(
        null,
        0,
        &hookMain,
        null,
        0,
        &hook_thread_id,
    ) orelse return 0;
    _ = SetThreadPriority(hook_thread_handle, 15);
    defer _ = CloseHandle(hook_thread_handle);
    defer _ = PostThreadMessageA(hook_thread_id, 0x0012, 0, 0);

    _ = PostThreadMessageA(main_thread_id, WM_RAW_STARTED, 0, 0);

    const interval_ms = 10;
    var qpf: u64 = undefined;
    var now: u64 = undefined;
    var past: u64 = undefined;
    _ = QueryPerformanceFrequency(@ptrCast(&qpf));
    _ = QueryPerformanceCounter(@ptrCast(&past));

    var size: u32 = @sizeOf(RAWINPUT.MOUSE);
    var data: RAWINPUT.MOUSE = undefined;
    var state: State = .{};
    var timer: usize = 0;
    var scroll_acu: Vec2i = @splat(0);
    var msg: MSG = undefined;

    var did_move = false;

    while (GetMessageA(&msg, null, 0, 0) > 0) {
        defer _ = DispatchMessageA(&msg);
        if (!hook_active) {
            if (msg.message == WM_HOOK_STARTED) hook_active = true;
            continue;
        }
        if (msg.message == 0xff
            and GetRawInputData(msg.lParam, 0x10000003, &data, &size, @sizeOf(RAWINPUT.HEADER)) > 0) _: {
            const flags = data.data.usButtonFlags;
            if (null == data.header.hDevice) {
                if (8 == 8 & flags) {
                    _ = ClipCursor(null);
                }
                break :_;
            }
            if (flags == 0) {
                scroll_acu += .{ data.data.lLastX, data.data.lLastY };
                if (state.is_scrolling) {
                    did_move = true;
                }
            } else if (8 == 8 & flags) {
                if (global_config.flick == 0) {
                    if (0 != KillTimer(null, timer)) timer = 0;
                }
                state.scroll_pending = false;
                state.is_scrolling = false;
                _ = ClipCursor(null);

                if (!did_move) {
                    _ = INPUT.send(&.{
                        INPUT.mi(.{ .dwFlags = 0x0008, .dwExtraInfo = @bitCast(MAGIC_WORD) }),
                        INPUT.mi(.{ .dwFlags = 0x0010, .dwExtraInfo = @bitCast(MAGIC_WORD) }),
                    });
                }
            } else if (4 == 4 & flags) {
                did_move = false;
                if (timer == 0) {
                    timer = SetTimer(null, 0, interval_ms, null);
                    if (timer == 0) break;
                }
                scroll_acu = @splat(0);
                state.vel = @splat(0);
                state.is_scrolling = true;
                state.scroll_pending = true;
                _ = GetCursorPos(&state.rect);
                state.rect[2] = state.rect[0] + 1;
                state.rect[3] = state.rect[1] + 1;
                _ = ClipCursor(&state.rect);
            } else if (global_config.flick != 0 and !state.is_scrolling) {
                state.vel = @splat(0);
                if (0 != KillTimer(null, timer)) timer = 0;
            }
        }
        _ = QueryPerformanceCounter(@ptrCast(&now));
        const dt = now - past;
        if (dt * 1000 > qpf * interval_ms) {
            if (state.step(scroll_acu, dt, qpf)) |send| state.flush(send);
            scroll_acu = @splat(0);
            past = now;
        }
    }
    return 0;
}

const State = struct {
    vel: Vec2f = @splat(0),
    res: Vec2f = @splat(0),
    rect: [4]i32 = undefined,
    is_scrolling: bool = false,
    scroll_pending: bool = false,

    fn step(state: *State, acu: Vec2i, tick: u64, freq: u64) ?Vec2f {
        if (state.is_scrolling) {
            var current_rect: [4]i32 = undefined;
            _ = GetClipCursor(&current_rect);
            if (current_rect[0] != state.rect[0] or
                current_rect[1] != state.rect[1] or
                current_rect[2] != state.rect[2] or
                current_rect[3] != state.rect[3]) _ = ClipCursor(&state.rect);
            var delta: Vec2f = .{
                @floatFromInt(global_config.sensX),
                @floatFromInt(global_config.sensY),
            };
            delta *= @floatFromInt(acu);
            state.vel += delta;
        } else if (global_config.flick == 0) {
            return null;
        }
        var dt: f32 = @floatFromInt(tick);
        dt /= @floatFromInt(freq);
        const mu: f32 = @floatFromInt(global_config.decay);
        const f0 = @exp(-dt * mu);
        const f1 = (1 - f0) / mu;
        var send = state.vel;
        send *= @splat(f1);
        state.vel *= @splat(f0);
        if (@reduce(.Add, state.vel * state.vel) < 1) {
            state.vel /= @splat(mu);
            send += state.vel;
            state.vel = @splat(0);
        }
        return send;
    }

    fn flush(state: *State, delta: Vec2f) void {
        state.res += delta;
        const thresh: Vec2f = .{ @floatFromInt(global_config.stepX), @floatFromInt(global_config.stepY) };
        const batch = thresh * @trunc(state.res / thresh);
        var send: Vec2i = @intFromFloat(batch);
        state.res -= batch;
        if (global_config.think != 0) {
            if (@abs(send[0]) > @abs(send[1])) {
                send[1] = 0;
                state.res[1] = 0;
            } else {
                send[0] = 0;
                state.res[0] = 0;
            }
        }
        if (0 == send[0] and 0 == send[1]) return;
        const buf: [2]INPUT = .{
            INPUT.mi(.{ .mouseData = -send[1], .dwFlags = 0x0800 }),
            INPUT.mi(.{ .mouseData =  send[0], .dwFlags = 0x1000 }),
        };
        state.scroll_pending = false;
        if (send[1] != 0) {
            _ = INPUT.send(buf[0..if (send[0] != 0) 2 else 1]);
        } else if (send[0] != 0) {
            _ = INPUT.send(buf[1..]);
        }
    }
};

extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*const SECURITY_ATTRIBUTES, bInitialOwner: i32, lpName: [*:0]const u8) callconv(.C) ?*anyopaque;
extern "kernel32" fn GetModuleFileNameA(hModule: ?HMODULE, lpFilename: [*]u8, nSize: u32) callconv(.C) u32;
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.C) ?HMODULE;
extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.C) i32;
extern "kernel32" fn GetPrivateProfileIntA(lpAppName: [*:0]const u8, lpKeyName: [*:0]const u8, nDefault: i32, lpFileName: [*:0]const u8) callconv(.C) i32;
extern "kernel32" fn WritePrivateProfileStringA(lpAppName: [*:0]const u8, lpKeyName: [*:0]const u8, lpString: [*:0]const u8, lpFileName: [*:0]const u8) callconv(.C) i32;
extern "kernel32" fn SetThreadPriority(hThread: *const anyopaque, nPriority: i32) callconv(.C) i32;
extern "kernel32" fn CreateThread(lpThreadAttributes: ?*const SECURITY_ATTRIBUTES, dwStackSize: usize, lpStartAddress: THREADPROC, lpParameter: ?*anyopaque, dwCreationFlags: u32, lpThreadId: ?*u32) callconv(.C) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.C) u32;
extern "kernel32" fn GetCurrentThreadId() callconv(.C) u32;
extern "kernel32" fn CloseHandle(hObject: *const anyopaque) callconv(.C) i32;
extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.C) i32;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.C) i32;

extern "user32" fn GetWindowLongPtrA(hWnd: HWND, nIndex: i32) callconv(.C) isize;
extern "user32" fn SetWindowLongPtrA(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.C) isize;
extern "user32" fn SetWindowLongA(hWnd: HWND, nIndex: i32, dwNewLong: i32) callconv(.C) i32;
extern "user32" fn SetWindowTextA(hWnd: HWND, lpString: ?[*:0]const u8) callconv(.C) i32;
extern "user32" fn CreateWindowExA(dwExStyle: u32, lpClassName: ?[*:0]const u8, lpWindowName: ?[*:0]const u8, dwStyle: u32, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?HMENU, hInstance: ?HMODULE, lpParam: ?*anyopaque) callconv(.C) ?HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.C) i32;
extern "user32" fn ShowWindowAsync(hWnd: HWND, nCmdShow: i32) callconv(.C) i32;
extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.C) i32;
extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.C) void;
extern "user32" fn PostThreadMessageA(idThread: u32, Msg: u32, wParam: usize, lParam: isize) callconv(.C) i32;
extern "user32" fn SendMessageA(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.C) i32;
extern "user32" fn GetMessageA(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.C) i32;
extern "user32" fn DispatchMessageA(lpMsg: *const MSG) callconv(.C) isize;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.C) i32;
extern "user32" fn RegisterRawInputDevices(pRawInputDevices: [*]const RAWINPUTDEVICE, uiNumDevices: u32, cbSize: u32) i32;
extern "user32" fn GetRawInputData(hRawInput: isize, uiCommand: u32, pData: ?*anyopaque, pcbSize: *u32, cbSizeHeader: u32) callconv(.C) i32;
extern "user32" fn SendInput(cInputs: u32, pInputs: [*]const INPUT, cbSize: i32) callconv(.C) u32;
extern "user32" fn LoadIconA(hInstance: ?HMODULE, lpIconName: [*:0]const u8) callconv(.C) ?HICON;
extern "user32" fn LoadMenuA(hInstance: ?HMODULE, lpMenuName: [*:0]const u8) callconv(.C) ?HMENU;
extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.C) i32;
extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: u32, x: i32, y: i32, nReserved: i32, hWnd: ?HWND, prcRect: ?*const [4]i32) callconv(.C) u32;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.C) i32;
extern "user32" fn GetSubMenu(hMenu: HMENU, nPos: i32) callconv(.C) ?HMENU;
extern "user32" fn MessageBoxA(hWnd: ?HWND, lpText: ?[*:0]const u8, lpCaption: ?[*:0]const u8, uType: u32) callconv(.C) i32;
extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: u32, lpTimerFunc: ?TIMERPROC) callconv(.C) usize;
extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.C) i32;
extern "user32" fn GetClipCursor(lprc: *[4]i32) callconv(.C) i32;
extern "user32" fn GetCursorPos(lpPoint: *[4]i32) callconv(.C) i32;
extern "user32" fn ClipCursor(lprc: ?*const [4]i32) callconv(.C) i32;
extern "user32" fn SetThreadDpiAwarenessContext(dpiContext: DPI_AWARENESS_CONTEXT) callconv(.C) DPI_AWARENESS_CONTEXT;
extern "user32" fn CreateDialogParamA(hInstance: ?HMODULE, lpTemplateName: [*:0]const u8, hWndParent: ?HWND, lpDialogFunc: ?DLGPROC, dwInitParam: isize) callconv(.C) ?HWND;
extern "user32" fn GetDlgItem(hDlg: ?HWND, nIDDlgItem: i32) callconv(.C) ?HWND;
extern "user32" fn SetDlgItemInt(hDlg: HWND, nIDDlgItem: i32, uValue: u32, bSigned: i32) callconv(.C) i32;
extern "user32" fn GetDlgItemInt(hDlg: HWND, nIDDlgItem: i32, lpTranslated: ?*i32, bSigned: i32) callconv(.C) u32;
extern "user32" fn GetDlgItemTextA(hDlg: HWND, nIDDlgItem: i32, lpString: [*:0]u8, cchMax: i32) callconv(.C) u32;
extern "user32" fn IsDialogMessageA(hDlg: HWND, lpMsg: *MSG) callconv(.C) i32;
extern "user32" fn IsDlgButtonChecked(hDlg: HWND, nIDButton: i32) callconv(.C) u32;
extern "user32" fn CheckDlgButton(hDlg: HWND, nIDButton: i32, uCheck: u32) callconv(.C) i32;
extern "user32" fn SetWindowsHookExA(idHook: i32, lpfn: HOOKPROC, hmod: ?HMODULE, dwThreadId: u32) callconv(.C) ?HHOOK;
extern "user32" fn UnhookWindowsHookEx(hhk: HHOOK) callconv(.C) i32;
extern "user32" fn CallNextHookEx(hhk: ?HHOOK, nCode: i32, wParam: usize, lParam: isize) callconv(.C) isize;
extern "user32" fn CallWindowProcA(lpPrevWndFunc: WNDPROC, hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.C) isize;

const DPI_AWARENESS_CONTEXT = enum(isize) {
    NULL = 0,
    UNAWARE = -1,
    SYSTEM_AWARE = -2,
    PER_MONITOR_AWARE = -3,
    PER_MONITOR_AWARE_V2 = -4,
    UNAWARE_GDISCALED = -5,
};

const WNDPROC = *const fn (hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.C) isize;
const DLGPROC = *const fn (hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.C) isize;
const HOOKPROC = *const fn (nCode: i32, wParam: usize, lParam: isize) callconv(.C) isize;
const TIMERPROC = *const fn (hWnd: ?HWND, uMsg: u32, idEvent: usize, dwTime: u32) callconv(.C) void;
const THREADPROC = *const fn (lpParameter: *anyopaque) callconv(.C) u32;

const HHOOK = *const opaque{};
const MSLLHOOKSTRUCT = extern struct {
    pt: [2]i32,
    mouseData: u32,
    flags: u32,
    time: u32,
    dwExtraInfo: usize,
};

const MSG = extern struct {
    hWnd: ?HWND,
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
    hwndTarget: ?HWND,
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
    fn mi(m: MOUSEINPUT)    INPUT { return .{ .type = 0, .input = .{.mi = m} }; }
    fn ki(k: KEYBDINPUT)    INPUT { return .{ .type = 1, .input = .{.ki = k} }; }
    fn hi(h: HARDWAREINPUT) INPUT { return .{ .type = 2, .input = .{.hi = h} }; }
    fn send(inputs: []const INPUT) u32 {
        return SendInput(@truncate(inputs.len), inputs.ptr, @sizeOf(INPUT));
    }
};

extern "shell32" fn IsUserAnAdmin() callconv(.C) i32;
extern "shell32" fn ShellExecuteA(hwnd: ?HWND, lpOperation: ?[*:0]const u8, lpFile: [*:0]const u8, lpParameters: ?[*:0]const u8, lpDirectory: ?[*:0]const u8, nShowCmd: i32) callconv(.C) ?HMODULE;
extern "shell32" fn Shell_NotifyIconGetRect(identifier: *const NOTIFYICONIDENTIFIER, iconLocation: *[4]i32) callconv(.C) i32;
extern "shell32" fn Shell_NotifyIconA(dwMessage: NIM, lpData: *const NOTIFYICONDATAA) callconv(.C) i32;
const NIM = enum(u32) {
    ADD = 0,
    MODIFY = 1,
    DELETE = 2,
    SETFOCUS = 3,
    SETVERSION = 4,
};

const NOTIFYICONDATAA = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONDATAA),
    hWnd: ?HWND = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0,
    hIcon: ?HICON = null,
    szTip: [128]u8 = undefined,
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    szInfo: [256]u8 = undefined,
    uTimeout: u32 = 0,
    szInfoTitle: [64]u8 = undefined,
    dwInfoFlags: u32 = 0,
    guidItem: GUID = @bitCast(@as(u128, 0)),
    hBalloonIcon: ?HICON = null,
};

const NOTIFYICONIDENTIFIER = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONIDENTIFIER),
    hWnd: HWND,
    uID: u32,
    guidItem: GUID = @bitCast(@as(u128, 0)),
};

const HWND = *const opaque{};
const HMENU = *const opaque{};
const HICON = *const opaque{};
const HMODULE = *const opaque{};
const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: i32,
};
const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};
