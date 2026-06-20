const std = @import("std");
const event_loop = @import("event_loop");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = init.args.iterate();
    _ = args.next();
    const port_arg = args.next() orelse return error.MissingPort;
    const port = try std.fmt.parseInt(u16, port_arg, 10);

    var loop = try event_loop.EventLoop.init(alloc, port);
    defer loop.deinit();

    const thread = try std.Thread.spawn(.{}, event_loop.EventLoop.run, .{&loop});
    defer {
        loop.stop();
        thread.join();
    }

    const poll = loop.dequeue(alloc) orelse return error.NoRequest;
    defer alloc.free(poll);

    const sep = std.mem.indexOfScalar(u8, poll, 0x1e) orelse return error.BadPoll;
    const conn_id = try std.fmt.parseInt(u64, poll[0..sep], 10);
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
    if (!loop.respond(conn_id, response)) return error.Respond;

    const delay = std.posix.timespec{ .sec = 0, .nsec = 50_000_000 };
    switch (std.posix.errno(std.posix.system.nanosleep(&delay, null))) {
        .SUCCESS, .INTR => {},
        else => return error.Sleep,
    }
}
