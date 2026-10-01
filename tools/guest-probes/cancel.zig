//! Boundary probe: where does `Io.Group.cancel` release a blocked task on
//! this FreeBSD riscv64 guest?
//!
//! This file is a throwaway diagnostic, not a test and not library code. It
//! answers one question, at the exact spot `src/conn.zig:1588-1635` fails: a
//! task spawned with `Group.concurrent` and released with `Group.cancel`
//! while it is blocked. The library test faults there, and the shape it
//! faults in is `concurrent` immediately followed by `cancel` with the task
//! blocked in `Io.Condition.wait` (`src/conn.zig:686`).
//!
//! Nothing here imports the library. The wait is reproduced from the same
//! primitives in the same order, so a fault below is a fault in the
//! cancellation machinery and not in the connection, the framing or the slot
//! table. The one thing copied verbatim from the library is the *shape* of
//! the call: claim a slot, take the state lock uncancelable, block in the
//! wait, give the slot back on the failed wait.
//!
//! Each stage is a separate process, selected by `argv[1]`, so a stage that
//! hangs or faults cannot hide the boundaries after it — `cancel_suite.sh`
//! runs each one under `/usr/bin/timeout 120` and reports its status. The
//! stages, in the order the ladder runs them:
//!
//!   done      a group whose task has already finished, then `cancel`. The
//!             floor: a cancel on a group with nothing pending must return
//!             without reaching the implementation at all (`Io.zig:1298`).
//!   cond      a task genuinely blocked in `Io.Condition.wait`, released by
//!             `cancel`, with the slot it claimed given back — the library
//!             test's own assertion, in the library's own order.
//!   early     the same task with the library's ordering: `concurrent` and
//!             `cancel` back to back with nothing between them, so the cancel
//!             can arrive before the task reaches the wait, during the wait,
//!             or while it is still queued to start. The three orderings are
//!             all legal here, and which one ran is reported, because the
//!             difference between them is exactly what a fault would hide.
//!   event     a task blocked in `Io.Event.wait`, the other cancelation point
//!             the library uses (`src/conn.zig:1192`).
//!   sleep     a task blocked in `Io.sleep`, a cancelation point in the
//!             executor and not in any syscall.
//!   sockread  a task blocked in a real blocking read on a Unix socket, with
//!             the owner's cleanup asserting shutdown-before-close on both
//!             halves of the connection.
//!
//!   debug-done       `done` repeated on the allocator the failing library test
//!                   builds its executor with, `std.testing.allocator`
//!                   (`src/conn.zig:1595`).
//!   debug-condition  `cond` repeated on that same allocator.
//!   debug-condition-no-trace
//!                   `cond` repeated on that same allocator with the one
//!                   option that decides whether an allocation captures a
//!                   stack trace, which on this target is itself code that
//!                   has never run here.
//!
//! Those three are the only stages repeated, and only because the allocator
//! and the trace capture are competing causes for a fault that a cancel on
//! the page allocator would otherwise look like; `main` says what they can
//! and cannot tell apart.
//!
//! The gate before a cancel is a publication by the task itself, never a
//! delay: a task that has not said it is at its cancelation point has not
//! been cancelled *there*, and a probe that cannot prove where it was
//! cancelling is measuring its own timing, not the boundary. The gate is a
//! publication and not an inspection of the waiter's own state because the
//! waiter count inside `Io.Condition` is a private field of a std type, and a
//! probe that reaches into it fails to compile on any std version bump —
//! losing every stage at once to make one of them more precise.
//!
//! Every stage brackets the two operations whose failure is the question —
//! `Group.cancel` and `Threaded.deinit` — with markers, and every task
//! reports the error its blocked call returned. A stage that printed
//! `..._CANCEL_BEGIN` and never printed `..._CANCEL_DONE` did not return from
//! the cancel; one that printed `..._DEINIT_BEGIN` and never printed
//! `..._DEINIT_DONE` died inside the deinit. Both are answers.
//!
//! Markers go out with a raw `write(2)` rather than through `std.Io.File` or
//! `std.debug`. `std.Progress` installs a background thread and a tty check
//! that can suppress or interleave buffered output during a crash unwind, and
//! this file's entire value is that its output survives the fault it is
//! reporting.
//!
//! Build and run: `zig build-exe -OReleaseSafe -target riscv64-freebsd -lc
//! cancel.zig`, then `cancel <stage>`. Exit status 0 means every assertion in
//! the stage held; 3 means a stage ran and rejected its result; 4 means a
//! stage could not start. A status of 124 is the harness reporting a hang.

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
        mark("RISC_PROBE_CANCEL_MARK_OVERFLOW\n");
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

/// The name of an error, or `none` for the null of an error set a stage was
/// given. Generic so that a stage can hand it either an error the call
/// reported or the optional one it stored: the fine half of a collapsed
/// error, like the one `Io.net.Stream.Reader` keeps for a failed read, is
/// the interesting value and it is not always the one the caller saw.
fn errorName(err: anytype) []const u8 {
    if (@typeInfo(@TypeOf(err)) == .optional) {
        if (err) |e| return @errorName(e);
        return "none";
    }
    return @errorName(err);
}

/// A stage that reached the end of its work and rejected the result. Exits 3
/// so that a completed-but-wrong stage is distinguishable in the exit status
/// from a stage that was killed by a signal before it could report.
fn reject(stage: []const u8, detail: []const u8) noreturn {
    markf("RISC_PROBE_CANCEL_{s}_FAIL {s}", .{ stage, detail });
    std.process.exit(3);
}

/// A stage that could not start. Exits 4, distinct from `reject` so that "the
/// boundary was refused" and "the boundary produced a wrong answer" stay
/// separable in the exit status alone.
fn refused(stage: []const u8, detail: []const u8) noreturn {
    markf("RISC_PROBE_CANCEL_{s}_REFUSED {s}", .{ stage, detail });
    std.process.exit(4);
}

/// How long a stage waits for a task to publish that it is at its
/// cancelation point. Bounded, because a task that never reaches the wait is
/// a refusal and not a wait: at one millisecond a poll this is five seconds,
/// which is long enough for a task to be scheduled on a two-core guest
/// running a compiler's worth of work in the other slot, and short enough
/// that a stage which is never going to pass says so instead of eating the
/// harness timeout.
const gate_attempts: u32 = 5_000;

/// Blocks until the task has published that it is at the cancelation point
/// named by `what`. Every wait is reported with the number of polls it took,
/// so a stage that passed on the last poll is visible as such rather than as
/// a stage that passed quickly.
fn awaitPublished(io: Io, flag: *std.atomic.Value(u8), stage: []const u8, what: []const u8) void {
    var attempts: u32 = 0;
    while (flag.load(.acquire) == 0) {
        attempts += 1;
        if (attempts > gate_attempts) {
            markf("RISC_PROBE_CANCEL_{s}_GATE_GAVE_UP {s} attempts={d}", .{ stage, what, attempts });
            refused(stage, "gate_never_opened");
        }
        io.sleep(.fromMilliseconds(1), .awake) catch |err| {
            markf("RISC_PROBE_CANCEL_{s}_GATE_WAIT_ERROR {s} {s}", .{ stage, what, errorName(err) });
            refused(stage, "gate_wait_failed");
        };
    }
    markf("RISC_PROBE_CANCEL_{s}_GATE_OPENED {s} attempts={d}", .{ stage, what, attempts });
}

/// The shape of `Conn.call` with the connection left out: claim a slot, take
/// the state lock uncancelable, block in the wait, give the slot back if the
/// wait failed. `cond` and `early` share it, because the difference between
/// those two stages is when the cancel arrives and not what the task does.
const WaitCtx = struct {
    io: Io,
    stage: []const u8,
    mutex: Io.Mutex = .init,
    wake: Io.Condition = .init,
    /// Published by the task immediately before it enters the wait, so the
    /// cancel in a gated stage is known to arrive at a blocked wait rather
    /// than at a task that has not started yet.
    inside: std.atomic.Value(u8) = .init(0),
    /// SAFETY: written by the task before it publishes `inside`, and read by
    /// the main task only after `Group.cancel` has joined it.
    entered: bool = false,
    /// SAFETY: as `entered`. It is the library's `slot.used`, claimed before
    /// anything that can block and released again on the failed wait
    /// (`src/conn.zig:1075` and `src/conn.zig:686`).
    slot_claimed: u8 = 0,
    /// SAFETY: as `entered`, and it is only ever touched with `mutex` held.
    answered: bool = false,
    /// SAFETY: as `answered`.
    wakeups: u32 = 0,
    /// SAFETY: as `answered`.
    wait_error: ?anyerror = null,
};

fn waitTask(w: *WaitCtx) void {
    w.slot_claimed = 1;
    w.entered = true;
    markf("RISC_PROBE_CANCEL_{s}_TASK_ENTER slot_claimed={d}", .{ w.stage, w.slot_claimed });
    // Taken uncancelable, exactly as `src/conn.zig:680` takes it, so the only
    // cancelation point this task can reach is the wait itself. A lock taken
    // cancelably would let a cancel arrive between the claim and the wait and
    // the slot would be given back by a path the library does not have.
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    w.inside.store(1, .release);
    markf("RISC_PROBE_CANCEL_{s}_TASK_WAIT_BEGIN", .{w.stage});
    while (!w.answered) {
        w.wake.wait(w.io, &w.mutex) catch |err| {
            w.wait_error = err;
            w.slot_claimed = 0;
            markf("RISC_PROBE_CANCEL_{s}_TASK_WAIT_ERROR {s}", .{ w.stage, errorName(err) });
            return;
        };
        w.wakeups += 1;
    }
    w.slot_claimed = 0;
    markf("RISC_PROBE_CANCEL_{s}_TASK_LEFT wakeups={d}", .{ w.stage, w.wakeups });
}

/// `done`: the boundary under everything else. A group whose task has already
/// finished has no pending tasks and no token, so `Group.cancel` returns
/// without calling the implementation — and the library test calls it twice
/// (`src/conn.zig:1624` and `src/conn.zig:1628`), so this stage calls it
/// twice as well, the second time standing in for the `defer`.
fn stageDone(io: Io, stage: []const u8) void {
    var w: WaitCtx = .{
        .io = io,
        .stage = stage,
        // Nothing will ever answer, so this stage's task takes the `while`
        // once and finds the answer already there: it runs the whole call
        // shape and blocks in nothing.
        .answered = true,
    };
    var group: Io.Group = .init;
    group.concurrent(io, waitTask, .{&w}) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_SPAWN_ERROR {s}", .{ stage, errorName(err) });
        refused(stage, "concurrent_refused");
    };
    markf("RISC_PROBE_CANCEL_{s}_SPAWNED", .{stage});
    group.await(io) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_AWAIT_ERROR {s}", .{ stage, errorName(err) });
        refused(stage, "await_failed");
    };
    markf("RISC_PROBE_CANCEL_{s}_AWAITED entered={s} wakeups={d}", .{ stage, boolText(w.entered), w.wakeups });
    if (!w.entered) reject(stage, "task_never_ran");
    if (w.wait_error != null) reject(stage, "a_finished_task_saw_a_cancel");
    if (w.slot_claimed != 0) reject(stage, "slot_leaked");
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_BEGIN", .{stage});
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_DONE", .{stage});
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_AGAIN_DONE", .{stage});
}

/// `cond` and `early`: the same task, released by a cancel. `gated` is the
/// whole difference — the gated stage waits for the task to publish that it
/// is in the wait, the ungated one cancels the instant `concurrent` returns,
/// which is the ordering `src/conn.zig:1625-1628` uses.
fn stagePendingWait(io: Io, stage: []const u8, gated: bool) void {
    var w: WaitCtx = .{ .io = io, .stage = stage };
    var group: Io.Group = .init;
    group.concurrent(io, waitTask, .{&w}) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_SPAWN_ERROR {s}", .{ stage, errorName(err) });
        refused(stage, "concurrent_refused");
    };
    markf("RISC_PROBE_CANCEL_{s}_SPAWNED", .{stage});
    if (gated) awaitPublished(io, &w.inside, stage, "wait");
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_BEGIN task_inside_wait={s}", .{
        stage,
        boolText(w.inside.load(.acquire) == 1),
    });
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_DONE", .{stage});
    // `cancel` is a join, so everything the task wrote is visible here and
    // the outcome below is the one the failed wait produced rather than one
    // still being written — the property the library test's own comment on
    // `src/conn.zig:1626` relies on.
    markf("RISC_PROBE_CANCEL_{s}_OUTCOME entered={s} wait_error={s} wakeups={d} slot_claimed={d}", .{
        stage,
        boolText(w.entered),
        errorName(w.wait_error),
        w.wakeups,
        w.slot_claimed,
    });
    if (!w.entered) {
        // Legal only in the ungated stage, where the cancel can beat the
        // task to its first instruction. It is a different ordering, not a
        // different answer, so it is reported and not rejected.
        markf("RISC_PROBE_CANCEL_{s}_OUTCOME_ORDER task_never_started", .{stage});
    } else if (w.wait_error == null) {
        reject(stage, "the_task_left_the_wait_without_an_error");
    } else if (w.wait_error.? != error.Canceled) {
        reject(stage, "the_wait_did_not_report_canceled");
    }
    if (w.slot_claimed != 0) reject(stage, "slot_leaked");
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_AGAIN_DONE", .{stage});
}

const EventCtx = struct {
    io: Io,
    stage: []const u8,
    event: Io.Event = .unset,
    inside: std.atomic.Value(u8) = .init(0),
    /// SAFETY: as `WaitCtx.entered`.
    entered: bool = false,
    /// SAFETY: as `WaitCtx.entered`.
    wait_error: ?anyerror = null,
};

fn eventTask(c: *EventCtx) void {
    c.entered = true;
    markf("RISC_PROBE_CANCEL_{s}_TASK_ENTER", .{c.stage});
    c.inside.store(1, .release);
    markf("RISC_PROBE_CANCEL_{s}_TASK_WAIT_BEGIN", .{c.stage});
    c.event.wait(c.io) catch |err| {
        c.wait_error = err;
        markf("RISC_PROBE_CANCEL_{s}_TASK_WAIT_ERROR {s}", .{ c.stage, errorName(err) });
        return;
    };
    markf("RISC_PROBE_CANCEL_{s}_TASK_LEFT", .{c.stage});
}

/// `event`: the second cancelation point the library blocks in
/// (`src/conn.zig:1192`). An event that nobody sets has no way to be
/// released except a cancel, so the boundary here is the executor's and not
/// the condition's.
fn stageEvent(io: Io) void {
    const stage = "EVENT";
    var c: EventCtx = .{ .io = io, .stage = stage };
    var group: Io.Group = .init;
    group.concurrent(io, eventTask, .{&c}) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_SPAWN_ERROR {s}", .{ stage, errorName(err) });
        refused(stage, "concurrent_refused");
    };
    markf("RISC_PROBE_CANCEL_{s}_SPAWNED", .{stage});
    awaitPublished(io, &c.inside, stage, "event_wait");
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_BEGIN", .{stage});
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_DONE", .{stage});
    markf("RISC_PROBE_CANCEL_{s}_OUTCOME entered={s} wait_error={s} is_set={s}", .{
        stage,
        boolText(c.entered),
        errorName(c.wait_error),
        boolText(c.event.isSet()),
    });
    if (!c.entered) reject(stage, "task_never_ran");
    if (c.wait_error == null) {
        reject(stage, "the_wait_returned_without_a_cancel");
    } else if (c.wait_error.? != error.Canceled) {
        reject(stage, "the_wait_did_not_report_canceled");
    }
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_AGAIN_DONE", .{stage});
}

const SleepCtx = struct {
    io: Io,
    stage: []const u8,
    inside: std.atomic.Value(u8) = .init(0),
    /// SAFETY: as `WaitCtx.entered`.
    entered: bool = false,
    /// SAFETY: as `WaitCtx.entered`.
    wait_error: ?anyerror = null,
};

fn sleepTask(c: *SleepCtx) void {
    c.entered = true;
    markf("RISC_PROBE_CANCEL_{s}_TASK_ENTER", .{c.stage});
    c.inside.store(1, .release);
    markf("RISC_PROBE_CANCEL_{s}_TASK_SLEEP_BEGIN", .{c.stage});
    // Long enough that the sleep is unambiguously still pending when the
    // cancel arrives, and well past the harness timeout: a sleep this stage
    // did not cancel would end the stage at 124 with the boundary named,
    // rather than returning on its own and passing.
    c.io.sleep(.fromSeconds(600), .awake) catch |err| {
        c.wait_error = err;
        markf("RISC_PROBE_CANCEL_{s}_TASK_SLEEP_ERROR {s}", .{ c.stage, errorName(err) });
        return;
    };
    markf("RISC_PROBE_CANCEL_{s}_TASK_LEFT", .{c.stage});
}

/// `sleep`: a cancelation point that is the executor's own and not a syscall
/// and not a futex, so it separates "the cancel is delivered at all" from
/// "the cancel reaches a waiter the way this waiter was made".
fn stageSleep(io: Io) void {
    const stage = "SLEEP";
    var c: SleepCtx = .{ .io = io, .stage = stage };
    var group: Io.Group = .init;
    group.concurrent(io, sleepTask, .{&c}) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_SPAWN_ERROR {s}", .{ stage, errorName(err) });
        refused(stage, "concurrent_refused");
    };
    markf("RISC_PROBE_CANCEL_{s}_SPAWNED", .{stage});
    awaitPublished(io, &c.inside, stage, "sleep");
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_BEGIN", .{stage});
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_DONE", .{stage});
    markf("RISC_PROBE_CANCEL_{s}_OUTCOME entered={s} wait_error={s}", .{
        stage,
        boolText(c.entered),
        errorName(c.wait_error),
    });
    if (!c.entered) reject(stage, "task_never_ran");
    if (c.wait_error == null) {
        reject(stage, "the_sleep_ended_without_a_cancel");
    } else if (c.wait_error.? != error.Canceled) {
        reject(stage, "the_sleep_did_not_report_canceled");
    }
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_AGAIN_DONE", .{stage});
}

const SockCtx = struct {
    io: Io,
    stage: []const u8 = "SOCKREAD",
    server: *Io.net.Server,
    inside: std.atomic.Value(u8) = .init(0),
    /// SAFETY: as `WaitCtx.entered`.
    entered: bool = false,
    /// SAFETY: as `WaitCtx.entered`.
    accepted: bool = false,
    /// SAFETY: as `WaitCtx.entered`.
    accept_error: ?anyerror = null,
    /// What the `Io.Reader` interface reported. Every underlying failure of a
    /// socket read arrives here as `error.ReadFailed`, so this is the coarse
    /// half of the answer.
    read_error: ?anyerror = null,
    /// The error the reader kept for diagnostics, which is the fine half and
    /// the one that says *which* failure it was.
    read_detail: ?anyerror = null,
    got: usize = 0,
    got_buffer: [16]u8 = [_]u8{0} ** 16,
    /// SAFETY: as `WaitCtx.entered`.
    task_stream_closed: bool = false,
    /// SAFETY: as `WaitCtx.entered`.
    task_shutdown_error: ?anyerror = null,
};

fn sockReadTask(c: *SockCtx) void {
    c.entered = true;
    markf("RISC_PROBE_CANCEL_{s}_TASK_ENTER", .{c.stage});
    const stream = c.server.accept(c.io) catch |err| {
        c.accept_error = err;
        markf("RISC_PROBE_CANCEL_{s}_TASK_ACCEPT_ERROR {s}", .{ c.stage, errorName(err) });
        return;
    };
    c.accepted = true;
    markf("RISC_PROBE_CANCEL_{s}_TASK_ACCEPTED", .{c.stage});
    // Everything above this line is a task that can be blocked and released
    // by the executor. The read below is a thread in a kernel read, which is
    // a different mechanism: it can only be left by the cancel, by data, or
    // by the peer going away.
    var buffer: [64]u8 = undefined;
    var reader = stream.reader(c.io, &buffer);
    c.inside.store(1, .release);
    markf("RISC_PROBE_CANCEL_{s}_TASK_READ_BEGIN", .{c.stage});
    // Bound to a name first: `expr catch |err| { ... } else |n| { ... }` is
    // parsed as a labeled block with an `else` arm rather than as the two
    // arms of an error union, because that is what `blk: { ... } else { ... }`
    // means. An `if` over the bound error union says the same thing without
    // the ambiguity.
    const read_result = reader.interface.readSliceShort(&c.got_buffer);
    if (read_result) |n| {
        c.got = n;
        markf("RISC_PROBE_CANCEL_{s}_TASK_READ {d} bytes_from_a_silent_peer", .{ c.stage, n });
    } else |err| {
        c.read_error = err;
        // `@errorCast` because the reader's own error set is a subset of the
        // catch-all one this context stores, and a widened error is what the
        // field is for.
        c.read_detail = if (reader.err) |e| @errorCast(e) else null;
        markf("RISC_PROBE_CANCEL_{s}_TASK_READ_ERROR {s} detail={s}", .{
            c.stage,
            errorName(err),
            errorName(reader.err),
        });
    }
    // The order of the two operations below is the point, on the half of the
    // connection that had the blocked read: a shutdown releases the peer's
    // read deterministically, where a close alone leaves what the peer sees
    // up to the kernel's discretion. Both steps are marked so a stage that
    // dies inside them says which one it was in.
    markf("RISC_PROBE_CANCEL_{s}_TASK_SHUTDOWN_BEGIN", .{c.stage});
    stream.shutdown(c.io, .send) catch |err| {
        c.task_shutdown_error = err;
        markf("RISC_PROBE_CANCEL_{s}_TASK_SHUTDOWN_ERROR {s}", .{ c.stage, errorName(err) });
    };
    markf("RISC_PROBE_CANCEL_{s}_TASK_SHUTDOWN_DONE", .{c.stage});
    markf("RISC_PROBE_CANCEL_{s}_TASK_CLOSE_BEGIN", .{c.stage});
    stream.close(c.io);
    c.task_stream_closed = true;
    markf("RISC_PROBE_CANCEL_{s}_TASK_CLOSED", .{c.stage});
}

/// `sockread`: a blocking read on a real Unix socket, cancelled, with the
/// owner's cleanup asserting the same shutdown-before-close order on the half
/// the owner holds. The client connects and then says nothing, so the task's
/// read has exactly one release: the cancel.
fn stageSockRead(io: Io, tmpdir: []const u8) void {
    const stage = "SOCKREAD";
    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const path = std.fmt.bufPrint(&path_buffer, "{s}/risc-probe-cancel-{x}.sock", .{
        tmpdir,
        std.mem.readInt(u64, &nonce, .little),
    }) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_PATH_ERROR {s}", .{ stage, errorName(err) });
        refused(stage, "socket_path_too_long");
    };
    markf("RISC_PROBE_CANCEL_{s}_PATH dir={s}", .{ stage, tmpdir });
    // A socket file left by a killed run is the one thing in the scratch
    // directory that belongs to this stage, and it would make listen fail.
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            markf("RISC_PROBE_CANCEL_{s}_UNLINK_ERROR {s}", .{ stage, errorName(err) });
            refused(stage, "stale_socket");
        },
    };
    const address = Io.net.UnixAddress.init(path) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_ADDRESS_ERROR {s}", .{ stage, errorName(err) });
        refused(stage, "address_rejected");
    };
    var server = address.listen(io, .{}) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_LISTEN_ERROR {s}", .{ stage, errorName(err) });
        refused(stage, "listen_failed");
    };
    markf("RISC_PROBE_CANCEL_{s}_LISTENED", .{stage});
    var c: SockCtx = .{ .io = io, .server = &server };
    var group: Io.Group = .init;
    group.concurrent(io, sockReadTask, .{&c}) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_SPAWN_ERROR {s}", .{ stage, errorName(err) });
        server.deinit(io);
        refused(stage, "concurrent_refused");
    };
    markf("RISC_PROBE_CANCEL_{s}_SPAWNED", .{stage});
    const client = address.connect(io) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_CONNECT_ERROR {s}", .{ stage, errorName(err) });
        // The task is blocked in `accept` at this point, so the stage is
        // released rather than left with an outstanding task for the harness
        // to kill.
        group.cancel(io);
        server.deinit(io);
        refused(stage, "connect_failed");
    };
    markf("RISC_PROBE_CANCEL_{s}_CONNECTED", .{stage});
    awaitPublished(io, &c.inside, stage, "socket_read");
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_BEGIN task_inside_read={s}", .{
        stage,
        boolText(c.inside.load(.acquire) == 1),
    });
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_DONE", .{stage});
    markf("RISC_PROBE_CANCEL_{s}_OUTCOME entered={s} accepted={s} accept_error={s} read_error={s} read_detail={s} got={d} task_closed={s} task_shutdown_error={s}", .{
        stage,
        boolText(c.entered),
        boolText(c.accepted),
        errorName(c.accept_error),
        errorName(c.read_error),
        errorName(c.read_detail),
        c.got,
        boolText(c.task_stream_closed),
        errorName(c.task_shutdown_error),
    });
    if (!c.accepted) reject(stage, "the_task_never_accepted");
    if (c.read_error == null) reject(stage, "the_read_returned_instead_of_being_cancelled");
    const detail = c.read_detail orelse reject(stage, "the_read_reported_no_underlying_error");
    if (detail != error.Canceled) reject(stage, "the_read_did_not_report_canceled");
    if (!c.task_stream_closed) reject(stage, "the_task_left_its_stream_open");
    // The owner's own half, in the same order the task used on its half.
    markf("RISC_PROBE_CANCEL_{s}_OWNER_SHUTDOWN_BEGIN", .{stage});
    client.shutdown(io, .send) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_OWNER_SHUTDOWN_ERROR {s}", .{ stage, errorName(err) });
    };
    markf("RISC_PROBE_CANCEL_{s}_OWNER_SHUTDOWN_DONE", .{stage});
    markf("RISC_PROBE_CANCEL_{s}_OWNER_CLOSE_BEGIN", .{stage});
    client.close(io);
    markf("RISC_PROBE_CANCEL_{s}_OWNER_CLOSE_DONE", .{stage});
    markf("RISC_PROBE_CANCEL_{s}_LISTENER_CLOSE_BEGIN", .{stage});
    server.deinit(io);
    markf("RISC_PROBE_CANCEL_{s}_LISTENER_CLOSED", .{stage});
    Io.Dir.cwd().deleteFile(io, path) catch |err| {
        markf("RISC_PROBE_CANCEL_{s}_UNLINK_AFTER_ERROR {s}", .{ stage, errorName(err) });
    };
    markf("RISC_PROBE_CANCEL_{s}_CLEANUP_DONE", .{stage});
    group.cancel(io);
    markf("RISC_PROBE_CANCEL_{s}_CANCEL_AGAIN_DONE", .{stage});
}

const stage_names = [_][]const u8{
    "done",
    "cond",
    "early",
    "event",
    "sleep",
    "sockread",
    // The three stages below repeat the boundaries the library test is made
    // of, on the library test's own allocator. See `main`.
    "debug-done",
    "debug-condition",
    "debug-condition-no-trace",
};

/// Runs the stage named by `stage`. Split out of `main` so that both
/// allocators reach one copy of the ladder: a difference between the page
/// allocator and the testing allocator then has to be a difference in the
/// allocator, and not a difference between two copies of the same stages.
fn runStage(stage: []const u8, io: Io, init: std.process.Init) void {
    if (std.mem.eql(u8, stage, "done")) {
        stageDone(io, "DONE");
    } else if (std.mem.eql(u8, stage, "cond")) {
        stagePendingWait(io, "COND", true);
    } else if (std.mem.eql(u8, stage, "early")) {
        // No gate, deliberately: this is the library's ordering, and the
        // stage's value is that the cancel arrives with no guarantee about
        // where the task is.
        stagePendingWait(io, "EARLY", false);
    } else if (std.mem.eql(u8, stage, "event")) {
        stageEvent(io);
    } else if (std.mem.eql(u8, stage, "sleep")) {
        stageSleep(io);
    } else if (std.mem.eql(u8, stage, "sockread")) {
        stageSockRead(io, init.minimal.environ.getPosix("TMPDIR") orelse "/tmp");
    } else if (std.mem.eql(u8, stage, "debug-done")) {
        stageDone(io, "DEBUGDONE");
    } else if (std.mem.eql(u8, stage, "debug-condition")) {
        // The gated ordering, on the testing allocator. Ungated as well
        // would be a third copy of one boundary; the page allocator's
        // `early` stage already covers that ordering.
        stagePendingWait(io, "DEBUGCOND", true);
    } else if (std.mem.eql(u8, stage, "debug-condition-no-trace")) {
        // The same boundary as `debug-condition`, on the same allocator, with
        // the one option that decides whether an allocation captures a stack
        // trace. Nothing else about the stage changes.
        stagePendingWait(io, "DEBUGCOND_NOTRACE", true);
    }
}

/// Runs the stage and then the executor's teardown, both bracketed by
/// markers. Not deferred, on purpose: a `defer` would run the teardown after
/// the stage's own last marker and on the refusal paths too, and this is the
/// last boundary the probe has. A stage that printed `_DEINIT_BEGIN` and
/// never printed `_DEINIT_DONE` died inside `Threaded.deinit`; a stage that
/// never printed the begin marker died before it. An explicit call makes
/// both answers visible, and it is why `threaded` is taken by pointer here:
/// `Threaded.deinit` overwrites its receiver with `undefined`, so nothing may
/// touch it afterwards, and in particular the allocator that built it must
/// outlive this call and not be read back through it.
fn runStageAndDeinit(stage: []const u8, threaded: *Io.Threaded, init: std.process.Init) void {
    runStage(stage, threaded.io(), init);
    markf("RISC_PROBE_CANCEL_STAGE_OK stage={s}\n", .{stage});
    markf("RISC_PROBE_CANCEL_DEINIT_BEGIN stage={s}\n", .{stage});
    threaded.deinit();
    markf("RISC_PROBE_CANCEL_DEINIT_DONE stage={s}\n", .{stage});
    markf("RISC_PROBE_CANCEL_EXIT stage={s} code={d}\n", .{ stage, @as(u8, 0) });
}

/// Runs the stage on an executor built from a `DebugAllocator` configured by
/// `config`. The configuration is a comptime parameter because the
/// allocator's *type* is its configuration, so a call site passes a struct
/// literal and its values are checked against the real field types there
/// instead of being inferred from the literal alone. `DebugAllocatorConfig`
/// is that same `Config`, re-exported (std/heap.zig:19).
fn runDebugStage(
    comptime config: std.heap.DebugAllocatorConfig,
    stage: []const u8,
    init: std.process.Init,
) void {
    var debug_allocator: std.heap.DebugAllocator(config) = .init;
    // The configuration is in the marker, so a run that says which stage it
    // was also says which allocator options it ran under without the reader
    // having to trust that the stage name implied them.
    markf("RISC_PROBE_CANCEL_ALLOCATOR debug stage={s} stack_trace_frames={d} canary={x}\n", .{
        stage,
        config.stack_trace_frames,
        config.canary,
    });
    var threaded: Io.Threaded = .init(debug_allocator.allocator(), .{});
    runStageAndDeinit(stage, &threaded, init);
    // The leak check is a marker of its own rather than part of the exit
    // status: an allocation the executor did not give back after a cancelled
    // task is a finding about the boundary, not a failure of it, and the
    // reader has to be able to see it without the run being scored wrong.
    // The allocator is deinited here and not in a `defer`, for the same
    // reason the executor is: a stage that never got here has already said
    // where it stopped.
    markf("RISC_PROBE_CANCEL_{s}_ALLOCATOR_CHECK {t}\n", .{ stage, debug_allocator.deinit() });
}

pub fn main(init: std.process.Init) !void {
    // `std.process.Init` is the only way to reach `argv` in this compiler, so
    // it is used for the stage selector and the temporary directory and for
    // nothing else. Every boundary below runs on a privately constructed
    // `Io.Threaded`, the same one the failing library test builds at
    // `src/conn.zig:1595`, so a difference between this probe and the test
    // cannot be an executor difference.
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const stage_arg = args.next() orelse {
        mark("RISC_PROBE_CANCEL_USAGE expected one of: done cond early event sleep sockread debug-done debug-condition debug-condition-no-trace\n");
        std.process.exit(4);
    };
    if (args.next() != null) {
        mark("RISC_PROBE_CANCEL_USAGE expected exactly one stage name\n");
        std.process.exit(4);
    }
    // A direct coercion, not `std.mem.span`: `Span` takes sentinel
    // *pointers* only, and a `[:0]const u8` value is a slice pointer, which
    // `mem.zig:859` rejects outright.
    const stage: []const u8 = stage_arg;
    var known = false;
    for (stage_names) |name| {
        if (std.mem.eql(u8, stage, name)) known = true;
    }
    if (!known) {
        markf("RISC_PROBE_CANCEL_USAGE unknown_stage {s}\n", .{stage});
        std.process.exit(4);
    }
    markf("RISC_PROBE_CANCEL_ENTER stage={s}\n", .{stage});
    const cpu_count = std.Thread.getCpuCount() catch null;
    if (cpu_count) |n| markf("RISC_PROBE_CANCEL_ENV cpu_count={d}\n", .{n});

    if (std.mem.eql(u8, stage, "debug-done") or
        std.mem.eql(u8, stage, "debug-condition") or
        std.mem.eql(u8, stage, "debug-condition-no-trace"))
    {
        // The failing library test builds its executor on
        // `std.testing.allocator` (`src/conn.zig:1595`) and every other stage
        // here builds its own on the page allocator. The executor allocates
        // through whichever allocator it was given, so a cancel that is only
        // broken on one of them is a different cause than a cancel that is
        // broken on both — and which one it is, is not something the page
        // allocator stages can say. These stages exist to say it, and only for
        // the boundaries the library test is made of: the completed cancel
        // (`debug-done`) and the pending cancel (`debug-condition`, and the
        // same boundary again with stack traces off on the allocations,
        // `debug-condition-no-trace`). Every other boundary is deliberately
        // not repeated, because the ladder is a diagnostic and a second copy
        // of each stage would double the run for one extra bit of evidence.
        //
        // The options are the ones `std.testing.allocator` is constructed
        // with in this compiler (std/testing.zig), reproduced field for
        // field rather than defaulted, so that this is the testing
        // allocator's behaviour and not a debug allocator's. The canary in
        // particular is part of the identity: a default-constructed
        // `DebugAllocator` handed where the testing allocator belongs is
        // meant to panic, and a default one here would not be the allocator
        // the test uses. It is not `std.testing.allocator` itself because
        // that one refuses to exist outside a test build.
        //
        // `debug-condition-no-trace` is the one competing cause this can
        // separate on its own: with frames configured, every allocation the
        // executor makes captures a stack trace, and capturing one on this
        // target is itself code that has never run here. Same allocator, same
        // canary, same resize behaviour, same boundary, same ordering — the
        // only difference is whether an allocation walks the frame pointer.
        // If the pending cancel passes there and fails in `debug-condition`,
        // the trace capture is where to look, and nothing else in this file
        // can say so.
        if (std.mem.eql(u8, stage, "debug-condition-no-trace")) {
            runDebugStage(.{
                .stack_trace_frames = 0,
                .resize_stack_traces = true,
                .canary = @truncate(0x2731e675c3a701ba),
            }, stage, init);
        } else {
            runDebugStage(.{
                .stack_trace_frames = if (std.debug.sys_can_stack_trace) 10 else 0,
                .resize_stack_traces = true,
                .canary = @truncate(0x2731e675c3a701ba),
            }, stage, init);
        }
    } else {
        // `page_allocator` and not a debug allocator: this probe is killed by
        // faults, and an allocator that reports on exit would add a second
        // reporting path to a run whose whole value is that its markers
        // survive. The `debug-` stages are where the allocator that reports
        // is exercised, and they are bounded the same way.
        markf("RISC_PROBE_CANCEL_ALLOCATOR page stage={s}\n", .{stage});
        var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
        runStageAndDeinit(stage, &threaded, init);
    }
}
