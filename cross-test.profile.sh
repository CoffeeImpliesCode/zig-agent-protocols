# Executed coverage for the house gate, not a compile-only target count.
# Every row passed the complete thirteen-binary test step under Zig 0.16.0.
# The declared Nix environment supplies QEMU; missing runners are failures.
# The full published support table remains in cross-test.full.profile.sh.
# That audit records unavailable runners and failed Wine execution explicitly.
CROSS_MATRIX=(
  'x86_64-linux|auto'
  'aarch64-linux|auto'
  'aarch64_be-linux|auto'
  'arm-linux|auto'
  'armeb-linux|auto'
  'hexagon-linux|auto'
  'loongarch64-linux|auto'
  'mips-linux|auto'
  'mipsel-linux|auto'
  'mips64-linux|auto'
  'mips64el-linux|auto'
  'powerpc-linux|auto'
  'powerpc64-linux|auto'
  'powerpc64le-linux|auto'
  'riscv32-linux|auto'
  'riscv64-linux|auto'
  's390x-linux|auto'
  'thumb-linux|auto'
  'thumbeb-linux|auto'
  'x86-linux|auto'
)
CROSS_BUILD_STEP=test
CROSS_JOBS=4
CROSS_BUILD_JOBS=2
CROSS_REQUIRE_RUNNERS=1

# Per-test and whole-target deadlines; neither is an outer matrix deadline.
CROSS_TIMEOUT=900
CROSS_BUILD_TIMEOUT=3600

# CROSS_PREFIX stays caller-owned: the gate supplies approved project scratch.
# --targets selects a subset; it never adds rows to this profile.