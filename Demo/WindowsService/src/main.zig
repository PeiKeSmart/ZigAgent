const std = @import("std");
const windows = @import("std").os.windows;

const ServiceStatus = struct {
    dwServiceType: u32,
    dwCurrentState: u32,
    dwControlsAccepted: u32,
    dwWin32ExitCode: u32,
    dwServiceSpecificExitCode: u32,
    dwCheckPoint: u32,
    dwWaitHint: u32,
};

var serviceStatus: ServiceStatus = undefined;
var hStatus: windows.Handle = windows.INVALID_HANDLE_VALUE;

fn serviceMain(argc: c_int, argv: [*][*]const u8) void {
    hStatus = windows.RegisterServiceCtrlHandlerA("MyService", controlHandler);
    if (hStatus == windows.INVALID_HANDLE_VALUE) {
        return;
    }

    serviceStatus = ServiceStatus{
        .dwServiceType = windows.SERVICE_WIN32_OWN_PROCESS,
        .dwCurrentState = windows.SERVICE_START_PENDING,
        .dwControlsAccepted = windows.SERVICE_ACCEPT_STOP | windows.SERVICE_ACCEPT_SHUTDOWN,
        .dwWin32ExitCode = 0,
        .dwServiceSpecificExitCode = 0,
        .dwCheckPoint = 0,
        .dwWaitHint = 0,
    };

    if (initService()) {
        serviceStatus.dwCurrentState = windows.SERVICE_RUNNING;
        windows.SetServiceStatus(hStatus, &serviceStatus);
    } else {
        serviceStatus.dwCurrentState = windows.SERVICE_STOPPED;
        windows.SetServiceStatus(hStatus, &serviceStatus);
        return;
    }

    while (serviceStatus.dwCurrentState == windows.SERVICE_RUNNING) {
        // 模拟一些工作，通过睡眠来模拟
        windows.Sleep(3000);
    }
}

pub fn main() anyerror!void {
    const serviceMainPtr: windows.SERVICE_MAIN_FUNCTION = serviceMain;
    const serviceTable: [2]windows.SERVICE_TABLE_ENTRY = [_]windows.SERVICE_TABLE_ENTRY{
        windows.SERVICE_TABLE_ENTRY{
            .lpServiceName = "MyService",
            .lpServiceProc = serviceMainPtr,
        },
        windows.SERVICE_TABLE_ENTRY{
            .lpServiceName = null,
            .lpServiceProc = null,
        },
    };

    if (!windows.StartServiceCtrlDispatcher(&serviceTable)) {
        std.debug.print("Error: {}\n", .{windows.GetLastError()});
    }
}

fn controlHandler(request: u32) void {
    switch (request) {
        windows.SERVICE_CONTROL_STOP, windows.SERVICE_CONTROL_SHUTDOWN => {
            serviceStatus.dwCurrentState = windows.SERVICE_STOPPED;
            windows.SetServiceStatus(hStatus, &serviceStatus);
            return;
        },
        else => {},
    }

    windows.SetServiceStatus(hStatus, &serviceStatus);
}

fn initService() bool {
    // 服务的初始化代码
    return true; // 返回 true 表示成功
}
