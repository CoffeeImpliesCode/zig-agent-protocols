{ pkgs, lib, ... }:

# The interface library has no system library dependencies, so the only
# development input is the house gate. `packages` stays free of `zig`:
# `zig` on this host is the anyzig shim, which resolves the toolchain by
# reading `.minimum_zig_version` from build.zig.zon. A nixpkgs `zig` here
# would shadow the shim and build with whatever version nixpkgs ships, which
# the manifest does not pin.
let
  packages = [ ];

  # Zig flocks every global-cache manifest. A build that dies holding one of
  # its manifest locks wedges every later build that wants the same cache, so
  # each project gets its own root under the node-local scratch disk.
  #
  # The anyzig shim resolves its toolchain through this same variable, at
  # `<root>/p/<hash>`. A root without `p` makes the shim re-fetch the tarball
  # from ziglang.org, fail extraction, and exit 1 in silence, so `p` is a
  # symlink to the one shared toolchain store: build caches stay per-project,
  # downloaded toolchains stay shared.
  zigCache = "/tmp/zig-caches/zig-agent-proto";
in
{
  inherit packages;

  env = {
    # The shim stages a download in its appdata directory before unpacking it,
    # and appdata is the one path the shim reads from no variable a project can
    # set through zig. Left at the default it lands on $HOME/.local/share, which
    # here is an NFS export, and the staged archive does not survive the round
    # trip: extraction aborts with "illegal file type 'unknown'" and the shim
    # exits 1 in silence, so every documented command fails for a reason no
    # message names. Node-local scratch, the same disk the cache root uses.
    XDG_DATA_HOME = "/tmp/xdg-data";
    ZIG_GLOBAL_CACHE_DIR = zigCache;
  };

  # The shim exits 1 with no output when it cannot resolve a toolchain, so a
  # broken pin looks like a mysterious silent build failure. Report the
  # version on entry instead. Creating the root first keeps that report fast
  # on a node whose scratch was wiped, and the `p` symlink keeps the shim from
  # rebuilding the toolchain from the hashstore on every entry.
  enterShell = ''
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    [ -e "$ZIG_GLOBAL_CACHE_DIR/p" ] || ln -s /tmp/zig-global-cache/p "$ZIG_GLOBAL_CACHE_DIR/p"
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