"""Guest coverage must account for every root and every test, not merely a VM exit."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

RUNNER = Path(__file__).resolve().parents[1] / "tools" / "cross_guest.py"

def run_count(tmp_path: Path, data: bytes, *extra: str) -> subprocess.CompletedProcess[str]:
    log = tmp_path / "guest.log"
    log.write_bytes(data)
    return subprocess.run([sys.executable, str(RUNNER), "count", str(log), *extra],
                          capture_output=True, text=True, timeout=30)


def test_complete_guest_receipt_counts_executed_tests(tmp_path: Path) -> None:
    result = run_count(tmp_path, b"boot chatter\r\nZAP_GUEST_EXPECTED       2\r\n"
                       b"ZAP_GUEST_BEGIN library\r\nAll 617 tests passed.\r\n"
                       b"ZAP_GUEST_END library 0\r\nZAP_GUEST_BEGIN testio\r\n"
                       b"All 9 tests passed.\r\nZAP_GUEST_END testio 0\r\n"
                       b"ZAP_GUEST_COMPLETE\r\n")
    assert result.returncode == 0, result.stderr
    assert result.stdout == "626\n"


def test_receipt_roots_must_match_exported_manifest(tmp_path: Path) -> None:
    manifest = tmp_path / "manifest"
    manifest.write_text("library\ntestio\n", encoding="ascii")
    complete = (b"ZAP_GUEST_EXPECTED 2\nZAP_GUEST_BEGIN library\n"
                b"All 617 tests passed.\nZAP_GUEST_END library 0\n"
                b"ZAP_GUEST_BEGIN testio\nAll 9 tests passed.\n"
                b"ZAP_GUEST_END testio 0\nZAP_GUEST_COMPLETE\n")
    shrunk = (b"ZAP_GUEST_EXPECTED 1\nZAP_GUEST_BEGIN library\n"
              b"All 617 tests passed.\nZAP_GUEST_END library 0\n"
              b"ZAP_GUEST_COMPLETE\n")
    assert run_count(tmp_path, complete, "--require-manifest", str(manifest)).returncode == 0
    shrunk_result = run_count(tmp_path, shrunk, "--require-manifest", str(manifest))
    assert shrunk_result.returncode == 1
    assert shrunk_result.stdout == ""


@pytest.mark.parametrize("summary,exit_code", [
    (b"All 9 tests passed.", 1),
    (b"8 passed; 1 skipped; 0 failed.", 0),
    (b"8 passed; 0 skipped; 1 failed.", 1),
])
def test_failed_or_skipped_tests_are_not_guest_passage(tmp_path: Path, summary: bytes,
                                                       exit_code: int) -> None:
    result = run_count(tmp_path, b"ZAP_GUEST_EXPECTED 1\nZAP_GUEST_BEGIN testio\n" + summary +
                       b"\nZAP_GUEST_END testio " + str(exit_code).encode() +
                       b"\nZAP_GUEST_COMPLETE\n")
    assert result.returncode == 1
    assert result.stdout == ""


@pytest.mark.parametrize("tail", [
    b"ZAP_GUEST_COMPLETE\n",
    b"ZAP_GUEST_BEGIN library\nAll 617 tests passed.\nZAP_GUEST_END library 0\n"
    b"ZAP_GUEST_COMPLETE\n",
])
def test_missing_or_repeated_roots_cannot_complete_the_receipt(tmp_path: Path, tail: bytes) -> None:
    result = run_count(tmp_path, b"ZAP_GUEST_EXPECTED 2\nZAP_GUEST_BEGIN library\n"
                       b"All 617 tests passed.\nZAP_GUEST_END library 0\n" + tail)
    assert result.returncode == 1
    assert result.stdout == ""
