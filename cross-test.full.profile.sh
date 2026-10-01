# Audit every row in cross-test's published Zig support table.
# Compilation, execution and test counts remain separate in its JSON summary.
# Known runtime failures are not suppressed; this audit may correctly exit 1.
unset CROSS_MATRIX
CROSS_BUILD_STEP=test
CROSS_JOBS=4
CROSS_BUILD_JOBS=2
CROSS_TIMEOUT=900
CROSS_BUILD_TIMEOUT=3600
CROSS_REQUIRE_RUNNERS=0
