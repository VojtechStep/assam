const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const DesktopFlare = enum {
    occupied,
    free,
    urgent,
};

pub const DesktopLayout = enum {
    tile,
    monocle,
};

pub const NodeLayout = enum {
    tile,
    pseudotile,
    float,
    fullscreen,
};

pub const NodeFlags = packed struct {
    sticky: u1,
    private: u1,
    locked: u1,
    marked: u1,
};

pub const Report = union(enum) {
    monitor: struct {
        name: []const u8,
        focused: bool,
    },
    desktop: struct {
        name: []const u8,
        focused: bool,
        flare: DesktopFlare,
    },
    desktop_layout: DesktopLayout,
    node_layout: NodeLayout,
    node_flags: NodeFlags,

    const Self = @This();

    pub const ParseError = error{
        UnknownDesktopLayout,
        UnknownNodeLayout,
        UnknownReportType,
        UnknownNodeFlag,
    };

    pub fn deinit(self: *Self, allocator: *Allocator) void {
        switch (self.*) {
            .monitor => |m| {
                allocator.free(m.name);
            },
            .desktop => |d| {
                allocator.free(d.name);
            },
            else => {},
        }
    }

    pub fn parse(allocator: *Allocator, str: []const u8) (ParseError || Allocator.Error)!Report {
        if (str.len < 1) {
            return error.UnknownReportType;
        }

        return switch (str[0]) {
            'M', 'm' => Report{
                .monitor = .{
                    .name = try allocator.dupe(u8, str[1..]),
                    .focused = str[0] == 'M',
                },
            },
            'O', 'o', 'F', 'f', 'U', 'u' => Report{
                .desktop = .{
                    .name = try allocator.dupe(u8, str[1..]),
                    .focused = std.ascii.isUpper(str[0]),
                    .flare = switch (std.ascii.toLower(str[0])) {
                        'o' => .occupied,
                        'f' => .free,
                        'u' => .urgent,
                        else => unreachable,
                    },
                },
            },
            'L' => Report{
                .desktop_layout = switch (str[1]) {
                    'T' => .tile,
                    'M' => .monocle,
                    else => return error.UnknownDesktopLayout,
                },
            },
            'T' => Report{
                .node_layout = switch (str[1]) {
                    'T' => .tile,
                    'P' => .pseudotile,
                    'F' => .float,
                    '=' => .fullscreen,
                    else => return error.UnknownNodeLayout,
                },
            },
            'G' => rep: {
                var flags = mem.zeroes(NodeFlags);
                for (str[1..]) |flag| {
                    switch (flag) {
                        'S' => {
                            flags.sticky = 1;
                        },
                        'P' => {
                            flags.private = 1;
                        },
                        'L' => {
                            flags.locked = 1;
                        },
                        'M' => {
                            flags.marked = 1;
                        },
                        else => return error.UnknownNodeFlag,
                    }
                }
                break :rep Report{
                    .node_flags = flags,
                };
            },
            else => error.UnknownReportType,
        };
    }

    pub fn parse_report(allocator: *Allocator, report: []const u8) !std.ArrayList(Report) {
        var list = std.ArrayList(Report).init(allocator);

        errdefer list.deinit();
        if (report.len < 1 or report[0] != 'W') {
            return list;
        }

        var it = mem.tokenize(report[1..], ":");

        while (it.next()) |part| {
            if (Report.parse(allocator, part)) |rep| {
                try list.append(rep);
            } else |err| {
                std.log.debug("Error parsing report part: {}", .{err});
            }
        }

        return list;
    }
};
