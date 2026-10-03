#!/usr/bin/env bash
# Remove one path this account owns, or refuse and say which check stopped it.
#
# Deleting by name is the accident this exists to stop. A path on a shared
# mount can be replaced between the moment a caller decided to delete it and
# the moment `rm` looks, a recursive delete crosses into whatever is mounted
# underneath it, and a path that is still open is a path something is reading.
# So nothing is removed until every one of these has passed:
#
#   ownership    the path and every entry under it belongs to this account
#   volume       the resolved path is a per-account directory on one of the
#                approved scratch mounts
#   containment  no filesystem is mounted at or under it in this namespace,
#                and nothing in it is a device, a socket or a fifo
#   liveness     no process of this account holds it, and `lsof` reports
#                nothing open under it either
#
# A check that cannot be evaluated is a failed check. Every refusal exits 1,
# prints the reason, and leaves the path exactly as it found it.
#
# Scope, stated plainly rather than implied, because the liveness check is the
# one that cannot be made total from here. What is established is: no process
# OWNED BY THIS ACCOUNT has it as a working directory, root, executable, open
# descriptor or mapping, and `lsof` reports nothing open under it. That is the
# whole claim. It is not a claim about every process on the node: this account
# cannot read another account's /proc/<pid>/fd, and `lsof` is bound by the same
# procfs permissions, so on a node that forbids it lsof sees no better than the
# scan above. The two are two witnesses over the same ground, not a second
# opinion about other accounts.
#
# So the precondition this is built for is a real one and not a hedge: a
# directory this account created at mode 0700, moments ago, that no other
# account has a path to and therefore cannot have opened. It is not a
# general-purpose tree remover and does not claim to be.
#
# The other half of the same limitation is about this account rather than
# another one. A process of this account whose /proc entries the kernel will
# not open — a process that is not dumpable, so its cwd, root, exe and maps
# belong to root and open with EACCES for its own user — is refused, because
# "cannot be read" is not "holds nothing". Such processes are ordinary on a
# host where the account logs in over SSH: the session process and the pam
# helper that came with it are two of them, they live as long as the login
# does, and no reading of them is available from inside the session. Reading
# one takes CAP_SYS_PTRACE over it, so on such a host the answer this can
# give is a refusal naming the pid and the entry that would not open, which
# is a question about the machine rather than a verdict about the tree.
#
# Two shapes are accepted, each with its own checks:
#
#   safe-rm-dir.sh DIR         a directory, removed recursively. A symlink
#                              INSIDE it is removed as itself and its target
#                              is untouched: `rm` unlinks a symlink and never
#                              follows one. A symlink AS the argument is
#                              refused, because the caller asked for a
#                              directory and did not get one.
#   safe-rm-dir.sh --link LNK  a symlink, unlinked. Its target is inspected but
#                              never removed, so this can repair a dangling
#                              link without touching what it pointed at.
set -u

usage() {
    echo "usage: safe-rm-dir.sh DIR | safe-rm-dir.sh --check DIR | safe-rm-dir.sh --link LINK" >&2
}

# Findings from the checks below, carried in globals rather than in exit codes
# so a reason survives a command substitution. A subshell would swallow it.
SCAN_ERR=
SCAN_FOREIGN=
SCAN_ODD=
LIVE_ERR=
LIVE_HIT=

# The same for the process walk: what it found under one process, what it
# could not read, and what it read about that process on the way in.
PROC_HIT=
PROC_BLIND=
PID_NAME=
PID_UID=
PID_UIDS=
PID_STATE=
PID_START=

die() {
    echo "safe-rm-dir: refusing to remove $1: $2" >&2
    exit 1
}

# The approved volumes, in the order the host scratch policy orders them, and
# the per-account directory on each. A path outside one of these is refused
# even when this account owns it: /tmp and /var/tmp are small volumes every
# process on the node shares, and $HOME is NFS.
approved_roots() {
    local user
    user=$(id -un) || return 1
    printf '%s\n' \
        "/home/tmp2/$user" "/home/tmp/$user" "/vol/tmp2/$user" "/vol/tmp/$user"
}

# After resolution, so a link pointing out of an approved name cannot smuggle
# the removal onto /tmp.
on_approved_volume() {
    local resolved=$1 root
    while read -r root; do
        case "$resolved" in
            "$root" | "$root"/*) return 0 ;;
        esac
    done < <(approved_roots)
    return 1
}

# Any filesystem mounted at $1 or anywhere below it, in THIS mount namespace.
#
# `find -xdev` and `rm --one-file-system` do not cover this: a bind mount of
# the same filesystem shares the device id, so both walk straight through it
# and a recursive delete removes what the bind exposes. The only place that
# fact exists is this namespace's mount table, so it is read directly. Field 5
# of /proc/self/mountinfo is the mount point, and the kernel writes a path the
# way it escapes one: backslash as `\134`, space as `\040`, tab as `\011`,
# newline as `\012`. Comparing the raw field would miss a mount point whose
# path contains any of those, and a miss here is not a near-miss — it is a bind
# mount the recursive delete then walks into. So the field is decoded first.
#
# The order is not the kernel's and has to differ from it: the kernel escapes
# the backslash before the rest, so a path holding the four characters `\040`
# arrives as `\134040`, and decoding the backslash first turns that into
# `\040` for the next substitution to read as a space. The three specific
# escapes go first and the backslash last, which is the only order that cannot
# cascade.
#
# A line that cannot be read at all prints the sentinel below instead of
# nothing, because "no mount found" and "could not look" must never look
# alike, and the caller refuses on the sentinel rather than on an empty
# string.
mountpoints_under() {
    local tree=$1 mount rc=0
    # The tree arrives through the environment, never through `awk -v`.
    # `-v` processes its argument as a program fragment, so a backslash in a
    # caller's path is interpreted a second time and the comparison is then
    # against a different string than the one the caller asked about — which
    # for a containment check is a silent pass, not a loud one.
    mount=$(_ZAP_MOUNT_TREE="$tree" awk "$_ZAP_MOUNT_AWK" /proc/self/mountinfo 2>/dev/null) || rc=$?
    case "$rc" in
        0)
            printf '%s' "$mount"
            ;;
        3)
            printf '%s' UNREADABLE-MOUNTINFO
            ;;
        *)
            # awk itself failed — missing binary, unreadable table. Run it once
            # more without swallowing stderr so the refusal can quote the
            # reason instead of reporting a condition nobody can diagnose.
            printf 'awk could not read the mount table: %s\n' \
                "$(_ZAP_MOUNT_TREE="$tree" awk "$_ZAP_MOUNT_AWK" /proc/self/mountinfo 2>&1 >/dev/null)" >&2
            printf '%s' UNREADABLE-MOUNTINFO
            ;;
    esac
    return 0
}

# The mount-table reader, as one awk program. Exit 0 with a mount point on
# stdout when one sits at or under the tree, exit 0 with nothing when none
# does, and exit 3 when a line could not be read at all. Status 2 is awk's own
# failure and is left for the caller to distinguish from a clean answer.
_ZAP_MOUNT_AWK='''
BEGIN { t = ENVIRON["_ZAP_MOUNT_TREE"] }
NF < 5 { print "UNREADABLE-MOUNTINFO"; exit 3 }
{
    mp = $5
    gsub(/\\040/, " ", mp)
    gsub(/\\011/, "\t", mp)
    gsub(/\\012/, "\n", mp)
    gsub(/\\134/, "\\", mp)
}
mp == t || index(mp, t "/") == 1 { print mp; exit }
'''

# Nothing mounted at $2 or anywhere under it, or a refusal. $1 is what the
# refusal is about, in the caller's own words.
#
# `mountpoint` is not asked, and that is the point of this function. It
# answers 1 for "not a mount point" and 32 for anything it could not decide —
# a path it cannot canonicalize, a table it cannot read — and it answers 127
# when it is not installed at all. A `mountpoint -q ... && die` cannot tell
# those apart, so a helper that reached for it went on to delete on the
# strength of a tool that was missing, or that had already said it did not
# know. The mount table is read directly instead, once, by the walk above, and
# every answer that is not "nothing is mounted" is a refusal — including every
# answer that is not an answer.
#
# The two refusals stay apart because they are different facts. A mount at the
# path itself is the question `mountpoint` was being asked; a mount below it is
# what the walk finds and no device test can see, because a bind mount shares
# this device's id.
refuse_if_mounted() {
    local subject=$1 tree=$2 mount
    [ -r /proc/self/mountinfo ] \
        || die "$subject" "cannot read /proc/self/mountinfo, so a filesystem mounted at or under $tree cannot be excluded"
    mount=$(mountpoints_under "$tree")
    case "$mount" in
        UNREADABLE-MOUNTINFO)
            die "$subject" "a line of /proc/self/mountinfo could not be read, so a filesystem mounted at or under $tree cannot be excluded"
            ;;
        "")
            ;;
        "$tree")
            die "$subject" "$tree is a mount point; a bind mount shares this device's id, so no device test can see it"
            ;;
        *)
            die "$subject" "$mount is a filesystem mounted inside $tree; a bind mount shares this device's id, so no device test can see it"
            ;;
    esac
}

# The tree walk. Two passes each so that a read error is never mistaken for an
# empty result: `find` prints its findings on stdout and its failures on
# stderr, and a scan that could not read part of the tree would otherwise look
# exactly like a clean one.
scan_tree() {
    local tree=$1 uid=$2 errors
    SCAN_ERR=
    SCAN_FOREIGN=
    SCAN_ODD=

    errors=$(find "$tree" -xdev ! -uid "$uid" -print -quit 2>&1 >/dev/null)
    [ -z "$errors" ] || {
        SCAN_ERR="could not read every entry under $tree: $errors"
        return 1
    }
    SCAN_FOREIGN=$(find "$tree" -xdev ! -uid "$uid" -print -quit 2>/dev/null)

    # Links are deliberately not in this set: `rm` unlinks a symlink and does
    # not follow it, so an owned link inside the tree is safe to remove and its
    # target is not touched. Devices, sockets and fifos are refused, because
    # they are the entries where "remove the entry" and "remove what it stands
    # for" stop being the same question.
    errors=$(find "$tree" -xdev \( ! -type f -a ! -type d -a ! -type l \) -print -quit 2>&1 >/dev/null)
    [ -z "$errors" ] || {
        SCAN_ERR="could not read every entry under $tree: $errors"
        return 1
    }
    local odd
    odd=$(find "$tree" -xdev \( ! -type f -a ! -type d -a ! -type l \) -print -quit 2>/dev/null)
    [ -z "$odd" ] || {
        SCAN_ODD="$odd"
        return 1
    }
    return 0
}

# Live references, over the processes of this account.
#
# Both witnesses are required, and a failure in either is a failure to
# establish the answer rather than an answer. The scope is this account's
# processes, plus whatever `lsof` can see — which on a procfs that forbids it
# is not more than that, so lsof is a second witness over the same ground and
# not a view of other accounts. What is refused is anything that would leave
# the answer unknown: a tool that is missing, a process of this account that
# cannot be read, and a hit in either witness.
#
# Nothing below decides anything by reading what a tool said. A filter
# written in English — `grep -v 'No such file or directory'` — is only a filter
# on a host whose locale is English, and this one is not: under it `find`
# reports a process that exited between the glob and the walk as `Datei oder
# Verzeichnis nicht gefunden`, the filter drops nothing, and every ordinary
# exit on a host running anything at all becomes a refusal that never goes
# away. So every answer here is an exit status, or the same /proc entry looked
# at twice: a process that has exited leaves a directory that is not there any
# more, and a process whose entries this account may not read leaves one that
# is. Those are different facts about procfs, and both are asked for directly.
live_reference() {
    local tree=$1 uid=$2 dir errors hit seen=0
    LIVE_ERR=
    LIVE_HIT=

    if ! command -v lsof >/dev/null 2>&1; then
        LIVE_ERR="lsof is not on PATH, so live references cannot be established"
        return 1
    fi
    [ -d /proc ] || {
        LIVE_ERR="/proc is not a directory here, so live references cannot be established"
        return 1
    }

    # Every process on the node, this account's singled out by the uids in its
    # own status file and not by the owner of its /proc directory. A program
    # that kept this account's real uid while it ran as another one is still a
    # process of this account, and it is exactly the process whose descriptors
    # must not be assumed away — while its /proc entries have become root's,
    # which is what an owner test would drop on the floor.
    for dir in /proc/[0-9]*; do
        # A pid that exited between the glob and this test is left out. That is
        # the ordinary case on a host running anything at all, and a process
        # that is not there cannot be holding anything.
        [ -d "$dir" ] || continue
        seen=$((seen + 1))
        check_process "$dir" "$tree" "$uid"
        case $? in
            0) ;;
            1)
                LIVE_HIT=$PROC_HIT
                return 1
                ;;
            2)
                LIVE_ERR=$PROC_BLIND
                return 1
                ;;
        esac
    done
    [ "$seen" -gt 0 ] || {
        LIVE_ERR="no process could be listed under /proc, so none can be cleared"
        return 1
    }

    errors=$(lsof +D "$tree" 2>&1 >/dev/null)
    [ -z "$errors" ] || {
        LIVE_ERR="lsof could not read the tree: $errors"
        return 1
    }
    # lsof exits 1 and prints nothing when it finds nothing; its first line is
    # a header, so anything after it is an open file.
    hit=$(lsof +D "$tree" 2>/dev/null | sed -n 2p)
    if [ -n "$hit" ]; then
        LIVE_HIT="lsof: $hit"
        return 1
    fi
    return 0
}

# One process, one answer about $2 — the tree — for the account $3.
#
#   0  it holds nothing under the tree, or it is not this account's, or it is
#      no longer running
#   1  it holds the tree, and PROC_HIT names the reference
#   2  it runs as this account and could not be read, and PROC_BLIND names the
#      process and the entry that would not open
#
# Two passes and no more. The second is for the one race a single pass cannot
# read: a pid that exits while it is being inspected and is taken by another
# process immediately after, where what is on disk belongs to a process nobody
# has looked at. The start time says which of the two is on disk now. A third
# pass would only repeat the second, so the second failure is reported.
check_process() {
    local dir=$1 tree=$2 uid=$3 pass start
    PROC_HIT=
    PROC_BLIND=

    for pass in 1 2; do
        if ! read_pid_identity "$dir"; then
            # A process that has exited takes its status with it. One that is
            # still there and will not say who it is cannot be cleared either:
            # it may well be this account's, and an unknown process is not an
            # absent one.
            [ -d "$dir" ] && {
                PROC_BLIND="$dir/status could not be read, so it cannot be told whether a process of this account is still running there"
                return 2
            }
            return 0
        fi
        case " $PID_UIDS " in
            *" $uid "*) ;;
            *) return 0 ;;
        esac

        if ! read_pid_stat "$dir"; then
            [ -d "$dir" ] && {
                PROC_BLIND="$dir/stat could not be read, so whether it is still running is unknown"
                return 2
            }
            return 0
        fi
        # A zombie has already given everything back: the kernel closes its
        # descriptors and drops its address space before the process becomes
        # one, so what is left of it in /proc is the links with their targets
        # gone — a working directory that will not read and a descriptor
        # directory that will not open. Those look exactly like a reading this
        # account is not allowed to take, and they must not be answered as
        # one: a zombie holds nothing by definition. A dead task, likewise.
        case $PID_STATE in
            Z | X | x) return 0 ;;
        esac
        start=$PID_START

        inspect_process "$dir" "$tree"
        case $? in
            0) return 0 ;;
            1) return 1 ;;
            *)
                # Whatever is under this pid now is not the process this pass
                # started on, so it has not been inspected: look again, once.
                if [ "$pass" = 1 ] && [ -d "$dir" ] && read_pid_stat "$dir" &&
                    [ "$PID_START" != "$start" ]; then
                    continue
                fi
                # And a process that went while it was being read holds
                # nothing now, which is an answer and not a question: the
                # same pid the pass started on is simply not there.
                [ -d "$dir" ] || return 0
                printf -v PROC_BLIND 'process %s (%s, uid %s, state %s) is running as this account, but %s; reading it takes CAP_SYS_PTRACE over that process, which is what the kernel asks of anyone who would read a process that is not dumpable, and this account has no such capability — so what it holds is unknown rather than nothing' \
                    "${dir#/proc/}" "$PID_NAME" "$PID_UID" "$PID_STATE" "$PROC_BLIND"
                return 2
                ;;
        esac
    done
}

# What one process of this account holds under $2, and whether it can be told.
#
#   0  it holds nothing under the tree
#   1  it does, and PROC_HIT names the reference
#   2  it could not be read, and PROC_BLIND names the entry that would not open
inspect_process() {
    local dir=$1 tree=$2 name target listing walk entry
    PROC_HIT=
    PROC_BLIND=

    # Its working directory, its root and its executable. Those links exist
    # whether or not this account may read their targets, so the second look
    # is what tells the two apart: a link that is not there any more is a
    # process that has gone, and a link that is there and will not read is a
    # process this account is not allowed to follow.
    #
    # The targets are compared as text. `find -lname` would take the tree's
    # own path for a pattern, so a directory named `tmp[1]` would also match
    # files under `tmp1`.
    for name in cwd root exe; do
        target=$(readlink -- "$dir/$name" 2>/dev/null)
        case $target in
            "$tree" | "$tree"/*)
                PROC_HIT="$dir/$name -> $target"
                return 1
                ;;
        esac
        if [ -z "$target" ] && [ -L "$dir/$name" ]; then
            PROC_BLIND="$dir/$name is there but its target cannot be read"
            return 2
        fi
    done

    # Every open descriptor, with the targets the kernel wrote for them. The
    # permission to search the directory is tested before the walk and again
    # after it, because a walk that produced nothing must not be able to pass
    # for a clean one — either test failing is a refusal. What is not a
    # refusal is a descriptor that closed during the walk: it produces no
    # line, which is the right answer for a descriptor that is no longer open.
    [ -x "$dir/fd" ] || {
        PROC_BLIND="$dir/fd cannot be searched, so its descriptors cannot be read"
        return 2
    }
    listing=$(find "$dir/fd" -mindepth 1 -maxdepth 1 -printf '%p\t%l\n' 2>/dev/null)
    walk=$?
    case $walk in
        # find exits 1 when an entry went away under it, which is the race
        # above; the directory was searchable on both sides of the walk.
        0 | 1) ;;
        *)
            PROC_BLIND="$dir/fd could not be walked (find exited $walk), so its descriptors are unknown"
            return 2
            ;;
    esac
    while IFS= read -r entry; do
        case ${entry#*$'\t'} in
            "$tree" | "$tree"/*)
                PROC_HIT="${entry%%$'\t'*} -> ${entry#*$'\t'}"
                return 1
                ;;
        esac
    done <<< "$listing"
    [ -x "$dir/fd" ] || {
        PROC_BLIND="$dir/fd stopped being searchable while it was being read"
        return 2
    }

    # A mapped file is an executable or a library still being run out of the
    # tree; deleting it leaves that process reading a hole. grep's exit
    # status is the whole of the answer and carries no message: 0 a line
    # matched, 1 none did, anything else the file could not be read — and
    # which of the two failures it was is not in the status, so it is settled
    # by the caller looking at the pid again rather than by the text.
    grep -F -q -- "$tree" "$dir/maps" 2>/dev/null
    case $? in
        0)
            PROC_HIT="$dir/maps maps $tree"
            return 1
            ;;
        1) ;;
        *)
            PROC_BLIND="$dir/maps could not be read, so what this process has mapped is unknown"
            return 2
            ;;
    esac
    return 0
}

# A process's identity, from its status file: the name it runs under in
# PID_NAME, its real uid in PID_UID, and all four uids in PID_UIDS.
#
# All four count as this account. A program that kept this account's real uid
# while it ran as another one is a process of this account, and its
# descriptors are exactly the ones that must not be assumed away.
#
# Nonzero when the file could not be read or carried no Uid line, which is not
# the same as a process that reads as empty: the caller tells those apart by
# looking at the same pid directory again.
read_pid_identity() {
    local dir=$1 key name real effective saved filesystem _
    PID_NAME=
    PID_UID=
    PID_UIDS=
    # The group, and not a `done 2>/dev/null < file`, because redirections are
    # applied in the order they are written: with the input redirect first,
    # bash reports the process that has just exited before stderr has been
    # turned anywhere, and every vanished pid prints a line of its own.
    {
        while read -r key name real effective saved filesystem _; do
            case $key in
                Name:) PID_NAME=$name ;;
                Uid:*)
                    PID_UID=$real
                    PID_UIDS="$real $effective $saved $filesystem"
                    return 0
                    ;;
            esac
        done < "$dir/status"
    } 2>/dev/null
    return 1
}

# The state and the start time of a process, from its stat file: the state is
# the third field of the line and the start time the twenty-second.
#
# comm — the second field — is the executable's name in parentheses and may
# itself hold spaces and parentheses, so everything after it is counted from
# the LAST ') ' in the line rather than from the start of it.
read_pid_stat() {
    local dir=$1 line
    local -a field
    PID_STATE=
    PID_START=
    { read -r line < "$dir/stat"; } 2>/dev/null || return 1
    case $line in
        *") "*) ;;
        *) return 1 ;;
    esac
    field=()
    read -r -a field <<< "${line##*) }" || return 1
    [ "${#field[@]}" -ge 20 ] || return 1
    PID_STATE=${field[0]}
    PID_START=${field[19]}
}

check_removable() {
    local path=$1 resolved=$2 uid=$3
    refuse_if_mounted "$path" "$resolved"

    scan_tree "$resolved" "$uid"
    [ -z "$SCAN_ERR" ] || die "$path" "$SCAN_ERR"
    [ -z "$SCAN_FOREIGN" ] || die "$path" "$SCAN_FOREIGN belongs to another account"
    [ -z "$SCAN_ODD" ] || die "$path" "$SCAN_ODD is a device, a socket or a fifo"

    live_reference "$resolved" "$uid"
    [ -z "$LIVE_ERR" ] || die "$path" "$LIVE_ERR"
    [ -z "$LIVE_HIT" ] || die "$path" "a process still holds it: $LIVE_HIT"
}

remove_link() {
    local link=$1 parent target resolved uid
    [ -n "$link" ] || die "" "no path given"
    [ "$link" != "/" ] || die "$link" "is the root directory"
    [ -L "$link" ] || die "$link" "is not a symlink"
    uid=$(id -u) || die "$link" "cannot read this account's id"

    # `-O` follows a link, so the link's own owner is read from stat, which
    # does not. An unlink is a write to the directory holding the link, so
    # that directory is the one whose ownership decides it.
    [ "$(stat -c %u -- "$link" 2>/dev/null)" = "$uid" ] \
        || die "$link" "the link belongs to another account"
    parent=$(dirname -- "$link")
    [ -d "$parent" ] && [ ! -L "$parent" ] || die "$link" "its directory is not a directory"
    [ -O "$parent" ] || die "$link" "its directory belongs to another account"
    # Same reason as in remove_tree: the directory holding the link is what
    # keeps this out of another account's reach, so it is checked rather than
    # assumed.
    [ "$(stat -c %a -- "$parent" 2>/dev/null)" = "700" ] \
        || die "$link" "its directory is not mode 0700"
    resolved=$(realpath -m -- "$parent") || die "$link" "its directory does not resolve"
    on_approved_volume "$resolved" || die "$link" "its directory is not on an approved volume"
    # The mount table is asked about the link's own name here. `mountpoint -q`
    # was asked about it before and followed the link instead, so it answered
    # for a target this mode must not stat: a link whose target is gone could
    # not be resolved at all, and the 32 it answered with read exactly like the
    # 1 that means "not a mount point". The walk compares two strings and never
    # looks at the target, so a dangling link is still a link this can repair;
    # a live target's own mount question is asked below, where there is a
    # target to ask about.
    refuse_if_mounted "$link" "$link"

    # The link itself, before it goes: nothing open, nothing mounted here.
    live_reference "$link" "$uid"
    [ -z "$LIVE_ERR" ] || die "$link" "$LIVE_ERR"
    [ -z "$LIVE_HIT" ] || die "$link" "a process still holds it: $LIVE_HIT"

    # The target is inspected before anything is unlinked, so this is never
    # the first step of removing something larger than the link. A target that
    # is already gone is the ordinary reason this mode exists; one that is
    # there is held to the same volume, mount and liveness tests a directory
    # would be, and is then left strictly alone.
    target=$(readlink -- "$link") || die "$link" "cannot be read"
    case "$target" in
        /*) resolved=$(realpath -m -- "$target") ;;
        *) resolved=$(realpath -m -- "$parent/$target") ;;
    esac
    if [ -e "$resolved" ]; then
        [ -d "$resolved" ] || die "$link" "it points at $resolved, which is not a directory"
        [ -O "$resolved" ] || die "$link" "it points at $resolved, owned by another account"
        on_approved_volume "$resolved" || die "$link" "it points at $resolved, which is not on an approved volume"
        refuse_if_mounted "$link" "$resolved"
        live_reference "$resolved" "$uid"
        [ -z "$LIVE_ERR" ] || die "$link" "$LIVE_ERR"
        [ -z "$LIVE_HIT" ] || die "$link" "its target $resolved is still held: $LIVE_HIT"
    fi

    unlink -- "$link" || die "$link" "unlink failed"
    [ ! -e "$link" ] && [ ! -L "$link" ] || die "$link" "is still there"
    printf 'safe-rm-dir: removed the symlink %s\n' "$link"
}

remove_tree() {
    local path=$1 operation=${2:-remove} resolved uid
    [ -n "$path" ] || die "" "no path given"
    [ "$path" != "/" ] || die "$path" "is the root directory"
    [ ! -L "$path" ] || die "$path" "is a symlink; --link removes a link, not what it points at"
    [ -d "$path" ] || die "$path" "is not a directory"
    uid=$(id -u) || die "$path" "cannot read this account's id"
    [ -O "$path" ] || die "$path" "belongs to another account"
    # The liveness evidence below covers this account's processes and whatever
    # lsof can see; it cannot cover another account's descriptors. Mode 0700
    # is what turns that from a limitation into a precondition this can
    # actually check: no other account has a path into it, so none can have
    # opened anything under it. The claim in the header is therefore enforced
    # here rather than trusted to the caller.
    [ "$(stat -c %a -- "$path" 2>/dev/null)" = "700" ] \
        || die "$path" "is not mode 0700; this removes only a directory no other account can reach"

    resolved=$(realpath -m -- "$path") || die "$path" "does not resolve"
    on_approved_volume "$resolved" || die "$path" "$resolved is not on an approved volume"
    check_removable "$path" "$resolved" "$uid"
    if [ "$operation" = check ]; then
        printf 'safe-rm-dir: checked %s\n' "$resolved"
        return
    fi

    # --one-file-system keeps the recursive delete inside what was walked.
    rm -rf --one-file-system -- "$resolved" || die "$path" "rm failed"
    [ ! -e "$resolved" ] && [ ! -L "$resolved" ] || die "$path" "is still there"
    printf 'safe-rm-dir: removed %s\n' "$resolved"
}

case "${1-}" in
    --check)
        [ $# -eq 2 ] || {
            usage
            exit 1
        }
        remove_tree "$2" check
        ;;
    --link)
        [ $# -eq 2 ] || {
            usage
            exit 1
        }
        remove_link "$2"
        ;;
    "" | -h | --help)
        usage
        exit 1
        ;;
    *)
        [ $# -eq 1 ] || {
            usage
            exit 1
        }
        remove_tree "$1"
        ;;
esac