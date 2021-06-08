const std = @import("std");
const os = std.os;
const io = std.io;
const net = std.net;
const fs = std.fs;

pub const io_mode = .evented;

const pulse = @cImport({
    @cInclude("pulse/pulseaudio.h");
});

const CHUNK_SIZE: u32 = 1280;

const CONNECTION_READ_TIMEOUT: i64 = 5000; // Time in ms

pub fn main() !void {
    var err: c_int = undefined;

    std.debug.warn("Starting\n", .{});

    const allocator = std.heap.c_allocator;
    const req_listen_addr = try net.Address.parseIp4("0.0.0.0", 5988);
    const loop = std.event.Loop.instance.?;
    // loop.beginOneEvent(); // Hotfix for program exiting without it. Might be unecessary?
    // defer loop.finishOneEvent();

    var props = pulse.pa_proplist_new();
    defer pulse.pa_proplist_free(props);

    var sndServer = SndServer{
        .clients = std.AutoHashMap(*Client, void).init(allocator),
        .lock = std.Thread.Mutex{},
        // .pulseLock = std.Mutex{},
        .mainloop = pulse.pa_threaded_mainloop_new().?,
        .mainloop_api = undefined,
        .context = undefined,
        .checkStalledFrame = undefined,
    };

    //TODO: Is there a better way to do this?
    // sndServer.announcerFrame = async sndServer.announcer();
    sndServer.checkStalledFrame = async sndServer.checkStalled();
    sndServer.mainloop_api = pulse.pa_threaded_mainloop_get_api(sndServer.mainloop).?;
    sndServer.context = pulse.pa_context_new_with_proplist(sndServer.mainloop_api, "zig-sndrecv", props).?;
    err = pulse.pa_context_connect(sndServer.context, null, pulse.pa_context_flags.PA_CONTEXT_NOFLAGS, null);
    std.debug.assert(err == 0);

    // Start mainloop
    err = pulse.pa_threaded_mainloop_start(sndServer.mainloop);
    std.debug.assert(err == 0);

    // Starting TCP Listener
    var server = net.StreamServer.init(net.StreamServer.Options{});
    defer server.deinit();

    try server.listen(req_listen_addr);

    std.debug.warn("Listening at {}\n", .{server.listen_address.getPort()});

    while (true) {
        const client_con = try server.accept();
        std.debug.warn("Client connected!\n", .{});
        const client = try allocator.create(Client);
        client.* = Client{
            .con = client_con,
            .frame = async client.handle(&sndServer),
            .last_read = std.time.milliTimestamp(),
        };
        var held_lock = sndServer.lock.acquire();
        defer held_lock.release();
        try sndServer.clients.putNoClobber(client, {});
    }
}

const SndServer = struct {
    clients: std.AutoHashMap(*Client, void),
    lock: std.Thread.Mutex,
    // pulseLock: std.Mutex,
    mainloop: *pulse.pa_threaded_mainloop,
    mainloop_api: *pulse.pa_mainloop_api,
    context: *pulse.pa_context,
    // announcerFrame: @Frame(announcer),
    checkStalledFrame: @Frame(checkStalled),

    // fn announcer(self: *SndServer) !void {
    //     // TODO Send UDP announcements
    // }

    fn checkStalled(self: *SndServer) !void {
        const loop = std.event.Loop.instance.?;
        while (true) {
            loop.sleep(2000000000);

            var held_lock = self.lock.acquire();
            defer held_lock.release();

            var it = self.clients.iterator();

            var current_time = std.time.milliTimestamp();
            while (it.next()) |entry| {
                if (current_time - entry.key.last_read > CONNECTION_READ_TIMEOUT) { // 5 seconds after last read
                    // std.debug.warn("Detected stalled connection. Closing broken connections is WIP\n", .{});
                    // entry.key.con.file.close();
                    // entry.key.con.stream.close();
                }
            }
        }
    }
};

const Client = struct {
    con: net.StreamServer.Connection,
    frame: @Frame(handle),
    last_read: i64,
    fn handle(self: *Client, server: *SndServer) !void {
        defer {
            var held_lock = server.lock.acquire();
            _ = server.clients.remove(self);
            held_lock.release();
        }

        var err: c_int = undefined;
        _ = try self.con.stream.write("SNDStream v0.1\n"); // Is irrelevant for normal connections, but helps debugging :)

        // Getting AudioStream
        // TODO: Might also need server lock
        // var pulse_lock = server.pulseLock.acquire();
        pulse.pa_threaded_mainloop_lock(server.mainloop);

        var ss = pulse.pa_sample_spec{
            .format = pulse.pa_sample_format.PA_SAMPLE_S16LE,
            .rate = 48000,
            .channels = 2,
        };

        //TODO: make name the ip address of the client
        // Name seems to be irrelevant for at least GNOMEs Settings. Might have to create a new context per connection?
        var stream = pulse.pa_stream_new(server.context, "", &ss, null);
        defer {
            pulse.pa_threaded_mainloop_lock(server.mainloop);
            _ = pulse.pa_stream_disconnect(stream); // Error here is irrelevant
            pulse.pa_stream_unref(stream); // Should free this stream, since there should only be one ref but who knows...
            pulse.pa_threaded_mainloop_unlock(server.mainloop);
        }

        err = pulse.pa_stream_connect_playback(stream, null, null, pulse.pa_stream_flags.PA_STREAM_NOFLAGS, null, null);
        pulse.pa_threaded_mainloop_unlock(server.mainloop);
        // pulse_lock.release();

        if (err != 0) { // Some error. What error exactly, i don't know but when it happens but it at least does not crash everything
            std.debug.warn("Error while connecting audio stream {}\n", .{err});
            return;
        }

        while (true) {
            var buf: [CHUNK_SIZE * 3]u8 = undefined;
            const amt = try self.con.stream.read(&buf);
            self.last_read = std.time.milliTimestamp();
            if (amt == 0) { //Peer disconnected
                std.debug.warn("Peer disconnected!\n", .{});
                break;
            }
            const msg = buf[0..amt];

            // pulse_lock = server.pulseLock.acquire();
            pulse.pa_threaded_mainloop_lock(server.mainloop);
            defer pulse.pa_threaded_mainloop_unlock(server.mainloop);

            err = pulse.pa_stream_write(stream, msg.ptr, msg.len, null, 0, pulse.pa_seek_mode.PA_SEEK_RELATIVE);
            if (err != 0) { // Again I don't know when this happends, but I will just break the connection
                std.debug.warn("Error while writing audio stream {}\n", .{err});
                return;
            }
            // pulse_lock.release();
        }
    }
};
