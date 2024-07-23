// TODO: this type has an InvalidHandleValue of '0', what can Zig do with this information?
pub const SERVICE_STATUS_HANDLE = isize;

pub const LPHANDLER_FUNCTION = *const fn (
    dwControl: u32,
) callconv(@import("std").os.windows.WINAPI) void;

pub const LPHANDLER_FUNCTION_EX = *const fn (
    dwControl: u32,
    dwEventType: u32,
    lpEventData: ?*anyopaque,
    lpContext: ?*anyopaque,
) callconv(@import("std").os.windows.WINAPI) u32;

pub const LPSERVICE_MAIN_FUNCTIONA = *const fn (
    dwNumServicesArgs: u32,
    lpServiceArgVectors: ?*?PSTR,
) callconv(@import("std").os.windows.WINAPI) void;

pub const SERVICE_TABLE_ENTRYA = extern struct {
    lpServiceName: ?PSTR,
    lpServiceProc: ?LPSERVICE_MAIN_FUNCTIONA,
};

// TODO: this type is limited to platform 'windows5.1.2600'
pub extern "advapi32" fn RegisterServiceCtrlHandlerExW(
    lpServiceName: ?[*:0]const u16,
    lpHandlerProc: ?LPHANDLER_FUNCTION_EX,
    lpContext: ?*anyopaque,
) callconv(@import("std").os.windows.WINAPI) SERVICE_STATUS_HANDLE;

// TODO: this type is limited to platform 'windows5.1.2600'
pub extern "advapi32" fn RegisterServiceCtrlHandlerA(
    lpServiceName: ?[*:0]const u8,
    lpHandlerProc: ?LPHANDLER_FUNCTION,
) callconv(@import("std").os.windows.WINAPI) SERVICE_STATUS_HANDLE;

const thismodule = @This();
pub usingnamespace switch (@import("../zig.zig").unicode_mode) {
    .ansi => struct {
        pub const RegisterServiceCtrlHandler = thismodule.RegisterServiceCtrlHandlerA;
    },
    .wide => struct {},
    .unspecified => struct {},
};

const PSTR = @import("../foundation.zig").PSTR;
