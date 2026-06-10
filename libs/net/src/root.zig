// libs/net/src/root.zig
// SPDX-License-Identifier: MIT
const std = @import("std");
const ffi = @import("gawk_ffi");
const event_loop = @import("event_loop");

var _loop: ?*event_loop.EventLoop = null;
var _loop_thread: ?std.Thread = null;
const _loop_alloc = std.heap.c_allocator;

const _ffi_entry = ffi.makeDlLoad(.{
    .name = "hawk_net",
    .functions = &.{
        .{ .name = "hawk_net_listen",  .impl = &netListen,  .args = 1 },
        .{ .name = "hawk_net_poll",    .impl = &netPoll,    .args = 0 },
        .{ .name = "hawk_net_respond", .impl = &netRespond, .args = 4 },
    },
});
comptime {
    _ = _ffi_entry;
}

fn netListen(args: ffi.Args) ffi.Result {
    if (_loop != null) return .{ .int = 1 }; // idempotent
    const port_val = args.getInt(0);
    if (port_val <= 0 or port_val > 65535) return .{ .int = 0 };
    const port: u16 = @intCast(port_val);

    const loop = _loop_alloc.create(event_loop.EventLoop) catch return .{ .int = 0 };
    loop.* = event_loop.EventLoop.init(_loop_alloc, port) catch {
        _loop_alloc.destroy(loop);
        return .{ .int = 0 };
    };
    _loop = loop;

    _loop_thread = std.Thread.spawn(.{}, event_loop.EventLoop.run, .{loop}) catch {
        loop.deinit();
        _loop_alloc.destroy(loop);
        _loop = null;
        return .{ .int = 0 };
    };

    return .{ .int = 1 };
}

fn netPoll(_: ffi.Args) ffi.Result {
    const loop = _loop orelse return .none;
    const result = loop.dequeue(ffi.gawkAllocator()) orelse return .none;
    return .{ .string = result };
}

fn netRespond(args: ffi.Args) ffi.Result {
    const loop = _loop orelse return .{ .int = 0 };
    const conn_id_str = args.getString(0);
    const status_line = args.getString(1);
    const headers = args.getString(2);
    const body = args.getString(3);

    const conn_id = std.fmt.parseInt(u64, conn_id_str, 10) catch return .{ .int = 0 };

    const data = std.fmt.allocPrint(_loop_alloc, "{s}\r\n{s}\r\n{s}", .{
        status_line, headers, body,
    }) catch return .{ .int = 0 };
    defer _loop_alloc.free(data);

    return .{ .int = if (loop.respond(conn_id, data)) 1 else 0 };
}
