//! The Zig half of the A2A 1.0 interoperability exchange.
//!
//! This is a participant, not a library module. `test/interop/a2a_peer.py`
//! starts this executable as a child process and drives it against a genuine
//! upstream `a2a-sdk` in both directions: this file as the client against the
//! SDK's own agent, and this file as the server against the SDK's own client.
//! Nothing here is imported by the library, and the library keeps its
//! zero-dependency guarantee because this process is a peer and not a caller.
//!
//! Every buffer is fixed and at file scope, because the borrowed pointers the
//! runtime keeps — the reader, the writer, the `std.http.Client` and every
//! decoded value — have to outlive the call that borrowed them. Every string a
//! report carries is copied into the report's own storage before the scratch it
//! was decoded into is reused, so the report read at the end of a run still
//! says what the wire said at the time.
//!
//! ## Why the argument line is parsed rather than read in place
//!
//! [`parseArgs`] is a pure function of the words: no `Io`, no allocator, no
//! clock and no global state. That is what lets the tests below pin every
//! refusal, every bound and every role/flag mismatch without starting a
//! process and without opening a socket, which is the only way those rules can
//! be checked deterministically.
//!
//! ## The endpoint is an argument, not a convention
//!
//! Both roles take the endpoint as a word rather than deriving one:
//!
//!   - a client is told which advertised path-and-query it is expected to have
//!     selected, so it can report whether it used the card's endpoint or a
//!     guess;
//!   - a server is told the exact path-and-query its card advertises and the
//!     exact target its POST answers, so the card and the route cannot drift
//!     apart.
//!
//! A server is also told two ports. It listens on one, which the kernel picks
//! when it is zero, and it advertises another, because the supervisor may relay
//! the wire through a socket of its own and the card has to name a port a
//! client can reach. Those are separate words rather than one derived value
//! because the kernel's choice is only known once the socket is bound, and a
//! card that named it would have to be rewritten after the fact.
//!
//! ## What each role proves
//!
//! The client discovers the card, selects the first JSONRPC 1.0 interface the
//! card advertises, checks the selected endpoint against the one it was told to
//! expect, and sends two `SendMessage` calls: one whose text asks the peer for
//! a Task and one whose text asks for a Message. The two arms are a `oneof` on
//! the wire, so a client that read both as the same value would be wrong twice
//! and tell nobody.
//!
//! The server serves the card at the well-known path, answers a typed
//! `SendMessage` in whichever arm the request's text asked for, and takes
//! connections until it has answered the request count it was given. A peer
//! that hangs up early does not end the run: `accept` waits on a listening
//! socket, so the run goes on waiting for the next connection, and a peer that
//! stops short of its budget is ended by the supervisor's deadline, which
//! kills the process group rather than waiting for a request that is not
//! coming.

const std = @import("std");
const proto = @import("zig-agent-proto");

const a2a = proto.a2a;
const a2a_http = proto.a2a_http;
const json = proto.json;

const Io = std.Io;
const testing = std.testing;

/// The fixed marker both peers put in what they send, and the name this
/// process reports itself under. A fixed word rather than a path or a
/// hostname: what a report carries is kept as evidence, so it must not say
/// anything about the machine that produced it.
const marker = "zig-agent-proto-interop";

/// The text that asks the peer for the other arm of the result `oneof`.
///
/// The peer is an echo agent and answers on what it is told, which is why this
/// is the text rather than a request member: the switch has to survive the
/// protobuf round trip, and the text is the one field both ends certainly
/// carry.
const ask_for_task = "result:task";
const ask_for_message = "result:message";

/// The message id this client sends. Fixed, because the evidence is compared
/// against a later run and a generated id would be a different document.
const request_message_id = "zig-agent-proto-interop-request";

/// The ids the server answers with, for the same reason.
const answer_message_id = "zig-agent-proto-interop-answer";
const answer_task_id = "zig-agent-proto-interop-task";
const answer_artifact_id = "zig-agent-proto-interop-artifact";

/// Agent software label, separate from each interface's `protocolVersion`.
/// PROTOCOLS.md section 5.1 forbids patch components in Agent Cards.
const card_version: []const u8 = marker;

/// The protocol version this process speaks, in the spelling a header and a
/// card both carry.
///
/// A literal rather than a formatted value, so the string a report prints, the
/// one the card advertises and the one the `A2A-Version` header carries are one
/// constant rather than three formats of a value. The comptime block below is
/// what keeps that from being a claim: if the runtime ever binds another
/// version, this stops being a build.
const version_wire: []const u8 = "1.0";

comptime {
    var buffer: [16]u8 = undefined;
    // A `u16` prints as at most five digits, so eleven of the sixteen bytes are all
    // `format` can want and its `error.BufferTooSmall` cannot be what reaches here.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    if (!std.mem.eql(u8, a2a_http.version.format(&buffer) catch unreachable, version_wire)) {
        @compileError("this participant advertises and binds a version the runtime does not");
    }
}

// --- the frozen shape ----------------------------------------------------------

/// Which end of the wire this process is.
///
/// Two roles and no default: a run with no role is a refusal, because a
/// participant that guessed which end it was would be the thing the supervisor
/// exists to check.
pub const Role = enum {
    /// Discover, select, bind and send. The peer is the SDK's own agent.
    client,
    /// Serve the card and answer one SendMessage per request. The peer is the
    /// SDK's own client.
    server,
};

/// Every way a command line can be refused, one member per fault.
///
/// The members are separate rather than one `InvalidArgument` because the
/// faults are separate: a reader who typed `--port 65536` and a reader who
/// typed `--port -1` have to be told different things, and a driver that
/// collapsed both into one message taught neither of them anything.
pub const CliError = error{
    /// A word that is not a flag this participant knows, including a joined
    /// spelling such as `--role=client` and a name spelled differently such as
    /// `--Role`. Neither is silently dropped and neither is guessed at.
    UnknownFlag,
    /// A flag this participant knows, given twice. The last one does not win:
    /// a line that repeats a flag was assembled by something that did not read
    /// what it wrote, and picking one of the two would hide that.
    DuplicateFlag,
    /// A flag that takes a value, with nothing after it or with another flag
    /// after it. A flag is not a value.
    MissingValue,
    /// A word that is not a flag at all. This participant takes no positional
    /// argument, so there is nothing a bare word could have meant.
    UnexpectedArgument,
    /// A flag the named role does not take. Both roles share this file, so a
    /// client flag on a server line names a role the flag does not belong to;
    /// ignoring it would run a role the reader did not ask for.
    FlagNotForRole,
    /// No `--role`. There is no default role: which end of the wire this
    /// process is, is the one thing the reader has to say.
    MissingRole,
    /// A `--role` that is neither `client` nor `server`. The two spellings are
    /// exact and lower case.
    InvalidRole,
    /// No `--base-url` on a client line.
    MissingBaseUrl,
    /// A `--base-url` that is not an http or https origin with a host and no
    /// path, query or fragment of its own.
    InvalidBaseUrl,
    /// No `--expect-endpoint` on a client line. A client that is not told which
    /// endpoint to expect cannot report whether it used the advertised one.
    MissingExpectEndpoint,
    /// An `--expect-endpoint` that is not a path, optionally with a query: no
    /// leading slash, an absolute URL, an empty word, a bare query or a
    /// fragment.
    InvalidExpectEndpoint,
    /// No `--rpc-target` on a server line.
    MissingRpcTarget,
    /// An `--rpc-target` that is not a path, optionally with a query: no
    /// leading slash, an absolute URL, an empty word, a bare query or a
    /// fragment.
    InvalidRpcTarget,
    /// No `--advertise-port` on a server line, or a zero that names no port a
    /// client can dial.
    MissingAdvertisePort,
    /// An `--advertise-port` outside `1..65535`.
    AdvertisePortOutOfRange,
    /// No `--requests` on a server line. Bounded work is chosen rather than
    /// defaulted, so the number a report carries is one the reader picked.
    MissingRequests,
    /// A count that is not a run of decimal digits: empty, signed, in another
    /// base, separated, or with anything trailing it.
    NotANumber,
    /// A count of decimal digits that no `u32` holds. Distinct from a range
    /// complaint because no bound is what was crossed.
    CountOverflow,
    /// A `--port` outside `0..65535`.
    PortOutOfRange,
    /// A `--requests` outside `1..64`.
    RequestsOutOfRange,
};

/// What a command line asks for.
pub const Parsed = union(enum) {
    /// The usage was asked for. Nothing is dialled, nothing is served and
    /// nothing is reported.
    help,
    /// A client run, complete and in range.
    client: ClientConfig,
    /// A server run, complete and in range.
    server: ServerConfig,
};

/// A client run: which agent to find, and which of its endpoints to expect.
pub const ClientConfig = struct {
    /// Scheme, host and port, with no trailing slash. Discovery is a GET of
    /// the well-known path against this origin; nothing else is dialled.
    base_url: []const u8,
    /// The path-and-query the card is expected to advertise, compared against
    /// the selected binding's URI rather than against a constant.
    expect_endpoint: []const u8,
    /// Where the machine-readable report goes, or null for a run that reports
    /// on standard error only.
    report_file: ?[]const u8 = null,
};

/// A server run: where to listen, what the card says, and how much to serve.
pub const ServerConfig = struct {
    /// The port to listen on, `0..65535`. Zero is the kernel's choice.
    port: u32,
    /// The port the card's advertised URL names, `1..65535`.
    advertise_port: u32,
    /// The path-and-query the card advertises and the POST target answers,
    /// byte for byte. One value for both is what keeps the card and the route
    /// from drifting apart.
    rpc_target: []const u8,
    /// How many requests this run may serve before it stops and reports.
    requests: u32,
    /// Where the machine-readable report goes, or null.
    report_file: ?[]const u8 = null,
};

/// The most requests a server role may be asked to serve.
///
/// A run is bounded so a peer that never hangs up cannot hold the supervisor
/// open, and so the request count the report carries is a number somebody
/// chose rather than a number that happened.
pub const requests_max: u32 = 64;

/// The port a server role may listen on, inclusive.
pub const port_min: u32 = 0;
pub const port_max: u32 = 65535;

/// The port a server role may advertise, inclusive. One is the low end
/// because zero names no port a client can dial.
pub const advertise_port_min: u32 = 1;
pub const advertise_port_max: u32 = 65535;

/// The most words a command line may hold after the program name.
///
/// A complete line is twelve words. An array this size keeps the copy bounded
/// and makes a longer line a refusal rather than a truncation, because a
/// truncated line would parse as a shorter line and run something the reader
/// did not ask for.
const max_words = 24;

/// The usage, in one string so `--help` and a refusal cannot drift apart.
const usage =
    \\usage: a2a-interop --role client --base-url URL --expect-endpoint TARGET [--report-file PATH]
    \\       a2a-interop --role server --port N --advertise-port M --rpc-target TARGET
    \\                    --requests N [--report-file PATH]
    \\       a2a-interop --help
    \\
    \\Drives one end of an A2A 1.0 exchange against a genuine upstream SDK. Every
    \\argument is a flag this participant knows, and every other word is a refusal.
    \\
    \\  --role ROLE           which end of the wire this process is: client or server.
    \\                         Required; there is no default.
    \\  --base-url URL        client only. The origin to discover against: an http
    \\                         or https URL with a host and no path, query or
    \\                         fragment of its own. One trailing slash is accepted
    \\                         and normalized away.
    \\  --expect-endpoint T   client only. The target, optionally with a query, the
    \\                         card is expected to advertise. Checked against the
    \\                         selected binding's URI, so the report says whether
    \\                         the advertised endpoint or a guess was used.
    \\  --port N              server only. The port to listen on, 0..{d}. Zero is
    \\                         the kernel's choice; the supervisor names one of
    \\                         its own instead, because it has to bind its relay
    \\                         in front of this process before the card can name
    \\                         the port that relay is on.
    \\  --advertise-port M    server only. The port the card's advertised URL names,
    \\                         1..{d}. Separate from --port because the supervisor
    \\                         may relay the wire and the card still has to name a
    \\                         port a client can reach.
    \\  --rpc-target TARGET   server only. The target, optionally with a query, the
    \\                         card advertises and that the POST answers, byte for
    \\                         byte.
    \\  --requests N          server only. How many requests this run may serve
    \\                         before it stops and reports, 1..{d}.
    \\  --report-file PATH    where the machine-readable report goes. A run without
    \\                         one reports on standard error only and still exits
    \\                         with the same status.
    \\  --help, -h            print this and run nothing.
    \\
    \\A flag given twice, a flag with no value or with another flag after it, an
    \\unknown flag, a word that is not a flag, a flag the role does not take, a
    \\count that is not decimal digits, a count no u32 holds and a count outside
    \\its range are each refused on standard error beside this usage, with exit
    \\status 2. --help does not hide any of them when it stands on the same line.
    \\
    \\A client writes one JSON report to its report file and a summary to standard
    \\error. A server prints one line of JSON readiness to standard output — the
    \\kernel's port, the port its card advertises, its target and its request
    \\budget — then serves, then writes its report and exits. A failed check is
    \\a non-zero exit and a report whose "failure" member says which check.
    \\
;

// --- the program ---------------------------------------------------------------

/// The program's whole path: read the words, then either print the usage, run a
/// client or run a server.
///
/// Nothing is written to standard output before the line has been read, so a
/// refused line leaves the usage and nothing else — never a partial readiness
/// line that reads like a server that came up.
///
/// A run's own output is answered the same way. The usage, the readiness line
/// and the closing summary each leave this process on a write and a flush, and
/// a fault in any of them is returned from here rather than left under a zero
/// exit status over output nobody received. A refused line is the one
/// exception: `refuse` leaves through `exit(2)` after its own best-effort
/// flush, and the status it has already chosen is what says the line failed.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var words: [max_words][]const u8 = undefined;
    const line = readWords(init, &words) catch |fault| refuse(io, fault);

    const parsed = parseArgs(line) catch |fault| refuse(io, fault);

    switch (parsed) {
        .help => try writeUsage(io, Io.File.stdout()),
        .client => |config| try runClient(io, config),
        .server => |config| try runServer(io, config),
    }
}

/// Read the words after the program name into `storage`.
///
/// The program name is dropped: it is the shell's word, not the participant's,
/// and nothing below reads it. A line with more words than `storage` holds is
/// a refusal rather than a truncation.
fn readWords(init: std.process.Init, storage: *[max_words][]const u8) CliError![]const []const u8 {
    var it = std.process.Args.iterate(init.minimal.args);
    _ = it.skip();

    var count: usize = 0;
    while (it.next()) |argument| {
        if (count == storage.len) return error.UnexpectedArgument;
        // The iterator hands back a sentinel-terminated slice, and the words
        // this file compares are the bytes before the sentinel.
        storage[count] = argument[0..argument.len :0];
        count += 1;
    }
    return storage[0..count];
}

/// Read a command line into a run request, the usage, or the fault that
/// refuses it.
///
/// The parse is a pure function of the words, which is what lets the tests
/// below pin every refusal without starting a process. The order of the checks
/// is the order the failures bind: a word that is not a flag, then a flag
/// nobody knows, then a flag given twice, then the flags the named role does
/// not take, then every value the line carries, then the usage, and only then
/// the required flags a run needs. A word that is *there* and wrong is a fault
/// in the line; a word that is *absent* is a gap in a run, and asking for the
/// usage is a complete request with no run in it to be missing anything.
pub fn parseArgs(args: []const []const u8) CliError!Parsed {
    var role: ?Role = null;
    var base_url: ?[]const u8 = null;
    var expect_endpoint: ?[]const u8 = null;
    var rpc_target: ?[]const u8 = null;
    var port: ?[]const u8 = null;
    var advertise_port: ?[]const u8 = null;
    var requests: ?[]const u8 = null;
    var report_file: ?[]const u8 = null;
    var help = false;
    var seen = std.EnumArray(Flag, bool).initFill(false);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (!isFlag(argument)) return error.UnexpectedArgument;

        const flag = flagOf(argument) orelse return error.UnknownFlag;
        if (seen.get(flag)) return error.DuplicateFlag;
        seen.set(flag, true);

        switch (flag) {
            .help => help = true,
            .role => role = std.meta.stringToEnum(Role, try takeValue(args, &index)) orelse
                return error.InvalidRole,
            .base_url => base_url = try takeValue(args, &index),
            .expect_endpoint => expect_endpoint = try takeValue(args, &index),
            .rpc_target => rpc_target = try takeValue(args, &index),
            .port => port = try takeValue(args, &index),
            .advertise_port => advertise_port = try takeValue(args, &index),
            .requests => requests = try takeValue(args, &index),
            .report_file => report_file = try takeValue(args, &index),
        }
    }

    // A flag the named role does not take, as soon as there is a role to judge it
    // against. A line with no role has nothing to judge against, so the absence
    // is reported below instead — a role that was never named is a different
    // fault from a flag that belongs to the other one.
    if (role) |named| {
        for ([_]Flag{
            .base_url, .expect_endpoint, .rpc_target,
            .port,     .advertise_port,  .requests,
        }) |flag| {
            const takes = switch (named) {
                .client => switch (flag) {
                    .base_url, .expect_endpoint => true,
                    else => false,
                },
                .server => switch (flag) {
                    .rpc_target, .port, .advertise_port, .requests => true,
                    else => false,
                },
            };
            // Asked on whether the flag was given rather than on which value it
            // was given, so a flag that arrived on the wrong role is one fault
            // however many values it carried.
            if (seen.get(flag) and !takes) return error.FlagNotForRole;
        }
    }

    // Every value the line does carry is read and held to its range here, before
    // the usage is answered. A count outside its range is a bad argument
    // whatever else the line says, and a word that is not a count is a bad
    // argument in the same way: both are faults in the line rather than
    // absences from it.
    if (base_url) |url| {
        if (!isOrigin(url)) return error.InvalidBaseUrl;
    }
    if (expect_endpoint) |target| {
        if (!isTarget(target)) return error.InvalidExpectEndpoint;
    }
    if (rpc_target) |target| {
        if (!isTarget(target)) return error.InvalidRpcTarget;
    }
    if (advertise_port) |text| {
        const advertised = try parseCount(text);
        if (advertised < advertise_port_min or advertised > advertise_port_max) {
            return error.AdvertisePortOutOfRange;
        }
    }
    if (port) |text| {
        const listen = try parseCount(text);
        if (listen < port_min or listen > port_max) return error.PortOutOfRange;
    }
    if (requests) |text| {
        const budget = try parseCount(text);
        if (budget == 0 or budget > requests_max) return error.RequestsOutOfRange;
    }

    // Answered after every fault above and before every absence below, because
    // the usage is the whole answer to a line that asked for it — there is
    // nothing left to run and therefore nothing left to require — while a
    // required flag that is missing is a gap in a run somebody asked for.
    if (help) return .help;

    // Which end of the wire this process is, is the one thing the reader has to
    // say: there is no default role, and `--report-file` is the one flag both
    // roles take, so it cannot stand in for one.
    const chosen = role orelse return error.MissingRole;

    return switch (chosen) {
        .client => .{ .client = .{
            .base_url = stripTrailingSlash(base_url orelse return error.MissingBaseUrl),
            .expect_endpoint = expect_endpoint orelse return error.MissingExpectEndpoint,
            .report_file = report_file,
        } },
        .server => .{ .server = .{
            .port = if (port) |text| try parseCount(text) else port_min,
            .advertise_port = try parseCount(
                advertise_port orelse return error.MissingAdvertisePort,
            ),
            .rpc_target = rpc_target orelse return error.MissingRpcTarget,
            .requests = try parseCount(requests orelse return error.MissingRequests),
            .report_file = report_file,
        } },
    };
}

/// The flags this participant knows, named by the exact word that names each one.
const Flag = enum {
    role,
    base_url,
    expect_endpoint,
    port,
    advertise_port,
    rpc_target,
    requests,
    report_file,
    help,
};

/// The flag a word names, or null for a word that names none.
///
/// The match is on the whole word, so a joined spelling and a name spelled
/// differently are both unknown flags: guessing at either would run something
/// the reader did not ask for.
fn flagOf(argument: []const u8) ?Flag {
    const table = .{
        .{ "--role", Flag.role },
        .{ "--base-url", Flag.base_url },
        .{ "--expect-endpoint", Flag.expect_endpoint },
        .{ "--port", Flag.port },
        .{ "--advertise-port", Flag.advertise_port },
        .{ "--rpc-target", Flag.rpc_target },
        .{ "--requests", Flag.requests },
        .{ "--report-file", Flag.report_file },
        .{ "--help", Flag.help },
        .{ "-h", Flag.help },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, argument, entry[0])) return entry[1];
    }
    return null;
}

/// Whether a word names a flag rather than supplying a value.
///
/// A `-` followed by a digit is a signed number and not a flag. `-1` is a
/// mistake a reader makes often enough to deserve the `NotANumber` the count
/// parser gives it rather than the `MissingValue` a flag would produce, and
/// `std.fmt.parseInt` alone would not give it that: it reads the sign, negates
/// and returns an overflow.
fn isFlag(argument: []const u8) bool {
    if (argument.len < 2 or argument[0] != '-') return false;
    return !std.ascii.isDigit(argument[1]);
}

/// The word after a flag that takes one, advancing past it.
///
/// A flag is not a value, so a flag at the end of the line and a flag followed
/// by another flag are one fault: the value is missing, not wrong.
fn takeValue(args: []const []const u8, index: *usize) CliError![]const u8 {
    if (index.* + 1 >= args.len or isFlag(args[index.* + 1])) return error.MissingValue;
    index.* += 1;
    return args[index.*];
}

/// A count as a `u32`.
///
/// The digits are checked here rather than left to `parseInt`, because the two
/// faults a bad count can be are different faults: a word that is not a number
/// is `NotANumber`, and a number no `u32` holds is `CountOverflow`.
fn parseCount(text: []const u8) CliError!u32 {
    if (text.len == 0) return error.NotANumber;
    for (text) |digit| {
        if (!std.ascii.isDigit(digit)) return error.NotANumber;
    }
    return std.fmt.parseInt(u32, text, 10) catch error.CountOverflow;
}

/// Whether a word is an origin this participant will dial.
///
/// The check is here rather than left to the URI parser because the two faults
/// are different faults: a reader who typed a path where an origin belongs and
/// a reader who typed `ftp://` have to be told different things, and both are
/// refusals rather than a URL a dialer would try and fail on.
fn isOrigin(text: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, text, "://") orelse return false;
    if (!std.mem.eql(u8, text[0..scheme_end], "http") and
        !std.mem.eql(u8, text[0..scheme_end], "https")) return false;
    const authority = text[scheme_end + 3 ..];
    // An origin is a scheme, a host and a port, and nothing else. A path, a
    // query or a fragment here is a request the peer was never asked for, and
    // the well-known path is appended by the discovery request itself.
    const cut = std.mem.indexOfAny(u8, authority, "/?#") orelse return authority.len != 0;
    // One exception, in one position: a single trailing slash is the origin
    // spelled the way a URL is usually typed, so it is normalized away rather
    // than refused. A second slash, a slash with anything behind it, and a
    // bare `http:///` whose host is empty are three different words, and none
    // of them is that origin.
    return cut == authority.len - 1 and cut != 0 and authority[cut] == '/';
}

/// The origin without a single trailing slash, so the value a report prints and
/// the value the dialer is given are the same bytes.
fn stripTrailingSlash(text: []const u8) []const u8 {
    if (std.mem.endsWith(u8, text, "/")) return text[0 .. text.len - 1];
    return text;
}

/// Whether a word is a request target: a path, optionally with a query.
///
/// Deliberately narrower than "any URI". A target is what goes on the request
/// line, so it begins with `/`, carries no scheme, no authority and no
/// fragment, and a query is allowed because a card may advertise one and a
/// client that dropped it would not be using the endpoint it was told about.
fn isTarget(text: []const u8) bool {
    if (text.len == 0 or text[0] != '/') return false;
    if (std.mem.findScalar(u8, text, '#') != null) return false;
    if (std.mem.indexOf(u8, text, "://") != null) return false;
    // A target with nothing but a query names no path.
    const cut = std.mem.findScalar(u8, text, '?') orelse return true;
    return cut != 1;
}

/// Write the usage, with every bound printed from the names it bounds.
fn writeUsage(io: Io, file: Io.File) !void {
    var buffer: [4096]u8 = undefined;
    var stream = file.writer(io, &buffer);
    try stream.interface.print(usage, .{
        port_max, advertise_port_max, requests_max,
    });
    // The usage leaves this process on this one flush, so a `--help` answered
    // with no usage and a zero status would be a success that never happened:
    // the fault is returned to `main`, which is the only way this participant
    // can say it did not write what it was asked for.
    try stream.flush();
}

/// The fault as a phrase, for the line that precedes the usage.
///
/// The phrase names the fault rather than the offending word, because
/// [`CliError`] is where the fault is kept and a word the reader already typed
/// does not need repeating; the usage that follows names every word this
/// participant takes.
fn reason(fault: CliError) []const u8 {
    return switch (fault) {
        error.UnknownFlag => "an unknown flag",
        error.DuplicateFlag => "a flag given twice",
        error.MissingValue => "a flag with no value after it",
        error.UnexpectedArgument => "an argument that is not a flag",
        error.FlagNotForRole => "a flag the role on this line does not take",
        error.MissingRole => "no --role, and there is no default role",
        error.InvalidRole => "a role that is not client or server",
        error.MissingBaseUrl => "no --base-url for a client",
        error.InvalidBaseUrl => "a base URL that is not an http or https origin",
        error.MissingExpectEndpoint => "no --expect-endpoint for a client",
        error.InvalidExpectEndpoint => "an expected endpoint that is not a target",
        error.MissingRpcTarget => "no --rpc-target for a server",
        error.InvalidRpcTarget => "an RPC target that is not a target",
        error.MissingAdvertisePort => "no --advertise-port for a server, or one that is zero",
        error.AdvertisePortOutOfRange => "an advertise port outside 1..65535",
        error.MissingRequests => "no --requests for a server",
        error.NotANumber => "a count that is not a run of decimal digits",
        error.CountOverflow => "a count no u32 holds",
        error.PortOutOfRange => "a listen port outside 0..65535",
        error.RequestsOutOfRange => "requests outside 1..64",
    };
}

/// Say what was wrong with the line, print the usage beside it, and leave with
/// the status a refused line gets.
///
/// `noreturn`, because there is nothing to dial, serve or report: the only
/// honest answer to a line this participant refuses is to stop. The buffer
/// holds a whole refusal, because a message that arrives in two writes is a
/// message another line can land in the middle of.
fn refuse(io: Io, fault: CliError) noreturn {
    var buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    const err = &stderr.interface;

    // A refused line is about to leave the process, and this is the only place
    // it can say why. A write to a closed or full standard error has nowhere
    // else to go: reporting it would need another write to the same stream.
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    err.print("a2a-interop: {s}\n", .{reason(fault)}) catch {};
    err.print(usage, .{ port_max, advertise_port_max, requests_max })
    // The rest of the same refusal: the usage follows the phrase on the same
    // stream, and the phrase above already established that a failed write
    // there cannot be reported any other way.
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    catch {};
    // `exit` runs no defer, so the message is flushed here rather than on the
    // way out: a refusal the reader never sees is a refusal that did not happen,
    // and this is the one chance it has of reaching them.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    stderr.flush() catch {};
    std.process.exit(2);
}

// --- what a run concluded ------------------------------------------------------

/// What the client role concluded, in the order the supervisor reads it.
const ClientReport = struct {
    // SAFETY: `copyBounded` writes it and stores the count the report slices it with.
    expected_endpoint: [256]u8 = undefined,
    expected_endpoint_len: usize = 0,
    // SAFETY: `writeTarget` writes the target and returns the count it wrote alongside.
    selected_endpoint: [256]u8 = undefined,
    selected_endpoint_len: usize = 0,
    // SAFETY: `copyBounded` writes it and stores the count the report slices it with.
    selected_binding: [64]u8 = undefined,
    selected_binding_len: usize = 0,
    // SAFETY: `copyBounded` writes it and stores the count the report slices it with.
    selected_version: [64]u8 = undefined,
    selected_version_len: usize = 0,
    /// Which entry of `supportedInterfaces` the selection chose, read back from
    /// the binding rather than counted here: a client that selected the first
    /// entry because it could and one that selected it because the card said so
    /// produce the same index and mean different things.
    interface_index: usize = 0,
    endpoint_matched: bool = false,
    // SAFETY: `copyBounded` writes it and stores the count the report slices it with.
    task_id: [128]u8 = undefined,
    task_id_len: usize = 0,
    /// The state the Task came back in, spelled the way the wire spells it:
    /// `TASK_STATE_COMPLETED`, not the Zig field name no peer ever sends.
    // SAFETY: `copyBounded` writes the wire spelling and stores the count it slices with.
    task_state: [64]u8 = undefined,
    task_state_len: usize = 0,
    // SAFETY: `copyBounded` writes it and stores the count the report slices it with.
    task_text: [256]u8 = undefined,
    task_text_len: usize = 0,
    // SAFETY: `copyBounded` writes it and stores the count the report slices it with.
    message_id: [128]u8 = undefined,
    message_id_len: usize = 0,
    // SAFETY: `copyBounded` writes it and stores the count the report slices it with.
    message_text: [256]u8 = undefined,
    message_text_len: usize = 0,
    peer_error_code: i32 = 0,
    // SAFETY: `copyBounded` writes it and stores the count the report slices it with.
    peer_error_message: [128]u8 = undefined,
    peer_error_message_len: usize = 0,
    // SAFETY: `fail` writes it and stores the count every reader of the failure slices with.
    failure: [512]u8 = undefined,
    failure_len: usize = 0,
    ok: bool = false,
};

/// What the server role concluded.
const ServerReport = struct {
    listen_port: u16 = 0,
    advertise_port: u16 = 0,
    // SAFETY: `runServer` copies it before the role runs and the report document reads it.
    rpc_target: [256]u8 = undefined,
    rpc_target_len: usize = 0,
    // SAFETY: `runServer` copies it before the role runs and the report document reads it.
    card_path: [128]u8 = undefined,
    card_path_len: usize = 0,
    requests_served: u32 = 0,
    send_message_answers: u32 = 0,
    task_answers: u32 = 0,
    message_answers: u32 = 0,
    // SAFETY: `fail` writes it and stores the count every reader of the failure slices with.
    failure: [512]u8 = undefined,
    failure_len: usize = 0,
    ok: bool = false,
};

// --- the client role -----------------------------------------------------------

fn runClient(io: Io, config: ClientConfig) !void {
    var report: ClientReport = .{};
    clientRole(io, config, &report) catch |err| {
        fail("the client role failed: {s}", .{@errorName(err)}, &report);
    };
    try finishClient(io, config, &report);
}

/// The client's whole exchange, in the order the specification requires.
///
/// Every early return here has already recorded why, and every one of them
/// still falls through to the report, because a run that stops without saying
/// which check stopped it is a run nobody can act on.
fn clientRole(io: Io, config: ClientConfig, report: *ClientReport) !void {
    copyBounded(&report.expected_endpoint, &report.expected_endpoint_len, config.expect_endpoint);

    // 1. The origin to discover against. The word is checked by `parseArgs` and
    // parsed here, so a value that got past the check and fails to parse is
    // still a refusal rather than a dialled guess.
    const origin = std.Uri.parse(config.base_url) catch {
        fail("the base URL did not parse as a URI", .{}, report);
        return;
    };

    var http: std.http.Client = .{ .allocator = std.heap.smp_allocator, .io = io };
    defer http.deinit();

    // 2. Discovery. The card's arena is storage at file scope, because the
    // binding this returns borrows the card's body and the client keeps that
    // binding for the rest of the run.
    var card = cardArena();
    const discovered = try a2a_http.discover(io, &http, origin, .{
        .transfer = &buffers.discovery_transfer,
        .body = &buffers.discovery_body,
        .scratch = &buffers.discovery_scratch,
    }, &card);
    const binding = discovered.binding;

    // The selected binding is read out of the card rather than written down, so
    // the report says which interface the card named rather than which one this
    // file expected to find.
    const selected = discovered.card.supported_interfaces[binding.interface_index];
    report.selected_endpoint_len = writeTarget(&report.selected_endpoint, binding.uri);
    copyBounded(&report.selected_binding, &report.selected_binding_len, selected.protocol_binding);
    copyBounded(&report.selected_version, &report.selected_version_len, selected.protocol_version);
    report.interface_index = binding.interface_index;

    // 3. The endpoint check. This is the claim the whole direction turns on: the
    // endpoint the client dialled is the one the card advertised, path and
    // query alike, and not a target this file could have reconstructed.
    report.endpoint_matched = targetMatches(binding.uri, config.expect_endpoint);
    if (!report.endpoint_matched) {
        fail("the selected endpoint is not the advertised endpoint this run was told " ++
            "to expect", .{}, report);
        return;
    }

    var client = try a2a_http.Client.init(io, &http, binding);

    // 4. The Task arm, then the Message arm. Both are read as whichever arm the
    // peer's answer carries, and an answer carrying both or neither is a
    // failure: the oneof has exactly two arms and a client that accepted a
    // third would be reading a shape the wire does not have.
    if (!send(io, &client, ask_for_task, .task, report)) return;
    if (!send(io, &client, ask_for_message, .message, report)) return;
}

/// Which arm of the result `oneof` a call is expected to come back as.
const Expect = enum { task, message };

/// One typed `SendMessage`, and the check on the arm it came back as.
fn send(io: Io, client: *a2a_http.Client, text: []const u8, expected: Expect, report: *ClientReport) bool {
    // The request's own storage lives at file scope: `sendMessage` borrows it
    // for the length of the call, and the call is what encodes it.
    buffers.request_parts[0] = .{ .content = .{ .text = text } };
    const request: a2a.SendMessageRequest = .{
        .message = .{
            .message_id = request_message_id,
            .role = .user,
            .parts = buffers.request_parts[0..1],
        },
    };

    // A fresh arena per call: the one below resets itself at its public
    // boundary, and two calls sharing one arena would have the second decode
    // write over the first one's values.
    var content = contentArena();

    const reply = client.sendMessage(io, request, .{
        .transfer = &buffers.send_transfer,
        .body = &buffers.send_body,
        .scratch = &buffers.send_scratch,
        .params = &buffers.send_params,
        .envelope = &buffers.send_envelope,
        .base64 = &buffers.send_base64,
    }, &content) catch |err| {
        fail("SendMessage: the call failed, was refused before the wire, or came back " ++
            "as something that is not one answer to one request: {s}", .{@errorName(err)}, report);
        return false;
    };

    switch (reply.outcome) {
        .peer_error => |object| {
            // An explicit peer error is an outcome of its own, kept beside the
            // code and the message rather than folded into a transport failure:
            // it says what the peer said, and a client that turned it into a
            // socket error would be saying something the wire does not.
            report.peer_error_code = object.code;
            copyBounded(&report.peer_error_message, &report.peer_error_message_len, object.message);
            fail("SendMessage came back as a peer error where a result was expected, " ++
                "code {d}", .{object.code}, report);
            return false;
        },
        .result => |response| switch (response) {
            .task => |task| {
                if (expected != .task) {
                    fail("SendMessage came back with a Task where a Message was asked for", .{}, report);
                    return false;
                }
                copyBounded(&report.task_id, &report.task_id_len, task.id);
                // The ProtoJSON spelling, which is what crossed the wire. The
                // Zig field name is a library convenience, and a report whose
                // every other text is copied off the wire has to say this one
                // in the peer's spelling too.
                copyBounded(&report.task_state, &report.task_state_len, task.status.state.wireName());
                const text_of_task = taskText(&task);
                copyBounded(&report.task_text, &report.task_text_len, text_of_task);
                if (report.task_id_len == 0 or report.task_text_len == 0) {
                    fail("the Task that came back carried no id or no text", .{}, report);
                    return false;
                }
                return true;
            },
            .message => |answer| {
                if (expected != .message) {
                    fail("SendMessage came back with a Message where a Task was asked for", .{}, report);
                    return false;
                }
                copyBounded(&report.message_id, &report.message_id_len, answer.message_id);
                const text_of_message = textOfParts(answer.parts);
                copyBounded(&report.message_text, &report.message_text_len, text_of_message);
                if (report.message_id_len == 0 or report.message_text_len == 0) {
                    fail("the Message that came back carried no id or no text", .{}, report);
                    return false;
                }
                return true;
            },
        },
    }
}

/// The first text part of a message, or null when it carries none.
///
/// Read through the message's own parts rather than by a substring of the raw
/// body, so a peer that answers with a part of another kind is a message with
/// no text and not a message whose text happens to be somewhere else.
fn textOfMessage(message: *const a2a.Message) []const u8 {
    return textOfParts(message.parts);
}

/// The first text part of a part list, or the empty string when there is none.
fn textOfParts(parts: []const a2a.Part) []const u8 {
    for (parts) |part| switch (part.content) {
        .text => |text| return text,
        else => {},
    };
    return "";
}

/// The text a task carries: its first artifact, then its status message.
///
/// A Task and a Message are the two arms of one `oneof`, and this is where the
/// task arm's text lives, so the check on it is the same check the message arm
/// gets rather than a special case for whichever arm arrived.
fn taskText(task: *const a2a.Task) []const u8 {
    if (task.artifacts) |artifacts| {
        for (artifacts) |*artifact| {
            const text = textOfParts(artifact.parts);
            if (text.len != 0) return text;
        }
    }
    if (task.status.message) |*status_message| return textOfMessage(status_message);
    return "";
}

// --- the server role -----------------------------------------------------------

fn runServer(io: Io, config: ServerConfig) !void {
    var report: ServerReport = .{};
    copyBounded(&report.rpc_target, &report.rpc_target_len, config.rpc_target);
    copyBounded(&report.card_path, &report.card_path_len, a2a.discovery_path);
    serverRole(io, config, &report) catch |err| {
        fail("the server role failed: {s}", .{@errorName(err)}, &report);
    };
    try finishServer(io, config, &report);
}

/// The server's whole life: bind, report the port, serve, hang up.
fn serverRole(io: Io, config: ServerConfig, report: *ServerReport) !void {
    const address = try Io.net.IpAddress.parse("127.0.0.1", @intCast(config.port));
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);

    // The kernel's choice, read back off the listening socket, so two runs and
    // two tests cannot collide over a port.
    report.listen_port = listener.socket.address.getPort();

    // The card names the advertised port, not the listening one, and the target
    // it serves is the same word the card advertises. The URL is composed into
    // storage the runtime borrows for the life of the call, so it is a fixed
    // buffer rather than something built on the way in and gone by the time the
    // card is encoded.
    const url = try std.fmt.bufPrint(&buffers.advertised_url, "http://127.0.0.1:{d}{s}", .{
        config.advertise_port,
        config.rpc_target,
    });
    report.advertise_port = @intCast(config.advertise_port);
    buffers.answer_parts[0] = .{ .content = .{ .text = marker ++ ":echo" } };

    try announce(io, report, config);

    const interfaces = [_]a2a.AgentInterface{.{
        .url = url,
        .protocol_binding = a2a.binding.jsonrpc,
        .protocol_version = version_wire,
    }};
    const card = agentCard(&interfaces);
    // The served count lives in the report rather than in a local, for the
    // reason the handler's answer counters do: every path out of this function
    // goes through `report`, including the ones a `try` takes out of it, so a
    // count kept in a local is a number a failed run's report cannot state
    // beside the answers this run really gave.
    while (report.requests_served < config.requests) {
        // `accept` waits on a listening socket, which no peer can shut down, so
        // the bound is the request budget rather than a timeout: a peer that
        // never connects leaves this wait, and the supervisor's own deadline is
        // what ends the run and reports it.
        const stream = try listener.accept(io);
        // `shutdown` before `close`: a close on a socket whose peer still has
        // unread bytes in its receive queue answers with a reset, and the reset
        // discards those bytes, so a client that has not read its reply yet
        // loses it.
        defer {
            // A shutdown that failed changes nothing: `close` below ends the socket anyway.
            // gate-reviewed-zlint-next-statement: suppressed-errors
            stream.shutdown(io, .both) catch {};
            stream.close(io);
        }

        // `std.http.Server` keeps raw pointers to both halves of the stream, so
        // they are fields of the participant rather than locals of this
        // function.
        buffers.stream_reader = Io.net.Stream.Reader.init(stream, io, &buffers.read_buffer);
        buffers.stream_writer = Io.net.Stream.Writer.init(stream, io, &buffers.write_buffer);
        buffers.server = std.http.Server.init(
            &buffers.stream_reader.interface,
            &buffers.stream_writer.interface,
        );

        // A fresh arena per connection rather than one reset by hand: the reset
        // is what every public decoder does at its own boundary, and an arena
        // still holding the previous connection's values would be one this file
        // has to remember to clear.
        var content = contentArena();

        // One request per call. A call that answers leaves the connection open
        // for the next request on it, which is what an HTTP/1.1 peer holding a
        // keep-alive connection expects; a call that returns false saw clean
        // end of file, and the next connection is accepted below.
        while (try a2a_http.serve(io, &buffers.server, card, config.rpc_target, .{
            .ctx = report,
            .call = echo,
        }, .{
            .transfer = &buffers.serve_transfer,
            .body = &buffers.serve_body,
            .envelope_scratch = &buffers.serve_envelope_scratch,
            .payload_scratch = &buffers.serve_payload_scratch,
            .payload_out = &buffers.serve_payload_out,
            .envelope_out = &buffers.serve_envelope_out,
            .base64 = &buffers.serve_base64,
        }, &content)) {
            report.requests_served += 1;
            if (report.requests_served >= config.requests) break;
        }
    }
}

/// The one line of readiness, on standard output, which the wire does not use.
///
/// The port the kernel gave the listening socket is only knowable here, so the
/// supervisor's wait for this line is what tells it which port to relay to.
fn announce(io: Io, report: *const ServerReport, config: ServerConfig) !void {
    var line: [1024]u8 = undefined;
    const ready = try readinessLine(&line, report, config);

    var buffer: [2048]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    // The readiness line is the supervisor's only way to learn the port the
    // kernel gave this run, and it is what this process has to answer with
    // before it serves a single request. A line that cannot be written is not
    // a line a supervisor can wait for: it would sit on its own deadline for
    // a run that has already failed to say it came up. So the write is
    // reported here, and so is the flush that carries it, and the run stops
    // here rather than serving behind a readiness nobody received.
    try stdout.interface.writeAll(ready);
    try stdout.flush();
}

/// The readiness line as one JSON object and the newline that ends it.
///
/// Composed with the library's JSON writer over a buffer the caller owns,
/// rather than with a format string over the process's own writer, for the two
/// reasons the supervisor depends on: a value the peer named is escaped the way
/// JSON requires, and a buffer that cannot hold the whole line is an error
/// here rather than a half-written line the supervisor would read as a ready
/// one. Nothing is borrowed past the call, because the writer is built here
/// and the result points into the buffer that was passed in.
///
/// The 1024 bytes the caller hands this are a bound rather than a guess. Every
/// member but the target is a literal or a number of at most five digits, so
/// what the target itself occupies is what the line has left for it; a target
/// the buffer cannot hold is `error.BufferTooSmall` out of here, and the run
/// records that rather than announcing a port beside a truncated target.
fn readinessLine(
    out: []u8,
    report: *const ServerReport,
    config: ServerConfig,
) proto.EncodeError![]const u8 {
    var text = json.Writer.init(out);
    try text.slice("{\"event\":\"listening\",\"port\":");
    try number(&text, report.listen_port);
    try text.slice(",\"advertise_port\":");
    try number(&text, report.advertise_port);
    try text.slice(",\"rpc_target\":");
    try text.string(config.rpc_target);
    try text.slice(",\"card_path\":");
    try text.string(a2a.discovery_path);
    try text.slice(",\"protocol_version\":");
    try text.string(version_wire);
    try text.slice(",\"requests\":");
    try number(&text, config.requests);
    try text.slice(",\"a2a_interop\":");
    try text.string(marker);
    try text.slice("}\n");
    return text.written();
}

/// The card borrows its interfaces and URL from the server's live storage.
/// The remaining members contain only constants.
fn agentCard(interfaces: []const a2a.AgentInterface) a2a.AgentCard {
    return .{
        .name = marker,
        .description = "Interoperability participant for zig-agent-proto. " ++
            "Fixed inputs, fixed outputs.",
        .supported_interfaces = interfaces,
        .version = card_version,
        .capabilities = .{ .streaming = false, .push_notifications = false },
        .default_input_modes = &[_][]const u8{"text/plain"},
        .default_output_modes = &[_][]const u8{"text/plain"},
        .skills = &[_]a2a.AgentSkill{.{
            .id = "echo",
            .name = "echo",
            .description = "Answer a message with a Task, or with a Message when the text " ++
                "asks for it.",
            .tags = &[_][]const u8{"interop"},
            .examples = &[_][]const u8{ ask_for_task, ask_for_message },
            .input_modes = &[_][]const u8{"text/plain"},
            .output_modes = &[_][]const u8{"text/plain"},
        }},
    };
}

/// The handler the runtime calls for a decoded `SendMessage`.
///
/// The answer is built in storage at file scope and the switch is on the
/// request's own text, so the arm the caller asked for is the arm it gets and
/// nothing here re-reads the raw body.
// The parameter order is `a2a_http.Handler.call`'s own, and that
// function-pointer type is a frozen part of the binding's published surface,
// so the executor stays where the type puts it rather than moving ahead of the
// context the same type hands back.
// ziglint-ignore: Z023
fn echo(ctx: ?*anyopaque, io: Io, request: a2a.SendMessageRequest) anyerror!a2a_http.Outcome {
    _ = io;
    const report: *ServerReport = @ptrCast(@alignCast(ctx orelse return error.NoContext));

    const text = textOfMessage(&request.message);
    if (std.mem.indexOf(u8, text, ask_for_message) != null) {
        report.send_message_answers += 1;
        report.message_answers += 1;
        return .{ .result = .{ .message = .{
            .message_id = answer_message_id,
            .role = .agent,
            .parts = buffers.answer_parts[0..1],
        } } };
    }
    report.send_message_answers += 1;
    report.task_answers += 1;
    return .{ .result = .{ .task = .{
        .id = answer_task_id,
        .status = .{ .state = .completed },
        .artifacts = &[_]a2a.Artifact{.{
            .artifact_id = answer_artifact_id,
            .name = "echo",
            .parts = buffers.answer_parts[0..1],
        }},
    } } };
}

// --- storage -------------------------------------------------------------------

// Every buffer this file needs is at file scope, because the runtime borrows
// pointers to them and those pointers have to outlive the call. The decoders'
// scratch is one region used one at a time: a decoded value is read before the
// next one is decoded, so no two borrows out of it are live at once.

var buffers: struct {
    // SAFETY: `discover` fills it per discovery and the card borrows only what it wrote.
    discovery_transfer: [8192]u8 = undefined,
    // SAFETY: `discover` fills it per discovery; the binding borrows that card's own run.
    discovery_body: [64 * 1024]u8 = undefined,
    // SAFETY: `discover` unescapes into it per discovery, before anything reads it back.
    discovery_scratch: [16 * 1024]u8 = undefined,

    // SAFETY: `send` hands it to the client, which fills it on every call.
    send_transfer: [8192]u8 = undefined,
    // SAFETY: `send` hands it to the client, which fills it on every call.
    send_body: [128 * 1024]u8 = undefined,
    // SAFETY: `send` hands it to the client as decode scratch, written before it is read.
    send_scratch: [32 * 1024]u8 = undefined,
    // SAFETY: `send` hands it to the client, which encodes the params into it.
    send_params: [32 * 1024]u8 = undefined,
    // SAFETY: `send` hands it to the client, which encodes the envelope into it.
    send_envelope: [32 * 1024]u8 = undefined,
    // SAFETY: `send` hands it to the client as the base64 run it encodes into.
    send_base64: [8 * 1024]u8 = undefined,

    // SAFETY: `serverRole` hands it to `serve`, which reads chunk lengths into it.
    serve_transfer: [8192]u8 = undefined,
    // SAFETY: `serverRole` hands it to `serve`, which fills it for every request.
    serve_body: [128 * 1024]u8 = undefined,
    // SAFETY: `serverRole` hands it to `serve` as scratch it decodes into before using.
    serve_envelope_scratch: [64 * 1024]u8 = undefined,
    // SAFETY: `serverRole` hands it to `serve` as scratch it decodes into before using.
    serve_payload_scratch: [64 * 1024]u8 = undefined,
    // SAFETY: `serverRole` hands it to `serve`, which encodes the answer into it.
    serve_payload_out: [128 * 1024]u8 = undefined,
    // SAFETY: `serverRole` hands it to `serve`, which encodes the reply envelope into it.
    serve_envelope_out: [32 * 1024]u8 = undefined,
    // SAFETY: `serverRole` hands it to `serve` as the base64 run it encodes into.
    serve_base64: [8 * 1024]u8 = undefined,

    // SAFETY: `serverRole` hands it to the stream reader it assigns below.
    read_buffer: [16 * 1024]u8 = undefined,
    // SAFETY: `serverRole` hands it to the stream writer it assigns below.
    write_buffer: [16 * 1024]u8 = undefined,
    // SAFETY: `serverRole` assigns it before `serve` builds the server out of it.
    stream_reader: Io.net.Stream.Reader = undefined,
    // SAFETY: `serverRole` assigns it before `serve` builds the server out of it.
    stream_writer: Io.net.Stream.Writer = undefined,
    // SAFETY: `serverRole` assigns it from the two fields above before any request runs.
    server: std.http.Server = undefined,

    // SAFETY: `serverRole` bufPrints the URL and the card it serves borrows that run.
    advertised_url: [128]u8 = undefined,
    // SAFETY: `send` assigns element 0 before the request borrowing it goes out.
    request_parts: [2]a2a.Part = undefined,
    // SAFETY: `serverRole` assigns element 0 before `echo` answers out of it.
    answer_parts: [1]a2a.Part = undefined,
} = .{};

/// The card arena over storage that outlives every discovery response.
var card_interfaces: [8]a2a.AgentInterface = undefined;
var card_skills: [8]a2a.AgentSkill = undefined;
var card_extensions: [4]a2a.AgentExtension = undefined;
var card_signatures: [2]a2a.AgentCardSignature = undefined;
var card_schemes: [4]a2a.SecuritySchemeEntry = undefined;
var card_requirements: [4]a2a.SecurityRequirement = undefined;
var card_requirement_entries: [8]a2a.SecurityRequirementEntry = undefined;
var card_scopes: [8]a2a.OAuthScope = undefined;
var card_strings: [64][]const u8 = undefined;

/// The content arena over storage that outlives every decoded document.
var content_parts: [64]a2a.Part = undefined;
var content_artifacts: [16]a2a.Artifact = undefined;
var content_messages: [32]a2a.Message = undefined;
var content_strings: [64][]const u8 = undefined;
var content_bytes: [8 * 1024]u8 = undefined;

/// The arena the discovery decodes its card into.
fn cardArena() a2a.CardArena {
    return a2a.CardArena.init(
        &card_interfaces,
        &card_skills,
        &card_extensions,
        &card_signatures,
        &card_schemes,
        &card_requirements,
        &card_requirement_entries,
        &card_scopes,
        &card_strings,
    );
}

/// The arena a `SendMessage` decodes into.
///
/// A fresh value per call rather than one arena reset by hand: the reset is
/// what every public decoder does at its own boundary, and an arena that was
/// left holding a previous call's values would be one this file has to
/// remember to clear.
fn contentArena() a2a.ContentArena {
    return a2a.ContentArena.init(
        &content_parts,
        &content_artifacts,
        &content_messages,
        &content_strings,
        &content_bytes,
    );
}

// --- endpoints -----------------------------------------------------------------

/// The text of a URI component, whichever of the two spellings it holds.
fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw, .percent_encoded => |text| text,
    };
}

/// Copy a URI's path and query into a fixed field, as a request target.
///
/// No allocation and no intermediate: the two components are copied one after
/// the other, and a target with no query is a target with no `?` in it either.
fn writeTarget(field: []u8, uri: std.Uri) usize {
    var written: usize = 0;
    written += copyInto(field, written, componentText(uri.path));
    if (uri.query) |query| {
        written += copyInto(field, written, "?");
        written += copyInto(field, written, componentText(query));
    }
    return written;
}

fn copyInto(field: []u8, at: usize, text: []const u8) usize {
    const room = @min(text.len, field.len -| at);
    @memcpy(field[at..][0..room], text[0..room]);
    return room;
}

/// Whether a URI names exactly the target that was expected.
///
/// Compared in pieces rather than by formatting the URI into a string and
/// comparing text, because a comparison that goes through a formatted copy is a
/// comparison whose result depends on the formatter.
fn targetMatches(uri: std.Uri, expected: []const u8) bool {
    const cut = std.mem.findScalar(u8, expected, '?');
    const want_path = if (cut) |at| expected[0..at] else expected;
    if (!std.mem.eql(u8, componentText(uri.path), want_path)) return false;
    const want_query = if (cut) |at| expected[at + 1 ..] else null;
    if (uri.query) |query| {
        return std.mem.eql(u8, componentText(query), want_query orelse "");
    }
    return want_query == null;
}

// --- reporting -----------------------------------------------------------------

/// Copy a decoded string into a field's own storage, and report its length.
///
/// The decode scratch is reused by the next call, so a report field that
/// borrowed from it would say whatever the last decode left behind. Truncating
/// rather than refusing keeps a long peer string from turning a check into a
/// failure: a check compares the whole text, and only the report is bounded.
fn copyBounded(field: []u8, len: *usize, text: []const u8) void {
    len.* = copyInto(field, 0, text);
}

/// Record the first failure, and take the report's verdict with it.
///
/// A later failure is a consequence of the first, so the first one is the
/// message that gets kept. The verdict is cleared on every path through here
/// because a report that says `ok` beside a `failure` is the one artefact that
/// could be read as a passing run.
fn fail(comptime format: []const u8, args: anytype, report: anytype) void {
    report.ok = false;
    if (report.failure_len != 0) return;
    var buffer: [512]u8 = undefined;
    const written = std.fmt.bufPrint(&buffer, format, args) catch {
        report.failure_len = copyInto(&report.failure, 0, format);
        return;
    };
    report.failure_len = copyInto(&report.failure, 0, written);
}

/// One member's value as a decimal integer.
///
/// Formatted into a small buffer and then written into the document, which is
/// how every number in every report and in the readiness line is spelled: one
/// place, so a port and a count cannot each look like something different.
fn number(text: *json.Writer, value: anytype) proto.EncodeError!void {
    var buffer: [24]u8 = undefined;
    const written = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.BufferTooSmall;
    try text.slice(written);
}

/// One member's value as a JSON boolean.
///
/// Written unquoted: a reader of the evidence reads `true` beside `ok` as the
/// verdict this run reached, and a quoted word is a string it would have to
/// know to unquote before it could believe.
fn boolean(text: *json.Writer, value: bool) proto.EncodeError!void {
    try text.slice(if (value) "true" else "false");
}

fn finishClient(io: Io, config: ClientConfig, report: *ClientReport) !void {
    report.ok = report.failure_len == 0;

    var buffer: [2048]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    const err = &stderr.interface;

    // The report file is what a supervisor reads this run out of, so one that
    // could not be written is a run nobody can check. The fault is recorded
    // rather than swallowed, and recording a fault takes the verdict with it,
    // so the line below and the exit status say the report is missing instead
    // of the process leaving a success behind a file that was never produced.
    writeClientReport(io, config, report) catch |write_fault| {
        fail("the report file could not be written: {s}", .{@errorName(write_fault)}, report);
    };

    // Everything below writes the run's human-readable summary to standard
    // error, after the report file has been written and the verdict has been
    // taken from it. Each line goes into the buffer above rather than onto the
    // descriptor, and the longest of them is the failure line: a fixed 28-byte
    // phrase followed by every byte `copyInto` will put in the 512-byte
    // `ClientReport.failure`, which is 541 with the newline against this
    // function's 2048-byte buffer. So no line here can fill that buffer and
    // begin a write of its own, and what they can meet is the stream itself —
    // which is the flush at the end below.
    if (report.failure_len != 0) {
        err.print("a2a-interop client: FAILED: {s}\n", .{
            report.failure[0..report.failure_len],
        })
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        catch {};
    } else {
        err.print("a2a-interop client: {s} {s}, endpoint {s}\n", .{
            report.selected_binding[0..report.selected_binding_len],
            report.selected_version[0..report.selected_version_len],
            report.selected_endpoint[0..report.selected_endpoint_len],
        })
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        catch {};
        // The index the selection chose, which is 0 for the first entry of the
        // card and something else only when the card listed an interface this
        // client skips before the one it bound to.
        err.print("  card interface {d} of the ones the card advertised\n", .{
            report.interface_index,
        })
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        catch {};
        err.print("  SendMessage answered with a Task in state {s} and with a Message\n", .{
            report.task_state[0..report.task_state_len],
        })
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        catch {};
    }
    // The whole summary is still in the buffer and this is the one write that
    // carries it out, so a standard error that will not take it has left this
    // run with nothing to say for itself. That is returned from here, where it
    // becomes the exit status, rather than dropped under a verdict that says
    // the run passed: `exit` runs no defer, so there is no second chance
    // after this line either.
    try stderr.flush();
    if (!report.ok) std.process.exit(1);
}

fn finishServer(io: Io, config: ServerConfig, report: *ServerReport) !void {
    // Derived rather than carried, so the verdict in the report file and the
    // verdict the exit status gives are the same verdict and neither can be
    // the other one.
    report.ok = report.failure_len == 0;

    var buffer: [2048]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    const err = &stderr.interface;

    // As in the client role: a report nobody can read is a run nobody can
    // check, and the only way to say that is to record the fault and let it
    // take the exit status with it.
    writeServerReport(io, config, report) catch |write_fault| {
        fail("the report file could not be written: {s}", .{@errorName(write_fault)}, report);
    };

    // As in the client role: these lines repeat the report file and the exit
    // status for whoever is watching the process, and they reach the buffer
    // rather than the descriptor. The longest is the failure line again — the
    // same 28-byte phrase beside the same 512-byte field, against the same
    // 2048-byte buffer — and the served line beside it is under 400 with the
    // numbers and the target it prints. What they can meet is the stream
    // itself, which is the flush at the end below.
    if (report.failure_len != 0) {
        err.print("a2a-interop server: FAILED: {s}\n", .{
            report.failure[0..report.failure_len],
        })
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        catch {};
    } else {
        err.print("a2a-interop server: served {d} of {d} requests on port {d}, advertising {d}{s}\n", .{
            report.requests_served, config.requests,   report.listen_port,
            report.advertise_port,  config.rpc_target,
        })
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        catch {};
        err.print("  {d} SendMessage answers: {d} Tasks and {d} Messages\n", .{
            report.send_message_answers, report.task_answers, report.message_answers,
        })
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        catch {};
    }
    // As in the client role: this is the one write that carries the summary
    // out, and a standard error that will not take it is a run that cannot
    // report itself, so the fault is returned from here rather than left
    // under a verdict that says the run passed.
    try stderr.flush();
    if (!report.ok) std.process.exit(1);
}

/// Write the client report to the path this run was given, or to nothing at
/// all when it named none.
fn writeClientReport(io: Io, config: ClientConfig, report: *const ClientReport) !void {
    const path = config.report_file orelse return;
    var buffer: [4096]u8 = undefined;
    const document = clientReportDocument(&buffer, report) catch return error.ReportTooLong;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = document });
}

/// The client report as one JSON object and the newline that ends it.
///
/// The same members, in the same order and under the same names as the format
/// string this replaces, because the supervisor reads them by name. What is
/// different is how a value gets into the document: every text field goes
/// through the writer's own string escaping rather than being spliced between
/// quotes. A peer that answered with a quote, a backslash or a control byte
/// used to be able to make this document say something the run did not, and a
/// report nobody can parse is a run that cannot be checked at all.
///
/// The buffer is the caller's, and its size is a bound rather than a guess.
/// The report's text fields are fixed-size copies totalling 2138 bytes, the
/// document's own punctuation, quotes and numbers add under 350 more, and
/// 4096 holds every report whose peer text needed no escaping. Escaping can
/// ask for six bytes per byte, so a peer whose text did need it can outgrow
/// the buffer: that is `error.BufferTooSmall` out of here, which the caller
/// reports as a run it could not write down, rather than a report that drops
/// the field it had no room for.
fn clientReportDocument(out: []u8, report: *const ClientReport) proto.EncodeError![]const u8 {
    var text = json.Writer.init(out);
    try text.slice("{\"role\":\"client\",\"marker\":");
    try text.string(marker);
    try text.slice(",\"protocol_version\":");
    try text.string(version_wire);
    try text.slice(",\"expected_endpoint\":");
    try text.string(report.expected_endpoint[0..report.expected_endpoint_len]);
    try text.slice(",\"selected_endpoint\":");
    try text.string(report.selected_endpoint[0..report.selected_endpoint_len]);
    try text.slice(",\"selected_binding\":");
    try text.string(report.selected_binding[0..report.selected_binding_len]);
    try text.slice(",\"selected_version\":");
    try text.string(report.selected_version[0..report.selected_version_len]);
    try text.slice(",\"interface_index\":");
    try number(&text, report.interface_index);
    try text.slice(",\"endpoint_matched\":");
    try boolean(&text, report.endpoint_matched);
    try text.slice(",\"task_id\":");
    try text.string(report.task_id[0..report.task_id_len]);
    try text.slice(",\"task_state\":");
    try text.string(report.task_state[0..report.task_state_len]);
    try text.slice(",\"task_text\":");
    try text.string(report.task_text[0..report.task_text_len]);
    try text.slice(",\"message_id\":");
    try text.string(report.message_id[0..report.message_id_len]);
    try text.slice(",\"message_text\":");
    try text.string(report.message_text[0..report.message_text_len]);
    try text.slice(",\"peer_error_code\":");
    try number(&text, report.peer_error_code);
    try text.slice(",\"peer_error_message\":");
    try text.string(report.peer_error_message[0..report.peer_error_message_len]);
    try text.slice(",\"failure\":");
    try text.string(report.failure[0..report.failure_len]);
    try text.slice(",\"ok\":");
    try boolean(&text, report.ok);
    try text.slice("}\n");
    return text.written();
}

/// Write the server report to the path this run was given, or to nothing at
/// all when it named none.
fn writeServerReport(io: Io, config: ServerConfig, report: *const ServerReport) !void {
    const path = config.report_file orelse return;
    var buffer: [2048]u8 = undefined;
    const document = serverReportDocument(&buffer, config, report) catch return error.ReportTooLong;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = document });
}

/// The server report as one JSON object and the newline that ends it.
///
/// The same members, in the same order and under the same names as the format
/// string this replaces, composed for the same reasons as the client report:
/// a text field is escaped by the writer instead of being spliced between
/// quotes, and a buffer that cannot hold the document is an error out of here
/// rather than a report with half of it in it.
///
/// The budget is what this run was asked to serve and the served count is what
/// it did, which is why they are two members rather than one: a run that
/// stopped short of its budget has to say so in the document instead of by its
/// own requested count reading lower than itself.
///
/// The 2048 bytes the caller hands this are a bound rather than a guess. This
/// document's text fields are fixed-size copies totalling 922 bytes, and its
/// punctuation, quotes and seven numbers add under 250 more, so every report
/// whose peer text needed no escaping fits with room to spare; a peer whose
/// text did need escaping is `error.BufferTooSmall` out of here, which the
/// caller reports as a run it could not write down.
fn serverReportDocument(
    out: []u8,
    config: ServerConfig,
    report: *const ServerReport,
) proto.EncodeError![]const u8 {
    var text = json.Writer.init(out);
    try text.slice("{\"role\":\"server\",\"marker\":");
    try text.string(marker);
    try text.slice(",\"protocol_version\":");
    try text.string(version_wire);
    try text.slice(",\"listen_port\":");
    try number(&text, report.listen_port);
    try text.slice(",\"advertise_port\":");
    try number(&text, report.advertise_port);
    try text.slice(",\"rpc_target\":");
    try text.string(report.rpc_target[0..report.rpc_target_len]);
    try text.slice(",\"card_path\":");
    try text.string(report.card_path[0..report.card_path_len]);
    try text.slice(",\"requests_budget\":");
    try number(&text, config.requests);
    try text.slice(",\"requests_served\":");
    try number(&text, report.requests_served);
    try text.slice(",\"send_message_answers\":");
    try number(&text, report.send_message_answers);
    try text.slice(",\"task_answers\":");
    try number(&text, report.task_answers);
    try text.slice(",\"message_answers\":");
    try number(&text, report.message_answers);
    try text.slice(",\"failure\":");
    try text.string(report.failure[0..report.failure_len]);
    try text.slice(",\"ok\":");
    try boolean(&text, report.ok);
    try text.slice("}\n");
    return text.written();
}

// --- the tests -----------------------------------------------------------------

/// Parse the composed line before its temporary argument array expires.
/// The returned configuration borrows the original strings, not this array.
fn withWords(
    base: []const []const u8,
    extra: []const []const u8,
) (CliError || error{LineTooLong})!Parsed {
    var words: [16][]const u8 = undefined;
    if (base.len + extra.len > words.len) return error.LineTooLong;
    for (base, 0..) |word, index| words[index] = word;
    for (extra, 0..) |word, index| words[base.len + index] = word;
    return parseArgs(words[0 .. base.len + extra.len]);
}

fn expectClient(parsed: CliError!Parsed) !ClientConfig {
    return switch (try parsed) {
        .help => error.ExpectedAClientRun,
        .client => |config| config,
        .server => error.ExpectedAServerRun,
    };
}

fn expectServer(parsed: CliError!Parsed) !ServerConfig {
    return switch (try parsed) {
        .help => error.ExpectedAServerRun,
        .client => error.ExpectedAClientRun,
        .server => |config| config,
    };
}

fn expectHelp(parsed: CliError!Parsed) !void {
    return switch (try parsed) {
        .help => {},
        .client, .server => error.ExpectedHelp,
    };
}

test "role: a bare line is refused rather than given a default role" {
    try testing.expectError(CliError.MissingRole, parseArgs(&.{}));
    // A line of words that belong to both roles is still a line with no role,
    // and `--report-file` is one of them because it is the one flag both roles
    // take.
    try testing.expectError(CliError.MissingRole, parseArgs(&.{
        "--report-file", "run/report.json",
    }));
    try testing.expectError(
        CliError.MissingRole,
        parseArgs(&.{ "--port", "0", "--requests", "1", "--report-file", "r.json" }),
    );
}

test "role: a spelling that is neither client nor server is refused" {
    for ([_][]const u8{ "agent", "Client", "CLIENT", "", "serve", "Server", "client " }) |bad| {
        try testing.expectError(CliError.InvalidRole, parseArgs(&.{ "--role", bad }));
    }
}

test "role: a role given twice is refused rather than letting the last one win" {
    try testing.expectError(
        CliError.DuplicateFlag,
        parseArgs(&.{ "--role", "client", "--role", "server" }),
    );
}

test "role: the two roles do not share the flags that name an endpoint" {
    for ([_][]const []const u8{
        &.{ "--role", "server", "--base-url", "http://127.0.0.1:1", "--requests", "1" },
        &.{ "--role", "client", "--rpc-target", "/a2a", "--base-url", "http://127.0.0.1:1" },
        &.{ "--role", "server", "--expect-endpoint", "/a2a", "--requests", "1" },
        &.{ "--role", "client", "--port", "0", "--base-url", "http://127.0.0.1:1" },
        &.{ "--role", "client", "--advertise-port", "8080", "--base-url", "http://127.0.0.1:1" },
        &.{ "--role", "client", "--requests", "1", "--base-url", "http://127.0.0.1:1" },
    }) |line| {
        try testing.expectError(CliError.FlagNotForRole, parseArgs(line));
    }
}

test "client: base-url is required and must be an http or https origin" {
    // The endpoint is never guessed, so there is nothing to fall back to: a
    // client line with no origin would be a claim about a peer nobody named,
    // and a default of localhost is exactly such a claim.
    try testing.expectError(
        CliError.MissingBaseUrl,
        parseArgs(&.{ "--role", "client", "--expect-endpoint", "/a2a" }),
    );
    for ([_][]const u8{
        "127.0.0.1:8080", // no scheme
        "ftp://127.0.0.1", // a scheme no A2A binding is carried over
        "ws://127.0.0.1", // nor is a websocket one
        "http://", // no host
        "http://127.0.0.1/rpc", // an origin carries no path of its own
        "http://127.0.0.1:8080?x=1", // nor a query
        "http://127.0.0.1:8080#f", // nor a fragment
        "http://127.0.0.1/rpc/", // a path is a path with a trailing slash
        "http://127.0.0.1//", // nor is one with a second slash
        "http:///", // a slash with no host in front of it
        "http://?x=1", // nor is an empty host with a query
        "",
    }) |bad| {
        try testing.expectError(CliError.InvalidBaseUrl, parseArgs(&.{
            "--role",            "client",
            "--base-url",        bad,
            "--expect-endpoint", "/a2a",
        }));
    }
    // A single trailing slash is the same origin spelled the way a URL is
    // usually typed, and the value a report prints is the value the dialer is
    // given, so the slash is removed rather than carried into a request line.
    const ok = try expectClient(parseArgs(&.{
        "--role",            "client",
        "--base-url",        "http://127.0.0.1:8080/",
        "--expect-endpoint", "/a2a",
    }));
    try testing.expectEqualStrings("http://127.0.0.1:8080", ok.base_url);
    // The port is not part of the origin's spelling: a host on its own is the
    // same origin with the default port, and the trailing slash in front of
    // nothing is the one place a slash belongs.
    const no_port = try expectClient(parseArgs(&.{
        "--role",            "client",
        "--base-url",        "http://example.invalid/",
        "--expect-endpoint", "/a2a",
    }));
    try testing.expectEqualStrings("http://example.invalid", no_port.base_url);
    const with_port = try expectClient(parseArgs(&.{
        "--role",            "client",
        "--base-url",        "https://example.invalid:8443",
        "--expect-endpoint", "/a2a",
    }));
    try testing.expectEqualStrings("https://example.invalid:8443", with_port.base_url);
}

test "client: expect-endpoint is a target, may carry a query, and is required" {
    // The point of the run is that the endpoint came from the card, so a client
    // that is not told which endpoint to expect cannot report whether it used
    // the advertised one or a guess.
    try testing.expectError(
        CliError.MissingExpectEndpoint,
        parseArgs(&.{ "--role", "client", "--base-url", "http://127.0.0.1:8080" }),
    );
    for ([_][]const u8{
        "agents/echo/a2a-v1", // no leading slash: a path, not a segment
        "http://127.0.0.1/a2a", // absolute: the card is what carries the scheme
        "/a2a#frag", // a fragment is never sent
        "", // empty
        "?peer=zig", // a query with no path is not a target
    }) |bad| {
        try testing.expectError(CliError.InvalidExpectEndpoint, parseArgs(&.{
            "--role",            "client",
            "--base-url",        "http://127.0.0.1:8080",
            "--expect-endpoint", bad,
        }));
    }
    const plain = try expectClient(parseArgs(&.{
        "--role",            "client",
        "--base-url",        "http://127.0.0.1:8080",
        "--expect-endpoint", "/agents/echo/a2a-v1",
    }));
    try testing.expectEqualStrings("/agents/echo/a2a-v1", plain.expect_endpoint);
    // A query is part of the advertised target and has to survive the parse, or
    // a card that advertises one could never be exercised end to end.
    const with_query = try expectClient(parseArgs(&.{
        "--role",            "client",
        "--base-url",        "http://127.0.0.1:8080",
        "--expect-endpoint", "/agents/echo/a2a-v1?peer=zig",
    }));
    try testing.expectEqualStrings("/agents/echo/a2a-v1?peer=zig", with_query.expect_endpoint);
}

test "server: the listen port takes zero and 65535 and refuses either side" {
    const base: []const []const u8 = &.{
        "--role",           "server",
        "--advertise-port", "8080",
        "--rpc-target",     "/a2a",
        "--requests",       "1",
    };
    const at_zero = try expectServer(try withWords(base, &.{ "--port", "0" }));
    try testing.expectEqual(@as(u32, 0), at_zero.port);
    const at_max = try expectServer(try withWords(base, &.{ "--port", "65535" }));
    try testing.expectEqual(@as(u32, 65535), at_max.port);
    try testing.expectError(CliError.PortOutOfRange, withWords(base, &.{ "--port", "65536" }));
    // A negative port is not a number at all rather than a range complaint,
    // because no `u32` holds it and no bound is what was crossed.
    try testing.expectError(CliError.NotANumber, withWords(base, &.{ "--port", "-1" }));
}

test "server: the advertised port is required and zero names no port a client can dial" {
    try testing.expectError(
        CliError.MissingAdvertisePort,
        parseArgs(&.{ "--role", "server", "--rpc-target", "/a2a", "--requests", "1" }),
    );
    // The card has to name a port the peer can reach, and the kernel's choice on
    // the listening socket is only known once it is bound, so the two are
    // separate words and zero advertises nothing a client could dial.
    for ([_][]const u8{ "0", "65536" }) |bad| {
        try testing.expectError(CliError.AdvertisePortOutOfRange, parseArgs(&.{
            "--role",           "server",
            "--advertise-port", bad,
            "--rpc-target",     "/a2a",
            "--requests",       "1",
        }));
    }
    const parsed = try expectServer(parseArgs(&.{
        "--role",           "server",
        "--advertise-port", "1",
        "--rpc-target",     "/a2a",
        "--requests",       "1",
    }));
    try testing.expectEqual(@as(u32, 1), parsed.advertise_port);
}

test "server: rpc-target is a target, may carry a query, and is required" {
    try testing.expectError(
        CliError.MissingRpcTarget,
        parseArgs(&.{
            "--role",           "server",
            "--advertise-port", "8080",
            "--requests",       "1",
        }),
    );
    for ([_][]const u8{
        "a2a", // no leading slash
        "http://x/a2a", // absolute: the card carries the scheme, not the path
        "/a2a#frag", // a fragment is never sent
        "?peer=zig", // a query with no path is not a target
        "",
    }) |bad| {
        try testing.expectError(CliError.InvalidRpcTarget, parseArgs(&.{
            "--role",           "server",
            "--advertise-port", "8080",
            "--rpc-target",     bad,
            "--requests",       "1",
        }));
    }
    const parsed = try expectServer(parseArgs(&.{
        "--role",           "server",
        "--advertise-port", "8080",
        "--rpc-target",     "/agents/echo/a2a-v1?peer=zig",
        "--requests",       "1",
    }));
    try testing.expectEqualStrings("/agents/echo/a2a-v1?peer=zig", parsed.rpc_target);
}

test "server: requests is one to sixty-four and is chosen rather than defaulted" {
    const base: []const []const u8 = &.{ "--role", "server", "--advertise-port", "8080", "--rpc-target", "/a2a" };
    // A run that serves however many requests a peer sends is a run whose
    // length a peer decides, so the count is asked for rather than assumed.
    try testing.expectError(CliError.MissingRequests, parseArgs(base));
    const one = try expectServer(try withWords(base, &.{ "--requests", "1" }));
    try testing.expectEqual(@as(u32, 1), one.requests);
    const at_max = try expectServer(try withWords(base, &.{ "--requests", "64" }));
    try testing.expectEqual(requests_max, at_max.requests);
    for ([_][]const u8{ "0", "65", "1000" }) |bad| {
        try testing.expectError(CliError.RequestsOutOfRange, withWords(base, &.{ "--requests", bad }));
    }
}

test "count: a word that is not a run of decimal digits is not a count" {
    const base: []const []const u8 = &.{ "--role", "server", "--rpc-target", "/a2a" };
    for ([_][]const u8{ "abc", "12x", "", "0x10", " 7", "+3", "1_0", "7.0" }) |bad| {
        try testing.expectError(CliError.NotANumber, withWords(base, &.{ "--requests", bad }));
        try testing.expectError(CliError.NotANumber, withWords(base, &.{ "--port", bad }));
        try testing.expectError(CliError.NotANumber, withWords(base, &.{ "--advertise-port", bad }));
    }
}

test "count: a count no u32 holds is an overflow rather than a range complaint" {
    const base: []const []const u8 = &.{ "--role", "server", "--rpc-target", "/a2a" };
    for ([_][]const u8{ "4294967296", "99999999999999999999" }) |bad| {
        try testing.expectError(CliError.CountOverflow, withWords(base, &.{ "--requests", bad }));
        try testing.expectError(CliError.CountOverflow, withWords(base, &.{ "--port", bad }));
        try testing.expectError(CliError.CountOverflow, withWords(base, &.{ "--advertise-port", bad }));
    }
}

test "flag: an unknown flag is refused rather than ignored" {
    try testing.expectError(CliError.UnknownFlag, parseArgs(&.{"--nope"}));
    try testing.expectError(CliError.UnknownFlag, parseArgs(&.{"-x"}));
    // A joined spelling is not a spelling this participant takes, and reading
    // it as a flag nobody knows would drop it silently.
    try testing.expectError(CliError.UnknownFlag, parseArgs(&.{"--role=client"}));
    try testing.expectError(CliError.UnknownFlag, parseArgs(&.{ "--Role", "client" }));
}

test "flag: a flag given twice is refused rather than letting the last one win" {
    try testing.expectError(CliError.DuplicateFlag, parseArgs(&.{
        "--role",           "server",
        "--advertise-port", "8080",
        "--rpc-target",     "/a2a",
        "--rpc-target",     "/b",
        "--requests",       "1",
    }));
    try testing.expectError(CliError.DuplicateFlag, parseArgs(&.{
        "--role",           "server",
        "--advertise-port", "8080",
        "--rpc-target",     "/a2a",
        "--requests",       "1",
        "--port",           "0",
        "--port",           "0",
    }));
    // A flag given once, on the role that does not take it, is the role mismatch
    // and nothing else; the case above is found while the words are being read,
    // which is before there is a role to judge them against. So a line carrying
    // both faults is reported as the repeat: the run never happened, and the
    // repeat is what says the line was not assembled by anybody who read it.
    try testing.expectError(CliError.FlagNotForRole, parseArgs(&.{
        "--role",     "server",
        "--base-url", "http://127.0.0.1:8080",
        "--requests", "1",
    }));
    try testing.expectError(CliError.FlagNotForRole, parseArgs(&.{
        "--role",            "client",
        "--base-url",        "http://127.0.0.1:8080",
        "--expect-endpoint", "/a2a",
        "--rpc-target",      "/a2a",
    }));
}

test "flag: a flag with no value after it, or another flag after it, has no value" {
    for ([_][]const u8{
        "--role", "--base-url",       "--expect-endpoint", "--rpc-target",
        "--port", "--advertise-port", "--requests",        "--report-file",
    }) |flag| {
        try testing.expectError(CliError.MissingValue, parseArgs(&.{flag}));
    }
    try testing.expectError(
        CliError.MissingValue,
        parseArgs(&.{ "--role", "--base-url", "http://127.0.0.1:8080" }),
    );
    try testing.expectError(
        CliError.MissingValue,
        parseArgs(&.{ "--role", "client", "--base-url", "--report-file", "r.json" }),
    );
}

test "flag: a word that is not a flag at all is refused" {
    try testing.expectError(CliError.UnexpectedArgument, parseArgs(&.{"client"}));
    try testing.expectError(
        CliError.UnexpectedArgument,
        parseArgs(&.{ "--role", "client", "extra" }),
    );
}

test "help: --help and -h ask for the usage rather than for a run" {
    try expectHelp(parseArgs(&.{"--help"}));
    try expectHelp(parseArgs(&.{"-h"}));
    // Asked for beside an otherwise complete line it still wins: a line that
    // asks for usage runs nothing, so the rest of it is not a run.
    try expectHelp(parseArgs(&.{
        "--role",            "client",
        "--base-url",        "http://127.0.0.1:8080",
        "--expect-endpoint", "/a2a",
        "--help",
    }));
}

test "help: --help does not hide a typo, a missing value or a bad role" {
    try testing.expectError(CliError.UnknownFlag, parseArgs(&.{ "--help", "--nope" }));
    try testing.expectError(CliError.UnknownFlag, parseArgs(&.{ "--nope", "--help" }));
    try testing.expectError(CliError.MissingValue, parseArgs(&.{ "--help", "--role" }));
    try testing.expectError(CliError.InvalidRole, parseArgs(&.{ "--help", "--role", "agent" }));
    // The ranges are checked before the usage for the same reason a typo is: a
    // count outside its range is a bad argument whatever else the line says,
    // and a line that runs nothing has not excused it.
    try testing.expectError(CliError.RequestsOutOfRange, parseArgs(&.{
        "--help", "--role",
        "server", "--advertise-port",
        "8080",   "--rpc-target",
        "/a2a",   "--requests",
        "0",
    }));
    try testing.expectError(CliError.AdvertisePortOutOfRange, parseArgs(&.{
        "--help", "--role",
        "server", "--advertise-port",
        "0",      "--rpc-target",
        "/a2a",   "--requests",
        "1",
    }));
}

test "help: --help asked for twice is a flag given twice" {
    try testing.expectError(CliError.DuplicateFlag, parseArgs(&.{ "--help", "-h" }));
}

test "report-file: a run without one still has a role, and one with it names it" {
    const without = try expectServer(parseArgs(&.{
        "--role",           "server",
        "--advertise-port", "8080",
        "--rpc-target",     "/a2a",
        "--requests",       "1",
    }));
    try testing.expect(without.report_file == null);
    const with = try expectServer(parseArgs(&.{
        "--role",           "server",
        "--advertise-port", "8080",
        "--rpc-target",     "/a2a",
        "--requests",       "1",
        "--report-file",    "run/server-report.json",
    }));
    try testing.expectEqualStrings("run/server-report.json", with.report_file.?);
}

test "target: a URI matches only the target whose path and query it carries" {
    // The comparison the endpoint check is made on, and the reason it compares
    // components rather than formatted text: a fragment is not sent, an
    // expected target with no query does not match a URI that carries one, and
    // a query is part of what a card advertised.
    const plain = try std.Uri.parse("http://127.0.0.1:8080/agents/echo/a2a-v1");
    try testing.expect(targetMatches(plain, "/agents/echo/a2a-v1"));
    try testing.expect(!targetMatches(plain, "/agents/echo/a2a-v1?peer=zig"));
    try testing.expect(!targetMatches(plain, "/agents/echo/a2a-v2"));
    try testing.expect(!targetMatches(plain, "agents/echo/a2a-v1"));

    const with_query = try std.Uri.parse("http://127.0.0.1:8080/agents/echo/a2a-v1?peer=zig");
    try testing.expect(targetMatches(with_query, "/agents/echo/a2a-v1?peer=zig"));
    // A URI carrying a query is not a URI whose path alone was expected, and a
    // client that dropped the query would not be using the advertised endpoint.
    try testing.expect(!targetMatches(with_query, "/agents/echo/a2a-v1"));

    const fragment = try std.Uri.parse("http://127.0.0.1:8080/a2a?x=1#f");
    try testing.expect(targetMatches(fragment, "/a2a?x=1"));
    try testing.expect(!targetMatches(fragment, "/a2a?x=1#f"));
}

test "target: the request target a URI names is its path and query and nothing else" {
    // What a report prints, and the two components are copied in order with no
    // `?` on a target that carries no query.
    var field: [128]u8 = undefined;
    const plain = try std.Uri.parse("http://127.0.0.1:8080/agents/echo/a2a-v1");
    const plain_len = writeTarget(&field, plain);
    try testing.expectEqualStrings("/agents/echo/a2a-v1", field[0..plain_len]);

    const with_query = try std.Uri.parse("http://127.0.0.1:8080/agents/echo/a2a-v1?peer=zig");
    const query_len = writeTarget(&field, with_query);
    try testing.expectEqualStrings("/agents/echo/a2a-v1?peer=zig", field[0..query_len]);
}

test "report: text a peer chose comes back out of the document as the text that went in" {
    // The report is read back by a supervisor that knows nothing about this
    // file, and every text field in it is whatever a peer answered with. A
    // value spliced between quotes without escaping either makes the document
    // unparseable or hands the reader a different string than the wire
    // carried, so the check is that the text survives a round trip byte for
    // byte through this module's own reader.
    var report: ClientReport = .{};
    const answered = "quote \" backslash \\ newline \n tab \t bell \x07 done";
    copyBounded(&report.task_text, &report.task_text_len, answered);
    copyBounded(&report.failure, &report.failure_len, answered);
    report.endpoint_matched = true;
    report.peer_error_code = -32001;

    var buffer: [4096]u8 = undefined;
    const document = try clientReportDocument(&buffer, &report);

    var reader = json.Reader.init(document);
    var scratch: [1024]u8 = undefined;
    const empty = try reader.beginObject();
    try testing.expect(!empty);

    var role: ?[]const u8 = null;
    var task_text: ?[]const u8 = null;
    var failure: ?[]const u8 = null;
    var code: ?[]const u8 = null;
    var matched: ?bool = null;
    var ok: ?bool = null;
    while (try reader.nextKey(&scratch)) |key| {
        if (std.mem.eql(u8, key, "role")) {
            role = try reader.string(&scratch);
        } else if (std.mem.eql(u8, key, "task_text")) {
            task_text = try reader.string(&scratch);
        } else if (std.mem.eql(u8, key, "failure")) {
            failure = try reader.string(&scratch);
        } else if (std.mem.eql(u8, key, "peer_error_code")) {
            code = try reader.number();
        } else if (std.mem.eql(u8, key, "endpoint_matched")) {
            matched = try reader.boolean();
        } else if (std.mem.eql(u8, key, "ok")) {
            ok = try reader.boolean();
        } else {
            try reader.skipValue(&scratch);
        }
    }
    try testing.expect(reader.atEnd());

    try testing.expectEqualStrings("client", role.?);
    try testing.expectEqualStrings(answered, task_text.?);
    try testing.expectEqualStrings(answered, failure.?);
    try testing.expectEqualStrings("-32001", code.?);
    try testing.expect(matched.?);
    try testing.expect(!ok.?);
    // One line, and it is the newline this document ends with: a supervisor
    // that waits for a line must not be handed a second one because a peer put
    // a newline in the text it answered with.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, document, "\n"));
    try testing.expectEqual(@as(u8, '\n'), document[document.len - 1]);
}
