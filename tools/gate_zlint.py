#!/usr/bin/env python3
"""The house gate's zlint, with reviewed cleanup waivers and nothing else waived.

`zig-gate` reads its file list on stdin, runs its zlint section against
`$ZLINT` twice — once as `$ZLINT -S`, whose `Found N errors and M warnings`
line it counts, and once as `$ZLINT -S -f json`, whose records it reduces to a
per-rule histogram — so both spellings have to keep working. This file is what
the project's own `gate` script passes as `$ZLINT` and for nothing else:
`zlint` on PATH stays the raw analyzer, and `ZLINT=zlint zig-gate` runs the
gate exactly as the host tool ships.

The wrapper asks the raw analyzer for `-S -f json` over the same files it was
handed, reads every record in that report, and adjudicates exactly one rule:
`suppressed-errors` on one statement, in one of the sixteen source paths a
human read line by line and that are named below. That adjudication is not this
file's judgement. Every other rule — every rule that exists now and every rule
added later — stays open, is counted, and is printed, because a review of a
caught transport error says nothing about a rule nobody has read.

The review is recorded in the source, not here. The source carries exactly

    // gate-reviewed-zlint-next-statement: suppressed-errors

and the statement it covers is the next physical line that is not one of the
existing `// ziglint-ignore: Z026` and
`// zwanzig-disable-next-line: empty-catch-engine` rows, which are jumped
because they are contiguous and each names the rule it already silences. A
blank line, a paragraph of prose, a statement, any other directive or a second
marker cannot be jumped, because a marker that could skip a gap would be a
waiver of a range and the range is the claim nobody reviewed. The target may
be an empty `catch {}` or a bounded-format `catch unreachable`; either way it is
one statement, never a function, and the proof of it is the comment above the
function or the call, which this file does not read.

What this file checks is the shape of that record and never the truth of the
comment above it: one reviewed path, one exact marker, one target line, and
exactly one `warn`-level `suppressed-errors` record on that line. A manual
review is not a safety analysis any tool performed, and this file must not be
read as one.

Everything else is a refusal. An annotation naming another rule, one in a file
this review never covered, one whose target line no longer carries the finding
it was written for, one that matches two findings, two annotations claiming one
finding, a report holding a record this file cannot read, a record for a file
that was not selected, a level outside `error` and `warn`, an empty file list, a
duplicate file, and a path outside the checkout. Refusal fails the run: every
way this file could be wrong produces the same false green, which is a waiver
nobody re-read.

The counts are computed over the whole report before anything is displayed, and
errors are displayed before warnings, so five hundred warnings cannot hide the
one fatal record behind a display cap. A `Found N errors and M warnings` line
is printed only on a run this wrapper could judge. A refusal prints the
findings it refused to waive, so the run stays attributable to real source
positions, and prints no count at all: the gate counts that line, and a count
printed beside a refusal reads as a clean run. A failure before the report can
be read at all prints the cause and nothing else.

Standard library only. This is development tooling; no Zig file imports it and
the library keeps its zero-dependency guarantee.

Environment:
  GATE_ZLINT_BIN           the analyzer to run. Unset resolves `zlint` on PATH,
                           and a `zlint` that resolves to this file is refused
                           rather than delegated to.
  GATE_PROJECT_ROOT        the checkout the findings are relative to. Defaults
                           to the directory this file lives two levels under.
  GATE_ZLINT_TIMEOUT_SECONDS
                           deadline for the analyzer. Default 900. An analyzer
                           that has not answered by then is killed: a gate run
                           cannot hang on it.

Exit: 0 when nothing is open, 1 when at least one finding is open, 2 on refusal.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from typing import NamedTuple

REVIEWED_RULE = "suppressed-errors"
MARKER_TEXT = "// gate-reviewed-zlint-next-statement: suppressed-errors"
MARKER_PREFIX_RE = re.compile(r"^//\s*gate-reviewed-zlint-next-statement:")
EXACT_MARKER_RE = re.compile(
    r"^//\s*gate-reviewed-zlint-next-statement:\s*suppressed-errors\s*$"
)
# The rows an existing review already stands behind. They are jumped only
# because they are contiguous and because each one names the rule it silences;
# a fence this file cannot read exactly is not a fence.
FENCE_ROWS = frozenset(
    {
        "// ziglint-ignore: Z026",
        "// zwanzig-disable-next-line: empty-catch-engine",
    }
)

# The sixteen paths a human read before any of these markers existed. The list
# is frozen: it is not a list of findings and it is not a place to add the next
# file that happens to be convenient. A file absent from it may still be
# analyzed and may still report findings, but an annotation in it is refused.
# Extending this list means reading the file and recording that review here, not
# editing one name into one tuple.
REVIEWED_FILES = frozenset(
    {
        "src/a2a_demo.zig",
        "src/a2a_http.zig",
        "src/a2a_interop.zig",
        "src/acp_session.zig",
        "src/bench.zig",
        "src/bench_runtime.zig",
        "src/bridge_session.zig",
        "src/conn.zig",
        "src/http.zig",
        "src/http_demo.zig",
        "src/mcp_interop.zig",
        "src/mcp_session.zig",
        "src/runtime_demo.zig",
        "src/sessions_demo.zig",
        "src/testio.zig",
        "test/loopback_test.zig",
    }
)

LEVELS = ("error", "warn")
REQUIRED_FIELDS = ("code", "level", "message", "source_name", "labels")

DISPLAY_LIMIT = 100
FORWARDED_STDERR_LIMIT = 20
DEFAULT_TIMEOUT_SECONDS = 900

EXIT_CLEAN = 0
EXIT_OPEN = 1
EXIT_REFUSED = 2

REFUSAL_PREFIX = "zlint: refusing to judge this run:"


class Refusal(Exception):
    """A condition this wrapper will not interpret. The gate fails on it."""


class Annotation(NamedTuple):
    """One marker in one source file, and whether it is the exact reviewed one."""

    relative: str
    line: int
    text: str
    exact: bool


class Selection(NamedTuple):
    """One selected file: the checkout's name, what was asked for, its source."""

    relative: str
    requested: str
    lines: list[str]


class Report(NamedTuple):
    """One analyzer record, with the source position this file read off it."""

    record: dict
    source: str
    line: int
    column: int

    @property
    def where(self) -> str:
        return f"{self.source}:{self.line}:{self.column}"


class AnalyzerRun(NamedTuple):
    status: int
    stdout: bytes
    stderr: str


def main(argv: list[str]) -> int:
    try:
        return adjudicate_run(argv)
    except Refusal as refusal:
        return refuse(str(refusal))
    except Exception as error:  # noqa: BLE001
        # A crash in here is a bug, and a bug must not read as "the analyzer had
        # findings" — that status is the one the gate treats as advisory. Fail
        # the run and name the failure instead.
        return refuse(f"unexpected failure while judging this run: {error!r}")


def adjudicate_run(argv: list[str]) -> int:
    json_mode = parse_arguments(argv)
    analyzer = resolve_analyzer()
    root = resolve_root()
    selection = select_sources(root)
    document = run_analyzer(analyzer, selection)
    forward_analyzer_stderr(document.stderr)
    if document.status not in (0, 1):
        raise Refusal(
            f"the analyzer exited {document.status}, which is neither its clean "
            "status (0) nor its findings status (1)"
        )
    try:
        report = document.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Refusal(f"the analyzer's report is not UTF-8: {error}") from error
    records = parse_records(report, selection, root)
    if document.status == 1 and not records:
        raise Refusal(
            "the analyzer exited 1 to report findings and its report holds no "
            "record; refusing to read a report that contradicts its own status "
            "as clean"
        )
    annotations = scan_annotations(selection)
    closed, open_indices, refusals = adjudicate(records, annotations, selection)

    if json_mode:
        emit_open_json(records, open_indices)
    else:
        emit_open_text(records, open_indices, not refusals)
    report_reviews(records, closed)

    for message in refusals:
        print(f"{REFUSAL_PREFIX} {message}", file=sys.stderr)
    if refusals:
        return EXIT_REFUSED
    if open_indices:
        return EXIT_OPEN
    return EXIT_CLEAN


# -- the seam the house gate drives ------------------------------------------


def parse_arguments(argv: list[str]) -> bool:
    """The one option pair this gate uses, and nothing else.

    `$ZLINT -S` is the counted text run and `$ZLINT -S -f json` is the histogram
    run. An option this file does not understand is refused rather than dropped:
    an option that changes what the analyzer reports is not one to pass through
    unread, and forwarding it would let a run change meaning without this file
    knowing.
    """
    json_mode = False
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "-S":
            index += 1
        elif argument in ("-f", "--format"):
            index += 1
            if index >= len(argv):
                raise Refusal(f"{argument} was given no value to read a report format from")
            json_mode = require_format(argv[index])
            index += 1
        elif argument.startswith(("-f=", "--format=")):
            json_mode = require_format(argument.split("=", 1)[1])
            index += 1
        else:
            raise Refusal(f"{argument!r} is not an option this wrapper understands")
    return json_mode


def require_format(value: str) -> bool:
    if value == "json":
        return True
    if value == "text":
        return False
    raise Refusal(f"{value!r} is not a report format this wrapper can read")


# -- the analyzer ------------------------------------------------------------


def resolve_analyzer() -> str:
    override = os.environ.get("GATE_ZLINT_BIN", "").strip()
    analyzer = override or shutil.which("zlint")
    if not analyzer:
        raise Refusal(
            "no zlint analyzer to run: set GATE_ZLINT_BIN or put zlint on PATH"
        )
    if os.path.realpath(analyzer) == os.path.realpath(__file__):
        raise Refusal(
            f"{analyzer} is this wrapper; delegating to it would analyze "
            "nothing and recurse"
        )
    if not (os.path.isfile(analyzer) and os.access(analyzer, os.X_OK)):
        raise Refusal(f"{analyzer} is not an executable analyzer")
    return analyzer


def resolve_root() -> str:
    override = os.environ.get("GATE_PROJECT_ROOT", "").strip()
    if override:
        return os.path.realpath(override)
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.realpath(os.path.join(here, os.pardir))


def timeout_seconds() -> int:
    raw = os.environ.get("GATE_ZLINT_TIMEOUT_SECONDS", "").strip()
    if not raw:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        seconds = int(raw)
    except ValueError as error:
        raise Refusal(
            f"GATE_ZLINT_TIMEOUT_SECONDS is {raw!r}, which is not a number of seconds"
        ) from error
    if seconds < 1:
        raise Refusal("GATE_ZLINT_TIMEOUT_SECONDS must be at least one second")
    return seconds


def run_analyzer(analyzer: str, selection: list[Selection]) -> AnalyzerRun:
    """The raw analyzer over exactly the files the gate named, as JSON.

    The same list goes back on stdin in the same form, because that list is the
    only thing that decides what was analyzed: a wrapper that widened,
    narrowed or reordered it would report on sources the run never selected.
    """
    listing = "".join(f"{entry.requested}\n" for entry in selection)
    command = [analyzer, "-S", "-f", "json"]
    try:
        completed = subprocess.run(
            command,
            input=listing.encode("utf-8"),
            capture_output=True,
            timeout=timeout_seconds(),
        )
    except subprocess.TimeoutExpired as error:
        forward_analyzer_stderr(decode_stderr(error.stderr))
        raise Refusal(
            f"the analyzer did not answer within {timeout_seconds()} seconds; a "
            "gate run cannot wait on it"
        ) from error
    except OSError as error:
        raise Refusal(f"the analyzer could not be started: {error}") from error
    return AnalyzerRun(
        completed.returncode, completed.stdout, decode_stderr(completed.stderr)
    )


def decode_stderr(raw: bytes | None) -> str:
    return (raw or b"").decode("utf-8", "replace")


def forward_analyzer_stderr(text: str) -> None:
    """The analyzer's own summary, verbatim and bounded.

    It is evidence of what the analyzer did with the files it was given, so it
    is passed through rather than reworded, and it is passed through on the
    paths that refuse too, because refusing without the analyzer's reason
    leaves a failure nothing to act on. It is bounded because a diagnostic that
    prints without end is one of the ways a gate run stops being a gate run.
    """
    lines = [line for line in text.splitlines() if line.strip()]
    for line in lines[:FORWARDED_STDERR_LIMIT]:
        print(line, file=sys.stderr)
    if len(lines) > FORWARDED_STDERR_LIMIT:
        print(
            f"zlint: {len(lines) - FORWARDED_STDERR_LIMIT} further analyzer "
            "line(s) not shown",
            file=sys.stderr,
        )


# -- the selected sources ----------------------------------------------------


def select_sources(root: str) -> list[Selection]:
    """The files the gate named, as this checkout names them, and their source.

    Every one of them is read here, before the analyzer runs, so a file that
    cannot be read is a refusal naming the file rather than an annotation that
    quietly matches nothing later.
    """
    requested = read_file_list()
    if not requested:
        raise Refusal(
            "no source file was given to analyze; a file list that excluded "
            "everything would otherwise read as a clean run"
        )
    selection: list[Selection] = []
    seen: dict[str, str] = {}
    for entry in requested:
        relative = relative_within(root, entry)
        if relative == os.pardir or relative.startswith(os.pardir + os.sep) or os.path.isabs(relative):
            raise Refusal(
                f"{entry} resolves to {relative}, which is outside {root}; a "
                "finding there could not be attributed to this checkout"
            )
        if not relative.endswith(".zig"):
            raise Refusal(f"{entry} is not a Zig source file")
        if relative in seen:
            raise Refusal(
                f"{entry} and {seen[relative]} are the same file, {relative}; "
                "one selection cannot name a source twice"
            )
        seen[relative] = entry
        try:
            with open(os.path.join(root, relative), encoding="utf-8") as source:
                lines = source.read().splitlines()
        except FileNotFoundError as error:
            raise Refusal(f"{relative} was selected but does not exist") from error
        except (OSError, UnicodeDecodeError) as error:
            raise Refusal(
                f"{relative} cannot be read as UTF-8 source: {error}"
            ) from error
        selection.append(Selection(relative, entry, lines))
    return selection


def read_file_list() -> list[str]:
    raw = sys.stdin.buffer.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Refusal(f"the file list on stdin is not UTF-8: {error}") from error
    return [line.strip() for line in text.splitlines() if line.strip()]


def relative_within(root: str, requested: str) -> str:
    """A requested file as the checkout names it, however it was asked for.

    The gate hands over what `find` printed, which is `./src/conn.zig`, and a
    hand-run wrapper may hand over an absolute path. The annotation lookup, the
    reviewed-path list and the paths inside the report are all compared against
    the checkout's own names, so all of them are normalized this way before any
    of them is compared with another.
    """
    path = requested if os.path.isabs(requested) else os.path.join(root, requested)
    return os.path.relpath(os.path.realpath(path), root).replace(os.sep, "/")


# -- the report --------------------------------------------------------------


def parse_records(report: str, selection: list[Selection], root: str) -> list[Report]:
    """Every record the analyzer reported, each one checked to be usable.

    One JSON object per line: no array, no wrapper and no partial record. Every
    field a decision could be made from has to be there and of the right shape.
    A record this file cannot read is refused rather than dropped, because
    dropping it would turn a report it does not understand into a clean run.
    """
    records: list[Report] = []
    for number, line in enumerate(report.splitlines(), start=1):
        if not line.strip():
            continue
        where = f"record {number}"
        try:
            record = json.loads(line)
        except ValueError as error:
            raise Refusal(
                f"{where} of the analyzer's report is not JSON: {error}"
            ) from error
        if not isinstance(record, dict):
            raise Refusal(f"{where} is a {type(record).__name__}, not a JSON object")
        for field in REQUIRED_FIELDS:
            if field not in record:
                raise Refusal(f"{where} has no {field}")
        for field in ("code", "level", "message", "source_name"):
            if not isinstance(record[field], str) or not record[field]:
                raise Refusal(f"{where} has no usable {field}")
        if record["level"] not in LEVELS:
            raise Refusal(
                f"{where} has level {record['level']!r}, which is neither "
                f"{' nor '.join(LEVELS)}; a level this file does not know is "
                "refused rather than treated as advisory"
            )
        records.append(read_labels(record, selection, root, where))
    return records


def read_labels(record: dict, selection: list[Selection], root: str, where: str) -> Report:
    """The source position of one record, and the file it belongs to."""
    labels = record["labels"]
    if not isinstance(labels, list) or not labels:
        raise Refusal(f"{where} has no labels, so it has no source position")
    for position, label in enumerate(labels, start=1):
        if not isinstance(label, dict):
            raise Refusal(f"{where} label {position} is not a JSON object")
        for edge in ("start", "end"):
            point = label.get(edge)
            if not isinstance(point, dict):
                raise Refusal(f"{where} label {position} has no {edge}")
            for axis in ("line", "column"):
                value = point.get(axis)
                if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                    raise Refusal(
                        f"{where} label {position} {edge}.{axis} is {value!r}, "
                        "which is not a source position"
                    )
    source = attributed_source(record["source_name"], selection, root, where)
    line, column = position_of(labels)
    if line > len(selection[source].lines):
        raise Refusal(
            f"{where} names {selection[source].relative}:{line}, and that file "
            f"has {len(selection[source].lines)} line(s); a record pointing "
            "outside its own source cannot be matched to a statement"
        )
    return Report(record, selection[source].relative, line, column)


def attributed_source(source_name: str, selection: list[Selection], root: str, where: str) -> int:
    """Which selected file a record claims, refusing one that claims no file."""
    try:
        relative = relative_within(root, source_name)
    except ValueError as error:
        raise Refusal(f"{where} names {source_name!r}, which is not a path") from error
    for index, entry in enumerate(selection):
        if entry.relative == relative:
            return index
    raise Refusal(
        f"{where} names {relative}, which is not one of the "
        f"{len(selection)} file(s) this run selected; a finding for a file the "
        "gate did not name cannot be adjudicated here"
    )


def position_of(labels: list[dict]) -> tuple[int, int]:
    """The line and column a record is about.

    The analyzer marks the span its message is really about with `primary`, and
    falling back to the first label keeps a record with no marked label
    attached to a real line instead of to nothing.
    """
    label = labels[0]
    for candidate in labels:
        if candidate.get("primary") is True:
            label = candidate
            break
    return label["start"]["line"], label["start"]["column"]


# -- the annotations ---------------------------------------------------------


def scan_annotations(selection: list[Selection]) -> list[Annotation]:
    """Every marker in every selected file, in the order the files were named."""
    annotations: list[Annotation] = []
    for entry in selection:
        for number, line in enumerate(entry.lines, start=1):
            stripped = line.strip()
            if not MARKER_PREFIX_RE.match(stripped):
                continue
            annotations.append(
                Annotation(
                    entry.relative,
                    number,
                    stripped,
                    bool(EXACT_MARKER_RE.match(stripped)),
                )
            )
    return annotations


def target_line(lines: list[str], marker: int) -> int:
    """The one statement line a marker covers.

    The rows already carrying `ziglint-ignore: Z026` or
    `zwanzig-disable-next-line: empty-catch-engine` are jumped, because they are
    contiguous and each names the rule it silences. Nothing else is jumped: a
    blank line, prose, a statement, any other directive or a second marker ends
    the cover, so a marker can never grow past the statement beneath it. A
    `catch {}` and a bounded-format `catch unreachable` are both that one
    statement, and neither is a function, a block or a range.
    """
    cursor = marker
    while cursor < len(lines) and lines[cursor].strip() in FENCE_ROWS:
        cursor += 1
    return cursor + 1


def adjudicate(
    records: list[Report], annotations: list[Annotation], selection: list[Selection]
) -> tuple[dict[int, Annotation], list[int], list[str]]:
    """Which record each annotation closes, and every refusal they earned.

    Returns the closed records by index, the indices of the records that stay
    open, and the refusals. A record no annotation covers is open whatever it
    is: a rule nobody reviewed is a rule this file has no opinion about, and
    keeping it visible is what stops a review from becoming a general waiver.
    """
    refusals: list[str] = []
    closed: dict[int, Annotation] = {}
    sources = {entry.relative: entry for entry in selection}

    for annotation in annotations:
        where = f"{annotation.relative}:{annotation.line}"
        if not annotation.exact:
            refusals.append(
                f"{where} carries '{annotation.text}', which is not a marker "
                f"this review accepts; the only one it accepts is '{MARKER_TEXT}'"
            )
            continue
        if annotation.relative not in REVIEWED_FILES:
            refusals.append(
                f"{where} carries '{MARKER_TEXT}', and this review covers "
                f"{len(REVIEWED_FILES)} named paths only; "
                f"{annotation.relative} is not one of them"
            )
            continue
        lines = sources[annotation.relative].lines
        if annotation.line >= len(lines):
            refusals.append(
                f"{where} carries '{MARKER_TEXT}' and there is no line under it "
                "to review"
            )
            continue
        marked = target_line(lines, annotation.line)
        if marked > len(lines):
            refusals.append(
                f"{where} carries '{MARKER_TEXT}' and the rows under it run off "
                "the end of the file, so it covers no statement"
            )
            continue
        covered = [
            index
            for index, report in enumerate(records)
            if report.source == annotation.relative
            and report.line == marked
            and report.record["code"] == REVIEWED_RULE
        ]
        if not covered:
            refusals.append(
                f"{where} carries '{MARKER_TEXT}' and names "
                f"{annotation.relative}:{marked}, and no '{REVIEWED_RULE}' "
                "record was reported there; an annotation nothing reports is "
                "stale, not clean"
            )
            continue
        if len(covered) > 1:
            refusals.append(
                f"{where} carries '{MARKER_TEXT}' and "
                f"{annotation.relative}:{marked} carries {len(covered)} "
                f"'{REVIEWED_RULE}' records; one marker covers one statement, "
                "not an ambiguous line"
            )
            continue
        index = covered[0]
        if records[index].record["level"] != "warn":
            refusals.append(
                f"{where} carries '{MARKER_TEXT}' and the record at "
                f"{annotation.relative}:{marked} is level "
                f"{records[index].record['level']!r}; this review is a review of "
                "reviewed warnings and waives no error"
            )
            continue
        if index in closed:
            first = closed[index]
            refusals.append(
                f"{where} and {first.relative}:{first.line} both close the "
                f"record at {annotation.relative}:{marked}; one record is "
                "closed by one annotation"
            )
            continue
        closed[index] = annotation

    open_indices = [index for index in range(len(records)) if index not in closed]
    return closed, open_indices, refusals


# -- what the wrapper prints -------------------------------------------------


def format_record(report: Report) -> str:
    record = report.record
    return f"{report.where}: {record['level']}({record['code']}): {record['message']}"


def order_open(open_indices: list[int], records: list[Report]) -> list[int]:
    """Errors before warnings, so a display cap cannot bury the fatal one."""
    errors = [index for index in open_indices if records[index].record["level"] == "error"]
    warnings = [index for index in open_indices if records[index].record["level"] == "warn"]
    return errors + warnings


def emit_open_text(records: list[Report], open_indices: list[int], counted: bool) -> None:
    """The open findings, and the gate's count of them when there is one to give.

    `counted` is false whenever this run is refused. A refusal prints the
    findings it refused to waive, so the run stays attributable to real source
    positions, and prints no count at all: the gate counts this line, and a
    count beside a refusal is a number a reader can mistake for a clean run.
    """
    ordered = order_open(open_indices, records)
    shown = ordered[:DISPLAY_LIMIT]
    for index in shown:
        print(format_record(records[index]))
    if counted:
        errors = sum(
            1 for index in open_indices if records[index].record["level"] == "error"
        )
        # Counted over the whole report, not over what was displayed: a cap
        # limits what a reader has to read, never what the gate is told is open.
        print(f"Found {errors} errors and {len(open_indices) - errors} warnings")
    hidden = len(ordered) - len(shown)
    if hidden:
        print(
            f"zlint: {hidden} further open finding(s) not shown; run zlint "
            "directly for the whole report"
        )
    if not counted:
        print(
            "zlint: this run was refused, so no count is reported; anything "
            "printed above is what the analyzer reported and stayed open, and "
            "the reason is on stderr"
        )


def emit_open_json(records: list[Report], open_indices: list[int]) -> None:
    """Every open record, complete and uncapped, as the analyzer's own NDJSON.

    The gate reduces this to a per-rule histogram, so a cap here would delete
    rules from a count, and a summary line here would break the reader that is
    parsing it. A refused run still writes its open records for the same reason
    the text run still prints its findings: those records are what the run is
    attributable to, and there is no banner here for a reader to mistake them
    for. Records are written back exactly as they arrived: nothing added,
    nothing dropped, nothing summarized.
    """
    for index in order_open(open_indices, records):
        sys.stdout.write(json.dumps(records[index].record, separators=(",", ":")) + "\n")


def report_reviews(records: list[Report], closed: dict[int, Annotation]) -> None:
    """The reviews, on stderr, as reviews.

    A reviewed record is not an open finding and is never printed as one. It is
    named on stderr with the marker that stands behind it, because a run whose
    open count is zero is otherwise indistinguishable from a run that had
    nothing to waive.
    """
    if not closed:
        return
    print(
        f"zlint-reviewed: {len(closed)} '{REVIEWED_RULE}' record(s) closed by "
        "an exact-statement annotation, on manual review of the source and not "
        "by any automatic analysis:",
        file=sys.stderr,
    )
    for index in sorted(closed, key=lambda item: records[item].where):
        annotation = closed[index]
        print(
            f"zlint-reviewed: {records[index].where} reviewed by "
            f"{annotation.relative}:{annotation.line} '{MARKER_TEXT}'",
            file=sys.stderr,
        )


def refuse(message: str) -> int:
    print(f"{REFUSAL_PREFIX} {message}", file=sys.stderr)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))