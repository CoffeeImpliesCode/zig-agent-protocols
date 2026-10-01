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

DEFAULT_TIMEOUT_SECONDS = 900
MAX_REPORTED_OPEN = 100
MAX_FORWARDED_STDERR_LINES = 20

EXIT_CLEAN = 0
EXIT_OPEN = 1
EXIT_REFUSED = 2

MARKER_RE = re.compile(r"^//\s*gate-reviewed-zbc-next-line:\s*(\S+)\s*$")
RECURSIVE_CALL_RE = re.compile(r"\bself\.skipValue\(")


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
            command, capture_output=True, timeout=timeout_seconds()
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


def refuse(message: str) -> int:
    print(f"zbc: refusing to judge this run: {message}", file=sys.stderr)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))