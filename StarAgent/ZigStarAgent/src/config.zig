/// config.zig — StarAgent XML 配置文件加载与保存
///
/// 对应配置文件: StarAgent.xml
/// 格式与 NewLife Stardust StarAgent 保持一致。
///
/// 使用 zzig.xml DOM + Writer 模块：
///   - 加载：xml.Dom.parseFile  → DOM → Config 结构体
///   - 保存：xml.createAnyWriter → 带注释的格式化 XML
///
/// 内存策略：
///   ConfigResult 内部持有一个 ArenaAllocator，所有配置字符串（包括 DOM）
///   均由该 arena 统一管理，调用方只需在使用完后调用 result.deinit()。
const std = @import("std");
const zzig = @import("zzig");
const xml = zzig.xml;

// ─── 数据结构 ─────────────────────────────────────────────────────────────────

/// 单个托管应用服务信息（对应 XML 中的 <ServiceInfo> 元素属性）
pub const ServiceInfo = struct {
    /// 服务名称（唯一标识）
    name: []const u8 = "",
    /// 可执行文件名或 .zip 包名
    file_name: []const u8 = "",
    /// 启动参数
    arguments: []const u8 = "",
    /// 工作目录（相对或绝对路径；空=可执行文件所在目录）
    working_directory: []const u8 = "",
    /// 运行用户名（空=继承父进程）
    user_name: []const u8 = "",
    /// 是否启用
    enable: bool = false,
    /// 运行模式（Default / ...）
    mode: []const u8 = "Default",
    /// 环境变量（key=value,key2=val2 格式）
    environments: []const u8 = "",
    /// 进程退出后是否自动停止代理对该进程的管理
    auto_stop: bool = false,
    /// 文件变化时是否自动重载进程
    reload_on_change: bool = false,
    /// 最大内存限制（MB；0=不限）
    max_memory: u64 = 0,
    /// 进程优先级
    priority: []const u8 = "Normal",
};

/// StarAgent 运行时配置（完整字段集）
pub const Config = struct {
    /// 调试模式开关
    debug: bool = true,
    /// 星尘证书编码
    code: []const u8 = "",
    /// 密钥
    secret: []const u8 = "",
    /// 所属项目名（新节点默认加入的项目）
    project: []const u8 = "",
    /// 本地监听端口
    local_port: u16 = 5500,
    /// 更新通道（Release / Beta / ...）
    channel: []const u8 = "Release",
    /// 是否使用 Windows 自动启动（false=使用系统服务）
    use_autorun: bool = false,
    /// 登录用户名（用户模式存储，服务模式读取）
    user_name: []const u8 = "root",
    /// DPI 信息，如 "96*96"（用户模式存储，服务模式读取）
    dpi: []const u8 = "",
    /// 分辨率，如 "1024*768"（用户模式存储，服务模式读取）
    resolution: []const u8 = "",
    /// 重启进程或服务的延迟（ms）
    delay: u32 = 3000,
    /// 同步服务器时间间隔（秒；0=不同步）
    sync_time: u32 = 0,
    /// 启动钩子（对 dotNet 应用注入星尘监控钩子）
    startup_hook: bool = false,
    /// 托管应用服务列表
    services: []const ServiceInfo = &.{},
};

/// 配置加载结果（携带内存所有权）
///
/// 所有配置字符串由内部 arena 管理，调用方须在使用完毕后调用 deinit()。
pub const ConfigResult = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,

    pub fn deinit(self: *ConfigResult) void {
        self.arena.deinit();
    }
};

// ─── 加载 ──────────────────────────────────────────────────────────────────────

/// 从 XML 文件加载 StarAgent 配置。
///
/// - 若文件不存在或解析失败，返回全默认值的 ConfigResult。
/// - 所有配置字符串由 ConfigResult 内部 arena 统一管理。
///
/// 调用方：
/// ```zig
/// var result = try config.load(allocator, "StarAgent.xml");
/// defer result.deinit();
/// const cfg = result.config;
/// ```
pub fn load(gpa: std.mem.Allocator, path: []const u8) !ConfigResult {
    // result_arena 持有全部配置字符串的生命周期
    var result_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer result_arena.deinit();
    const alloc = result_arena.allocator();

    // DOM 解析使用独立的临时 arena，解析完成后整体释放
    var dom_arena = std.heap.ArenaAllocator.init(gpa);
    defer dom_arena.deinit();

    var doc = xml.Dom.parseFile(dom_arena.allocator(), path) catch |err| {
        std.log.warn("[config] 读取配置文件 '{s}' 失败: {} — 使用默认值", .{ path, err });
        return ConfigResult{
            .arena = result_arena,
            .config = Config{},
        };
    };
    defer doc.deinit();

    const root = doc.root;

    // ── services 解析 ──────────────────────────────────────────────────────────
    var services_list: std.ArrayList(ServiceInfo) = .{};
    defer services_list.deinit(alloc);

    if (root.child("Services")) |svc_elem| {
        const infos = svc_elem.childrenNamed("ServiceInfo", dom_arena.allocator()) catch &[_]*xml.Dom.Element{};
        defer dom_arena.allocator().free(infos);

        for (infos) |svc| {
            const info = ServiceInfo{
                .name = dupeAttr(alloc, svc, "Name"),
                .file_name = dupeAttr(alloc, svc, "FileName"),
                .arguments = dupeAttr(alloc, svc, "Arguments"),
                .working_directory = dupeAttr(alloc, svc, "WorkingDirectory"),
                .user_name = dupeAttr(alloc, svc, "UserName"),
                .enable = parseBoolAttr(svc, "Enable", false),
                .mode = dupeAttr(alloc, svc, "Mode"),
                .environments = dupeAttr(alloc, svc, "Environments"),
                .auto_stop = parseBoolAttr(svc, "AutoStop", false),
                .reload_on_change = parseBoolAttr(svc, "ReloadOnChange", false),
                .max_memory = parseU64Attr(svc, "MaxMemory", 0),
                .priority = dupeAttr(alloc, svc, "Priority"),
            };
            services_list.append(alloc, info) catch {};
        }
    }

    const services_slice: []const ServiceInfo = services_list.toOwnedSlice(alloc) catch &[_]ServiceInfo{};

    // ── 主配置字段解析 ──────────────────────────────────────────────────────────
    const cfg = Config{
        .debug = parseTextBool(alloc, root, "Debug", true),
        .code = parseTextDupe(alloc, root, "Code", ""),
        .secret = parseTextDupe(alloc, root, "Secret", ""),
        .project = parseTextDupe(alloc, root, "Project", ""),
        .local_port = parseTextU16(alloc, root, "LocalPort", 5500),
        .channel = parseTextDupe(alloc, root, "Channel", "Release"),
        .use_autorun = parseTextBool(alloc, root, "UseAutorun", false),
        .user_name = parseTextDupe(alloc, root, "UserName", "root"),
        .dpi = parseTextDupe(alloc, root, "Dpi", ""),
        .resolution = parseTextDupe(alloc, root, "Resolution", ""),
        .delay = parseTextU32(alloc, root, "Delay", 3000),
        .sync_time = parseTextU32(alloc, root, "SyncTime", 0),
        .startup_hook = parseTextBool(alloc, root, "StartupHook", false),
        .services = services_slice,
    };

    std.log.info("[config] 已加载配置文件 '{s}'，服务数: {d}", .{ path, cfg.services.len });

    return ConfigResult{
        .arena = result_arena,
        .config = cfg,
    };
}

// ─── 保存 ──────────────────────────────────────────────────────────────────────

/// 将配置保存到 XML 文件（带中文注释，格式化缩进）。
///
/// 若目标文件不存在则创建；已存在则覆盖。
pub fn save(cfg: *const Config, gpa: std.mem.Allocator, path: []const u8) !void {
    // 先序列化到内存 buffer，再整体写盘（与 zzig dom.zig 内部策略保持一致）
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(gpa);

    var w = xml.createAnyWriter(gpa, buf.writer(gpa).any(), .{ .indent = "  " });
    defer w.deinit();

    // 数字转字符串临时缓冲区（栈上，避免分配）
    var num_buf: [32]u8 = undefined;

    try w.xmlDeclaration("UTF-8", null);
    try w.elementStart("StarAgent");

    // ── 简单文本字段 ────────────────────────────────────────────────────────────
    try writeTextBool(&w, "Debug", "调试开关。默认true", cfg.debug);
    try writeTextStr(&w, "Code", "证书", cfg.code);
    try writeTextStr(&w, "Secret", "密钥", cfg.secret);
    try writeTextStr(&w, "Project", "项目名。新节点默认所需要加入的项目", cfg.project);

    const port_str = std.fmt.bufPrint(&num_buf, "{d}", .{cfg.local_port}) catch "5500";
    try writeTextStr(&w, "LocalPort", "本地端口。默认5500", port_str);

    try writeTextStr(&w, "Channel", "更新通道。默认Release", cfg.channel);
    try writeTextBool(&w, "UseAutorun", "Windows自启动。自启动需要用户登录桌面，默认false使用系统服务", cfg.use_autorun);
    try writeTextStr(&w, "UserName", "用户名称。用户模式存储，服务模式读取", cfg.user_name);
    try writeTextStr(&w, "Dpi", "像素点。例如96*96。用户模式存储，服务模式读取", cfg.dpi);
    try writeTextStr(&w, "Resolution", "分辨率。例如1024*768。用户模式存储，服务模式读取", cfg.resolution);

    const delay_str = std.fmt.bufPrint(&num_buf, "{d}", .{cfg.delay}) catch "3000";
    try writeTextStr(&w, "Delay", "延迟时间。重启进程或服务的延迟时间，默认3000ms", delay_str);

    const sync_str = std.fmt.bufPrint(&num_buf, "{d}", .{cfg.sync_time}) catch "0";
    try writeTextStr(&w, "SyncTime", "同步时间间隔。定期同步服务器时间到本地，默认0秒不同步", sync_str);

    try writeTextBool(&w, "StartupHook", "启动挂钩。拉起目标进程时，对dotNet应用注入星尘监控钩子，默认false", cfg.startup_hook);

    // ── <Services> ─────────────────────────────────────────────────────────────
    try w.comment("应用服务集合");
    try w.elementStart("Services");

    for (cfg.services) |svc| {
        try w.elementStart("ServiceInfo");
        try w.attribute("Name", svc.name);
        try w.attribute("FileName", svc.file_name);
        try w.attribute("Arguments", svc.arguments);
        try w.attribute("WorkingDirectory", svc.working_directory);
        try w.attribute("UserName", svc.user_name);
        try w.attribute("Enable", boolStr(svc.enable));
        try w.attribute("Mode", svc.mode);
        try w.attribute("Environments", svc.environments);
        try w.attribute("AutoStop", boolStr(svc.auto_stop));
        try w.attribute("ReloadOnChange", boolStr(svc.reload_on_change));
        const mem_str = std.fmt.bufPrint(&num_buf, "{d}", .{svc.max_memory}) catch "0";
        try w.attribute("MaxMemory", mem_str);
        try w.attribute("Priority", svc.priority);
        try w.elementEnd(); // ServiceInfo（无子节点→自闭合）
    }

    try w.elementEnd(); // Services
    try w.elementEnd(); // StarAgent
    try w.eof();

    // 整体写入磁盘
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(buf.items);

    std.log.info("[config] 配置已保存到 '{s}'", .{path});
}

/// 若 XML 文件不存在则以默认配置创建，否则跳过（保留现有配置）。
pub fn ensureDefault(gpa: std.mem.Allocator, path: []const u8) !void {
    // O_CREAT + O_EXCL：仅在不存在时创建，已存在则返回 error.PathAlreadyExists
    std.fs.cwd().access(path, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        // 文件不存在，写出默认配置
        const default_cfg = Config{
            .services = defaultServices(),
        };
        try save(&default_cfg, gpa, path);
        std.log.info("[config] 已生成默认配置文件 '{s}'", .{path});
    };
}

// ─── 内部辅助 ─────────────────────────────────────────────────────────────────

/// 默认服务示例（仅在首次生成配置时填充）
fn defaultServices() []const ServiceInfo {
    // 静态生命周期的示例列表；实际运行时应从文件读取
    return &[_]ServiceInfo{
        .{
            .name = "test",
            .file_name = "ping",
            .arguments = "newlifex.com",
            .enable = false,
        },
    };
}

/// 从元素文本子节点解析字符串，复制到 arena；失败或空则返回 default
fn parseTextDupe(
    alloc: std.mem.Allocator,
    elem: *const xml.Dom.Element,
    tag: []const u8,
    default: []const u8,
) []const u8 {
    const child = elem.child(tag) orelse return default;
    const t = child.innerText(alloc) catch return default;
    if (t.len == 0) {
        alloc.free(t);
        return default;
    }
    return t;
}

/// 从元素文本子节点解析 bool
fn parseTextBool(
    alloc: std.mem.Allocator,
    elem: *const xml.Dom.Element,
    tag: []const u8,
    default: bool,
) bool {
    const child = elem.child(tag) orelse return default;
    const t = child.innerText(alloc) catch return default;
    defer alloc.free(t);
    return std.mem.eql(u8, t, "true");
}

/// 从元素文本子节点解析 u16
fn parseTextU16(
    alloc: std.mem.Allocator,
    elem: *const xml.Dom.Element,
    tag: []const u8,
    default: u16,
) u16 {
    const child = elem.child(tag) orelse return default;
    const t = child.innerText(alloc) catch return default;
    defer alloc.free(t);
    return std.fmt.parseInt(u16, std.mem.trim(u8, t, " \t\r\n"), 10) catch default;
}

/// 从元素文本子节点解析 u32
fn parseTextU32(
    alloc: std.mem.Allocator,
    elem: *const xml.Dom.Element,
    tag: []const u8,
    default: u32,
) u32 {
    const child = elem.child(tag) orelse return default;
    const t = child.innerText(alloc) catch return default;
    defer alloc.free(t);
    return std.fmt.parseInt(u32, std.mem.trim(u8, t, " \t\r\n"), 10) catch default;
}

/// 从元素属性解析字符串，复制到 arena；属性不存在则返回空切片
fn dupeAttr(
    alloc: std.mem.Allocator,
    elem: *const xml.Dom.Element,
    attr_name: []const u8,
) []const u8 {
    const val = elem.attr(attr_name) orelse return "";
    return alloc.dupe(u8, val) catch "";
}

/// 从元素属性解析 bool；属性不存在则返回 default
fn parseBoolAttr(
    elem: *const xml.Dom.Element,
    attr_name: []const u8,
    default: bool,
) bool {
    const val = elem.attr(attr_name) orelse return default;
    return std.mem.eql(u8, val, "true");
}

/// 从元素属性解析 u64；属性不存在或解析失败则返回 default
fn parseU64Attr(
    elem: *const xml.Dom.Element,
    attr_name: []const u8,
    default: u64,
) u64 {
    const val = elem.attr(attr_name) orelse return default;
    return std.fmt.parseInt(u64, val, 10) catch default;
}

/// 写入带注释的文本子元素（bool 版）
fn writeTextBool(w: anytype, tag: []const u8, comment_text: []const u8, value: bool) !void {
    try w.comment(comment_text);
    try w.elementStart(tag);
    try w.text(boolStr(value));
    try w.elementEnd();
}

/// 写入带注释的文本子元素（字符串版）
fn writeTextStr(w: anytype, tag: []const u8, comment_text: []const u8, value: []const u8) !void {
    try w.comment(comment_text);
    try w.elementStart(tag);
    if (value.len > 0) try w.text(value);
    try w.elementEnd();
}

/// bool → XML 文本
inline fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}
