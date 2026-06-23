// SPDX-License-Identifier: MIT
const std = @import("std");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

fn usage() noreturn {
    std.debug.print("usage: hawk-socket-owner <port> <cmd> [args...]\n", .{});
    std.process.exit(2);
}

fn clearCloseOnExec(fd: std.posix.socket_t) !void {
    const flags_rc = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
    if (std.posix.errno(flags_rc) != .SUCCESS) return error.Fcntl;
    const flags: usize = @intCast(flags_rc);
    const next_flags = flags & ~@as(usize, std.posix.FD_CLOEXEC);
    if (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, next_flags)) != .SUCCESS) return error.Fcntl;
}

fn createSocket(port: u16) !std.posix.socket_t {
    const fd = blk: {
        const fd_rc = std.posix.system.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM,
            std.posix.IPPROTO.TCP,
        );
        if (std.posix.errno(fd_rc) != .SUCCESS) return error.SocketCreate;
        break :blk @as(std.posix.socket_t, @intCast(fd_rc));
    };
    errdefer _ = std.posix.system.close(fd);

    const reuse: c_int = 1;
    if (std.posix.errno(std.posix.system.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.REUSEADDR,
        @ptrCast(&reuse),
        @sizeOf(c_int),
    )) != .SUCCESS) return error.SetSockOptReuseAddr;

    try clearCloseOnExec(fd);

    const addr = std.posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
    };
    const bind_rc = std.posix.system.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
    if (std.posix.errno(bind_rc) != .SUCCESS) return error.Bind;

    const listen_rc = std.posix.system.listen(fd, 128);
    if (std.posix.errno(listen_rc) != .SUCCESS) return error.Listen;

    return fd;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    if (args.len < 3) usage();

    const port_str = std.mem.sliceTo(args[1], 0);
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const fd = try createSocket(port);
    errdefer _ = std.posix.system.close(fd);

    var fd_buf: [32]u8 = undefined;
    const fd_str = try std.fmt.bufPrintZ(&fd_buf, "{}", .{fd});
    if (setenv("HAWK_LISTEN_FD", fd_str.ptr, 1) != 0) return error.SetEnv;

    // args.vector.ptr[args.len] == null (C argv sentinel); safe cast for execvp
    _ = execvp(args[2], @ptrCast(args[2..].ptr));
    return error.Exec;
}
