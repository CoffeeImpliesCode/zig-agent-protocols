#!/usr/bin/env python3
"""The house gate's zbc, with one reviewed finding and nothing else waived.

`zig-gate` runs its zbc section against `$ZBC`, which this file is for the
project's own `gate` script and nothing else: `zbc` on PATH stays the analyzer,
and `ZBC=zbc zig-gate` runs the gate exactly as the host tool ships. The wrapper
asks the analyzer for JSON, reports every finding it is given in the analyzer's
own `severity(rule-id)` form, and adjudicates exactly one of them: the
`recursive-parse-fn-without-stack-check` finding on `json.Reader.skipValue`, whose
container nesting is bounded by `json.max_depth` through `enterContainer` in both
container arms. That adjudication is not this file's judgement. It is a review
recorded in the source, and the source records it as a comment naming both
container arms and the bound, then the marker

    // gate-reviewed-zbc-next-line: recursive-parse-fn-without-stack-check

on the line immediately above the recursive call it covers. What this file checks
is the shape of that record, never the truth of the claim the comment makes: one
file, one rule, one marker, on the line immediately above one finding, and that
line really is a recursive `skipValue` call. Everything else is refused.

Refusal is a failure, not a warning, because every way this file could be wrong
produces the same false green: output it cannot read, a status that is neither of
the analyzer's own two, an annotation that maps to no finding or to a finding it
may not waive, a marker in a file that was never reviewed, and a file list that
came out empty because an exclusion matched everything. Findings in a valid
report are printed even when the annotation is refused. An unreadable report or
unexpected analyzer status fails before findings can be interpreted.

Two things about the run itself are this file's business rather than the
analyzer's. The first is the source list. A named import is answered by
reading the `build.zig` that wires it, and the analyzer only looks for one
while walking up from a directory it was given: handed `src/*.zig` without
the checkout's `build.zig`, the walk starts inside `src/`, stops at the
source boundary, never reads the wiring, and every named import degrades
silently to an unknown type while the run still reports its findings. This
wrapper therefore names the governing `build.zig` to the analyzer whenever
the checkout has one and the caller's list does not, because that is what
puts the checkout root among the directories the walk starts from. Nothing
else about the list changes, and a file list that was empty is refused
before this wrapper adds anything to it.

The second is the analyzer's own `unresolved-import-lookups=N` summary. It
is not a count of missing imports: it counts distinct per-file lookups of a
named import that build wiring did not answer, one per file and module
name, and `std` is one per file that reaches a qualified std name because
the type engine resolves `std` from the toolchain `zig env` reports rather
than from `build.zig`. A nonzero count is therefore explained here, with the
names the analyzed sources spell and whoever can answer each, and never
adjudicated: it stays nonzero in a tree where nothing is wrong, so refusing
on it would fail every run over a number that is not a defect.

Standard library only. This is development tooling; no Zig file imports it and
the library keeps its zero-dependency guarantee.

Environment:
  GATE_ZBC_BIN             the analyzer to run. Unset resolves `zbc` on PATH,
                           and a `zbc` that resolves to this file is refused
                           rather than delegated to.
  GATE_PROJECT_ROOT        the checkout the findings are relative to. Defaults to
                           the directory this file lives two levels under.
  GATE_ZBC_TIMEOUT_SECONDS deadline for the analyzer. Default 900. An analyzer
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

REVIEWED_FILE = "src/json.zig"
RECURSION_RULE = "recursive-parse-fn-without-stack-check"
MARKER_PREFIX = "// gate-reviewed-zbc-next-line:"
REQUIRED_CITATIONS = ("enterContainer", "max_depth")
SEVERITIES = ("error", "warning")
REQUIRED_FIELDS = ("path", "rule_id", "severity", "start", "message")

# The checkout's governing build file: the only document that says which root
# a named import stands for, and the one the analyzer reads while walking up
# from a directory it was given.
GOVERNING_BUILD_FILE = "build.zig"
# Names the compiler answers itself. `std` comes from the toolchain `zig env`
# reports, the others from the compilation, so no build file wires them and
# the analyzer's own wiring lookup cannot answer them by design.
COMPILER_PROVIDED_MODULES = frozenset({"std", "builtin", "root", "compiler"})
MAX_REPORTED_MODULES = 20

DEFAULT_TIMEOUT_SECONDS = 900
MAX_REPORTED_OPEN = 100
MAX_FORWARDED_STDERR_LINES = 20

EXIT_CLEAN = 0
EXIT_OPEN = 1
EXIT_REFUSED = 2

MARKER_RE = re.compile(r"^//\s*gate-reviewed-zbc-next-line:\s*(\S+)\s*$")
RECURSIVE_CALL_RE = re.compile(r"\bself\.skipValue\(")
IMPORT_STRING_RE = re.compile(r'@import\(\s*"([^"\\]+)"')
UNRESOLVED_LOOKUPS_RE = re.compile(r"\bunresolved-import-lookups=(\d+)")
MODULE_WIRING_CALL_RE = re.compile(r'\badd(?:Module|Import|Options)\s*\(\s*"([^"]+)"')
MODULE_WIRING_ENTRY_RE = re.compile(r'\.name\s*=\s*"([^"]+)"')


class Refusal(Exception):
    """A condition this wrapper will not interpret. The gate fails on it."""


class Annotation(NamedTuple):
    relative: str
    line: int
    rule: str
    citations: str


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
    files, forwarded = split_arguments(argv)
    if not files:
        raise Refusal(
            "no source file was given to analyze; a file list that excluded "
            "everything would otherwise read as a clean run"
        )
    analyzer = resolve_analyzer()
    root = resolve_root()
    # The caller's own list is judged for emptiness first: a refusal that this
    # wrapper could fill in would be a refusal it invented.
    files = with_governing_build_file(root, files)
    report, status, analyzer_stderr = run_analyzer(analyzer, files, forwarded)
    findings = parse_findings(report)
    if status == 1 and not findings:
        raise Refusal(
            "the analyzer exited 1 to report findings and its JSON report is []; "
            "refusing to read a report that contradicts its own status as clean"
        )
    annotations, sources = scan_annotations(root, files)
    decisions, refusals = adjudicate(findings, annotations, sources)

    forward_analyzer_stderr(analyzer_stderr)
    report_unresolved_imports(analyzer_stderr, sources, root)
    print_report(findings, decisions)
    for message in refusals:
        print(f"zbc: refusing to judge this run: {message}", file=sys.stderr)

    if refusals:
        return EXIT_REFUSED
    if any(decision is None for decision in decisions):
        return EXIT_OPEN
    return EXIT_CLEAN


def split_arguments(argv: list[str]) -> tuple[list[str], list[str]]:
    """The files to analyze and the analyzer options to pass through.

    The gate passes file paths and nothing else. Anything that looks like an
    option is forwarded so a hand-run wrapper keeps working, except a format
    option: the adjudication reads JSON, and a report it did not ask for is a
    report it cannot judge.
    """
    files: list[str] = []
    forwarded: list[str] = []
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--format":
            index += 2
            continue
        if argument.startswith("--format="):
            index += 1
            continue
        if argument.startswith("-"):
            forwarded.append(argument)
        else:
            files.append(argument)
        index += 1
    return files, forwarded


def with_governing_build_file(root: str, files: list[str]) -> list[str]:
    """The analyzer's source list, with the checkout's build file named in it.

    A named import is answered by reading the `build.zig` that wires it, and
    the analyzer looks for one only while walking up from a directory it was
    given. Handed `src/*.zig` without that file, every source root it derives
    is inside `src/`, the walk stops where the source boundary does, and no
    wiring is ever read: each named import then answers "unknown type", the
    rules fall back to their conservative branch, and the run still reports
    its findings, so the loss is invisible in the report. Naming the file is
    what puts the checkout root among the roots the walk starts from, and it
    is the only side of this seam that can restore the wiring.

    Nothing else about the list changes: the file is added when the checkout
    has one and the caller's list does not name it, under the same relative
    name the checkout uses, however it was spelled on the way in. A list this
    wrapper was handed empty has already been refused before it gets here.
    """
    if not os.path.isfile(os.path.join(root, GOVERNING_BUILD_FILE)):
        return files
    if any(names_build_file(root, requested) for requested in files):
        return files
    return [GOVERNING_BUILD_FILE, *files]


def names_build_file(root: str, requested: str) -> bool:
    """Whether the checkout's build file is what this argument names."""
    try:
        return relative_within(root, requested) == GOVERNING_BUILD_FILE
    except ValueError:
        return False


def resolve_analyzer() -> str:
    override = os.environ.get("GATE_ZBC_BIN", "").strip()
    if override:
        candidates = [override]
    else:
        found = shutil.which("zbc")
        candidates = [found] if found else []
    if not candidates:
        raise Refusal(
            "no zbc analyzer to run: set GATE_ZBC_BIN or put zbc on PATH"
        )
    analyzer = candidates[0]
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
    raw = os.environ.get("GATE_ZBC_TIMEOUT_SECONDS", "").strip()
    if not raw:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        seconds = int(raw)
    except ValueError as error:
        raise Refusal(
            f"GATE_ZBC_TIMEOUT_SECONDS is {raw!r}, which is not a number of seconds"
        ) from error
    if seconds < 1:
        raise Refusal("GATE_ZBC_TIMEOUT_SECONDS must be at least one second")
    return seconds


def run_analyzer(
    analyzer: str, files: list[str], forwarded: list[str]
) -> tuple[str, int, str]:
    command = [analyzer, "--format=json", *forwarded, *files]
    try:
        completed = subprocess.run(
            command, capture_output=True, cwd=resolve_root(), timeout=timeout_seconds()
        )
    except subprocess.TimeoutExpired as error:
        raise Refusal(
            f"the analyzer did not answer within {timeout_seconds()} seconds; a "
            "gate run cannot wait on it"
        ) from error
    except OSError as error:
        raise Refusal(f"the analyzer could not be started: {error}") from error
    if completed.returncode not in (0, 1):
        raise Refusal(
            f"the analyzer exited {completed.returncode}, which is neither its "
            "clean status (0) nor its findings status (1)"
        )
    try:
        report = completed.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Refusal(f"the analyzer's report is not UTF-8: {error}") from error
    stderr = completed.stderr.decode("utf-8", "replace")
    return report, completed.returncode, stderr


def parse_findings(report: str) -> list[dict]:
    if not report.strip():
        raise Refusal(
            "the analyzer wrote nothing to stdout; refusing to read that as a "
            "clean report"
        )
    try:
        payload = json.loads(report)
    except ValueError as error:
        raise Refusal(f"the analyzer's report is not JSON: {error}") from error
    if not isinstance(payload, list):
        raise Refusal(
            f"the analyzer's report is a {type(payload).__name__}, not a JSON "
            "array of findings"
        )
    findings: list[dict] = []
    for index, entry in enumerate(payload):
        if not isinstance(entry, dict):
            raise Refusal(f"finding {index} is a {type(entry).__name__}, not an object")
        for field in REQUIRED_FIELDS:
            if field not in entry:
                raise Refusal(f"finding {index} has no {field}")
        if not isinstance(entry["path"], str) or not entry["path"]:
            raise Refusal(f"finding {index} has no usable path")
        if not isinstance(entry["rule_id"], str) or not entry["rule_id"]:
            raise Refusal(f"finding {index} has no usable rule_id")
        if entry["severity"] not in SEVERITIES:
            raise Refusal(
                f"finding {index} has severity {entry['severity']!r}, which is "
                f"neither {' nor '.join(SEVERITIES)}"
            )
        start = entry["start"]
        if not isinstance(start, dict) or "line" not in start:
            raise Refusal(f"finding {index} has no start.line")
        line = start["line"]
        if isinstance(line, bool) or not isinstance(line, int) or line < 1:
            raise Refusal(
                f"finding {index} has start.line {line!r}, which is not a source line"
            )
        if not isinstance(entry["message"], str):
            raise Refusal(f"finding {index} has no usable message")
        findings.append(entry)
    return findings


def scan_annotations(
    root: str, files: list[str]
) -> tuple[list[Annotation], dict[str, list[str]]]:
    """Every marker in every file the analyzer was given, and their sources."""
    annotations: list[Annotation] = []
    sources: dict[str, list[str]] = {}
    for requested in files:
        relative = relative_within(root, requested)
        absolute = os.path.join(root, relative)
        try:
            with open(absolute, encoding="utf-8") as source:
                lines = source.read().splitlines()
        except FileNotFoundError:
            continue
        except (OSError, UnicodeDecodeError) as error:
            raise Refusal(
                f"{relative} cannot be read, so its annotations cannot be "
                f"checked: {error}"
            ) from error
        sources[relative] = lines
        for number, line in enumerate(lines, start=1):
            match = MARKER_RE.match(line.strip())
            if match:
                annotations.append(
                    Annotation(relative, number, match.group(1), rationale_above(lines, number))
                )
    return annotations, sources


def relative_within(root: str, requested: str) -> str:
    """A requested file as the checkout names it, however it was asked for.

    The gate hands over what `find` printed, which is `./src/json.zig`, and a
    hand-run wrapper may hand over an absolute path. The annotation lookup and
    the finding paths are both compared against the checkout's own names, so
    both have to be normalized the same way before they are compared.
    """
    path = requested if os.path.isabs(requested) else os.path.join(root, requested)
    return os.path.relpath(os.path.realpath(path), root).replace(os.sep, "/")


def rationale_above(lines: list[str], number: int) -> str:
    """The contiguous comment block directly above an annotation."""
    block: list[str] = []
    cursor = number - 2
    while cursor >= 0:
        stripped = lines[cursor].strip()
        if not stripped.startswith("//"):
            break
        block.append(stripped)
        cursor -= 1
    return "\n".join(reversed(block))


def adjudicate(
    findings: list[dict],
    annotations: list[Annotation],
    sources: dict[str, list[str]],
) -> tuple[list[Annotation | None], list[str]]:
    """Which finding each annotation waives, and what it may not waive.

    Returns one entry per finding — the annotation that waives it, or None for a
    finding that stays open — together with the refusals the annotations
    earned. An annotation nothing checks is a waiver with no reader, so one
    that names a rule this review does not cover, one that is not attached to a
    recursive call, one that maps to no finding, one that sits in a file this
    review never looked at, and more than one of them in the reviewed file, are
    all refused rather than honored. The findings themselves are reported either
    way: a refusal says this run cannot be judged, not that the analyzer had
    nothing to say.
    """
    refusals: list[str] = []
    in_file = [a for a in annotations if a.relative == REVIEWED_FILE]
    if len(in_file) > 1:
        refusals.append(
            f"{REVIEWED_FILE} carries {len(in_file)} '{MARKER_PREFIX} ...' "
            "annotations; this review is one finding and one annotation"
        )

    decisions: list[Annotation | None] = [None] * len(findings)
    for annotation in annotations:
        where = f"{annotation.relative}:{annotation.line}"
        marker = f"'{MARKER_PREFIX} {annotation.rule}'"
        if annotation.relative != REVIEWED_FILE:
            refusals.append(
                f"{where} carries {marker}, and this review covers "
                f"{REVIEWED_FILE} only"
            )
            continue
        if annotation.rule != RECURSION_RULE:
            refusals.append(
                f"{where} {marker} annotates a rule this review does not cover; "
                f"the only rule reviewed here is '{RECURSION_RULE}'"
            )
            continue
        missing = [
            token for token in REQUIRED_CITATIONS if token not in annotation.citations
        ]
        if missing:
            refusals.append(
                f"{where} the rationale above {marker} must cite "
                f"{' and '.join(REQUIRED_CITATIONS)}; it does not mention "
                f"{' or '.join(missing)}"
            )
            continue
        marked = annotation.line + 1
        lines = sources.get(REVIEWED_FILE, [])
        if marked > len(lines) or not RECURSIVE_CALL_RE.search(lines[marked - 1]):
            refusals.append(
                f"{where} {marker} annotates line {marked}, which is not a "
                "recursive skipValue call"
            )
            continue
        waived = [
            index
            for index, entry in enumerate(findings)
            if relative_path(entry["path"]) == REVIEWED_FILE
            and entry["rule_id"] == RECURSION_RULE
            and entry["start"]["line"] == marked
        ]
        if not waived:
            refusals.append(
                f"{where} {marker} annotates line {marked}, and no finding was "
                "reported there"
            )
            continue
        for index in waived:
            decisions[index] = annotation
    return decisions, refusals


def relative_path(path: str) -> str:
    """A finding's file as the checkout names it."""
    try:
        return relative_within(resolve_root(), path)
    except ValueError:
        return path


def column_of(entry: dict) -> int:
    column = entry["start"].get("column", 1)
    if isinstance(column, bool) or not isinstance(column, int):
        return 1
    return column


def format_finding(entry: dict, label: str, annotation: Annotation | None) -> str:
    line = (
        f"{relative_path(entry['path'])}:{entry['start']['line']}:{column_of(entry)}"
    )
    text = f"{line}: {label}({entry['rule_id']}): {entry['message']}"
    if annotation is not None:
        text += (
            f"  [reviewed: {annotation.relative}:{annotation.line} "
            f"'{MARKER_PREFIX} {annotation.rule}']"
        )
    return text


def print_report(findings: list[dict], decisions: list[Annotation | None]) -> None:
    reviewed = [index for index, decision in enumerate(decisions) if decision]
    open_errors = [
        index for index, decision in enumerate(decisions)
        if not decision and findings[index]["severity"] == "error"
    ]
    open_warnings = [
        index for index, decision in enumerate(decisions)
        if not decision and findings[index]["severity"] == "warning"
    ]
    # The host gate distinguishes fatal errors from advisory warnings using
    # printed diagnoses. Spend the cap on errors first so warnings cannot hide
    # the only fatal diagnosis while the wrapper returns the shared exit 1.
    open_findings = open_errors + open_warnings
    # The waiver is the one line a truncated report may not cut, so reviewed
    # findings are printed before the cap is applied to anything else.
    for index in reviewed:
        print(format_finding(findings[index], "reviewed", decisions[index]))
    shown = open_findings[:MAX_REPORTED_OPEN]
    for index in shown:
        print(format_finding(findings[index], findings[index]["severity"], None))
    hidden = len(open_findings) - len(shown)
    summary = (
        f"zbc: {len(findings)} finding(s) reported, {len(reviewed)} reviewed, "
        f"{len(open_findings)} open (errors {len(open_errors)}, "
        f"warnings {len(open_warnings)}), {len(shown)} shown"
    )
    if hidden:
        summary += f", {hidden} not shown (run zbc directly for the whole report)"
    print(summary)
    if reviewed:
        first = decisions[reviewed[0]]
        where = f"{first.relative}:{first.line}" if first else REVIEWED_FILE
        print(
            f"zbc-reviewed: {len(reviewed)} finding(s) adjudicated by the "
            f"annotation at {where}; the nesting is bounded by max_depth "
            f"through {REQUIRED_CITATIONS[0]} in both container arms"
        )


def forward_analyzer_stderr(text: str) -> None:
    """The analyzer's own summary, verbatim and bounded.

    It is evidence of what the analyzer did with the files it was given, so it is
    passed through rather than reworded. It is bounded because a diagnostic that
    prints without end is one of the ways a gate run stops being a gate run.
    """
    lines = [line for line in text.splitlines() if line.strip()]
    for line in lines[:MAX_FORWARDED_STDERR_LINES]:
        print(line, file=sys.stderr)
    if len(lines) > MAX_FORWARDED_STDERR_LINES:
        print(
            f"zbc: {len(lines) - MAX_FORWARDED_STDERR_LINES} further analyzer "
            "line(s) not shown",
            file=sys.stderr,
        )


def report_unresolved_imports(
    stderr: str, sources: dict[str, list[str]], root: str
) -> None:
    """What the analyzer's unresolved-import counter counts, and who answers a name.

    The counter is a total, not a finding and not a defect in this checkout:
    it counts distinct per-file lookups of a named import that build wiring did
    not answer, one per file and module name. `std` is one per file that reaches
    a qualified std name, because the type engine resolves `std` from the
    toolchain `zig env` reports and never from `build.zig`, so the analyzer's
    wiring lookup cannot answer it even when nothing is wrong. A tree with no
    unresolved imports at all is not the normal state of a healthy checkout,
    and failing on this number would fail every run over a counter, so the run
    is not failed on it; what it gets instead is the number's meaning and the
    names the analyzed sources actually spell, grouped by whoever can answer
    each one. The analyzer reports no per-edge list, so these names are the
    edges the run depended on and not a claim about which ones it looked up.
    """
    match = UNRESOLVED_LOOKUPS_RE.search(stderr)
    if match is None or int(match.group(1)) == 0:
        return
    wired = wired_modules(root)
    names = named_imports(sources)
    groups = (
        ("compiler-provided", [n for n in names if n in COMPILER_PROVIDED_MODULES]),
        (
            "wired by build.zig",
            [n for n in names if n not in COMPILER_PROVIDED_MODULES and n in wired],
        ),
        (
            "named but not wired by build.zig",
            [n for n in names if n not in COMPILER_PROVIDED_MODULES and n not in wired],
        ),
    )
    print(
        f"zbc: analyzer unresolved-import-lookups={match.group(1)} is not a "
        "count of missing imports:",
        file=sys.stderr,
    )
    print(
        "zbc:   distinct per-file lookups of a named import that build wiring "
        "did not answer.",
        file=sys.stderr,
    )
    for label, group in groups:
        print(f"zbc:   {label}: {listed(group)}", file=sys.stderr)


def named_imports(sources: dict[str, list[str]]) -> list[str]:
    """The module names the analyzed sources import by name rather than by path.

    A relative import names a file beside the importer and is resolved against
    it; this is the other kind, the one that has to be answered by the build.
    """
    names: set[str] = set()
    for lines in sources.values():
        for line in lines:
            for name in IMPORT_STRING_RE.findall(line):
                if name and not name.startswith(".") and not name.endswith(".zig"):
                    names.add(name)
    return sorted(names)


def wired_modules(root: str) -> set[str]:
    """The names the governing `build.zig` wires with a literal call.

    `addModule`, `addImport`, `addOptions` and literal `.name` import entries
    declare bindings. An options module can be generated while its import name
    remains explicit. This reports those names, not whether the analyzer can
    load a generated file. Comments and computed names are not claimed.
    """
    path = os.path.join(root, GOVERNING_BUILD_FILE)
    try:
        with open(path, encoding="utf-8") as build:
            text = build.read()
    except (OSError, UnicodeDecodeError):
        return set()
    wired: set[str] = set()
    for line in text.splitlines():
        code = line.split("//", 1)[0]
        wired.update(MODULE_WIRING_CALL_RE.findall(code))
        wired.update(MODULE_WIRING_ENTRY_RE.findall(code))
    return wired


def listed(names: list[str]) -> str:
    """A bounded list, so one pathological source cannot print without end."""
    shown = names[:MAX_REPORTED_MODULES]
    if len(names) > MAX_REPORTED_MODULES:
        return ", ".join(shown) + f", {len(names) - MAX_REPORTED_MODULES} more"
    return ", ".join(shown) or "none"


def refuse(message: str) -> int:
    print(f"zbc: refusing to judge this run: {message}", file=sys.stderr)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))