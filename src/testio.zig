//! Scratch socket paths for the tests and the examples, kept out of `/tmp`.
//!
//! ## What this replaces
//!
//! Every test and every example that needs a real Unix socket used to spell its
//! own `/tmp/zig-agent-proto-<what>-<pid>-<tag>.sock` literal, a copy per
//! file, each one a string a rename had to find, and every one of them a write
//! into a directory the operating system owns and clears on its own schedule.
//! A socket file there outlives the run that made it, so a run killed halfway
//! leaves a name the next run of the same test cannot bind.
//!
//! ## Where the directory comes from
//!
//! `TMPDIR`, read through the caller's own environment block, and from nowhere
//! else. There is no default and no fallback, because the only value a default
//! could supply is the system one and silently writing there is the behaviour
//! this file exists to end. An unset `TMPDIR` is
//! [`error.MissingScratchDirectory`], which is the environment owner's to
//! answer. Whoever owns the environment decides where scratch lives; this file
//! only refuses system temporary directories and unsafe path shapes. Windows
//! uses the same caller-selected variable, not `TEMP` or `TMP` as a fallback.
//!
//! Nothing here is exported from the library root and no protocol surface
//! depends on it. These are the tests' and the examples' own files: a consumer
//! of this library has a scratch directory of its own to choose, and a
//! library-wide rule about where a stranger's temporary files go is not the
//! library's to impose.
//!
//! ## The rules, and what each is for
//!
//! - `/tmp` and `/var/tmp` are refused, and so is anything beneath them. They
//!   are the directories the system clears without warning, so a socket file
//!   is a name that may be gone before anything connects to it.
//! - A relative directory is refused, because it resolves against whatever
//!   directory the process happened to be started in, which is not a decision
//!   anybody made for a scratch socket.
//! - A `..` component is refused, and the filesystem root is refused. An
//!   upward step can leave the directory the environment named and land in one
//!   this check never saw, and a socket written at `/` is a socket nobody chose.
//! - The name carries the caller's `tag` and a nonce drawn from `Io.random`,
//!   so two runs of one file cannot choose the same path. A fixed name is a
//!   rendezvous point: whichever run reached the unlink second deletes the
//!   other's bound path, and the loser of that race aborts in a pump on a
//!   socket file that is gone, which reads as a protocol fault and is not one.
//! - The whole path is measured against `Io.net.UnixAddress.max_len` before
//!   anything is rendered, because that is the length `UnixAddress.init`
//!   refuses, and a refused name reaches a test as a peer that never connected
//!   rather than as the arithmetic that failed.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// The environment variable naming the directory scratch sockets go in.
const tmpdir_var = "TMPDIR";

/// The name rendered inside that directory. `zap` marks the file as this
/// library's in a directory that may hold other things, and both fields after
/// it are fixed width, so a name is the same length on every call.
const name_format = "zap-{x:0>16}-{x:0>16}.sock";

/// The exact length [`name_format`] renders, measured at compile time with both
/// fields at the widest a `u64` can spell. The suffix region in [`finishPath`]
/// is this long, so the format cannot fail to fit it and the bound on the path
/// is arithmetic rather than a length discovered after the fact. Counting it by
/// hand instead would be a number that a change to the format silently stops
/// describing.
const name_len = blk: {
    var probe: [128]u8 = undefined;
    const widest = std.fmt.bufPrint(
        &probe,
        name_format,
        .{ std.math.maxInt(u64), std.math.maxInt(u64) },
        // gate-reviewed-zlint-next-statement: suppressed-errors
    ) catch unreachable;
    break :blk widest.len;
};

/// What [`socketPath`] refuses, over and above the errors the directory create
/// can return from the host.
pub const Error = error{
    /// `TMPDIR` was unset, or set to nothing. There is no default to supply
    /// one, so this is the environment owner's to answer.
    MissingScratchDirectory,
    /// `TMPDIR` named a directory a scratch socket may not be written into.
    UnsafeScratchDirectory,
    /// The whole path is longer than `Io.net.UnixAddress.max_len`, so
    /// `UnixAddress.init` would refuse the name. A larger buffer cannot help;
    /// a shorter directory can.
    PathTooLong,
    /// The caller's buffer is shorter than the path this call renders into it.
    BufferTooSmall,
    /// The target has no supported environment and Unix socket backend.
    UnsupportedPlatform,
};

/// Renders a unique Unix socket path inside the caller's scratch directory and
/// returns it as a slice of `buffer`.
///
/// The path lives in `buffer` and nowhere else. `Io.net.UnixAddress` borrows
/// its path, so this buffer has to outlive both ends of the connection: a path
/// built in a callee's own frame would be dead the moment the callee returned,
/// and `connect` would then be asking for a socket whose name no longer exists.
///
/// `tag` is the caller's own discriminator. It makes the socket readable in a
/// directory listing and keeps two tests in one file from sharing a name; the
/// nonce is what keeps two runs of one file apart.
///
/// The directory is created if it is missing, and only once the name is known
/// to fit, so every failure above leaves no directory and no file behind for
/// the caller to clean up. The caller removes the file itself, after the
/// listener has closed rather than before: a path removed while the server is
/// still bound can no longer be connected to.
pub fn socketPath(
    io: std.Io,
    environ: std.process.Environ,
    buffer: []u8,
    tag: u64,
) ![]const u8 {
    switch (builtin.os.tag) {
        .windows => return windowsSocketPath(io, environ, buffer, tag),
        .wasi, .emscripten => return error.UnsupportedPlatform,
        else => {},
    }
    return posixSocketPath(io, environ, buffer, tag);
}

/// The half that names a POSIX environment block, split out so that it is only
/// compiled where there is one to name.
fn posixSocketPath(
    io: std.Io,
    environ: std.process.Environ,
    buffer: []u8,
    tag: u64,
) (Error || std.Io.Dir.CreateDirPathError)![]const u8 {
    // No allocator: `getPosix` walks the block the caller already holds and
    // borrows out of it.
    const value = environ.getPosix(tmpdir_var) orelse return error.MissingScratchDirectory;
    const dir = try scratchDir(value);
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const path = try render(buffer, dir, tag, std.mem.readInt(u64, &nonce, .little));
    // The environment owner is expected to have made this directory already;
    // making it here costs a stat when it exists and saves every bind under a
    // `TMPDIR` that nobody has created yet.
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return path;
}

/// Windows borrows WTF-16 from the caller's environment and transcodes directly
/// into its output buffer. The returned socket path owns no extra region.
fn windowsSocketPath(
    io: std.Io,
    environ: std.process.Environ,
    buffer: []u8,
    tag: u64,
) (Error || std.Io.Dir.CreateDirPathError)![]const u8 {
    const value = environ.getWindows(std.unicode.utf8ToUtf16LeStringLiteral(tmpdir_var)) orelse
        return error.MissingScratchDirectory;
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const path = try renderWindows(buffer, value, tag, std.mem.readInt(u64, &nonce, .little));
    const dir = path[0 .. path.len - name_len - 1];
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return path;
}

/// The directory `TMPDIR` named, with its trailing separators removed, or a
/// refusal.
///
/// Pure, so the rules below can be exercised over directories no test has any
/// business creating.
fn scratchDir(value: [:0]const u8) Error![]const u8 {
    if (value.len == 0) return error.MissingScratchDirectory;
    // Relative to what? The process's own working directory, which nobody
    // chose for this and which a CI runner sets per job.
    if (value[0] != '/') return error.UnsafeScratchDirectory;
    var components = std.mem.splitScalar(u8, value, '/');
    while (components.next()) |component| {
        // Refused rather than resolved: there is no allocator here to resolve
        // it into, and resolving it would only tell us the answer the check
        // above is trying to reach.
        if (std.mem.eql(u8, component, "..")) return error.UnsafeScratchDirectory;
    }
    var dir = value[0..value.len];
    while (dir.len > 1 and dir[dir.len - 1] == '/') dir = dir[0 .. dir.len - 1];
    // After trimming, a length of one is the filesystem root, and a value of
    // nothing but separators trims to it.
    if (dir.len == 1) return error.UnsafeScratchDirectory;
    if (isSystemTemp(dir)) return error.UnsafeScratchDirectory;
    return dir;
}

/// Whether `dir` is `/tmp`, `/var/tmp`, or is inside one of them.
fn isSystemTemp(dir: []const u8) bool {
    return std.mem.eql(u8, dir, "/tmp") or std.mem.startsWith(u8, dir, "/tmp/") or
        std.mem.eql(u8, dir, "/var/tmp") or std.mem.startsWith(u8, dir, "/var/tmp/");
}

/// A fully qualified Windows drive or UNC directory. Rooted-but-drive-relative
/// paths and device namespaces do not designate an ordinary scratch directory.
fn windowsScratchDir(value: []const u8) Error![]const u8 {
    if (value.len == 0) return error.MissingScratchDirectory;
    const dir = std.mem.trimEnd(u8, value, "\\/");
    const parsed = std.fs.path.parsePathWindows(u8, dir);
    switch (parsed.kind) {
        .drive_absolute, .unc_absolute => {},
        else => return error.UnsafeScratchDirectory,
    }
    if (dir.len <= parsed.root.len) return error.UnsafeScratchDirectory;
    var components = std.mem.tokenizeAny(u8, dir, "\\/");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.UnsafeScratchDirectory;
    }
    // Wine maps Unix directories through a drive. Keep the POSIX exclusions
    // when their spelling reaches us through that drive's root.
    if (parsed.kind == .drive_absolute) {
        var tail = std.mem.tokenizeAny(u8, dir[parsed.root.len..], "\\/");
        if (tail.next()) |first| {
            if (std.ascii.eqlIgnoreCase(first, "tmp")) return error.UnsafeScratchDirectory;
            if (std.ascii.eqlIgnoreCase(first, "var")) {
                if (tail.next()) |second| {
                    if (std.ascii.eqlIgnoreCase(second, "tmp")) return error.UnsafeScratchDirectory;
                }
            }
        }
    }
    return dir;
}

fn renderWindows(buffer: []u8, value: []const u16, tag: u64, nonce: u64) Error![]const u8 {
    var trimmed = value;
    while (trimmed.len != 0) {
        const last = std.mem.littleToNative(u16, trimmed[trimmed.len - 1]);
        if (last != '/' and last != '\\') break;
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    const dir_len = std.unicode.calcWtf8Len(trimmed);
    if (dir_len > std.Io.net.UnixAddress.max_len - 1 - name_len) return error.PathTooLong;
    if (dir_len > buffer.len) return error.BufferTooSmall;
    const written = std.unicode.wtf16LeToWtf8(buffer[0..dir_len], trimmed);
    const dir = try windowsScratchDir(buffer[0..written]);
    return finishPath(buffer, dir.len, '\\', tag, nonce);
}

/// Writes `<dir>/<name>` into `buffer` and returns it as a slice of it.
///
/// Touches no filesystem, which is what lets both bounds be measured over
/// directories that do not exist and buffers too small to hold the answer.
fn render(buffer: []u8, dir: []const u8, tag: u64, nonce: u64) Error![]const u8 {
    const path = try finishPath(buffer, dir.len, '/', tag, nonce);
    @memcpy(path[0..dir.len], dir);
    return path;
}

/// Appends the separator and fixed-width name after a caller-owned directory
/// prefix. Windows has already transcoded that prefix in place.
fn finishPath(buffer: []u8, dir_len: usize, separator: u8, tag: u64, nonce: u64) Error![]u8 {
    const needed = dir_len + 1 + name_len;
    // `max_len` first. It is the bound no buffer can move, and reporting it as
    // a short buffer would send the caller off to grow something that cannot
    // help.
    if (needed > std.Io.net.UnixAddress.max_len) return error.PathTooLong;
    if (needed > buffer.len) return error.BufferTooSmall;
    buffer[dir_len] = separator;
    // Cannot fail: this region is `name_len` bytes, measured at the widest u64.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    const name = std.fmt.bufPrint(buffer[dir_len + 1 ..][0..name_len], name_format, .{ tag, nonce }) catch unreachable;
    return buffer[0 .. dir_len + 1 + name.len];
}

test "an unset or empty TMPDIR is a refusal rather than a default directory" {
    try testing.expectError(error.MissingScratchDirectory, scratchDir(""));
}

test "the two directories the system clears are refused, and what is under them" {
    for ([_][:0]const u8{ "/tmp", "/tmp/zig-agent-proto", "/var/tmp", "/var/tmp/zig-agent-proto" }) |dir| {
        try testing.expectError(error.UnsafeScratchDirectory, scratchDir(dir));
    }
    // A name that merely starts with the same bytes is a different directory,
    // and refusing it would refuse a legitimate scratch root.
    for ([_][:0]const u8{ "/tmproot", "/var/tmproot", "/tmpfiles" }) |dir| {
        _ = try scratchDir(dir);
    }
}

test "a directory nobody designated as scratch is refused" {
    // Relative: resolved against whatever directory the process was started in.
    try testing.expectError(error.UnsafeScratchDirectory, scratchDir("tmp"));
    // The filesystem root, and the value that names nothing but separators.
    try testing.expectError(error.UnsafeScratchDirectory, scratchDir("/"));
    try testing.expectError(error.UnsafeScratchDirectory, scratchDir("///"));
    // An upward step that lands in a directory the checks never see: the
    // second one resolves to exactly `/tmp`.
    try testing.expectError(error.UnsafeScratchDirectory, scratchDir("/home/user/../../tmp"));
    try testing.expectError(error.UnsafeScratchDirectory, scratchDir("/var/tmp/../zig"));
}

test "one separator, however the directory spells its own end" {
    var plain_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    var slashed_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const dir = try scratchDir("/home/user/scratch");
    const plain = try render(&plain_buffer, dir, 0x5eed_0101, 0x5eed_0202);
    const slashed = try render(
        &slashed_buffer,
        try scratchDir("/home/user/scratch///"),
        0x5eed_0101,
        0x5eed_0202,
    );
    try testing.expectEqualStrings(plain, slashed);
    // The join puts exactly one separator there, whether or not the directory
    // arrived carrying one of its own.
    try testing.expectEqualStrings(dir, plain[0..dir.len]);
    try testing.expectEqual('/', plain[dir.len]);
}

test "the bound is the whole path, and the last length that fits is the one that binds" {
    const max_len = std.Io.net.UnixAddress.max_len;
    var buffer: [max_len]u8 = undefined;
    // `max_len - name_len - 1` bytes of directory, which with the separator
    // and the name is exactly `max_len`.
    const exact = try render(
        &buffer,
        "/" ++ "x" ** (max_len - name_len - 2),
        0x5eed_0101,
        0x5eed_0202,
    );
    try testing.expectEqual(max_len, exact.len);
    // One byte more is not a shorter socket name, it is no socket.
    try testing.expectError(error.PathTooLong, render(
        &buffer,
        "/" ++ "x" ** (max_len - name_len - 1),
        0x5eed_0101,
        0x5eed_0202,
    ));
}

test "a buffer too small for the name is reported rather than overrun" {
    var buffer: [8]u8 = undefined;
    // The path is far shorter than `max_len`, so this is the buffer and not
    // the name that is too small, and only one of the two answers is useful.
    try testing.expectError(error.BufferTooSmall, render(
        &buffer,
        "/scratch",
        0x5eed_0101,
        0x5eed_0202,
    ));
}

test "a name depends on the tag and on the nonce, not on either alone" {
    var first: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    var second: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    var third: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const base = try render(&first, "/scratch", 0x5eed_0101, 0x5eed_0202);
    // Same tag, different nonce: two runs of one file must not meet.
    try testing.expect(!std.mem.eql(u8, base, try render(
        &second,
        "/scratch",
        0x5eed_0101,
        0x5eed_0203,
    )));
    // Same nonce, different tag: two tests in one file must not meet.
    try testing.expect(!std.mem.eql(u8, base, try render(
        &third,
        "/scratch",
        0x5eed_0104,
        0x5eed_0202,
    )));
}

test "Windows scratch paths name a drive or share, not the current drive or its root" {
    for ([_][]const u8{
        "",                       "scratch",
        "\\scratch",              "C:scratch",
        "C:\\",                   "\\\\server\\share",
        "\\\\?\\C:\\scratch",     "\\\\.\\pipe\\scratch",
        "C:\\scratch\\..\\other", "C:/scratch/../other",
        "Z:\\tmp\\scratch",       "Z:\\var\\tmp\\scratch",
    }) |dir| {
        const expected: Error = if (dir.len == 0) error.MissingScratchDirectory else error.UnsafeScratchDirectory;
        try testing.expectError(expected, windowsScratchDir(dir));
    }
    try testing.expectEqualStrings("C:\\scratch", try windowsScratchDir("C:\\scratch\\\\"));
    try testing.expectEqualStrings("\\\\server\\share\\scratch", try windowsScratchDir("\\\\server\\share\\scratch\\"));
}

test "Windows socket paths preserve Unicode and bound the encoded bytes" {
    const value = std.unicode.utf8ToUtf16LeStringLiteral("C:\\scratch\\é🚀\\\\");
    const directory = "C:\\scratch\\é🚀";
    const expected = directory ++ "\\zap-0000000000000001-0000000000000002.sock";
    var buffer: [expected.len]u8 = undefined;
    try testing.expectEqualStrings(expected, try renderWindows(&buffer, value, 1, 2));
    try testing.expectError(error.BufferTooSmall, renderWindows(buffer[0 .. buffer.len - 1], value, 1, 2));
}
