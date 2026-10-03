"""What `devenv.nix` does at shell entry, run as the shell code it is.

`enterShell` is the only place the pinned compiler is resolved, and a failure
there is the quietest kind: the anyzig shim exits 1 without a message, so a
shell that entered anyway reported nothing and every command run in it failed
for a reason no message named. Its four decisions — where the account's tools
come from, what a missing tool does, which toolchain store `p` points at, and
which executable `zig` resolves to — are shell code with no nix in them, so
they are tested here as shell code.

The body is read out of `devenv.nix` rather than copied into this file. A copy
is a second statement of the same script and would keep passing after the one
that runs had broken. Nix interpolation is resolved the way nix resolves it,
from a table of the expressions this file actually uses, and an interpolation
the table does not know is an error: a silent empty substitution is how a test
ends up exercising a script nobody runs.

Nothing here touches a network, a nix store, a shared cache or a real Zig.
`zig` is a stub in a temporary directory that answers with the version and the
`zig env` output the case under test calls for, and every path the body names
points inside that directory.

The commands the bodies run are the ones this process was given, linked into a
private directory of their own. A case's `PATH` names that directory instead of
`/usr/bin:/bin`, because the declared environment keeps `mkdir`, `sed` and
`bash` in /nix/store and `/usr/bin` holds none of them: a fixture that hands a
body a directory its tools are not in never reaches the body, so the case
fails on the fixture and says nothing about the decision it was written for.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEVENV_NIX = REPO / "devenv.nix"
HELPER = REPO / "tools" / "safe-rm-dir.sh"

ENTER_SHELL_MARKER = "enterShell = ''"
GATE_MARKER = "scripts.gate.exec = ''"
BODY_END = "  '';"

# `zig` is asked two things by `enterShell` and answers both here, so a case
# reproduces one of the shim's real behaviours without the shim. The interpreter
# is filled in per case rather than spelled `#!/usr/bin/env bash`: that shebang
# asks `env` to find bash on PATH, and every PATH a case builds is narrower than
# the one this process was given, so such a stub could not start there.
STUB_ZIG_TEMPLATE = """\
#!@shell@
case "${1:-}" in
    version)
        printf '%s\\n' "$FAKE_VERSION"
        exit "${FAKE_VERSION_RC:-0}"
        ;;
    env)
        cat "$FAKE_ENV_FILE"
        ;;
    *)
        echo "stub zig: unexpected argument: $*" >&2
        exit 64
        ;;
esac
"""

# Printed after the body so a case can see the state entry left behind. Kept
# outside the extracted text on purpose: it is this file's probe, not
# devenv.nix's.
PROBE = textwrap.dedent(
    """
    printf 'ENTRY_PATH=%s\\n' "$PATH"
    printf 'ENTRY_ZIG=%s\\n' "${ZIG-}"
    printf 'ENTRY_WHICH_ZIG=%s\\n' "$(command -v zig || true)"
    printf 'ENTRY_WHICH_PYTEST=%s\\n' "$(command -v pytest || true)"
    """
)

SCRATCH_KEYS = ("cache", "data", "tmp", "zigGlobal", "zigLocal")

# The commands the two bodies and the stubs beside them run. Resolved from the
# PATH this process was given and not from the one a case hands the body: inside
# the declared environment every one of them is a /nix/store path, and
# `/usr/bin:/bin` stops the body at its first `mkdir`. Linking them into one
# private directory that plays the part `/usr/bin:/bin` played also bounds what
# a body can reach to exactly this list, so no analyzer this host happens to have
# installed answers for a case that removed one.
BODY_TOOLS = (
    "bash",
    "cat",
    "ln",
    "ls",
    "mkdir",
    "mkfifo",
    "mktemp",
    "readlink",
    "sed",
)

# What the copy of `tools/safe-rm-dir.sh` the gate runs beside it needs. Named
# apart because those are the remover's own requirements: it reports a missing
# one itself, in the sentence an operator reads, and the case that needs an
# answer from it is the case that has to hear it.
REMOVER_TOOLS = (
    "awk",
    "find",
    "grep",
    "id",
    "lsof",
    "mountpoint",
    "realpath",
    "rm",
    "stat",
)


def private_tools(root: Path, *, also: tuple[str, ...] = ()) -> Path:
    """Resolve real dependencies without exposing host analyzers to the fixture."""
    directory = root / "host-tools"
    directory.mkdir()
    absent: list[str] = []
    for name in BODY_TOOLS + also:
        found = shutil.which(name)
        if found is None:
            absent.append(name)
        else:
            (directory / name).symlink_to(found)
    absent = sorted(set(absent) - set(also))
    if absent:
        raise AssertionError(
            f"this environment has no {', '.join(absent)}; the body under test "
            "runs it, and a fixture cannot stand in for a command"
        )
    return directory


def stub_zig(shell: str) -> str:
    """`STUB_ZIG_TEMPLATE` with the interpreter this case resolved."""
    return STUB_ZIG_TEMPLATE.replace("@shell@", shell)


def render_script(marker: str, substitutions: dict[str, str]) -> str:
    """One `= ''` string out of devenv.nix, with its Nix holes filled in."""
    text = DEVENV_NIX.read_text(encoding="utf-8")
    start = text.index(marker)
    body = text[start + len(marker) : text.index(BODY_END, start + len(marker))]

    table = dict(substitutions)
    # The Wine block is an interpolation whose value is itself an indented
    # string. Take the string so the guard it carries is exercised rather than
    # dropped; wine is absent here, so the guard is the whole of it.
    wine = re.search(r"\$\{lib\.optionalString[^\n]*''\n(.*?)\n    ''\}", body, re.S)
    if wine is not None:
        table[
            "${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''\n"
            + wine.group(1)
            + "\n    ''}"
        ] = wine.group(1)
    # `''${` is how a Nix indented string spells a literal `${`. Those are the
    # script's own shell expansions, never holes, and the lookbehind below is
    # what keeps them out of the substitution table.
    unknown: list[str] = []

    def substitute(match: re.Match[str]) -> str:
        hole = match.group(0)
        if hole not in table:
            unknown.append(hole)
            return hole
        return table[hole]

    body = re.sub(r"(?<!'')\$\{([^{}]*)\}", substitute, body)

    # This is where nix turns `''${` back into `${`.
    body = body.replace("''${", "${")

    if unknown:
        raise AssertionError(
            f"devenv.nix: {marker} gained an interpolation this test supplies no "
            f"value for: {sorted(set(unknown))}"
        )
    return body


def render_enter_shell(substitutions: dict[str, str]) -> str:
    return render_script(ENTER_SHELL_MARKER, substitutions)


class EnterShellCase(unittest.TestCase):
    """One temporary world: a tool directory, a toolchain, a scratch root."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="devenv-enter-shell-"))
        # The shell that runs the body and the commands the body runs, both
        # taken from the caller's PATH rather than from the one a case hands
        # the body: a case may replace PATH wholesale, and the body has to be
        # reachable whatever it is given.
        self.host_tools = private_tools(self.tmp)
        self.bash = str(self.host_tools / "bash")
        self.addCleanup(self.drop_scratch)

        # The account's tool directory: the shim and everything zig-gate runs.
        self.bin = self.tmp / "bin"
        self.toolchain = self.tmp / "toolchain"
        self.declared = self.tmp / "declared"
        self.scratch = self.tmp / "scratch"
        self.store = self.tmp / "stores"
        self.project = self.tmp / "project"
        for directory in (
            self.bin,
            self.toolchain,
            self.declared,
            self.scratch,
            self.store,
            self.project,
        ):
            directory.mkdir()
        # The directory the body is told to put on PATH: the account's own.
        self.host_bin = self.bin

        self.tools = ("zig-gate", "ziglint", "zlint", "zbc", "zwanzig", "cross-test")
        self.stores: list[Path] = []

        # Every stub starts with the resolved bash, because a shebang naming
        # `/bin/sh`, or asking `env` for bash, is a stub that cannot start in an
        # environment whose only shell is under /nix/store.
        silent = f"#!{self.bash}\nexit 0\n"

        # What the shim resolves to: a directory of its own, so that the body
        # putting it ahead of the tool directory is observable.
        self.real_zig = self.toolchain / "zig"
        self._executable(self.real_zig, stub_zig(self.bash))
        self._executable(self.bin / "zig", stub_zig(self.bash))
        for tool in self.tools:
            self._executable(self.bin / tool, silent)

        # A tool this project declares itself. `packages` is that statement,
        # and a host tool directory must not come before it.
        self._executable(self.declared / "pytest", silent)

        self.env_file = self.tmp / "zig-env.txt"
        self.env_file.write_text(
            ".{\n"
            f'    .zig_exe = "{self.real_zig}",\n'
            '    .version = "0.16.0",\n'
            "}\n",
            encoding="utf-8",
        )

    def drop_scratch(self) -> None:
        """Remove this case's world with the repository's own remover.

        House rules apply to a test's own fixtures too: nothing here is
        deleted by name either. `safe-rm-dir.sh` checks ownership, volume,
        containment and live references before it removes anything, and a
        refusal leaves the directory and says where it is.
        """
        result = subprocess.run(
            [str(HELPER), str(self.tmp)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            print(
                f"safe-rm-dir left {self.tmp} in place: {result.stderr.strip()}",
                file=sys.stderr,
            )

    def _executable(self, path: Path, text: str) -> None:
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)

    def scratch_paths(self) -> dict[str, str]:
        return {
            "tmp": str(self.scratch / "tmp"),
            "cache": str(self.scratch / "cache"),
            "data": str(self.scratch / "xdg-data"),
            "zigGlobal": str(self.scratch / "zig-cache"),
            "zigLocal": str(self.scratch / "build-cache"),
        }

    def substitutions(self) -> dict[str, str]:
        scratch = self.scratch_paths()
        joined = " ".join(scratch[key] for key in SCRATCH_KEYS)
        return {
            "${hostBin}": str(self.host_bin),
            '${builtins.concatStringsSep " " (builtins.attrValues scratch)}': joined,
            '${builtins.concatStringsSep " " toolchainStores}': " ".join(
                str(store) for store in self.stores
            ),
            "${scratchRoot}": str(self.scratch),
            "${scratch.zigGlobal}": scratch["zigGlobal"],
        }

    def make_store(self, name: str) -> Path:
        """A shared toolchain store, with one unpacked toolchain in it."""
        path = self.store / name
        path.mkdir()
        (path / "N-V-hash").mkdir()
        return path


    # -- running --------------------------------------------------------

    def run_entry(
        self,
        *,
        version: str = "0.16.0",
        version_rc: int = 0,
        pin: str = "0.16.0",
    ) -> subprocess.CompletedProcess[str]:
        (self.project / "build.zig.zon").write_text(
            f'    .minimum_zig_version = "{pin}",\n', encoding="utf-8"
        )
        scratch = self.scratch_paths()
        for name in scratch.values():
            Path(name).mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)
        env.pop("ZIG", None)
        env.update(
            {
                "PATH": os.pathsep.join([str(self.declared), str(self.host_tools)]),
                "DEVENV_ROOT": str(self.project),
                "TMPDIR": scratch["tmp"],
                "XDG_DATA_HOME": scratch["data"],
                "XDG_CACHE_HOME": scratch["cache"],
                "ZIG_GLOBAL_CACHE_DIR": scratch["zigGlobal"],
                "ZIG_LOCAL_CACHE_DIR": scratch["zigLocal"],
                "FAKE_VERSION": version,
                "FAKE_VERSION_RC": str(version_rc),
                "FAKE_ENV_FILE": str(self.env_file),
            }
        )
        script = render_enter_shell(self.substitutions()) + PROBE
        return subprocess.run(
            [self.bash, "-c", script],
            env=env,
            cwd=self.project,
            capture_output=True,
            text=True,
            check=False,
        )

    def entry_field(self, result: subprocess.CompletedProcess[str], key: str) -> str:
        prefix = f"ENTRY_{key}="
        for line in result.stdout.splitlines():
            if line.startswith(prefix):
                return line[len(prefix) :]
        self.fail(f"entry reported no {prefix} line:\n{result.stdout}\n{result.stderr}")

    def toolchain_p(self) -> Path:
        return Path(self.scratch_paths()["zigGlobal"]) / "p"

    # -- the compiler ---------------------------------------------------

    def test_entry_resolves_the_pinned_toolchain_and_keeps_it(self) -> None:
        # Selected-executable freezing: from here `zig` IS the toolchain the
        # pin selected, so nothing that repoints a cache can move it.
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.entry_field(result, "ZIG"), str(self.real_zig))
        self.assertEqual(self.entry_field(result, "WHICH_ZIG"), str(self.real_zig))

    def test_a_version_other_than_the_pin_stops_entry(self) -> None:
        result = self.run_entry(version="0.15.1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("ENTRY_ZIG=", result.stdout, "entry continued past the pin check")

    def test_a_silent_shim_stops_entry(self) -> None:
        # The shim exits 1 without a word. Entry must refuse rather than carry
        # on with an unresolved compiler; the probe after the body is what
        # proves it refused rather than reported and continued.
        result = self.run_entry(version_rc=1)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("ENTRY_ZIG=", result.stdout, "entry continued past a silent shim")

    def test_a_manifest_without_a_pin_stops_entry(self) -> None:
        result = self.run_entry(pin="")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("ENTRY_ZIG=", result.stdout)

    # -- the account's tools --------------------------------------------

    def test_tool_directory_is_appended_so_declared_packages_win(self) -> None:
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.entry_field(result, "WHICH_PYTEST"), str(self.declared / "pytest"))
        path = self.entry_field(result, "PATH").split(os.pathsep)
        self.assertIn(str(self.bin), path)
        self.assertLess(
            path.index(str(self.declared)),
            path.index(str(self.bin)),
            "the account's tool directory must not come before a declared package",
        )

    def test_entry_does_not_require_the_gate_tools(self) -> None:
        # The analyzers are the gate's inputs, not entry's. An account that
        # has not built them can still resolve the pinned compiler and run a
        # peer, so entry must open.
        for tool in self.tools:
            if tool != "zig-gate":
                (self.bin / tool).unlink()
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.entry_field(result, "ZIG"), str(self.real_zig))

    # -- the toolchain store --------------------------------------------

    def test_a_shared_store_is_linked_when_this_account_has_one(self) -> None:
        store = self.make_store("home-tmp2")
        self.stores = [self.store / "never-created", store]
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.toolchain_p().resolve(), store.resolve())

    def test_the_first_present_store_wins(self) -> None:
        first = self.make_store("home-tmp2")
        second = self.make_store("home-tmp")
        self.stores = [first, second]
        self.run_entry()
        self.assertEqual(self.toolchain_p().resolve(), first.resolve())

    def test_a_dangling_store_link_stops_entry_and_is_left_alone(self) -> None:
        # The link the hard-coded target used to leave behind on any other
        # host. Entry must not unlink it: it did not create it, and a removal
        # it performed on its own would be a deletion nobody inspected.
        p = self.toolchain_p()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.symlink_to(self.tmp / "gone")
        result = self.run_entry()
        self.assertEqual(result.returncode, 1)
        # The decision is the refusal and the link surviving it; what the
        # refusal says about it is not this test's subject.
        self.assertTrue(p.is_symlink(), "entry removed a link it did not create")
        self.assertFalse(p.exists())

    def test_an_existing_link_is_not_repointed(self) -> None:
        first = self.make_store("home-tmp2")
        second = self.make_store("home-tmp")
        p = self.toolchain_p()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.symlink_to(first)
        self.stores = [second, first]
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(p.resolve(), first.resolve())

    def test_a_store_that_is_not_a_directory_is_skipped(self) -> None:
        absent = self.store / "never-created"
        empty = self.tmp / "not-a-store"
        empty.write_text("", encoding="utf-8")
        real = self.make_store("home-tmp2")
        self.stores = [absent, empty, real]
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.toolchain_p().resolve(), real.resolve())

    def test_a_real_p_directory_is_left_alone(self) -> None:
        p = self.toolchain_p()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.mkdir()
        (p / "unpacked").write_text("", encoding="utf-8")
        self.stores = [self.make_store("home-tmp2")]
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(p.is_symlink())
        self.assertTrue((p / "unpacked").exists())


class GateFixtureCase(unittest.TestCase):
    """The gate's fixture directory: one run's, and removable as that one run's.

    The gate used to delete a fixed `$TMPDIR/gate-analysis` before every run
    and hand pytest that same path as its `--basetemp`. A name is not a
    claim: any other process on that shared mount can fill the directory in
    first, and `rm -rf` on a name removes whatever is there at the moment it
    runs rather than what this run put there.

    The removal itself is `tools/safe-rm-dir.sh`, run from this repository and
    not restated here, so these cases run the gate's own text with the real
    helper beside it and stub `zig`, `pytest` and `zig-gate`. The refusal case
    is the one that matters: the gate has to leave the fixtures in place and
    fail, not delete them unchecked.

    What the helper answers is a property of the host rather than of the gate:
    it refuses a tree it cannot establish is unreferenced, and on a node where
    this account's own processes cannot be read through /proc, or where the
    account has no passwd entry to resolve its scratch volume from, it refuses
    every directory including a good one. The cases that need an accepted one
    ask about a 0700 directory of their own first and skip with the helper's own
    reason, rather than passing on a refusal they did not arrange.
    """

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="devenv-gate-fixture-"))
        self.host_tools = private_tools(self.tmp, also=REMOVER_TOOLS)
        self.bash = str(self.host_tools / "bash")
        self.addCleanup(self.drop_scratch)

        self.stubs = self.tmp / "stubs"
        self.project = self.tmp / "project"
        self.scratch = self.tmp / "scratch"
        for directory in (self.stubs, self.project, self.scratch):
            directory.mkdir()
        (self.project / "build.zig.zon").write_text(
            '    .minimum_zig_version = "0.16.0",\n', encoding="utf-8"
        )
        # The gate calls the helper as "$(pwd)/tools/safe-rm-dir.sh".
        (self.project / "tools").mkdir()
        shutil.copy2(REPO / "tools" / "safe-rm-dir.sh", self.project / "tools" / "safe-rm-dir.sh")

        self.real_zig = self.tmp / "toolchain" / "zig"
        self.real_zig.parent.mkdir()
        self.real_zig.write_text(f"#!{self.bash}\nexit 0\n", encoding="utf-8")
        self.real_zig.chmod(0o755)

        self.env_file = self.tmp / "zig-env.txt"
        self.env_file.write_text(
            f'.{{\n    .zig_exe = "{self.real_zig}",\n}}\n', encoding="utf-8"
        )
        # Records the `--basetemp` pytest was handed, so a case can read back
        # the directory the gate chose rather than inferring it afterwards.
        self.record = self.tmp / "pytest-basetemp"
        self.pytest_extra = ""
        self._stub("zig", stub_zig(self.bash))
        # `zig-gate` is the last thing the gate runs, so this stub is executed
        # rather than looked up, and starts the resolved bash for the reason the
        # compiler stub does.
        self._stub("zig-gate", f"#!{self.bash}\nexit 0\n")
        # The gate names any of these it cannot find and stops, so every case
        # that is not about a missing one has to provide them all.
        for tool in ("ziglint", "zlint", "zbc", "zwanzig", "cross-test"):
            self._stub(tool, f"#!{self.bash}\nexit 0\n")

    def drop_scratch(self) -> None:
        """Remove this case's world with the repository's own remover.

        House rules apply to a test's own fixtures too: nothing here is
        deleted by name either. `safe-rm-dir.sh` checks ownership, volume,
        containment and live references before it removes anything, and a
        refusal leaves the directory and says where it is.
        """
        result = subprocess.run(
            [str(HELPER), str(self.tmp)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            print(
                f"safe-rm-dir left {self.tmp} in place: {result.stderr.strip()}",
                file=sys.stderr,
            )

    def _write_pytest_stub(self) -> None:
        """Written per run, so a case can shape what pytest leaves behind."""
        self._stub(
            "pytest",
            f"#!{self.bash}\n"
            'basetemp=""\n'
            "while [ $# -gt 0 ]; do\n"
            '    if [ "$1" = "--basetemp" ]; then basetemp="$2"; fi\n'
            "    shift\n"
            "done\n"
            f'printf "%s\\n" "$basetemp" >> "{self.record}"\n'
            'mkdir -p "$basetemp"\n'
            f"{self.pytest_extra}"
            "exit 0\n",
        )

    def _stub(self, name: str, text: str) -> None:
        path = self.stubs / name
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)

    def gate_env(self) -> dict[str, str]:
        """What the gate is run with: its own stubs, then the commands they run."""
        env = dict(os.environ)
        env.pop("ZIG", None)
        env.update(
            {
                "PATH": os.pathsep.join([str(self.stubs), str(self.host_tools)]),
                "TMPDIR": str(self.scratch),
                "FAKE_VERSION": "0.16.0",
                "FAKE_VERSION_RC": "0",
                "FAKE_ENV_FILE": str(self.env_file),
            }
        )
        return env

    def run_gate(self) -> subprocess.CompletedProcess[str]:
        self._write_pytest_stub()
        return subprocess.run(
            [self.bash, "-c", render_script(GATE_MARKER, {})],
            env=self.gate_env(),
            cwd=self.project,
            capture_output=True,
            text=True,
            check=False,
        )


    def test_the_gate_names_a_missing_tool(self) -> None:
        # Naming the missing tool is the requirement; the sentence around it
        # is not, so this asserts the names and nothing about their layout.
        (self.stubs / "zbc").unlink()
        result = self.run_gate()
        self.assertEqual(result.returncode, 1)
        self.assertIn("zbc", result.stderr)
        for tool in ("ziglint", "zlint", "zwanzig", "cross-test"):
            self.assertNotIn(tool, result.stderr)

    def test_the_gate_names_every_tool_it_cannot_find(self) -> None:
        # Every host tool except the compiler, so the naming is all the gate
        # has left to report. `zig` stays: the version cross-check runs first
        # and needs it, so this is about the gate's own tools, not about a
        # directory that cannot run anything at all.
        for tool in os.listdir(self.stubs):
            if tool != "zig":
                (self.stubs / tool).unlink()
        result = self.run_gate()
        self.assertEqual(result.returncode, 1)
        for tool in ("zig-gate", "ziglint", "zlint", "zbc", "zwanzig", "cross-test"):
            self.assertIn(tool, result.stderr)
        self.assertNotIn("pytest", result.stderr)

    def basetemps(self) -> list[Path]:
        if not self.record.exists():
            return []
        return [
            Path(line)
            for line in self.record.read_text(encoding="utf-8").split()
            if line
        ]

    def test_the_fixture_directory_is_private_to_the_run(self) -> None:
        # Private: pytest got a directory of its own under the run's approved
        # root. That the run then succeeded is the next case's subject, because
        # whether this host's remover accepts the directory is not this one's.
        self.run_gate()
        (used,) = self.basetemps()
        self.assertEqual(used.parent, self.scratch)

    def test_the_fixture_directory_is_removed(self) -> None:
        # Removed: it did not outlive the run. The decision that removes it is
        # the remover's, so this is the case that needs one it accepts.
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        (used,) = self.basetemps()
        self.assertFalse(used.exists(), "the run's own fixture directory outlived it")

    def test_two_runs_do_not_share_one_directory(self) -> None:
        # The two names are the subject. The verdict this host's remover gave
        # either run is not, so both are read back rather than asserted on.
        self.run_gate()
        self.run_gate()
        first, second = self.basetemps()
        self.assertNotEqual(first, second)

    def test_a_directory_of_the_old_fixed_name_is_not_deleted(self) -> None:
        # What the previous script did: `rm -rf "$TMPDIR/gate-analysis"`.
        bystander = self.scratch / "gate-analysis"
        bystander.mkdir()
        (bystander / "not-ours").write_text("", encoding="utf-8")
        # The bystander is the subject; the verdict this host's remover returned
        # is not, so nothing here asks for an accepted one.
        self.run_gate()
        self.assertTrue((bystander / "not-ours").exists())
        (used,) = self.basetemps()
        self.assertNotEqual(used, bystander)

    def test_a_refused_cleanup_leaves_the_fixtures_and_fails_the_gate(self) -> None:
        # A tree the helper will not touch: something inside is not a plain
        # file or directory, so a recursive delete would remove a node rather
        # than what it stands for. (A symlink would not do: `rm` unlinks one
        # without following it, and pytest plants `*current` links of its own.)
        # The gate has to leave the fixtures where they are and say so. The
        # refusal this case arranges has to be the one the helper reports: on a
        # host that refuses every removal, any refusal would pass here.
        self.pytest_extra = 'mkfifo "$basetemp/pipe"\n'
        result = self.run_gate()
        self.assertEqual(result.returncode, 1)
        (used,) = self.basetemps()
        self.assertTrue(used.is_dir(), "a refused cleanup removed the fixtures anyway")
        # The path has to reach the operator: a refusal nobody can locate is a
        # refusal nobody acts on. The sentence around it is not asserted.
        self.assertIn(str(used), result.stderr)


if __name__ == "__main__":
    unittest.main()