const std = @import("std");
const logz = @import("logz");

pub fn start(gpa: std.mem.Allocator) !void {
    const thread = try std.Thread.spawn(.{}, watchLoop, .{gpa});
    thread.detach();
}

fn watchLoop(gpa: std.mem.Allocator) !void {
    const cwd = std.fs.cwd();

    var initial_inode: u64 = 0;
    var initial_mtime: i128 = 0;
    const path = try std.fs.selfExePathAlloc(gpa);
    defer gpa.free(path);

    // wait around till the inital inode is available
    while (true) {
        const stat = cwd.statFile(path) catch {
            std.Thread.sleep(2 * std.time.ns_per_s);
            continue;
        };
        initial_inode = stat.inode;
        initial_mtime = stat.mtime;
        break;
    }

    while (true) {
        std.Thread.sleep(2 * std.time.ns_per_s);

        const stat = cwd.statFile(path) catch |err| {
            logz.err()
                .string("path", path)
                .string("state", "Failed to stat()")
                .err(err)
                .log();
            continue;
        };

        const inode_changed = (stat.inode != initial_inode);
        const mtime_changed = (stat.mtime > initial_mtime);

        if (inode_changed or mtime_changed) {
            logz.info()
                .string("EXIT", "binary changed")
                .string("ACTION", "reboot ♻️")
                .int("INODE", stat.inode)
                .int("MTIME", stat.mtime)
                .log();

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
