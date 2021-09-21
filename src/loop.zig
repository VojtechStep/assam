const std = @import("std");
const os = std.os;

pub fn Loop(comptime Tags: anytype) type {
    return struct {
        efd: i32,
        sfd: os.fd_t,
        allocator: *std.mem.Allocator,
        process_queue: QueueType,
        process_map: MapType,

        const Self = @This();
        const Entry = struct {
            tag: Tags,
            process: *std.ChildProcess,
        };
        const QueueType = std.ArrayList(Entry);
        const MapType = std.AutoHashMap(std.os.fd_t, Entry);

        pub const ReadError = os.ReadError;
        pub const Reader = std.io.Reader(*Self, ReadError, read);

        pub fn init(allocator: *std.mem.Allocator) !Self {
            const efd = try os.epoll_create1(os.EPOLL_CLOEXEC);
            errdefer os.close(efd);

            var sigset = os.empty_sigset;
            os.linux.sigaddset(&sigset, os.SIGINT);
            os.linux.sigaddset(&sigset, os.SIGQUIT);
            _ = os.linux.sigprocmask(os.SIG_BLOCK, &sigset, null);
            const sfd = try os.signalfd(-1, &sigset, 0);

            var quit_event = os.epoll_event{
                .events = os.EPOLL_CTL_ADD,
                .data = .{ .fd = sfd },
            };
            try os.epoll_ctl(efd, os.EPOLL_CTL_ADD, sfd, &quit_event);

            return Self{
                .efd = efd,
                .sfd = sfd,
                .allocator = allocator,
                .process_queue = QueueType.init(allocator),
                .process_map = MapType.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.process_queue.items) |p| {
                p.process.deinit();
            }
            self.process_queue.deinit();

            var it = self.process_map.iterator();
            while (it.next()) |e| {
                const r = e.value_ptr.process.kill() catch @panic("Error killing process");
                // std.log.debug("Kill status: {}", .{r});
                e.value_ptr.process.deinit();
            }
            self.process_map.deinit();
            os.close(self.efd);
        }

        pub fn queueStdoutOfChild(self: *Self, comptime tag: Tags, exec: []const []const u8) !void {
            var process = try std.ChildProcess.init(
                exec,
                self.allocator,
            );
            errdefer process.deinit();
            process.stdin_behavior = .Close;
            process.stderr_behavior = .Close;
            process.stdout_behavior = .Pipe;

            try self.process_queue.append(Entry{
                .tag = tag,
                .process = process,
            });
        }

        pub fn spawn(self: *Self) !void {
            if (self.process_queue.items.len == 0) return;

            var backup_queue = QueueType.init(self.allocator);
            defer backup_queue.deinit();

            var p = self.process_queue.pop();
            while (true) : (p = self.process_queue.pop()) {
                self.trySpawnEntry(p) catch |err| {
                    backup_queue.append(p) catch @panic("Could not backup child");
                };
                if (self.process_queue.items.len == 0) break;
            }

            for (backup_queue.items) |b| {
                self.process_queue.append(b) catch @panic("Could not requeue child");
            }
        }

        fn trySpawnEntry(self: *Self, entry: Entry) !void {
            try entry.process.spawn();
            errdefer _ = entry.process.kill() catch @panic("Could not kill child");
            const fd = entry.process.stdout.?.handle;

            try self.process_map.putNoClobber(fd, entry);
            errdefer _ = self.process_map.fetchRemove(fd) orelse unreachable;

            var add_event = os.epoll_event{
                .events = os.EPOLLIN,
                .data = .{ .fd = fd },
            };
            try os.epoll_ctl(self.efd, os.EPOLL_CTL_ADD, fd, &add_event);
        }

        pub fn lines(self: *Self) !LineIterator(Tags) {
            return LineIterator(Tags){
                .context = self,
                .event_buffer = try self.allocator.alloc(os.epoll_event, self.process_map.count()),
                .pending_buffers = LineIterator(Tags).Pending.init(self.allocator),
            };
        }
    };
}

pub fn LineIterator(Tags: anytype) type {
    return struct {
        context: *Loop(Tags),
        event_buffer: []os.epoll_event,
        pending_buffers: Pending,

        const Self = @This();
        const Pending = std.ArrayList(Entry);
        const Entry = struct {
            tag: Tags, line: std.ArrayList(u8)
        };

        pub fn deinit(self: *Self) void {
            for (self.pending_buffers.items) |pb| {
                pb.line.deinit();
            }
            self.pending_buffers.deinit();
            self.context.allocator.free(self.event_buffer);
        }

        pub const IterError = error{
            Quit,
            Empty,
        };

        pub fn next(self: *Self) IterError!Entry {
            if (self.pending_buffers.items.len == 0) {
                const nfds = os.epoll_wait(self.context.efd, self.event_buffer, -1);

                for (self.event_buffer[0..nfds]) |e| {
                    if (e.data.fd == self.context.sfd) {
                        return error.Quit;
                    }
                    var process_entry = self.context.process_map.get(e.data.fd) orelse @panic("Unregistered file descriptor");
                    var file = process_entry.process.stdout.?;
                    var buffer = std.ArrayList(u8).init(self.context.allocator);
                    var reader = std.io.bufferedReader(file.reader()).reader();
                    reader.readUntilDelimiterArrayList(&buffer, '\n', 512) catch |err| switch (err) {
                        error.EndOfStream => {
                            if (buffer.items.len == 0) {
                                buffer.deinit();
                                continue;
                            }
                        },
                        else => {
                            std.log.crit("Could not read from file: {}", .{err});
                            buffer.deinit();
                            @panic("Could not read from file");
                        },
                    };
                    self.pending_buffers.append(Entry{
                        .line = buffer,
                        .tag = process_entry.tag,
                    }) catch @panic("Could not queue buffer");
                }
            }

            if (self.pending_buffers.items.len > 0) {
                return self.pending_buffers.pop();
            }

            return error.Empty;
        }
    };
}
