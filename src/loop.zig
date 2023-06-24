const std = @import("std");
const os = std.os;

pub fn Loop(comptime Tags: anytype) type {
    return struct {
        efd: i32,
        sfd: os.fd_t,
        allocator: std.mem.Allocator,
        process_queue: QueueType,
        process_map: MapType,

        const Self = @This();
        const Entry = struct {
            tag: Tags,
            process: std.ChildProcess,
        };
        const QueueType = std.ArrayList(Entry);
        const MapType = std.AutoHashMap(os.fd_t, Entry);

        pub fn init(allocator: std.mem.Allocator) !Self {
            const efd = try os.epoll_create1(os.system.EPOLL.CLOEXEC);
            errdefer os.close(efd);

            var sigset = os.empty_sigset;
            os.linux.sigaddset(&sigset, os.system.SIG.INT);
            os.linux.sigaddset(&sigset, os.system.SIG.QUIT);
            _ = os.linux.sigprocmask(os.system.SIG.BLOCK, &sigset, null);
            const sfd = try os.signalfd(-1, &sigset, 0);

            var quit_event = os.system.epoll_event{
                .events = os.system.EPOLL.CTL_ADD,
                .data = .{ .fd = sfd },
            };
            try os.epoll_ctl(efd, os.system.EPOLL.CTL_ADD, sfd, &quit_event);

            return Self{
                .efd = efd,
                .sfd = sfd,
                .allocator = allocator,
                .process_queue = QueueType.init(allocator),
                .process_map = MapType.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.process_queue.deinit();

            var it = self.process_map.iterator();
            while (it.next()) |e| {
                const r = e.value_ptr.process.kill() catch |kill_error| {
                    switch (kill_error) {
                        error.FileNotFound => {
                            std.log.warn("Could not find executable {}", .{e.value_ptr.tag});
                        },
                        else => {
                            std.log.err("Kill error: {} {}", .{ e.value_ptr.tag, kill_error });
                            @panic("Error killing process");
                        },
                    }
                    continue;
                };
                std.log.debug("Kill status: {}", .{r});
            }
            self.process_map.deinit();
            os.close(self.efd);
        }

        pub fn queueStdoutOfChild(self: *Self, comptime tag: Tags, exec: []const []const u8) !void {
            var process = std.ChildProcess.init(
                exec,
                self.allocator,
            );
            process.stdin_behavior = .Close;
            process.stderr_behavior = .Close;
            process.stdout_behavior = .Pipe;

            try self.process_queue.append(Entry{
                .tag = tag,
                .process = process,
            });
        }

        pub fn spawn(self: *Self) !usize {
            if (self.process_queue.items.len == 0) return 0;

            // Reserve enough memory to hold all the processes,
            // in both successful and unsuccessful versions
            try self.process_map.ensureUnusedCapacity(@truncate(u32, self.process_queue.items.len));
            var backup_queue = try QueueType.initCapacity(self.allocator, self.process_queue.items.len);
            defer backup_queue.deinit();

            var p = self.process_queue.popOrNull();
            while (p != null) : (p = self.process_queue.popOrNull()) {
                if (p) |*process| {
                    const stdoutFd = self.trySpawnEntry(process) catch {
                        backup_queue.appendAssumeCapacity(process.*);
                        continue;
                    };
                    self.process_map.putAssumeCapacityNoClobber(stdoutFd, process.*);
                } else unreachable;
            }

            for (backup_queue.items) |b| {
                self.process_queue.appendAssumeCapacity(b);
            }

            return self.process_queue.items.len;
        }

        fn trySpawnEntry(self: *Self, entry: *Entry) !os.fd_t {
            try entry.process.spawn();
            errdefer _ = entry.process.kill() catch @panic("Could not kill child");
            const fd = entry.process.stdout.?.handle;

            var add_event = os.system.epoll_event{
                .events = os.system.EPOLL.IN,
                .data = .{ .fd = fd },
            };
            try os.epoll_ctl(self.efd, os.system.EPOLL.CTL_ADD, fd, &add_event);

            return fd;
        }

        pub fn lines(self: *Self) !LineIterator(Tags) {
            return LineIterator(Tags){
                .context = self,
                .event_buffer = try self.allocator.alloc(os.system.epoll_event, self.process_map.count()),
                .pending_buffers = LineIterator(Tags).Pending.init(self.allocator),
            };
        }
    };
}

pub fn LineIterator(comptime Tags: anytype) type {
    return struct {
        context: *Loop(Tags),
        event_buffer: []os.system.epoll_event,
        pending_buffers: Pending,

        const Self = @This();
        const Pending = std.ArrayList(Entry);
        const Entry = struct { tag: Tags, line: std.ArrayList(u8) };

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
                    var buffered_reader = std.io.bufferedReader(file.reader());
                    var reader = buffered_reader.reader();
                    reader.readUntilDelimiterArrayList(&buffer, '\n', 512) catch |err| switch (err) {
                        error.EndOfStream => {
                            if (buffer.items.len == 0) {
                                buffer.deinit();
                                continue;
                            }
                        },
                        else => {
                            std.log.err("Could not read from file: {}", .{err});
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
