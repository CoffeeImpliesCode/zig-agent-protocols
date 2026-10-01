"""Boundary tests for the project's zbc adjudication wrapper.

The wrapper (`tools/gate_zbc.py`) is the only thing in this repository that is
allowed to decide that a zbc finding does not have to be fixed. It does so for
exactly one case — the recursion in `json.Reader.skipValue`, whose nesting is
bounded by `json.max_depth` through `enterContainer` in both container arms —
and only while `src/json.zig` carries the annotation that records that review.
The annotation is a reviewed waiver, not a proof the wrapper can check: what the
wrapper enforces is the shape of the record (this file, this rule, one marker
immediately above a recursive `skipValue` call, a contiguous rationale above it
that names the bound), never the truth of the claim the comment makes. What one
annotation covers is the one finding on the one line it stands above: a second
recursive call of the same function, in the same file, is not covered by it and
stays open, because a waiver that grows into a function is a larger claim than
the one that was reviewed.
Everything else about it is a refusal: analyzer output it cannot parse, an
analyzer that exits with anything but its own two finding statuses, an
annotation that maps to no finding, and any other recursive parse function.

These tests drive the wrapper as the house gate drives it: as a subprocess, with
a controlled analyzer standing in for `zbc` and a controlled source tree. The
analyzer stand-in exists so a decision can be pinned without depending on what
the installed analyzer happens to report today; what is asserted is the
wrapper's decision — which findings stay open, which one is adjudicated, and
which exit status the gate is handed — never that a string was copied.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
WRAPPER = REPO_ROOT / "tools" / "gate_zbc.py"

RECURSION_RULE = "recursive-parse-fn-without-stack-check"
OTHER_RULE = "intfromfloat-without-clamp"
MARKER_PREFIX = "// gate-reviewed-zbc-next-line:"

# Cites both container arms and the bound, which is what the annotation is
# allowed to stand on.
RATIONALE = (
    "// Nesting is bounded by json.max_depth: this function calls enterContainer",
    "// at the top of BOTH the object arm and the array arm below, and each arm's",
    "// defer leaveContainer runs before the next descent, so max_depth is checked",
    "// on every recursive step and a deeper document is refused, not recursed.",
)
WEAK_RATIONALE = (
    "// Reviewed: a human looked at this recursion once and liked what it saw.",
    "// Nothing here constrains how deep the parser can actually go.",
)

# Stands in for the analyzer. It prints exactly the bytes and the status the
# test chooses, on the streams the real analyzer uses: findings as a JSON array
# on stdout, a one-line summary on stderr, and it can be told never to answer.
# The report comes from a file rather than from the environment because a
# five-hundred-finding report is larger than one environment string can hold,
# and an environment that cannot hold it would fail the spawn instead of the
# behaviour under test.
FAKE_ANALYZER = '''#!/usr/bin/env python3
import os
import sys
import time

hang = os.environ.get("FAKE_ANALYZER_SLEEP")
if hang:
    time.sleep(float(hang))

with open(os.environ["FAKE_ANALYZER_REPORT"], encoding="utf-8") as report:
    sys.stdout.write(report.read())
sys.stderr.write("zbc: selected=2 analyzed=2 failed=0 findings=1 parser=Zig-0.16.0 "
                 "unresolved-import-lookups=2\\n")
sys.exit(int(os.environ["FAKE_ANALYZER_EXIT"]))
'''


def finding(path: str, rule: str, severity: str, line: int, *, column: int = 30) -> dict:
    """One analyzer finding in the documented JSON schema."""
    return {
        "path": path,
        "rule_id": rule,
        "severity": severity,
        "start": {"line": line, "column": column, "byte": 25867},
        "end": {"line": line, "column": column + 9, "byte": 25876},
        "message": f"`skipValue` calls itself recursively without a stack-depth guard ({rule})",
        "notes": [],
        "verdict": "unknown",
        "witness": None,
    }


def json_source(
    *,
    annotate: bool = True,
    rationale: tuple[str, ...] = RATIONALE,
    rule: str = RECURSION_RULE,
    blank_gap: int = 0,
    second_call: bool = False,
) -> tuple[str, int]:
    """A reader whose recursive calls sit at known lines.

    Returns the source text and the 1-based line number of the annotated
    recursive call, so a test can place a finding exactly where the annotation
    sits. `second_call` adds another recursive call further down the same
    function, unannotated, so a test can check that the annotation covers the
    one line it stands above and nothing else.
    """
    body = [
        "// A JSON reader whose container nesting is bounded by json.max_depth.",
        "",
        "pub const Reader = struct {",
        "    depth: u32 = 0,",
        "",
        "    pub fn skipValue(self: *Reader, scratch: []u8) void {",
        "        _ = scratch;",
        "        self.depth += 1;",
        "        defer self.depth -= 1;",
        "        if (self.depth > 128) return;",
    ]
    if annotate:
        body.extend(rationale)
        body.append(f"{MARKER_PREFIX} {rule}")
        body.extend("" for _ in range(blank_gap))
    body.append("        self.skipValue(scratch);")
    call_line = len(body)
    if second_call:
        body.append("        // the array arm recurses through the same bound")
        body.append("        self.skipValue(scratch);")
    body.append("    }")
    body.append("};")
    return "\n".join(body) + "\n", call_line


def run_gate(tmp_path: Path, *, sources: dict[str, str], stdout: str, exit_code: int,
             requested: tuple[str, ...] = ("src/json.zig",), analyzer_sleep: float | None = None,
             env_extra: dict[str, str] | None = None):
    """Run the wrapper the way the gate does, against a controlled tree."""
    project = tmp_path / "project"
    project.mkdir(exist_ok=True)
    for relative, text in sources.items():
        target = project / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    analyzer = tmp_path / "fake-zbc"
    analyzer.write_text(FAKE_ANALYZER, encoding="utf-8")
    analyzer.chmod(0o755)

    report = tmp_path / "analyzer-report.json"
    report.write_text(stdout, encoding="utf-8")

    env = dict(os.environ)
    env.update({
        "GATE_ZBC_BIN": str(analyzer),
        "GATE_PROJECT_ROOT": str(project),
        "FAKE_ANALYZER_REPORT": str(report),
        "FAKE_ANALYZER_EXIT": str(exit_code),
        "FAKE_ANALYZER_SLEEP": "" if analyzer_sleep is None else str(analyzer_sleep),
    })
    env.update(env_extra or {})
    return subprocess.run(
        [sys.executable, str(WRAPPER), *requested],
        capture_output=True,
        text=True,
        cwd=str(project),
        env=env,
        timeout=180,
    )


def call_lines(text: str) -> list[int]:
    """The 1-based lines of every recursive self-call in a source."""
    return [
        number
        for number, line in enumerate(text.splitlines(), start=1)
        if "self.skipValue(" in line
    ]


def analyzer_stdout(project: Path, findings: list[dict]) -> str:
    """The analyzer's stdout for a set of findings inside `project`."""
    resolved = []
    for entry in findings:
        entry = dict(entry)
        entry["path"] = str(project / entry["path"])
        resolved.append(entry)
    return json.dumps(resolved)


# --- the marked, bounded case: adjudicated and reported as reviewed ----------


def test_marked_bounded_recursion_is_adjudicated_and_reported_as_reviewed(tmp_path):
    text, line = json_source()
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, [finding("src/json.zig", RECURSION_RULE, "error", line)]),
        exit_code=1,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"src/json.zig:{line}" in result.stdout
    assert f"reviewed({RECURSION_RULE})" in result.stdout
    # The gate counts `error(` in this output; a reviewed finding must not be
    # counted as an open error, or the section could never pass.
    assert f"error({RECURSION_RULE})" not in result.stdout
    assert "zbc-reviewed: 1" in result.stdout


def test_reviewed_recursion_is_reported_next_to_open_findings(tmp_path):
    text, line = json_source()
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text, "src/bench.zig": "// bench\n"},
        stdout=analyzer_stdout(project, [
            finding("src/json.zig", RECURSION_RULE, "error", line),
            finding("src/bench.zig", OTHER_RULE, "warning", 1),
        ]),
        exit_code=1,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"reviewed({RECURSION_RULE})" in result.stdout
    assert f"warning({OTHER_RULE})" in result.stdout
    assert "zbc-reviewed: 1" in result.stdout


# --- every other finding stays open -----------------------------------------


def test_unrelated_error_stays_open_and_fails(tmp_path):
    text, line = json_source(annotate=False)
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, [finding("src/json.zig", "index-minus-one-without-zero-guard", "error", 2)]),
        exit_code=1,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert "error(index-minus-one-without-zero-guard)" in result.stdout
    assert "src/json.zig:2" in result.stdout


def test_unrelated_warning_stays_open_and_fails(tmp_path):
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/bench_runtime.zig": "// bench runtime\n"},
        stdout=analyzer_stdout(project, [finding("src/bench_runtime.zig", OTHER_RULE, "warning", 933)]),
        exit_code=1,
        requested=("src/bench_runtime.zig",),
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"warning({OTHER_RULE})" in result.stdout
    assert "src/bench_runtime.zig:933" in result.stdout


def test_recursion_in_another_file_is_not_waived(tmp_path):
    """A recursive parse function this wrapper has never reviewed stays open."""
    text, line = json_source()
    plain, _ = json_source(annotate=False)
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text, "src/other.zig": plain},
        stdout=analyzer_stdout(project, [
            finding("src/json.zig", RECURSION_RULE, "error", line),
            finding("src/other.zig", RECURSION_RULE, "error", line),
        ]),
        exit_code=1,
        requested=("src/json.zig", "src/other.zig"),
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"src/other.zig:{line}:30: error({RECURSION_RULE})" in result.stdout
    assert f"src/other.zig:{line}:30: reviewed" not in result.stdout
    assert "zbc-reviewed: 1" in result.stdout


def test_marker_outside_the_reviewed_file_fails_closed(tmp_path):
    """A marker this wrapper does not adjudicate is refused, not honoured."""
    text, line = json_source()
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text, "src/other.zig": text},
        stdout=analyzer_stdout(project, [finding("src/other.zig", RECURSION_RULE, "error", line)]),
        exit_code=1,
        requested=("src/json.zig", "src/other.zig"),
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert f"reviewed({RECURSION_RULE})" not in result.stdout
    assert f"error({RECURSION_RULE})" in result.stdout
    assert "src/other.zig" in result.stderr


def test_unannotated_recursive_call_in_the_same_function_stays_open(tmp_path):
    """One annotation covers one line; the other arm's call is not covered."""
    text, line = json_source(second_call=True)
    second = call_lines(text)[1]
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, [
            finding("src/json.zig", RECURSION_RULE, "error", line),
            finding("src/json.zig", RECURSION_RULE, "error", second),
        ]),
        exit_code=1,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"reviewed({RECURSION_RULE})" in result.stdout
    assert f"src/json.zig:{second}:30: error({RECURSION_RULE})" in result.stdout
    assert "zbc-reviewed: 1" in result.stdout


# --- annotations that do not carry the adjudication --------------------------


def test_annotation_whose_finding_is_missing_fails_closed(tmp_path):
    text, _ = json_source()
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, []),
        exit_code=0,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert "src/json.zig" in result.stderr
    assert MARKER_PREFIX in result.stderr


def test_annotation_separated_from_the_call_is_not_a_waiver(tmp_path):
    text, line = json_source(blank_gap=1)
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, [finding("src/json.zig", RECURSION_RULE, "error", line)]),
        exit_code=1,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert f"error({RECURSION_RULE})" in result.stdout + result.stderr
    assert MARKER_PREFIX in result.stderr


def test_annotation_without_the_required_rationale_fails_closed(tmp_path):
    text, line = json_source(rationale=WEAK_RATIONALE)
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, [finding("src/json.zig", RECURSION_RULE, "error", line)]),
        exit_code=1,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert f"reviewed({RECURSION_RULE})" not in result.stdout
    assert "enterContainer" in result.stderr
    assert "max_depth" in result.stderr


def test_annotation_naming_another_rule_fails_closed(tmp_path):
    text, line = json_source(rule="some-other-rule")
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, [finding("src/json.zig", RECURSION_RULE, "error", line)]),
        exit_code=1,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert f"reviewed({RECURSION_RULE})" not in result.stdout
    assert "some-other-rule" in result.stderr


def test_annotation_above_a_non_recursive_line_fails_closed(tmp_path):
    text, _ = json_source()
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, [finding("src/json.zig", RECURSION_RULE, "error", 3)]),
        exit_code=1,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert f"reviewed({RECURSION_RULE})" not in result.stdout


# --- tool failures the wrapper must not survive ------------------------------


def test_unparseable_output_fails_closed(tmp_path):
    text, _ = json_source(annotate=False)
    result = run_gate(tmp_path, sources={"src/json.zig": text}, stdout="{not json", exit_code=1)
    assert result.returncode == 2, result.stdout + result.stderr
    assert "json" in result.stderr.lower()


def test_output_that_is_not_a_finding_array_fails_closed(tmp_path):
    text, _ = json_source(annotate=False)
    result = run_gate(
        tmp_path, sources={"src/json.zig": text}, stdout='{"findings": []}', exit_code=1
    )
    assert result.returncode == 2, result.stdout + result.stderr


def test_finding_missing_a_required_field_fails_closed(tmp_path):
    text, _ = json_source(annotate=False)
    project = tmp_path / "project"
    entry = finding("src/json.zig", OTHER_RULE, "warning", 2)
    del entry["rule_id"]
    result = run_gate(
        tmp_path, sources={"src/json.zig": text}, stdout=analyzer_stdout(project, [entry]), exit_code=1
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert "rule_id" in result.stderr


def test_unknown_severity_fails_closed(tmp_path):
    text, _ = json_source(annotate=False)
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, [finding("src/json.zig", OTHER_RULE, "note", 2)]),
        exit_code=1,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert "note" in result.stderr


def test_empty_output_fails_closed(tmp_path):
    text, _ = json_source(annotate=False)
    result = run_gate(tmp_path, sources={"src/json.zig": text}, stdout="", exit_code=0)
    assert result.returncode == 2, result.stdout + result.stderr


def test_findings_status_with_no_findings_fails_closed(tmp_path):
    text, _ = json_source(annotate=False)
    result = run_gate(tmp_path, sources={"src/json.zig": text}, stdout="[]", exit_code=1)
    assert result.returncode == 2, result.stdout + result.stderr
    assert "[]" in result.stderr or "no findings" in result.stderr.lower()


def test_analyzer_failure_status_fails_closed(tmp_path):
    text, _ = json_source(annotate=False)
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout=analyzer_stdout(project, [finding("src/json.zig", OTHER_RULE, "error", 2)]),
        exit_code=3,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert f"error({OTHER_RULE})" not in result.stdout


def test_an_empty_file_list_fails_closed(tmp_path):
    """A file list that excluded everything would otherwise report clean."""
    result = run_gate(tmp_path, sources={}, stdout="[]", exit_code=0, requested=())
    assert result.returncode == 2, result.stdout + result.stderr
    assert "file" in result.stderr.lower()


# --- a gate run must end ----------------------------------------------------


def test_hanging_analyzer_is_cut_off(tmp_path):
    """An analyzer that never answers must not hold a gate run open."""
    text, _ = json_source(annotate=False)
    project = tmp_path / "project"
    result = run_gate(
        tmp_path,
        sources={"src/json.zig": text},
        stdout="",
        exit_code=1,
        analyzer_sleep=3600,
        env_extra={"GATE_ZBC_TIMEOUT_SECONDS": "2"},
    )
    assert result.returncode == 2, result.stdout + result.stderr


def test_truncated_report_accounts_for_what_it_left_out(tmp_path):
    """A bounded report still accounts for every finding it was given."""
    project = tmp_path / "project"
    findings = [finding("src/bench_runtime.zig", OTHER_RULE, "error", n) for n in range(1, 501)]
    result = run_gate(
        tmp_path,
        sources={"src/bench_runtime.zig": "// bench runtime\n"},
        stdout=analyzer_stdout(project, findings),
        exit_code=1,
        requested=("src/bench_runtime.zig",),
    )
    assert result.returncode == 1, result.stdout + result.stderr
    # Whatever the cap is, the report says how many findings there were and
    # names the ones it did not print: a truncated list is a summary, and a
    # summary that does not say it is one is a lie about what was checked.
    assert "500" in result.stdout
    assert "not shown" in result.stdout
    assert f"error({OTHER_RULE})" in result.stdout


def test_open_error_past_the_report_cap_still_fails_the_run(tmp_path):
    """Truncating the report must not truncate the verdict or hide the waiver."""
    project = tmp_path / "project"
    bench_findings = [
        finding("src/bench_runtime.zig", OTHER_RULE, "warning", n) for n in range(1, 501)
    ]
    bench_findings.append(finding("src/bench_runtime.zig", OTHER_RULE, "error", 501))
    result = run_gate(
        tmp_path,
        sources={"src/bench_runtime.zig": "// bench runtime\n"},
        stdout=analyzer_stdout(project, bench_findings),
        exit_code=1,
        requested=("src/bench_runtime.zig",),
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"error({OTHER_RULE})" in result.stdout

    # The gate distinguishes advisory warnings from fatal errors by the
    # diagnostics printed, not exit 1 alone. A late error must remain visible
    # after warning-heavy truncation, including when a reviewed finding follows
    # it; neither the fatal diagnosis nor the review may disappear.
    marked, call_line = json_source()
    with_reviewed = run_gate(
        tmp_path,
        sources={"src/bench_runtime.zig": "// bench runtime\n", "src/json.zig": marked},
        stdout=analyzer_stdout(
            project,
            bench_findings + [finding("src/json.zig", RECURSION_RULE, "error", call_line)],
        ),
        exit_code=1,
        requested=("src/bench_runtime.zig", "src/json.zig"),
    )
    assert with_reviewed.returncode == 1, with_reviewed.stdout + with_reviewed.stderr
    assert f"reviewed({RECURSION_RULE})" in with_reviewed.stdout
    assert "zbc-reviewed: 1" in with_reviewed.stdout
    assert f"error({OTHER_RULE})" in with_reviewed.stdout


def test_wrapper_refuses_to_delegate_to_itself(tmp_path):
    text, _ = json_source(annotate=False)
    project = tmp_path / "project"
    project.mkdir(exist_ok=True)
    (project / "src").mkdir(parents=True, exist_ok=True)
    (project / "src" / "json.zig").write_text(text, encoding="utf-8")

    # A `zbc` on PATH that is the wrapper: delegating to it would fork-bomb the
    # gate instead of analysing anything.
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "zbc").symlink_to(WRAPPER)

    env = dict(os.environ)
    env.pop("GATE_ZBC_BIN", None)
    env["PATH"] = str(bindir)
    env["GATE_PROJECT_ROOT"] = str(project)
    result = subprocess.run(
        [sys.executable, str(WRAPPER), "src/json.zig"],
        capture_output=True, text=True, cwd=str(project), env=env, timeout=60,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert "itself" in result.stderr or "zbc" in result.stderr