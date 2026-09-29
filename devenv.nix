{ pkgs, lib, ... }:

# The interface library has no system library dependencies, so the only
# development input is the house gate. `packages` stays free of `zig`:
# `zig` on this host is the anyzig shim, which resolves the toolchain by
# reading `.minimum_zig_version` from build.zig.zon. A nixpkgs `zig` here
# would shadow the shim and build with whatever version nixpkgs ships, which
# the manifest does not pin.
let
  packages = [ ];
in
{
  inherit packages;

  env = {
    # Zig flocks every global-cache manifest, so a build that dies holding one
    # of those locks wedges every later build wanting the same global cache.
    # A project-local global cache keeps this project independent of that;
    # the cost is one extra compiler_rt build.
    ZIG_GLOBAL_CACHE_DIR = ".zig-global-cache";
  };

  # The shim exits 1 with no output when it cannot resolve a toolchain, so a
  # broken pin looks like a mysterious silent build failure. Report the
  # version on entry instead.
  enterShell = ''
    echo "zig $(zig version 2>/dev/null || echo '<unresolved: check .minimum_zig_version>')"
  '';

  # The house gate: fmt, build, test, ast-check, ziglint, zlint, zbc. The
  # version cross-check runs first because every later step is meaningless
  # against a toolchain the manifest does not describe.
  scripts.gate.exec = ''
    set -eu
    version="$(zig version)"
    pin="$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)"
    test "$version" = "$pin" || {
      echo "zig $version does not match .minimum_zig_version $pin" >&2
      exit 1
    }
    zig-gate
  '';
}
