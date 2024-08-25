const std = @import("std");
const c = @cImport({
    @cInclude("portaudio.h");
});

const logger = std.log.scoped(.zaudio);

fn handleError(err: c_int) !void {
    switch (err) {
        c.paNoError => return,
        else => {
            logger.debug(
                "Unhandled error: {d} {s}\n",
                .{ err, c.Pa_GetErrorText(err) },
            );
            return error.UnknownError;
        },
    }
}

pub fn init() !void {
    try handleError(c.Pa_Initialize());
}

pub fn deinit() void {
    _ = c.Pa_Terminate();
}

const DataPipe = std.fifo.LinearFifo(f32, .Slice);

const CallbackHandler = struct {
    data_pipe: DataPipe,
    mutex: std.Thread.Mutex = .{},
    done: bool = false,

    const Status = enum {
        complete,
        more,
        abort,
    };

    fn callbackImpl(
        self: *CallbackHandler,
        output: []f32,
    ) !Status {
        var index: usize = 0;
        while (index < output.len) {
            if (self.mutex.tryLock()) {
                defer self.mutex.unlock();

                // if we're complete, then just return that
                if (self.done) return .complete;

                const read = self.data_pipe.read(output);
                if (read > 0) {
                    logger.debug("Read {d} values from stream", .{read});
                }

                index += read;
            } else {
                // spin the thread for a milisecond
                std.time.sleep(std.time.ns_per_ms);
            }
        }
        return .more;
    }

    fn callback(
        input: ?*const anyopaque,
        output: ?*anyopaque,
        frames_per_buffer: c_ulong,
        time_info: [*c]const c.PaStreamCallbackTimeInfo,
        flags: c.PaStreamCallbackFlags,
        ctx: ?*anyopaque,
    ) callconv(.C) c_int {
        _ = input;
        _ = time_info;
        _ = flags;
        const output_ptr: [*]f32 = @alignCast(@ptrCast(output.?));
        const self: *CallbackHandler = @alignCast(@ptrCast(ctx.?));

        const len: usize = @intCast(frames_per_buffer);
        const ret = self.callbackImpl(
            output_ptr[0..len],
        ) catch |err| {
            logger.err("portaudio_callback: {!}", .{err});
            return c.paAbort;
        };

        return switch (ret) {
            .complete => c.paComplete,
            .more => c.paContinue,
            .abort => c.paAbort,
        };
    }
};

pub const Stream = struct {
    pub const Options = struct {
        n_channels: usize = 0,
        mono: bool = true,
        sample_rate: f64 = 44100,
        frames_per_buffer: usize = 256,
    };

    stream: *c.PaStream,
    allocator: std.mem.Allocator,
    buffer: []const f32,
    handler: CallbackHandler,
    opts: Options,

    pub fn openDefault(
        allocator: std.mem.Allocator,
        opts: Options,
    ) !*Stream {
        const ptr = try allocator.create(Stream);
        errdefer allocator.destroy(ptr);

        const buffer = try allocator.alloc(f32, 8192);
        errdefer allocator.free(buffer);

        ptr.* = .{
            .allocator = allocator,
            .buffer = buffer,
            .stream = undefined,
            .handler = undefined,
            .opts = opts,
        };

        ptr.handler = .{
            .data_pipe = DataPipe.init(buffer),
        };

        const ret = c.Pa_OpenDefaultStream(
            @ptrCast(&ptr.stream),
            @intCast(opts.n_channels),
            @intFromBool(opts.mono),
            c.paFloat32,
            opts.sample_rate,
            @intCast(opts.frames_per_buffer),
            CallbackHandler.callback,
            @ptrCast(&ptr.handler),
        );
        try handleError(ret);
        return ptr;
    }

    fn writeData(self: *Stream, data: []const f32) !void {
        logger.debug("Writing {d} values into audio stream", .{data.len});

        while (true) {
            if (self.handler.mutex.tryLock()) {
                defer self.handler.mutex.unlock();
                // wait until there is space available
                if (self.handler.data_pipe.writableLength() > data.len) {
                    try self.handler.data_pipe.write(data);
                    break;
                }
            }
            std.time.sleep(std.time.ns_per_ms);
        }
    }

    /// Write data into the stream
    pub fn write(self: *Stream, data: []const f32) !void {
        try self.writeData(data);
    }

    /// Start the stream
    pub fn start(self: *Stream) !void {
        try handleError(c.Pa_StartStream(self.stream));
    }

    /// Stop the stream
    pub fn stop(self: *Stream) !void {
        {
            self.handler.mutex.lock();
            defer self.handler.mutex.unlock();
            self.handler.done = true;
        }
        try handleError(c.Pa_AbortStream(self.stream));
        // try handleError(c.Pa_StopStream(self.stream));
        logger.debug("Stream stopped", .{});
    }

    /// Close the stream and free allocated resources.
    pub fn close(self: *Stream) void {
        _ = c.Pa_CloseStream(self.stream);
        self.handler.data_pipe.deinit();
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }
};
