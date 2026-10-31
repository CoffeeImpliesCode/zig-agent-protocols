//! Boundary probe: does raw `std.Thread` work on this FreeBSD riscv64 guest?
//!
//! This file is a throwaway diagnostic, not a test and not library code. It
//! answers one question, deliberately separated from every other boundary in
//! the failure: can the process create, run and join a raw OS thread at all?
//! Nothing here touches `std.Io` after the environment line — so a fault in
//! this file is a fault in the thread or thread-local path itself, not in the
//! executor, the task pool or a socket.
//!
//! The stages run in ladder order, cheapest boundary first:
//!
//!   T  thread-local storage, touched from a spawned thread. Nothing else runs
//!      first, because the repeated low offset in the fault addresses across
//!      separately linked executables is the shape of a bad thread-local
//!      relocation or a bad thread pointer: the offset within a per-thread
//!      block is fixed even when the block's base is not.
//!   A  one `spawn`/`join` pair with a checked result.
//!   B  four threads at once, joined in order, sharing an atomic counter, so
//!      a lost update is distinguishable from a thread that never ran.
//!   C  a thread that spawns and joins its own thread, so any per-thread state
//!      established by the first spawn has to survive being used as the base
//!      for a second one.
//!
//! The sibling `concurrent.zig` picks up where this one stops: `std.Io`
//! tasks, the thread pool, `Io.Mutex`/`Io.Condition`, and a real Unix socket.
//! The first probe that does not print its closing marker is the boundary that
//! broke; a probe killed by a signal never prints one at all, which is why
//! every boundary is bracketed by markers instead of relying on the exit
//! status alone.
//!
//! Every stage asserts completed work, not merely the absence of a throw. A
//! stage that ran but computed the wrong answer reports the value it got, so
//! "the thread ran and produced a wrong answer" is distinguishable from "the
//! thread never ran".
//!
//! Markers go out with a raw `write(2)` rather than through `std.Io.File` or
//! `std.debug`. `std.Progress` installs a background thread and a tty check
//! that can suppress or interleave buffered output during a crash unwind, and
//! this file's entire value is that its output survives the fault it is
//! reporting.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn write(fd: c_int, buffer: [*]const u8, length: usize) isize;

/// Serializes marker emission across threads so a line is never split by an
/// interleaved write. The spin is bounded: a probe exists to be killed by a
/// fault, and it must not be turned into a hang by its own diagnostics. A
/// marker written after the bound is emitted unsynchronized, which is a
/// visibly torn line rather than a silent omission.
var mark_lock = std.atomic.Value(u32).init(0);

/// Two thread-local slots and nothing else. The fault being chased shows the
/// same low offset in its address across several differently linked
/// executables, which is what a broken thread-pointer or a broken
/// thread-local relocation looks like: the offset within the per-thread
/// block is fixed even though the block's base is not. Reading and writing
/// these from a spawned thread tests that mechanism on its own, with no
/// `std.Thread`, no executor and no library code in the path, so a fault here
/// is a fault in thread-local access and nowhere else.
threadlocal var tls_value: u64 = 0;
threadlocal var tls_anchor: u64 = 0;

/// Set by a spawned thread to the address of its own `tls_value` slot. The
/// main thread compares it against its own, because two threads resolving the
/// same address for a thread-local would make every later check meaningless.
var tls_slot_address: usize = 0;

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

/// The work each thread does, and the thread count, shared by stages A and B
/// so the two stages cannot disagree about how much work was asked for. A
/// stage B that loses an atomic update reports a total below
/// `expected_total`, which is a memory-model failure rather than a lost
/// thread: every thread that ran also wrote its own slot, and a thread that
/// never ran leaves that slot at zero.
const per_thread = 50_000;
const threads = 4;
const expected_total = per_thread * threads;

const A = struct {
    // SAFETY: written only by the worker, read only after `join` returns.
    sum: u64 = 0,
    // SAFETY: as `sum`.
    tid: std.Thread.Id = 0,
    // SAFETY: as `sum`.
    ran: bool = false,
};

const B = struct {
    // SAFETY: written only by the worker, read only after `join` returns.
    // One slot per thread: a shared counter alone cannot tell "a thread lost
    // its updates" from "a thread never ran".
    slot: u64 = 0,
    // SAFETY: as `slot`.
    tid: std.Thread.Id = 0,
};

const Inner = struct {
    // SAFETY: written only by the inner worker, read only after its `join`
    // inside the outer worker returns.
    sum: u64 = 0,
    // SAFETY: as `sum`.
    tid: std.Thread.Id = 0,
};

const Outer = struct {
    // SAFETY: written only by the outer worker, read only after `join`
    // returns in the main thread.
    inner_sum: u64 = 0,
    // SAFETY: as `inner_sum`.
    inner_tid: std.Thread.Id = 0,
    // SAFETY: as `inner_sum`.
    tid: std.Thread.Id = 0,
    // SAFETY: as `inner_sum`. The outer worker sets this rather than aborting,
    // so a nested-spawn fault is reported as a value instead of a dead join.
    join_failed: bool = false,
};

/// Deterministic, order-independent work: a plain accumulate. The main thread
/// computes the same value and compares, so a worker that ran on a thread with
/// a broken stack or a clobbered callee-saved register cannot pass by accident.
fn accumulate(iterations: u32) u64 {
    var sum: u64 = 0;
    for (0..iterations) |i| sum +%= @as(u64, i) *% 3 +% 1;
    return sum;
}

/// The value the worker writes into its own copy of `tls_value`. The main
/// thread asserts its own copy still reads zero afterwards, so a thread-local
/// that is not actually per-thread is caught by the value as well as by the
/// address.
const tls_probe_value: u64 = 0x7f1e_1e00_0000_0001;

fn workerA(slot: *A) void {
    mark("RISC_PROBE_THREAD_A_WORKER_ENTER\n");
    slot.sum = accumulate(per_thread);
    slot.tid = std.Thread.getCurrentId();
    slot.ran = true;
    markf("RISC_PROBE_THREAD_A_WORKER_DONE sum={d} tid={d}", .{ slot.sum, slot.tid });
}

/// Touches only the two thread-local slots. The write must land in this
/// thread's copy and nowhere else, and the slot's address must differ from
/// the main thread's; a thread-local that resolved to one shared address, or
/// to an address derived from a bad thread pointer, shows up here as a wrong
/// value or a repeated address rather than as a crash somewhere later.
fn workerTls() void {
    markf("RISC_PROBE_THREAD_TLS_WORKER_ENTER slot=0x{x}\n", .{@intFromPtr(&tls_value)});
    tls_value = tls_probe_value;
    tls_anchor = @intFromPtr(&tls_value);
    markf("RISC_PROBE_THREAD_TLS_WORKER_WROTE value=0x{x} anchor=0x{x}\n", .{ tls_value, tls_anchor });
    tls_slot_address = @intFromPtr(&tls_value);
    mark("RISC_PROBE_THREAD_TLS_WORKER_DONE\n");
}

fn workerB(shared: *std.atomic.Value(u64), slot: *B) void {
    markf("RISC_PROBE_THREAD_B_WORKER_ENTER tid={d}", .{std.Thread.getCurrentId()});
    var local: u64 = 0;
    for (0..per_thread) |_| {
        // A relaxed-increment / acquire-load pair, the shape the executor's
        // own work queues use. Each thread keeps a private count so its own
        // slot proves it ran to completion regardless of what the shared
        // counter lost.
        local += 1;
        _ = shared.fetchAdd(1, .monotonic);
    }
    slot.slot = local;
    slot.tid = std.Thread.getCurrentId();
    markf("RISC_PROBE_THREAD_B_WORKER_DONE local={d}", .{local});
}

fn innerWorker(slot: *Inner) void {
    markf("RISC_PROBE_THREAD_C_INNER_ENTER tid={d}", .{std.Thread.getCurrentId()});
    slot.sum = accumulate(1_000);
    slot.tid = std.Thread.getCurrentId();
    markf("RISC_PROBE_THREAD_C_INNER_DONE sum={d}", .{slot.sum});
}

fn outerWorker(slot: *Outer) void {
    markf("RISC_PROBE_THREAD_C_OUTER_ENTER tid={d}", .{std.Thread.getCurrentId()});
    slot.tid = std.Thread.getCurrentId();
    // The nested spawn is the point of this stage: a second `pthread_create`
    // issued from a thread that is itself not the main thread, so any
    // per-thread state the first spawn established has to survive being used
    // as the base for another one.
    var inner: Inner = .{};
    const inner_thread = std.Thread.spawn(.{}, innerWorker, .{&inner}) catch {
        mark("RISC_PROBE_THREAD_C_INNER_SPAWN_FAILED\n");
        slot.join_failed = true;
        return;
    };
    mark("RISC_PROBE_THREAD_C_INNER_SPAWNED\n");
    inner_thread.join();
    mark("RISC_PROBE_THREAD_C_INNER_JOINED\n");
    slot.inner_sum = inner.sum;
    slot.inner_tid = inner.tid;
    markf("RISC_PROBE_THREAD_C_OUTER_DONE inner_sum={d}", .{slot.inner_sum});
}

pub fn main(init: std.process.Init) !void {
    mark("RISC_PROBE_THREAD_ENTER\n");

    const main_tid = std.Thread.getCurrentId();
    // `getCpuCount` is the call `Io.Threaded.init` makes to size its async
    // pool, so a failure here is a fact the sibling probe needs rather than a
    // fact this file can act on.
    const cpus = std.Thread.getCpuCount() catch |err| blk: {
        markf("RISC_PROBE_THREAD_ENV cpu_count_error={t}", .{err});
        break :blk @as(?usize, null);
    };
    if (cpus) |n| markf("RISC_PROBE_THREAD_ENV cpu_count={d}", .{n});
    markf("RISC_PROBE_THREAD_ENV tid={d} single_threaded={s} use_pthreads={s} pointer_bits={d}", .{ main_tid, boolText(builtin.single_threaded), boolText(std.Thread.use_pthreads), @bitSizeOf(usize) });
    // The executor is received, not constructed: this probe must observe the
    // same `Io` the real test roots get from `std.start`, so that a difference
    // between the suite and this file cannot be an executor difference.
    markf("RISC_PROBE_THREAD_ENV io_userdata_nonnull={s}\n", .{boolText(init.io.userdata != null)});

    // ---- stage T: thread-local storage, before any thread exists ----------
    // Cheapest boundary first, and the one the repeated fault-address offset
    // points at. If this fails, every later stage's result is unreadable: a
    // thread-local that does not resolve correctly corrupts the executor's
    // own per-task state, which is what the later stages are built on.
    markf("RISC_PROBE_THREAD_TLS_MAIN_SLOT slot=0x{x} value={d}\n", .{ @intFromPtr(&tls_value), tls_value });
    const t_thread = std.Thread.spawn(.{}, workerTls, .{}) catch |err| {
        markf("RISC_PROBE_THREAD_TLS_SPAWN_ERROR {t}\n", .{err});
        std.process.exit(4);
    };
    mark("RISC_PROBE_THREAD_TLS_SPAWNED\n");
    t_thread.join();
    mark("RISC_PROBE_THREAD_TLS_JOINED\n");
    if (tls_slot_address == @intFromPtr(&tls_value)) reject("T", "shared_thread_local_slot");
    if (tls_slot_address == 0) reject("T", "null_thread_local_slot");
    if (tls_value != 0) reject("T", "worker_leaked_into_main_slot");
    markf("RISC_PROBE_THREAD_TLS_OK main=0x{x} worker=0x{x}\n", .{ @intFromPtr(&tls_value), tls_slot_address });

    // ---- stage A: one thread, joined, with a checked result ----------------
    mark("RISC_PROBE_THREAD_A_SPAWN_BEGIN\n");
    var a: A = .{};
    const a_thread = std.Thread.spawn(.{}, workerA, .{&a}) catch |err| {
        markf("RISC_PROBE_THREAD_A_SPAWN_ERROR {t}\n", .{err});
        std.process.exit(4);
    };
    mark("RISC_PROBE_THREAD_A_SPAWNED\n");
    a_thread.join();
    mark("RISC_PROBE_THREAD_A_JOINED\n");
    if (!a.ran) reject("A", "worker_never_ran");
    if (a.sum != accumulate(per_thread)) reject("A", "wrong_sum");
    if (a.tid == main_tid or a.tid == 0) reject("A", "thread_id_not_distinct");
    markf("RISC_PROBE_THREAD_A_OK sum={d} tid={d}\n", .{ a.sum, a.tid });

    // ---- stage B: several threads at once, joined in order -----------------
    markf("RISC_PROBE_THREAD_B_SPAWN_BEGIN threads={d} per_thread={d}\n", .{ threads, per_thread });
    var shared = std.atomic.Value(u64).init(0);
    var b: [threads]B = undefined;
    for (&b) |*slot| slot.* = .{};
    var b_threads: [threads]std.Thread = undefined;
    var spawned: usize = 0;
    for (&b_threads, 0..) |*thread, i| {
        thread.* = std.Thread.spawn(.{}, workerB, .{ &shared, &b[i] }) catch |err| {
            markf("RISC_PROBE_THREAD_B_SPAWN_ERROR index={d} err={t}\n", .{ i, err });
            for (b_threads[0..spawned]) |done| done.join();
            std.process.exit(4);
        };
        spawned += 1;
    }
    markf("RISC_PROBE_THREAD_B_SPAWNED count={d}\n", .{spawned});
    for (b_threads) |thread| thread.join();
    mark("RISC_PROBE_THREAD_B_JOINED\n");
    for (b, 0..) |slot, i| {
        if (slot.slot != per_thread) reject("B", "worker_short_run");
        if (slot.tid == main_tid or slot.tid == 0) reject("B", "thread_id_not_distinct");
        if (slot.tid == b[(i + 1) % threads].tid) reject("B", "duplicate_thread_id");
    }
    const total = shared.load(.acquire);
    if (total != expected_total) {
        markf("RISC_PROBE_THREAD_B_COUNTER total={d} expected={d}\n", .{ total, expected_total });
        reject("B", "lost_atomic_updates");
    }
    markf("RISC_PROBE_THREAD_B_OK total={d}\n", .{total});

    // ---- stage C: a thread that spawns and joins its own thread ------------
    mark("RISC_PROBE_THREAD_C_OUTER_SPAWN_BEGIN\n");
    var c: Outer = .{};
    const c_thread = std.Thread.spawn(.{}, outerWorker, .{&c}) catch |err| {
        markf("RISC_PROBE_THREAD_C_OUTER_SPAWN_ERROR {t}\n", .{err});
        std.process.exit(4);
    };
    mark("RISC_PROBE_THREAD_C_OUTER_SPAWNED\n");
    c_thread.join();
    mark("RISC_PROBE_THREAD_C_OUTER_JOINED\n");
    if (c.join_failed) reject("C", "nested_spawn_failed");
    if (c.tid == main_tid or c.tid == 0) reject("C", "outer_thread_id_not_distinct");
    if (c.inner_tid == c.tid or c.inner_tid == 0) reject("C", "inner_thread_id_not_distinct");
    if (c.inner_sum != accumulate(1_000)) reject("C", "wrong_sum");
    markf("RISC_PROBE_THREAD_C_OK outer={d} inner={d}\n", .{ c.tid, c.inner_tid });

    markf("RISC_PROBE_THREAD_EXIT {d}\n", .{@as(u8, 0)});
}
