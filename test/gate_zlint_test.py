"""Exercise the house gate's exact cleanup-waiver seam, not argument forwarding."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

WRAPPER = Path(__file__).resolve().parents[1] / "tools" / "gate_zlint.py"
RULE = "suppressed-errors"
MARKER = "// gate-reviewed-zlint-next-statement:"
FAKE_ANALYZER = """#!/usr/bin/env python3
import os
import sys
import time
if os.environ.get("FAKE_ANALYZER_SLEEP"):
    time.sleep(float(os.environ["FAKE_ANALYZER_SLEEP"]))
with open(os.environ["FAKE_ANALYZER_REPORT"], encoding="utf-8") as report:
    sys.stdout.write(report.read())
sys.stderr.write(os.environ.get("FAKE_ANALYZER_STDERR", ""))
sys.exit(int(os.environ["FAKE_ANALYZER_EXIT"]))
"""
FAKE_ANALYZER_RAW = """#!/usr/bin/env python3
import os
import sys
with open(os.environ["FAKE_ANALYZER_REPORT"], "rb") as report:
    sys.stdout.buffer.write(report.read())
sys.stderr.write(os.environ.get("FAKE_ANALYZER_STDERR", ""))
sys.exit(int(os.environ["FAKE_ANALYZER_EXIT"]))
"""


# The stand-in above decodes its report as UTF-8, which is what a report this
# wrapper has to parse looks like. A report that is not valid UTF-8 cannot get
# through it, so that one case needs a stand-in that copies bytes without
# decoding them: otherwise the child would fail in the wrong place and the test
# would prove something about the stand-in rather than about the wrapper.


def diagnostic(line: int, *, code: str = RULE, level: str = "warn", path: str = "src/conn.zig") -> dict:
    return {
        "level": level,
        "message": "A caught transport error was suppressed",
        "code": code,
        "source_name": path,
        "labels": [{"start": {"line": line, "column": 5}, "end": {"line": line, "column": 20},
                    "primary": False, "label": None}],
        "help": "Handle or propagate a failure outside best-effort teardown.",
    }


def source(*, annotated: bool = True, gap: str | None = None, rule: str = RULE,
           second: bool = False, cross_directives: bool = True) -> tuple[str, int, int | None]:
    rows = ["pub fn cleanup() void {", "    // transport.shutdown is best effort while unwinding; close still runs."]
    if annotated:
        rows.append(f"    {MARKER} {rule}")
        if cross_directives:
            rows.extend(["    // ziglint-ignore: Z026", "    // zwanzig-disable-next-line: empty-catch-engine"])
        if gap is not None:
            rows.append(gap)
    rows.append("    transport.shutdown(io, .both) catch {};")
    target = len(rows)
    other = None
    if second:
        rows.append("    transport.shutdown(io, .both) catch {};")
        other = len(rows)
    rows.extend(["    transport.close(io);", "}"])
    return "\n".join(rows) + "\n", target, other


def run_adapter(tmp_path: Path, report: list[dict] | str | bytes, *, text: str | None = None,
                status: int = 0, args: tuple[str, ...] = (), file: str = "src/conn.zig",
                stdin: str | None = None, sleep: float | None = None,
                stderr: str = "") -> subprocess.CompletedProcess[str]:
    checkout = tmp_path / "checkout"
    target = checkout / file
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text if text is not None else source(annotated=False)[0], encoding="utf-8")
    analyzer = tmp_path / "fake-zlint"
    analyzer.write_text(FAKE_ANALYZER_RAW if isinstance(report, bytes) else FAKE_ANALYZER,
                        encoding="utf-8")
    analyzer.chmod(0o755)
    payload = tmp_path / "report.ndjson"
    if isinstance(report, bytes):
        payload.write_bytes(report)
    else:
        payload.write_text(report if isinstance(report, str)
                           else "".join(json.dumps(row) + "\n" for row in report),
                           encoding="utf-8")
    env = os.environ.copy()
    env.update(GATE_PROJECT_ROOT=str(checkout), GATE_ZLINT_BIN=str(analyzer),
               FAKE_ANALYZER_REPORT=str(payload), FAKE_ANALYZER_EXIT=str(status),
               FAKE_ANALYZER_STDERR=stderr, PYTHONDONTWRITEBYTECODE="1")
    if sleep is not None:
        env.update(FAKE_ANALYZER_SLEEP=str(sleep), GATE_ZLINT_TIMEOUT_SECONDS="1")
    return subprocess.run([sys.executable, str(WRAPPER), "-S", *args],
                          input=stdin if stdin is not None else file + "\n",
                          cwd=checkout, env=env, capture_output=True, text=True, timeout=180)


def gate_counts(result: subprocess.CompletedProcess[str]) -> tuple[int, int]:
    """The exact summary seam the external house gate uses to assert warnings."""
    matches = re.findall(r"Found (\d+) errors and (\d+) warnings", result.stdout)
    assert len(matches) == 1, result.stdout
    return tuple(map(int, matches[0]))


def test_unmarked_warning_is_not_clean_even_when_raw_tool_exits_zero(tmp_path: Path) -> None:
    text, line, _ = source(annotated=False)
    result = run_adapter(tmp_path, [diagnostic(line)], text=text)
    assert result.returncode == 1
    assert gate_counts(result) == (0, 1)


@pytest.mark.parametrize("cross_directives", [False, True])
def test_exact_cleanup_review_accepts_only_its_statement(tmp_path: Path, cross_directives: bool) -> None:
    text, line, _ = source(cross_directives=cross_directives)
    result = run_adapter(tmp_path, [diagnostic(line)], text=text)
    assert result.returncode == 0
    assert gate_counts(result) == (0, 0)
    assert "reviewed" in result.stdout + result.stderr


def test_second_unmarked_catch_in_same_function_stays_asserted(tmp_path: Path) -> None:
    text, line, other = source(second=True)
    result = run_adapter(tmp_path, [diagnostic(line), diagnostic(other)], text=text)
    assert result.returncode == 1
    assert gate_counts(result) == (0, 1)


def test_same_line_other_rule_is_not_covered_by_cleanup_review(tmp_path: Path) -> None:
    text, line, _ = source()
    result = run_adapter(tmp_path, [diagnostic(line), diagnostic(line, code="future-rule")], text=text)
    assert result.returncode == 1
    assert gate_counts(result) == (0, 1)


def test_json_histogram_mode_contains_only_open_diagnoses(tmp_path: Path) -> None:
    text, line, other = source(second=True)
    result = run_adapter(tmp_path, [diagnostic(line), diagnostic(other, code="future-rule")],
                         text=text, args=("-f", "json"))
    assert result.returncode == 1
    rows = [json.loads(row) for row in result.stdout.splitlines()]
    assert [(row["code"], row["labels"][0]["start"]["line"]) for row in rows] == [("future-rule", other)]


@pytest.mark.parametrize("gap", ["", "    // unrelated prose", "    work();"])
def test_review_cannot_jump_a_blank_comment_or_statement(tmp_path: Path, gap: str) -> None:
    text, line, _ = source(gap=gap)
    result = run_adapter(tmp_path, [diagnostic(line)], text=text)
    assert result.returncode == 2


def test_stale_review_refuses_instead_of_becoming_a_clean_run(tmp_path: Path) -> None:
    text, _, _ = source()
    result = run_adapter(tmp_path, [], text=text)
    assert result.returncode == 2
    assert not re.search(r"Found \d+ errors and \d+ warnings", result.stdout)


def test_review_cannot_name_another_rule(tmp_path: Path) -> None:
    text, line, _ = source(rule="no-print")
    result = run_adapter(tmp_path, [diagnostic(line, code="no-print")], text=text)
    assert result.returncode == 2


def test_review_cannot_move_to_an_unreviewed_source_file(tmp_path: Path) -> None:
    text, line, _ = source()
    result = run_adapter(tmp_path, [diagnostic(line, path="src/unreviewed.zig")],
                         text=text, file="src/unreviewed.zig")
    assert result.returncode == 2


def test_raw_analyzer_failure_is_fatal_and_keeps_its_cause_visible(tmp_path: Path) -> None:
    result = run_adapter(tmp_path, [diagnostic(1)], status=2, stderr="zlint: compiler NotFound\n")
    assert result.returncode == 2
    assert "compiler NotFound" in result.stderr
    assert not re.search(r"Found 0 errors and 0 warnings", result.stdout)


@pytest.mark.parametrize("report", ["not json\n", "[]\n", '{"code":"suppressed-errors"}\n'])
def test_unreadable_report_cannot_pass(tmp_path: Path, report: str) -> None:
    result = run_adapter(tmp_path, report)
    assert result.returncode == 2


def test_unknown_diagnostic_level_is_not_treated_as_advisory(tmp_path: Path) -> None:
    result = run_adapter(tmp_path, [diagnostic(1, level="notice")])
    assert result.returncode == 2


def test_unknown_rule_stays_open(tmp_path: Path) -> None:
    result = run_adapter(tmp_path, [diagnostic(1, code="new-consumer-visible-rule")])
    assert result.returncode == 1
    assert gate_counts(result) == (0, 1)


def test_counts_do_not_hide_an_error_after_five_hundred_warnings(tmp_path: Path) -> None:
    report = [diagnostic(1, code="future-warning") for _ in range(500)]
    report.append(diagnostic(1, code="future-error", level="error"))
    result = run_adapter(tmp_path, report)
    assert result.returncode == 1
    assert gate_counts(result) == (1, 500)
    assert "future-error" in result.stdout


def test_empty_source_selection_refuses(tmp_path: Path) -> None:
    result = run_adapter(tmp_path, [], stdin="")
    assert result.returncode == 2


def test_analyzer_that_never_answers_is_fatal(tmp_path: Path) -> None:
    result = run_adapter(tmp_path, [], sleep=1.5)
    assert result.returncode == 2
    assert "timeout" in result.stderr.lower() or "within" in result.stderr.lower()


def test_unannotated_clean_selection_passes_with_zero_counts(tmp_path: Path) -> None:
    result = run_adapter(tmp_path, [])
    assert result.returncode == 0
    assert gate_counts(result) == (0, 0)


def test_warning_review_cannot_waive_an_error(tmp_path: Path) -> None:
    text, line, _ = source()
    result = run_adapter(tmp_path, [diagnostic(line, level="error")], text=text)
    assert result.returncode == 2
    assert not re.search(r"Found 0 errors and 0 warnings", result.stdout)



def test_a_findings_status_carrying_no_record_is_not_a_clean_run(tmp_path: Path) -> None:
    """An analyzer that says it found something and reports nothing is refusing."""
    result = run_adapter(tmp_path, [], status=1)
    assert result.returncode == 2
    assert not re.search(r"Found 0 errors and 0 warnings", result.stdout)


def test_two_records_on_one_line_leave_the_review_ambiguous(tmp_path: Path) -> None:
    """A marker must match exactly one record, or it cannot be said what it covers."""
    text, line, _ = source()
    result = run_adapter(tmp_path, [diagnostic(line), diagnostic(line)], text=text)
    assert result.returncode == 2


@pytest.mark.parametrize("labels", [
    [],
    "one label",
    [{"start": {"line": 1, "column": 1}, "primary": False, "label": None}],
    [{"start": {"line": True, "column": 1}, "end": {"line": 1, "column": 2},
      "primary": False, "label": None}],
])
def test_a_record_whose_position_cannot_be_read_is_refused(tmp_path: Path, labels: object) -> None:
    """A record with no usable position is one no line-based review can match."""
    row = diagnostic(1)
    row["labels"] = labels
    result = run_adapter(tmp_path, [row])
    assert result.returncode == 2


def test_a_record_pointing_past_the_end_of_its_source_is_refused(tmp_path: Path) -> None:
    result = run_adapter(tmp_path, [diagnostic(99)])
    assert result.returncode == 2


def test_a_record_for_a_file_the_gate_never_selected_is_refused(tmp_path: Path) -> None:
    result = run_adapter(tmp_path, [diagnostic(1, path="src/other.zig")])
    assert result.returncode == 2


def test_a_report_that_is_not_utf8_is_refused_rather_than_replaced(tmp_path: Path) -> None:
    result = run_adapter(tmp_path, b'{"code":"\xff\xfe"}\n')
    assert result.returncode == 2
    assert not re.search(r"Found 0 errors and 0 warnings", result.stdout)