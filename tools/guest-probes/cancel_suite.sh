#!/bin/sh
# Guest-side driver for the cancellation boundary probe (`cancel.zig`).
#
# This is a throwaway diagnostic harness, not the suite runner. It runs one
# boundary per process, each under a bounded timeout, from a writable
# working directory, and reports the exact exit status of each. It deliberately
# emits no `ZAP_GUEST_*` receipt: the suite's receipt parser treats those as a
# full-suite claim, and a probe run is not one. Every marker here is prefixed
# `RISC_PROBE_CANCEL_` so the two never collide on the same console.
#
# One stage per process is the whole point of the stage selector in the
# probe. A stage that hangs takes only its own process with it, and the
# boundaries after it still run and still answer: the console ends up saying
# which stage stopped and which stages passed, instead of saying nothing after
# the first one that did not come back.
#
# Each stage is expected to either print its closing `RISC_PROBE_CANCEL_EXIT`
# line and exit 0, or print a `RISC_PROBE_CANCEL_*_FAIL` /
# `..._REFUSED` line and exit 3 / 4. A stage that prints neither and dies
# with a signal is the interesting case: that is a fault inside the boundary
# it had reached, and the `RISC_PROBE_CANCEL_LAST` line names it — the last
# marker the process managed to write, which for a fault in `Group.cancel` is
# the `_CANCEL_BEGIN` marker and for a fault in `Threaded.deinit` is the
# `_DEINIT_BEGIN` one.
#
# Usage: cancel_suite.sh [stage ...]
#   With no arguments every stage runs, in ladder order: `done` first, because
#   a cancel on a group with nothing pending is the floor under all the
#   others, and `early` before the others that wait on a gate, because it is
#   the ordering the library test itself uses.
#   PROBE_DIR overrides where the binary is looked for.
#   RISC_PROBE_SCRATCH overrides the writable directory; it is validated
#   before anything is deleted from it.
#
# The three `debug-` stages are not in that default ladder. `debug-done` and
# `debug-condition` repeat the two boundaries the failing library test is made
# of — the completed cancel and the pending one — on the allocator that test
# builds its executor with (`std.testing.allocator`), because the allocator is
# a competing cause for a fault the page-allocator stages cannot tell apart
# from a broken cancel. `debug-condition-no-trace` is the pending boundary
# again on that same allocator with the one option that decides whether an
# allocation captures a stack trace, which on this target is itself code that
# has never run here. All three are opt-in so the default run stays one
# boundary per process; ask for them by name when the ladder itself has passed
# and the allocator or the trace capture is the next question.

set -u

# The probes are diagnostics: a core file costs more disk than it explains.
ulimit -c 0 2>/dev/null || true

scratch=${RISC_PROBE_SCRATCH:-/home/cross-probe-scratch}
# The payload is read-only and the probe needs a writable directory: the socket
# stage binds a file under TMPDIR. Each stage also runs with stdin closed so
# it can never swallow the console input the caller is driving.
# This name is a delete target, so it is validated before anything is removed:
# absolute, at least two components deep, free of `..` components, and not the
# payload this script was mounted from. A path that fails any of those is a
# setup failure rather than a recursive delete of something the caller did not
# mean to hand over.
case $scratch in
    /*) ;;
    *)
        echo RISC_PROBE_CANCEL_SETUP_FAILED scratch_not_absolute
        exit 1
        ;;
esac
case "/$scratch/" in
    */../*)
        echo RISC_PROBE_CANCEL_SETUP_FAILED scratch_has_parent_component
        exit 1
        ;;
esac
depth=0
rest=${scratch#/}
rest=${rest%/}
while [ -n "$rest" ]; do
    depth=$((depth + 1))
    case $rest in
        */*) rest=${rest#*/} ;;
        *) rest= ;;
    esac
done
if [ "$depth" -lt 2 ] || [ "$scratch" = "/home/cross-data" ]; then
    echo RISC_PROBE_CANCEL_SETUP_FAILED scratch_not_probe_owned
    exit 1
fi
if ! mkdir -p "$scratch"; then
    echo RISC_PROBE_CANCEL_SETUP_FAILED scratch
    exit 1
fi
# Only this probe's own leftovers go: a socket from a killed run is the one
# thing that belongs here, and anything else in the directory is left exactly
# as it was found.
for stale in "$scratch"/risc-probe-cancel-*.sock; do
    [ -e "$stale" ] || continue
    rm -f "$stale" || true
done
TMPDIR=$scratch
export TMPDIR
if ! cd "$scratch"; then
    echo RISC_PROBE_CANCEL_SETUP_FAILED cd
    exit 1
fi

probe_dir() {
    if [ -n "${PROBE_DIR:-}" ]; then
        printf '%s\n' "$PROBE_DIR"
        return
    fi
    for dir in /home/cross-data/probes /home/cross-data; do
        if [ -d "$dir" ]; then
            printf '%s\n' "$dir"
            return
        fi
    done
}

dir=$(probe_dir)
echo "RISC_PROBE_CANCEL_DIR $dir"
probe=$dir/cancel

if [ $# -gt 0 ]; then
    stages=$*
else
    stages="done cond early event sleep sockread"
fi

# Every stage must run bounded. Without `timeout(1)` a hung stage takes the
# whole guest boot with it, and its unfinished boundary then looks exactly
# like a guest that never answered, which is the ambiguity this harness exists
# to remove. FreeBSD base ships `/usr/bin/timeout`, so a missing one is a
# broken guest rather than a capability to work around: it is reported as a
# setup failure instead of falling back to an unbounded run.
if [ ! -x /usr/bin/timeout ]; then
    echo RISC_PROBE_CANCEL_SETUP_FAILED missing_timeout
    exit 1
fi
runner="/usr/bin/timeout 120"

# A stage name the probe does not have is caught here rather than run: the
# probe would refuse it in well under a second, but a misspelling in a list
# of stage names is easier to see when it never became a process.
known_stage() {
    case $1 in
        done|cond|early|event|sleep|sockread|debug-done|debug-condition|debug-condition-no-trace) return 0 ;;
        *) return 1 ;;
    esac
}

# The exit status a stage ended on, and what that status means for the
# boundary. Reported inline so a reader of the console does not have to hold a
# table to tell a wrong answer from a crash from a refusal.
describe() {
    case $1 in
        0) echo "every assertion in the stage held" ;;
        3) echo "a stage completed and rejected its result" ;;
        4) echo "a stage was refused before it ran" ;;
        124) echo "killed by the stage timeout: the boundary hung" ;;
        132) echo "SIGILL" ;;
        133) echo "SIGTRAP" ;;
        134) echo "SIGABRT: panic or failed assertion" ;;
        135) echo "SIGBUS" ;;
        136) echo "SIGFPE" ;;
        137) echo "SIGKILL" ;;
        139) echo "SIGSEGV" ;;
        126) echo "not executable" ;;
        127) echo "not found" ;;
        *) echo "see the markers above" ;;
    esac
}

failures=0
for stage in $stages; do
    if ! known_stage "$stage"; then
        echo "RISC_PROBE_CANCEL_UNKNOWN_STAGE $stage"
        failures=$((failures + 1))
        continue
    fi
    if [ ! -f "$probe" ]; then
        echo "RISC_PROBE_CANCEL_ABSENT $probe"
        failures=$((failures + 1))
        continue
    fi
    if [ ! -x "$probe" ]; then
        echo "RISC_PROBE_CANCEL_NOT_EXECUTABLE $probe"
        failures=$((failures + 1))
        continue
    fi
    echo "RISC_PROBE_CANCEL_BEGIN $stage"
    # stdout and stderr go to this stage's own log and the log is printed
    # afterwards: the markers are written with one unbuffered `write(2)` each,
    # so a stage that was killed has already written every marker it reached,
    # and printing them in one go keeps the console ordered even when a stage
    # died mid-line.
    log=$scratch/cancel-$stage.log
    $runner "$probe" "$stage" </dev/null >"$log" 2>&1
    status=$?
    cat "$log"
    echo "RISC_PROBE_CANCEL_END $stage $status $(describe "$status")"
    # The last marker the process managed to write, which is the precise
    # answer to "how far did it get": a stage killed inside `Group.cancel`
    # ends on `_CANCEL_BEGIN`, one killed inside `Threaded.deinit` ends on
    # `_DEINIT_BEGIN`, and one that hung in a gate ends on `_GATE_GAVE_UP`.
    last=$(grep '^RISC_PROBE_CANCEL_' "$log" | tail -n 1)
    echo "RISC_PROBE_CANCEL_LAST $stage ${last:-none}"
    if [ "$status" -ne 0 ]; then
        failures=$((failures + 1))
    fi
done

echo "RISC_PROBE_CANCEL_COMPLETE $failures"
[ "$failures" -eq 0 ]
