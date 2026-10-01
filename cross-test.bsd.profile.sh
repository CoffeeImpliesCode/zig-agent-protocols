# Complete runtime coverage in isolated FreeBSD, NetBSD and OpenBSD guests.
# Enter `devenv --profile bsd-cross shell` before using this artifact profile.
# cross-test's host policy may choose another cache. Keep this project's
# toolchain store selected before the anyzig shim resolves the compiler.
export ZIG_GLOBAL_CACHE_DIR="${CROSS_GUEST_ZIG_GLOBAL_CACHE_DIR:?enter devenv --profile bsd-cross shell}"
CROSS_MATRIX=(
  'x86_64-freebsd|python3'
  'aarch64-freebsd|python3'
  'riscv64-freebsd|python3'
  'arm-freebsd|python3'
  'powerpc64-freebsd|python3'
  'powerpc64le-freebsd|python3'
  'x86_64-netbsd|python3'
  'aarch64-netbsd|python3'
  'aarch64_be-netbsd|python3'
  'arm-netbsd|python3'
  'armeb-netbsd|python3'
  'powerpc-netbsd|python3'
  'x86-netbsd|python3'
  'mips-netbsd|python3'
  'mipsel-netbsd|python3'
  'x86_64-openbsd|python3'
  'x86-openbsd|python3'
  'aarch64-openbsd|python3'
  'arm-openbsd|python3'
  'riscv64-openbsd|python3'
  'powerpc-openbsd|python3'
  'powerpc64-openbsd|python3'
)
CROSS_JOBS=1
CROSS_BUILD_JOBS=2
CROSS_TIMEOUT=7200
CROSS_BUILD_TIMEOUT=3600
CROSS_REQUIRE_RUNNERS=1
CROSS_GUEST_SCRIPT="$(dirname -- "${BASH_SOURCE[0]}")/tools/cross_guest.py"

cross_artifact() {
  printf '%s/%s.iso\n' "$CROSS_PREFIX" "$1"
}

cross_build_command() {
  CROSS_COMMAND=("${CROSS_GUEST_PYTHON:?enter devenv --profile bsd-cross shell}" "$CROSS_GUEST_SCRIPT" build
    --zig "${ZIG_COMMAND[0]}" --prefix "$CROSS_PREFIX" --cache "$CROSS_CACHE_DIR"
    --jobs "$CROSS_BUILD_JOBS" "$1" -- "${CROSS_BUILD_ARGS[@]}")
}

cross_run_command() {
  CROSS_COMMAND=("${CROSS_GUEST_PYTHON:?enter devenv --profile bsd-cross shell}" "$CROSS_GUEST_SCRIPT" run "$1" "$2")
}

cross_count_tests() {
  "${CROSS_GUEST_PYTHON:?enter devenv --profile bsd-cross shell}" "$CROSS_GUEST_SCRIPT" count "$1"
}
