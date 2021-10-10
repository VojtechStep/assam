const std = @import("std");
const loop = @import("loop.zig");
const bspwm = @import("bspwm.zig");
const os = std.os;
const Allocator = std.mem.Allocator;

const BLUE = "#81a2be";
const GRAY = "#464c51";

const Children = enum {
    xtitle,
    bspc,
    date,
    battery,
};

const MonitorId = u8;

const Monitor = struct {
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    id: MonitorId,
};

const MonitorData = struct {
    // Own
    desktops: std.ArrayList(Desktop),
    // Own
    focused_title: []const u8,
};

const Desktop = struct {
    focused: bool = false,
    empty: bool = false,
    // Own
    name: []const u8,
};

const SystemState = struct {
    // Monitor name -> Monitor
    // Own
    monitor_map: std.StringHashMap(Monitor),
    // Monitor id -> Monitor data
    // Own
    monitor_data_map: std.AutoHashMap(MonitorId, MonitorData),
    last_monitor: u8 = 0,
    // Own
    date: ?[]const u8 = null,
    // Own
    battery: ?[]const u8 = null,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: *Allocator) void {
        {
            var it = self.monitor_map.iterator();
            while (it.next()) |pair| {
                allocator.free(pair.key_ptr.*);
            }
            self.monitor_map.deinit();
        }

        {
            var it = self.monitor_data_map.iterator();
            while (it.next()) |pair| {
                allocator.free(pair.value_ptr.focused_title);
                for (pair.value_ptr.desktops.items) |d| {
                    allocator.free(d.name);
                }
                pair.value_ptr.desktops.deinit();
            }
            self.monitor_data_map.deinit();
        }

        if (self.date) |d| {
            allocator.free(d);
        }
    }

    pub fn ensure_monitor_data(self: *Self, monitor: MonitorId, allocator: *Allocator) !*MonitorData {
        var data_result = try self.monitor_data_map.getOrPut(monitor);
        if (!data_result.found_existing) {
            data_result.value_ptr.* = .{
                .desktops = std.ArrayList(Desktop).init(allocator),
                .focused_title = try allocator.alloc(u8, 0),
            };
        }
        return data_result.value_ptr;
    }

    pub fn format(self: *Self, buf_writer: anytype) !void {
        const writer = buf_writer.writer();

        try writer.writeAll("%{U" ++ BLUE ++ "}");

        var it = self.monitor_map.iterator();

        // Print text on all monitors
        while (it.next()) |pair| {
            try writer.print("%{{S{}}}%{{l}} {s} ", .{ pair.value_ptr.id, pair.key_ptr.* });

            const is_selected = pair.value_ptr.id == self.last_monitor;

            if (self.monitor_data_map.get(pair.value_ptr.id)) |data| {
                for (data.desktops.items) |desk| {
                    if (desk.focused) {
                        if (is_selected) {
                            try writer.writeAll("%{F" ++ BLUE ++ "}%{R}");
                        } else {
                            try writer.writeAll("%{+u}");
                        }
                    }
                    defer if (desk.focused) {
                        if (is_selected) {
                            writer.writeAll("%{R}%{F-}") catch {};
                        } else {
                            writer.writeAll("%{-u}") catch {};
                        }
                    };
                    if (!desk.empty) {
                        try writer.writeAll(" %{+o}");
                    } else {
                        try writer.writeByte(' ');
                    }
                    defer if (!desk.empty) {
                        writer.writeAll("%{-o} ") catch {};
                    } else {
                        writer.writeByte(' ') catch {};
                    };
                    var correct_name = desk.name[0..];
                    if (std.mem.indexOfScalar(u8, correct_name, '_')) |i| {
                        correct_name = correct_name[i + 1 ..];
                    }
                    try writer.print("{s}", .{correct_name});
                }
                if (is_selected) {
                    try writer.print(" %{{F" ++ BLUE ++ "}}%{{R}} {s} %{{R}}%{{F-}}", .{data.focused_title});
                } else {
                    try writer.print(" %{{B" ++ GRAY ++ "}} {s} ", .{data.focused_title});
                }
            }

            try writer.writeAll("%{r}%{B-}");

            if (self.battery) |b| {
                try writer.writeAll(b);
                try writer.writeAll("% ");
            }

            if (self.date) |d| {
                try writer.writeAll(d);
                try writer.writeByte(' ');
            }
        }

        try writer.writeByte('\n');
        try buf_writer.flush();
    }
};

fn monitor_lessthan(context: void, lhs: Monitor, rhs: Monitor) bool {
    if (lhs.x < rhs.x or lhs.y + lhs.height <= rhs.y) {
        return true;
    }
    return false;
}

pub fn main() anyerror!void {
    std.io.getStdErr().close();
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 10,
    }){};
    defer _ = gpa.deinit();
    var allocator = &gpa.allocator;

    var state = st: {
        // Seed the monitor state. Replicate the sorting logic of lemonbar
        var monitor_seed_proc = try std.ChildProcess.exec(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "sh",
                "-c",
                \\ xrandr --query | \
                \\ rg "^([^ ]+) connected [^\d]*(\d+)x(\d+)\+(\d+)\+(\d+)" \
                \\ -or "\$1 \$2 \$3 \$4 \$5" --color=never
            },
        });
        defer allocator.free(monitor_seed_proc.stderr);
        defer allocator.free(monitor_seed_proc.stdout);
        std.log.debug("Seed exited with {}", .{monitor_seed_proc.term});

        // Temp variables, contain borrowed references
        var monitor_list = std.ArrayList(Monitor).init(allocator);
        defer monitor_list.deinit();
        var monitor_name_list = std.ArrayList([]const u8).init(allocator);
        defer monitor_name_list.deinit();

        // Get the data as lists
        var stdout_it = std.mem.tokenize(monitor_seed_proc.stdout, "\n ");
        var monitor_id: u8 = 0;
        while (stdout_it.next()) |mon_name| {
            const w = try std.fmt.parseInt(u32, stdout_it.next().?, 10);
            const h = try std.fmt.parseInt(u32, stdout_it.next().?, 10);
            const x = try std.fmt.parseInt(u32, stdout_it.next().?, 10);
            const y = try std.fmt.parseInt(u32, stdout_it.next().?, 10);
            try monitor_list.append(.{
                .width = w,
                .height = h,
                .x = x,
                .y = y,
                .id = monitor_id,
            });

            try monitor_name_list.append(mon_name);
            monitor_id += 1;
        }

        // Sort the rectangles
        std.sort.sort(
            Monitor,
            monitor_list.items,
            {},
            monitor_lessthan,
        );

        // Owns keys
        var monitor_map = std.StringHashMap(Monitor).init(allocator);
        errdefer {
            var err_mon_it = monitor_map.iterator();
            while (err_mon_it.next()) |pair| {
                allocator.free(pair.key_ptr.*);
            }
            monitor_map.deinit();
        }

        // Assign correct ids
        for (monitor_list.items) |*val, new_id| {
            // Get name by the old id
            const monitor_name = try allocator.dupe(u8, monitor_name_list.items[val.id]);
            // Assign new id
            val.id = @truncate(u8, new_id);
            try monitor_map.putNoClobber(monitor_name, val.*);
        }

        break :st SystemState{
            .monitor_map = monitor_map,
            .monitor_data_map = std.AutoHashMap(MonitorId, MonitorData).init(allocator),
        };
    };

    defer state.deinit(allocator);

    var el = try loop.Loop(Children).init(allocator);
    defer el.deinit();
    try el.queueStdoutOfChild(
        .xtitle,
        &[_][]const u8{ "xtitle", "-s", "-t", "500" },
    );
    try el.queueStdoutOfChild(
        .bspc,
        &[_][]const u8{ "bspc", "subscribe", "report" },
    );
    try el.queueStdoutOfChild(
        .date,
        &[_][]const u8{
            "sh",
            "-c",
            \\while :
            \\  do date "+%a, %b %d %H:%M"
            \\  sleep 30
            \\done
        },
    );
    try el.queueStdoutOfChild(.battery, &[_][]const u8{
        "sh",
        "-c",
        \\while :
        \\ do cat /sys/class/power_supply/*/capacity
        \\ sleep 30
        \\done
    });

    try el.spawn();

    {
        var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
        var iter = try el.lines();
        defer iter.deinit();

        while (iter.next()) |*msg| {
            defer msg.line.deinit();

            switch (msg.tag) {
                .xtitle => {
                    // parse xtitle
                    var data = try state.ensure_monitor_data(state.last_monitor, allocator);
                    allocator.free(data.focused_title);
                    data.focused_title = msg.line.toOwnedSlice();
                },
                .bspc => {
                    // parse bspc
                    // std.log.debug("WM update: {}", .{line});
                    const report = bspwm.Report.parse_report(allocator, msg.line.items) catch continue;
                    var last_seen_monitor = state.last_monitor;
                    defer report.deinit();
                    for (report.items) |*part| {
                        switch (part.*) {
                            .monitor => |m| {
                                defer part.deinit(allocator);
                                const id = state.monitor_map.get(m.name).?.id;
                                var data = state.ensure_monitor_data(id, allocator);
                                last_seen_monitor = id;
                                if (m.focused) {
                                    state.last_monitor = id;
                                }
                            },
                            .desktop => |d| {
                                var data = try state.ensure_monitor_data(last_seen_monitor, allocator);
                                var desktop = desk: {
                                    for (data.desktops.items) |*desk, i| {
                                        if (std.mem.eql(u8, desk.name, d.name)) {
                                            part.deinit(allocator);
                                            break :desk desk;
                                        }
                                    }
                                    try data.desktops.append(.{
                                        .name = d.name,
                                    });
                                    break :desk &data.desktops.items[data.desktops.items.len - 1];
                                };
                                desktop.focused = d.focused;
                                desktop.empty = d.flare == .free;
                            },
                            else => {
                                part.deinit(allocator);
                            },
                        }
                    }
                },
                .date => {
                    if (state.date) |d| {
                        allocator.free(d);
                    }
                    state.date = msg.line.toOwnedSlice();
                    // std.log.debug("Time: {}", .{msg.line.items});
                },
                .battery => {
                    if (state.battery) |b| {
                        allocator.free(b);
                    }
                    state.battery = msg.line.toOwnedSlice();
                },
            }
            try state.format(&stdout);
        } else |err| {
            std.log.debug("Loop exited: {}", .{err});
        }
    }
}
