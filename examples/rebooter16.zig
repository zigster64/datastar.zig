const std = @import("std");
const Io = std.Io;

pub fn start(io: Io, gpa: std.mem.Allocator) !void {
    _ = try io.concurrent(watchLoop, .{ io, gpa });
}

fn watchLoop(io: Io, gpa: std.mem.Allocator) !void {
    const cwd = std.fs.cwd();

    var initial_inode: u64 = 0;
    var initial_mtime: Io.Timestamp = .zero;
    const path = try std.fs.selfExePathAlloc(gpa);
    defer gpa.free(path);

    // wait around till the inital inode is available
    while (true) {
        const stat = cwd.statFile(path) catch {
            try io.sleep(.fromSeconds(2), .real);
            continue;
        };
        initial_inode = stat.inode;
        initial_mtime = stat.mtime;
        break;
    }

    while (true) {
        try io.sleep(.fromSeconds(2), .real);

        const stat = cwd.statFile(path) catch |err| {
            std.debug.print("Path {s} failed to stat(): {}\n", .{ path, err });
            continue;
        };

        const inode_changed = (stat.inode != initial_inode);
        const mtime_changed = (stat.mtime.toMilliseconds() > initial_mtime.toMilliseconds());

        if (inode_changed or mtime_changed) {
            std.debug.print("Binary Changed - Reboot ♻️\n", .{});

            const args = try std.process.argsAlloc(gpa);
            const self_path = try std.fs.selfExePathAlloc(gpa);

            var exec_args: std.ArrayList([]const u8) = .empty;
            try exec_args.append(gpa, self_path);

            for (args[1..]) |arg| {
                try exec_args.append(gpa, arg);
            }

            return std.process.execv(gpa, exec_args.items);
        }
    }
}
