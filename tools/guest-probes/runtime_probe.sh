#!/bin/sh
# Guest-side driver for the riscv64 boundary probes.
#
# This is a throwaway diagnostic harness, not the suite runner. It runs each
# probe binary once, under a bounded timeout, from a writable working
# directory, and reports the exact exit status of each one. It deliberately
# emits no `ZAP_GUEST_*` receipt: the suite's receipt parser treats those as a
# full-suite claim, and a probe run is not one. Every marker here is prefixed
# `RISC_PROBE_` so the two never collide on the same console.
#
# Each probe answers one boundary and is expected to either print its closing
# `RISC_PROBE_*_EXIT 0` line and exit 0, or print a `RISC_PROBE_FAIL` /
# `RISC_PROBE_REFUSED` line and exit 3 / 4 / 5. A probe that prints neither and
# dies with a signal is the interesting case: that is a fault inside the
# boundary it had reached, and the marker printed immediately before it says
# which boundary.
#
# Usage: runtime_probe.sh [name ...]
#   With no arguments both probes run, in ladder order: the raw-thread probe
#   first, because a fault there makes every later boundary meaningless.
#   PROBE_DIR overrides where the binaries are looked for.
#   RISC_PROBE_SCRATCH overrides the writable directory; it is validated before
#   anything is deleted from it.

set -u

# The probes are diagnostics: a core file costs more disk than it explains.
ulimit -c 0 2>/dev/null || true

scratch=${RISC_PROBE_SCRATCH:-/home/cross-probe-scratch}
# The payload is read-only and the probes need a writable directory: the socket
# stage binds a file under TMPDIR. Each probe also runs with stdin closed so it
# can never swallow the console input the caller is driving.
# This name is a delete target, so it is validated before anything is removed:
# absolute, at least two components deep, free of `..` components, and not the
# payload this script was mounted from. A path that fails any of those is a
# setup failure rather than a recursive delete of something the caller did not
# mean to hand over.
case $scratch in
    /*) ;;
    *)
        echo RISC_PROBE_SETUP_FAILED scratch_not_absolute
        exit 1
        ;;
esac
case "/$scratch/" in
    */../*)
        echo RISC_PROBE_SETUP_FAILED scratch_has_parent_component
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
    echo RISC_PROBE_SETUP_FAILED scratch_not_probe_owned
    exit 1
fi
if ! mkdir -p "$scratch"; then
    echo RISC_PROBE_SETUP_FAILED scratch
    exit 1
fi
# Only this probe's own leftovers go: a socket from a killed run is the one
# thing that belongs here, and anything else in the directory is left exactly
# as it was found. That is also why the directory is no longer chmod'ed —
# nothing but the probes' own sockets is ever removed from it.
for stale in "$scratch"/risc-probe-*.sock; do
    [ -e "$stale" ] || continue
    rm -f "$stale" || true
done
TMPDIR=$scratch
export TMPDIR
if ! cd "$scratch"; then
    echo RISC_PROBE_SETUP_FAILED cd
    exit 1
fi

probe_dir() {
    if [ -n "${PROBE_DIR:-}" ]; then
        printf '%s\n' "$PROBE_DIR"
        return
    fi
    for dir in /home/cross-data/probes /home/cross-data/tests /home/cross-data; do
        if [ -d "$dir" ]; then
            printf '%s\n' "$dir"
            return
        fi
    done
}

dir=$(probe_dir)
echo "RISC_PROBE_DIR $dir"

if [ $# -gt 0 ]; then
    names=$*
else
    names="thread concurrent"
fi

# Every probe must run bounded. Without `timeout(1)` a hung probe takes the
# whole guest boot with it, and its unfinished stage then looks exactly like a
# guest that never answered, which is the ambiguity this harness exists to
# remove. FreeBSD base ships `/usr/bin/timeout`, so a missing one means a
# broken guest rather than a capability to work around: it is reported as a
# setup failure instead of falling back to an unbounded run.
if [ ! -x /usr/bin/timeout ]; then
    echo RISC_PROBE_SETUP_FAILED missing_timeout
    exit 1
fi
runner="/usr/bin/timeout 120"

# The exit status a probe ended on, and what that status means for the
# boundary. Reported inline so a reader of the console does not have to hold a
# table to tell a wrong answer from a crash from a refusal.
describe() {
    case $1 in
        0) echo "all boundaries completed" ;;
        3) echo "a boundary completed and rejected its result" ;;
        4) echo "a boundary was refused before it ran" ;;
        5) echo "Io.concurrent refused: executor configuration" ;;
        124) echo "killed by the probe timeout: boundary hung" ;;
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
for name in $names; do
    probe=$dir/$name
    if [ ! -f "$probe" ]; then
        echo "RISC_PROBE_ABSENT $name"
        failures=$((failures + 1))
        continue
    fi
    if [ ! -x "$probe" ]; then
        echo "RISC_PROBE_NOT_EXECUTABLE $name"
        failures=$((failures + 1))
        continue
    fi
    echo "RISC_PROBE_BEGIN $name"
    # stdin is closed so a probe can never swallow the console input the
    # caller is sending; stdout and stderr are merged so a panic message on
    # stderr lands in the same stream as the markers.
    $runner "$probe" </dev/null 2>&1
    status=$?
    describe "$status"
    echo "RISC_PROBE_END $name $status"
    if [ "$status" -ne 0 ]; then
        failures=$((failures + 1))
    fi
done

echo "RISC_PROBE_COMPLETE $failures"
[ "$failures" -eq 0 ]