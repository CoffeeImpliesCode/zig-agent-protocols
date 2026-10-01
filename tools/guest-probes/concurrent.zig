//! Boundary probe: does `std.Io` task handling, and then a real socket, work
//! on this FreeBSD riscv64 guest?
//!
//! This file is a throwaway diagnostic, not a test and not library code. It
//! exists to draw one line: the sibling `thread.zig` establishes whether a
//! raw `pthread_create`/`join` pair and thread-local storage work at all, and
//! this one starts where that file stops, at the first boundary the executor
//! adds on top — a task the executor spawns and reaps itself. If `thread.zig`
//! passes and this file fails at stage A, the fault is in `std.Io`'s task
//! handling and not in `std.Thread`; if both fail, the fault is below both.
//!
//! The stages run in ladder order, so the first stage whose closing marker
//! never appears names the layer that broke:
//!
//!   A  `Io.Group.concurrent` + `Group.await` — the task pool, spawned from the
//!      main thread and joined back into it.
//!   B  `Io.Mutex` + `Io.Condition` between two tasks — the futex-backed
//!      parking the group completion path itself uses, reached without any
//!      socket in the picture.
//!   C  `Io.async` + `Future.await` returning a value — the async pool, which
//!      runs a task inline once the pool is saturated, so it is a different
//!      code path from `concurrent` even when both tasks complete.
//!   D  `Io.concurrent` + `Future.await` — a refusal here is
//!      `error.ConcurrencyUnavailable`, which is an executor configuration
//!      fact rather than a fault, and is reported as its own outcome.
//!   E  A Unix domain socket with the accept half running as a group task —
//!      the first boundary at which a descriptor crosses from the kernel.
//!
//! Every `Io` used here is the one received in `std.process.Init`, never a
//! privately constructed executor, so a difference between this file and the
//! real test roots cannot be an executor difference.
//!
//! Every stage asserts completed work, not merely the absence of a throw: the
//! tasks compute a value that the main thread recomputes independently and
//! compares, and the socket stage compares the bytes that actually crossed the
//! kernel. A stage that ran and produced a wrong answer reports the value it
//! got, which is a different diagnosis from a stage that never ran.
//!
//! Markers go out with a raw `write(2)` rather than through `std.Io.File` or
//! `std.debug`. `std.Progress` installs a background thread and a tty check
//! that can suppress or interleave buffered output during a crash unwind, and
//! this file's entire value is that its output survives the fault it is
//! reporting.

const std = @import("std");

const Io = std.Io;

extern "c" fn write(fd: c_int, buffer: [*]const u8, length: usize) isize;

/// Serializes marker emission across tasks so a line is never split by an
/// interleaved write. The spin is bounded: a probe exists to be killed by a
/// fault, and it must not be turned into a hang by its own diagnostics. A
/// marker written after the bound is emitted unsynchronized, which is a
/// visibly torn line rather than a silent omission.
var mark_lock = std.atomic.Value(u32).init(0);

fn mark(text: []const u8) void {
    var owned = false;
    var spins: usize = 0;
    while (!owned) {
        if (mark_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) {
            owned = true;
        } else {
            spins += 1;
            if (spins > 1_000_000) break;
            std.atomic.spinLoopHint();
        }
    }
    _ = write(1, text.ptr, text.len);
    if (owned) mark_lock.store(0, .release);
}

fn markf(comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format ++ "\n", args) catch {
        mark("RISC_PROBE_MARK_OVERFLOW\n");
        return;
    };
    mark(line);
}

/// Spelled out rather than formatted with `{}`, so a reader of the console
/// sees a word instead of a format-specifier disagreement between compiler
/// versions.
fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// A stage that reached the end of its work and rejected the result. Exits 3
/// so that a completed-but-wrong stage is distinguishable in the exit status
/// from a stage that was killed by a signal before it could report.
fn reject(stage: []const u8, detail: []const u8) noreturn {
    markf("RISC_PROBE_FAIL {s} {s}", .{ stage, detail });
    std.process.exit(3);
}

/// A stage that could not start. Exits 4, distinct from `reject` so that "the
/// boundary was refused" and "the boundary produced a wrong answer" stay
/// separable in the exit status alone.
fn refused(stage: []const u8, detail: []const u8) noreturn {
    markf("RISC_PROBE_REFUSED {s} {s}", .{ stage, detail });
    std.process.exit(4);
}

const stage_a_tasks = 4;
const stage_a_iterations: u32 = 20_000;
const stage_b_value: u64 = 0x5eed_0000_0000_0001;
const stage_b_value_mix: u64 = 0x0bad_f00d_0000_0002;

/// Stage A's per-task work. The multiplier is the task index so two tasks
/// cannot be distinguished by a constant that would also fit a task that
/// never ran.
fn groupSum(index: u32) u64 {
    var sum: u64 = 0;
    for (0..stage_a_iterations) |i| sum +%= @as(u64, i) *% 5 +% @as(u64, index);
    return sum;
}

/// Stage C and D's work, shared by both so a difference between the async and
/// the concurrent pool is a difference in the pool and not in the arithmetic.
fn poolSum(base: u64) u64 {
    var sum: u64 = 0;
    for (0..stage_a_iterations) |i| sum +%= @as(u64, i) *% 7 +% base;
    return sum;
}

const GroupTask = struct {
    index: u32,
    // SAFETY: written only by the task, read only after `Group.await` returns.
    slot: *u64,
};

fn groupTask(t: *GroupTask) void {
    markf("RISC_PROBE_CONC_A_TASK_ENTER index={d}\n", .{t.index});
    t.slot.* = groupSum(t.index);
    markf("RISC_PROBE_CONC_A_TASK_DONE index={d}\n", .{t.index});
}

const Handshake = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Set once the waiter is inside the condition's critical section, so the
    /// signaller has something to wait for and the wait is a real block rather
    /// than a task that ran to completion before anybody looked.
    registered: std.atomic.Value(u8) = .init(0),
    /// SAFETY: `value` is written under `mutex` and read under `mutex`; the
    /// atomic pair is only the release/acquire publication for `ready`.
    ready: std.atomic.Value(u8) = .init(0),
    value: u64 = 0,
    wakeups: u32 = 0,
    failure: ?anyerror = null,
};

fn waiterTask(h: *Handshake) void {
    mark("RISC_PROBE_CONC_B_WAITER_ENTER\n");
    h.mutex.lock(h.io) catch |err| {
        h.failure = err;
        markf("RISC_PROBE_CONC_B_WAITER_LOCK_ERROR {t}\n", .{err});
        return;
    };
    mark("RISC_PROBE_CONC_B_WAITER_LOCKED\n");
    h.registered.store(1, .release);
    while (h.ready.load(.acquire) == 0) {
        h.cond.wait(h.io, &h.mutex) catch |err| {
            h.failure = err;
            markf("RISC_PROBE_CONC_B_WAITER_WAIT_ERROR {t}\n", .{err});
            break;
        };
        h.wakeups += 1;
    }
    h.mutex.unlock(h.io);
    markf("RISC_PROBE_CONC_B_WAITER_LEFT value={d} wakeups={d}\n", .{ h.value, h.wakeups });
}

fn signallerTask(h: *Handshake) void {
    mark("RISC_PROBE_CONC_B_SIGNALLER_ENTER\n");
    // Bounded, and reported rather than assumed: a signaller that never sees
    // the waiter register would otherwise turn this stage into a pass.
    var attempts: u32 = 0;
    while (h.registered.load(.acquire) == 0) {
        attempts += 1;
        if (attempts > 2_000) {
            h.failure = error.WaiterNeverRegistered;
            mark("RISC_PROBE_CONC_B_SIGNALLER_GAVE_UP\n");
            return;
        }
        h.io.sleep(.fromMilliseconds(1), .awake) catch |err| {
            h.failure = err;
            markf("RISC_PROBE_CONC_B_SIGNALLER_SLEEP_ERROR {t}\n", .{err});
            return;
        };
    }
    h.mutex.lock(h.io) catch |err| {
        h.failure = err;
        markf("RISC_PROBE_CONC_B_SIGNALLER_LOCK_ERROR {t}\n", .{err});
        return;
    };
    h.value = stage_b_value;
    h.ready.store(1, .release);
    h.cond.signal(h.io);
    h.mutex.unlock(h.io);
    mark("RISC_PROBE_CONC_B_SIGNALLED\n");
}

const PoolTask = struct {
    base: u64,
};

fn poolTask(t: *PoolTask) u64 {
    markf("RISC_PROBE_CONC_POOL_TASK_ENTER base={d}\n", .{t.base});
    const sum = poolSum(t.base);
    markf("RISC_PROBE_CONC_POOL_TASK_DONE sum={d}\n", .{sum});
    return sum;
}

const request: []const u8 = "ping!";
const reply: []const u8 = "pong!";

const SocketTask = struct {
    io: Io,
    server: *Io.net.Server,
    // SAFETY: written only by the task, read only after `Group.await` returns.
    got: [request.len]u8 = undefined,
    echoed: bool = false,
    failure: ?anyerror = null,
};

fn acceptTask(s: *SocketTask) void {
    mark("RISC_PROBE_CONC_E_TASK_ENTER\n");
    const stream = s.server.accept(s.io) catch |err| {
        s.failure = err;
        markf("RISC_PROBE_CONC_E_TASK_ACCEPT_ERROR {t}\n", .{err});
        return;
    };
    const accepted = stream;
    mark("RISC_PROBE_CONC_E_TASK_ACCEPTED\n");
    defer accepted.close(s.io);

    var read_buffer: [64]u8 = undefined;
    var reader = accepted.reader(s.io, &read_buffer);
    reader.interface.readSliceAll(&s.got) catch |err| {
        s.failure = err;
        markf("RISC_PROBE_CONC_E_TASK_READ_ERROR {t}\n", .{err});
        return;
    };
    mark("RISC_PROBE_CONC_E_TASK_READ\n");

    var write_buffer: [64]u8 = undefined;
    var writer = accepted.writer(s.io, &write_buffer);
    writer.interface.writeAll(reply) catch |err| {
        s.failure = err;
        markf("RISC_PROBE_CONC_E_TASK_WRITE_ERROR {t}\n", .{err});
        return;
    };
    writer.interface.flush() catch |err| {
        s.failure = err;
        markf("RISC_PROBE_CONC_E_TASK_FLUSH_ERROR {t}\n", .{err});
        return;
    };
    s.echoed = true;
    mark("RISC_PROBE_CONC_E_TASK_ECHOED\n");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    mark("RISC_PROBE_CONC_ENTER\n");

    const cpus = std.Thread.getCpuCount() catch |err| blk: {
        markf("RISC_PROBE_CONC_ENV cpu_count_error={t}\n", .{err});
        break :blk @as(?usize, null);
    };
    if (cpus) |n| markf("RISC_PROBE_CONC_ENV cpu_count={d}\n", .{n});
    markf("RISC_PROBE_CONC_ENV io_userdata_nonnull={s}\n", .{boolText(io.userdata != null)});

    // ---- stage A: Group.concurrent, then Group.await -----------------------
    markf("RISC_PROBE_CONC_A_SPAWN_BEGIN tasks={d}\n", .{stage_a_tasks});
    var slots = [_]u64{0} ** stage_a_tasks;
    var tasks: [stage_a_tasks]GroupTask = undefined;
    var a_group: Io.Group = .init;
    defer a_group.cancel(io);
    for (&tasks, 0..) |*t, i| {
        t.* = .{ .index = @intCast(i), .slot = &slots[i] };
        a_group.concurrent(io, groupTask, .{t}) catch |err| {
            markf("RISC_PROBE_CONC_A_SPAWN_ERROR index={d} err={t}\n", .{ i, err });
            a_group.cancel(io);
            refused("A", "concurrent_refused");
        };
    }
    markf("RISC_PROBE_CONC_A_SPAWNED tasks={d}\n", .{stage_a_tasks});
    a_group.await(io) catch |err| {
        markf("RISC_PROBE_CONC_A_AWAIT_ERROR {t}\n", .{err});
        refused("A", "await_failed");
    };
    mark("RISC_PROBE_CONC_A_AWAITED\n");
    for (slots, 0..) |slot, i| {
        if (slot != groupSum(@intCast(i))) {
            markf("RISC_PROBE_CONC_A_SLOT index={d} value={d}\n", .{ i, slot });
            reject("A", "wrong_sum");
        }
    }
    mark("RISC_PROBE_CONC_A_OK\n");

    // ---- stage B: Io.Mutex and Io.Condition between two tasks --------------
    mark("RISC_PROBE_CONC_B_SPAWN_BEGIN\n");
    var h: Handshake = .{ .io = io };
    var b_group: Io.Group = .init;
    defer b_group.cancel(io);
    b_group.concurrent(io, waiterTask, .{&h}) catch |err| {
        markf("RISC_PROBE_CONC_B_SPAWN_ERROR err={t}\n", .{err});
        b_group.cancel(io);
        refused("B", "concurrent_refused");
    };
    b_group.concurrent(io, signallerTask, .{&h}) catch |err| {
        markf("RISC_PROBE_CONC_B_SPAWN_ERROR err={t}\n", .{err});
        b_group.cancel(io);
        refused("B", "concurrent_refused");
    };
    mark("RISC_PROBE_CONC_B_SPAWNED\n");
    b_group.await(io) catch |err| {
        markf("RISC_PROBE_CONC_B_AWAIT_ERROR {t}\n", .{err});
        refused("B", "await_failed");
    };
    mark("RISC_PROBE_CONC_B_AWAITED\n");
    if (h.failure) |err| {
        markf("RISC_PROBE_CONC_B_TASK_ERROR {t}\n", .{err});
        reject("B", "task_failed");
    }
    if (h.wakeups == 0) reject("B", "waiter_never_blocked");
    if (h.value != stage_b_value) {
        markf("RISC_PROBE_CONC_B_VALUE value={d} expected={d}\n", .{ h.value, stage_b_value });
        reject("B", "wrong_value");
    }
    markf("RISC_PROBE_CONC_B_OK wakeups={d}\n", .{h.wakeups});

    // ---- stage C: Io.async ------------------------------------------------
    mark("RISC_PROBE_CONC_C_ASYNC_BEGIN\n");
    var c_task: PoolTask = .{ .base = stage_b_value_mix };
    // `Io.async` and `Io.concurrent` are member functions whose first parameter
    // is the `Io` receiver, so the call is `io.async(function, args)`: naming
    // `io` again as an argument is a third argument where two are expected.
    var c_future = io.async(poolTask, .{&c_task});
    mark("RISC_PROBE_CONC_C_ASYNC_SPAWNED\n");
    const c_sum = c_future.await(io);
    markf("RISC_PROBE_CONC_C_ASYNC_AWAITED sum={d}\n", .{c_sum});
    if (c_sum != poolSum(stage_b_value_mix)) reject("C", "wrong_sum");

    // ---- stage D: Io.concurrent -------------------------------------------
    mark("RISC_PROBE_CONC_D_CONCURRENT_BEGIN\n");
    var d_task: PoolTask = .{ .base = stage_b_value_mix };
    var d_future = io.concurrent(poolTask, .{&d_task}) catch |err| {
        // A refusal is a configuration fact about the executor, not a fault,
        // and it gets its own exit status so it is never read as a crash.
        markf("RISC_PROBE_CONC_D_REFUSED {t}\n", .{err});
        std.process.exit(5);
    };
    mark("RISC_PROBE_CONC_D_CONCURRENT_SPAWNED\n");
    const d_sum = d_future.await(io);
    markf("RISC_PROBE_CONC_D_CONCURRENT_AWAITED sum={d}\n", .{d_sum});
    if (d_sum != poolSum(stage_b_value_mix)) reject("D", "wrong_sum");
    mark("RISC_PROBE_CONC_D_OK\n");

    // ---- stage E: a real Unix socket with the accept half in a task -------
    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const tmpdir = init.minimal.environ.getPosix("TMPDIR") orelse "/tmp";
    const path = std.fmt.bufPrint(&path_buffer, "{s}/risc-probe-{x}.sock", .{
        tmpdir,
        std.mem.readInt(u64, &nonce, .little),
    }) catch |err| {
        markf("RISC_PROBE_CONC_E_PATH_ERROR {t}\n", .{err});
        refused("E", "socket_path_too_long");
    };
    markf("RISC_PROBE_CONC_E_PATH dir={s}\n", .{tmpdir});
    // A socket file left by a killed run would make listen fail. An absent
    // file is the expected answer here; anything else is a real fault in the
    // scratch directory this run owns.
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            markf("RISC_PROBE_CONC_E_UNLINK_ERROR {t}\n", .{err});
            refused("E", "stale_socket");
        },
    };

    const address = Io.net.UnixAddress.init(path) catch |err| {
        markf("RISC_PROBE_CONC_E_ADDRESS_ERROR {t}\n", .{err});
        refused("E", "address_rejected");
    };
    mark("RISC_PROBE_CONC_E_LISTEN_BEGIN\n");
    var server = address.listen(io, .{}) catch |err| {
        markf("RISC_PROBE_CONC_E_LISTEN_ERROR {t}\n", .{err});
        refused("E", "listen_failed");
    };
    mark("RISC_PROBE_CONC_E_LISTENED\n");
    defer {
        server.deinit(io);
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var s: SocketTask = .{ .io = io, .server = &server };
    var e_group: Io.Group = .init;
    defer e_group.cancel(io);
    e_group.concurrent(io, acceptTask, .{&s}) catch |err| {
        markf("RISC_PROBE_CONC_E_SPAWN_ERROR {t}\n", .{err});
        e_group.cancel(io);
        refused("E", "concurrent_refused");
    };
    mark("RISC_PROBE_CONC_E_SPAWNED\n");

    mark("RISC_PROBE_CONC_E_CONNECT_BEGIN\n");
    const client = address.connect(io) catch |err| {
        markf("RISC_PROBE_CONC_E_CONNECT_ERROR {t}\n", .{err});
        // Cancelling rather than awaiting: the accept task is still blocked,
        // and a cancel releases it instead of leaving this process to be
        // killed by the caller's timeout with a task outstanding.
        e_group.cancel(io);
        refused("E", "connect_failed");
    };
    const connected = client;
    mark("RISC_PROBE_CONC_E_CONNECTED\n");
    defer connected.close(io);

    var client_write_buffer: [64]u8 = undefined;
    var client_writer = connected.writer(io, &client_write_buffer);
    client_writer.interface.writeAll(request) catch |err| {
        markf("RISC_PROBE_CONC_E_WRITE_ERROR {t}\n", .{err});
        e_group.cancel(io);
        refused("E", "write_failed");
    };
    client_writer.interface.flush() catch |err| {
        markf("RISC_PROBE_CONC_E_FLUSH_ERROR {t}\n", .{err});
        e_group.cancel(io);
        refused("E", "flush_failed");
    };
    mark("RISC_PROBE_CONC_E_WROTE\n");

    var client_read_buffer: [64]u8 = undefined;
    var client_reader = connected.reader(io, &client_read_buffer);
    var received: [reply.len]u8 = undefined;
    client_reader.interface.readSliceAll(&received) catch |err| {
        markf("RISC_PROBE_CONC_E_READ_ERROR {t}\n", .{err});
        e_group.cancel(io);
        refused("E", "read_failed");
    };
    mark("RISC_PROBE_CONC_E_READ\n");

    e_group.await(io) catch |err| {
        markf("RISC_PROBE_CONC_E_AWAIT_ERROR {t}\n", .{err});
        refused("E", "await_failed");
    };
    mark("RISC_PROBE_CONC_E_AWAITED\n");
    if (s.failure) |err| {
        markf("RISC_PROBE_CONC_E_TASK_ERROR {t}\n", .{err});
        reject("E", "peer_task_failed");
    }
    if (!s.echoed) reject("E", "peer_never_echoed");
    if (!std.mem.eql(u8, &s.got, request)) {
        mark("RISC_PROBE_CONC_E_PEER_BYTES_WRONG\n");
        reject("E", "peer_read_wrong_bytes");
    }
    if (!std.mem.eql(u8, &received, reply)) {
        mark("RISC_PROBE_CONC_E_CLIENT_BYTES_WRONG\n");
        reject("E", "client_read_wrong_bytes");
    }
    markf("RISC_PROBE_CONC_E_OK request={d} reply={d}\n", .{ request.len, reply.len });

    markf("RISC_PROBE_CONC_EXIT {d}\n", .{@as(u8, 0)});
}
