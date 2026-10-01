{ pkgs, lib, ... }:

# The interface library has no system library dependencies. Development inputs
# are the house gate, cross-target runners and the two interoperability SDKs.
# `packages` stays free of `zig`: `zig` on this host is the anyzig shim, which
# resolves the toolchain by reading `.minimum_zig_version` from build.zig.zon.
# A nixpkgs `zig` here would shadow the shim and build with whatever version
# nixpkgs ships, which the manifest does not pin.
#
# Python supplies development SDK peers and analyzer-policy tests only.
# Neither is a library dependency: no Zig file imports Python, and the peers
# are separate processes speaking real wire bytes. SDK versions, hashes and
# the API facts each peer uses are recorded in
# `test/interop/sdk-pins.json`, and both peers read that file and refuse to run
# against an environment that does not match it.
let
  inherit (pkgs) python3;
  # Nix already provides `python3Packages`; the override is built from it so
  # every transitive dependency is a pinned nixpkgs package rather than
  # something a resolver would fetch at shell entry.
  inherit (pkgs.python3.pkgs)
    buildPythonPackage
    google-api-core
    googleapis-common-protos
    hatchling
    httpx
    json-rpc
    packaging
    protobuf
    pydantic
    sse-starlette
    starlette
    uvicorn
    uv-dynamic-versioning
    pytest
    ;

  # a2a-sdk 1.2.1, built from the exact PyPI release rather than from
  # `python3Packages.a2a-sdk`, because the nixpkgs revision devenv.lock pins
  # carries 0.3.26 and the 0.3 line speaks protocol 0.3.0: its JSON-RPC methods
  # are `message/send` and `tasks/get`, where 1.0 uses `SendMessage` and
  # `GetTask`. No override of the 0.3 package would produce 1.0.
  #
  # The `hash` is the SHA-256 of the sdist as fetched, which is what `fetchurl`
  # checks, so it is a flat digest and not a NAR hash. It is the same digest
  # recorded as `sha256_sri` under `sdks["a2a-sdk"].source_bytes` in
  # `test/interop/sdk-pins.json`, and the peer script re-derives it.
  a2aSdk = buildPythonPackage {
    pname = "a2a-sdk";
    version = "1.2.1";
    pyproject = true;

    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/32/13/b00cf93d0cb46010d2ea0e3132c33212bd27e44f775c98ee84ca1ba6382f/a2a_sdk-1.2.1.tar.gz";
      hash = "sha256-BSMa3p4FmJo0RBRHREC/KrBJUDEt7VUZz3ef6h+5GNY=";
    };

    build-system = [ hatchling uv-dynamic-versioning ];

    # The sdist is a tagged release, not a checkout: there is no `.git` in it
    # for the `uv-dynamic-versioning` hatch plugin to read a version from. The
    # plugin's own documentation (docs/tips.md, "Nix (and Other Sandboxed
    # Build Environments)") names a pinned `fallback-version` as the way to
    # build a released sdist without the repository, which is exactly this
    # case. `--replace-fail` is what keeps the claim honest: a pyproject that
    # does not carry the line this expects fails the build instead of quietly
    # building a mis-versioned package.
    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail 'style = "pep440"' 'style = "pep440"
      fallback-version = "1.2.1"'
    '';

    # pyproject `[project].dependencies`, plus the `http-server` extra because
    # the peer serves the JSON-RPC endpoint and the Agent Card from Starlette
    # routes. `culsans` is absent on purpose: it is required only below Python
    # 3.13, and pkgs.python3 at this revision is 3.14.
    dependencies = [
      google-api-core
      googleapis-common-protos
      httpx
      json-rpc
      packaging
      protobuf
      pydantic
      sse-starlette
      starlette
      uvicorn
    ];

    # Importing the package is the check that matters here; the upstream test
    # suite needs pytest and a network, and a peer does not carry either.
    pythonImportsCheck = [ "a2a" ];
    doCheck = false;

    meta = {
      description = "Python SDK for the Agent2Agent (A2A) Protocol, pinned to the 1.0 line";
      homepage = "https://a2a-protocol.org/";
      license = lib.licenses.asl20;
    };
  };

  # One interpreter carrying both SDKs, so a peer process spawned by another
  # peer process resolves the same `mcp` and the same `a2a` as its parent. The
  # MCP SDK is the pinned nixpkgs package: 1.29.0 is the newest revision whose
  # own LATEST_PROTOCOL_VERSION is the 2025-11-25 this repository pins, and it
  # is already a fixed-output fetch of tag v1.29.0.
  interopPython = python3.withPackages (ps: [
    ps.mcp
    a2aSdk
  ]);

  # The gate analysis tests are development tooling as well, and `gate` runs
  # them before the house gate because they decide what the gate is allowed to
  # waive. They get their own interpreter rather than an import in the peer one:
  # the pinned SDKs are the peers' business and stay exactly as
  # `test/interop/sdk-pins.json` records them, and a test-only package has no
  # business in the environment that drives an exchange.
  gateTestPython = python3.withPackages (ps: [ pytest ]);

  # User-mode QEMU covers the published Linux architectures without installing
  # system emulators. Wine's WoW64 build runs both x86 and x86_64 PE executables
  # without requiring a 32-bit host environment. Both are development processes,
  # never dependencies of the interface library.
  crossRunners = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    (pkgs.qemu.override { userOnly = true; })
    pkgs.wineWow64Packages.minimal
  ];

  packages = [ interopPython gateTestPython ] ++ crossRunners;

  # One scratch root, one policy. `.envrc` bootstraps the same choice into
  # the shell before this file is evaluated and README.md states it; the
  # three have to agree because the value is derived in each of them rather
  # than configured in one and copied into the others.
  #
  # The candidates are ordered by what a build on them costs. The first two
  # are node-local physical mounts; the last two are approved scratch but
  # NFS, where a build is slow and a cache dies on renameat2. /tmp and
  # /var/tmp are not candidates at all: they are small volumes shared with
  # every other process on the node, and the interoperability peers refuse
  # them by name, so a run that defaulted there fails with a message that
  # mentions neither the mount nor this policy.
  #
  # The account name is part of each path because these are per-account
  # directories on mounts every account on the node can read. It is read
  # from the caller's environment rather than committed, so this file
  # publishes no account name and `devenv shell` resolves for whichever
  # account evaluates it.
  scratchUser = builtins.getEnv "USER";
  scratchCandidates =
    if scratchUser == "" then
      throw "zig-agent-proto: USER is unset, so this environment cannot name its per-account scratch directory; export USER before evaluating."
    else
      builtins.map (mount: "${mount}/${scratchUser}/zig-agent-proto") [
        "/home/tmp2"
        "/home/tmp"
        "/vol/tmp2"
        "/vol/tmp"
      ];

  scratchRoot =
    let present = builtins.filter builtins.pathExists scratchCandidates;
    in
    if present == [ ] then
      throw "zig-agent-proto: no approved scratch mount is present, so this environment has nowhere to put its caches, its temporary directory or an interoperability capture; expected one of ${builtins.concatStringsSep ", " scratchCandidates}. See README.md."
    else
      builtins.head present;

  # Every path this environment writes through, named once. The anyzig shim
  # downloads the pinned toolchain into `zigGlobal/p/<hash>` itself, so a
  # node that has never run this project needs no toolchain store prepared
  # for it. Nothing symlinks one cache's store into another: the shared
  # store this file used to name is gone, and a symlink to a missing target
  # makes the shim exit 1 without a word.
  scratch = {
    tmp = "${scratchRoot}/tmp";
    cache = "${scratchRoot}/cache";
    data = "${scratchRoot}/xdg-data";
    zigGlobal = "${scratchRoot}/zig-cache";
    zigLocal = "${scratchRoot}/build-cache";
  };
in
{
  inherit packages;
  # WASI execution is an audit, not a promise that Unix-socket tests can pass.
  profiles.cross-audit.module = { pkgs, ... }: {
    packages = [ pkgs.wasmtime ];
  };


  # Full-system guests are opt-in: ordinary codec development needs neither
  # disk images nor firmware. The release checksums pin the official CI images.
  profiles.bsd-cross.module = { pkgs, ... }:
    let
      guestPython = pkgs.python3.withPackages (ps: [
        (ps.buildPythonPackage {
          pname = "anita";
          version = "2.18";
          pyproject = true;
          src = pkgs.fetchurl {
            url = "https://www.gson.org/netbsd/anita/download/anita-2.18.tar.gz";
            sha512 = "c9d533c69d8cac1097795d792fb3bdb2069817b12db4d74c0ec510902e1b32fe581495db60b170de5aac9a8667b3cdf5550ef8361fac6a867c2ffc7d698f9b79";
          };
          build-system = [ ps.setuptools ];
          dependencies = [ ps.pexpect ];
          pythonImportsCheck = [ "anita" ];
        })
      ]);
      # The portable NetBSD/MirBSD utility supports mtree device nodes and
      # explicit FFS byte order; OpenBSD's older makefs supports neither.
      # This optional runner dependency is a pinned Linux host executable,
      # not a library dependency or an unsupported-platform override.
      netbsdMakefs = pkgs.stdenvNoCC.mkDerivation {
        pname = "makefs-netbsd";
        version = "20190105-3";
        src = pkgs.fetchurl {
          url = "https://deb.debian.org/debian/pool/main/m/makefs/makefs_20190105-3_amd64.deb";
          sha256 = "1dd366157906a6ffc0c55fe68d5ad873a3a6d7c95b2d9fce529684fd65149e69";
        };
        nativeBuildInputs = [ pkgs.dpkg pkgs.autoPatchelfHook ];
        buildInputs = [ pkgs.glibc ];
        unpackPhase = ''dpkg-deb -x "$src" .'';
        installPhase = ''
          install -Dm755 usr/sbin/makefs "$out/bin/makefs"
          install -Dm644 usr/share/man/man8/makefs.8.gz "$out/share/man/man8/makefs.8.gz"
        '';
        meta.platforms = [ "x86_64-linux" ];
      };
    in
    {
    packages = [ pkgs.qemu pkgs.xorriso pkgs.cdrtools netbsdMakefs pkgs.mtools pkgs.e2fsprogs pkgs.xz guestPython ];
    env = {
      CROSS_GUEST_PYTHON = "${guestPython}/bin/python3";
      CROSS_GUEST_CACHE = "${scratch.cache}/cross-guests";
      CROSS_GUEST_ZIG_GLOBAL_CACHE_DIR = scratch.zigGlobal;
      CROSS_QEMU_FIRMWARE = "${pkgs.qemu}/share/qemu";
      CROSS_NETBSD_MAKEFS = "${netbsdMakefs}/bin/makefs";
      CROSS_UBOOT_ARM = "${pkgs.pkgsCross.armv7l-hf-multiplatform.ubootQemuArm}/u-boot.bin";
      CROSS_UBOOT_RISCV64 = "${pkgs.pkgsCross.riscv64.ubootQemuRiscv64Smode}/u-boot.bin";
      CROSS_PMON_2E = "${pkgs.fetchurl {
        url = "https://github.com/loongson-community/pmon/releases/download/20210112/pmon-2edev.bin";
        sha256 = "81576c8581e6765a73a8b5070dfb3758bcc3b0737461d481ec97ab5b67751771";
      }}";
      CROSS_FREEBSD_AMD64_XZ = "${pkgs.fetchurl {
        url = "https://download.FreeBSD.org/releases/CI-IMAGES/15.1-RELEASE/amd64/Latest/FreeBSD-15.1-RELEASE-amd64-BASIC-CI-ufs.raw.xz";
        sha256 = "908e735f18ba192eaf48c2703b549225c9b96e74e3784bd9278c7120b4139962";
      }}";
      CROSS_FREEBSD_ARM64_XZ = "${pkgs.fetchurl {
        url = "https://download.FreeBSD.org/releases/CI-IMAGES/15.1-RELEASE/aarch64/Latest/FreeBSD-15.1-RELEASE-arm64-aarch64-BASIC-CI-ufs.raw.xz";
        sha256 = "69f5009497ea4e550910f4f71d13fd56c468e6a5df492c8117df7116c7118820";
      }}";
      CROSS_FREEBSD_RISCV64_XZ = "${pkgs.fetchurl {
        url = "https://download.FreeBSD.org/releases/VM-IMAGES/15.1-RELEASE/riscv64/Latest/FreeBSD-15.1-RELEASE-riscv-riscv64-ufs.raw.xz";
        sha256 = "46adb88fa8614af88807424d80cc24f05d8faf5e5f04c76532eeef2cb5da8cb1";
      }}";
      CROSS_FREEBSD_ARMV7_XZ = "${pkgs.fetchurl {
        url = "https://download.FreeBSD.org/releases/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-arm-armv7-GENERICSD.img.xz";
        sha256 = "d568d7324825af9072405b11b7d0f4ba892d10ca05687fe4fd65e328e72cf7b8";
      }}";
      CROSS_FREEBSD_POWERPC64_ISO_XZ = "${pkgs.fetchurl {
        url = "https://download.FreeBSD.org/releases/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-powerpc-powerpc64-bootonly.iso.xz";
        sha256 = "f35c65d120542f2aa849b8fdf3c930e9c76d29d389c6509e245ef3a2b25155ad";
      }}";
      CROSS_FREEBSD_POWERPC64LE_ISO_XZ = "${pkgs.fetchurl {
        url = "https://download.FreeBSD.org/releases/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-powerpc-powerpc64le-bootonly.iso.xz";
        sha256 = "d80a4b1d99d3f64d2852055831fc9bba5b26d60e64bcbcaa50a6afd62914022a";
      }}";
      CROSS_NETBSD_AMD64_LIVE_GZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/images/11.0/NetBSD-11.0-amd64-live.img.gz";
        sha512 = "ad0bc2786b2cd8b7c140ae108fd780064465fe06337a3a2c3f3b694ed3a1e042b3d401c9a682be02c081f3eb3efeba1246cfd6a8803149468ebfbd9c0e7c77e8";
      }}";
      CROSS_NETBSD_AARCH64_RAW = "${pkgs.fetchurl {
        name = "NetBSD-11.0-arm64mbr.img";
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-aarch64/binary/gzimg/arm64mbr.img.gz";
        sha512 = "ce7f952173412779ed3d990c9de69e36f8440e2a6849cace8c6cd3894c894b1a48c138b5faf0d500b263f6e7ef3b962dbe52ba7f350575b3acef64fc3fd827f7";
        # The release manifest hashes the raw image, not its gzip container.
        postFetch = ''
          ${pkgs.gzip}/bin/gzip -dc "$out" > image.raw
          mv image.raw "$out"
        '';
      }}";
      CROSS_NETBSD_AARCH64_KERNEL_GZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-aarch64/binary/kernel/netbsd-GENERIC64.img.gz";
        sha512 = "62a120ee688902e632f5e536e41aa9e6e74a55759a91d9c5bd3b2e12092b7d3bdaf00aa98c67b87466a04b8c0fff19b9d804814cd1efb0b665b6a82d39c0e179";
      }}";
      CROSS_NETBSD_I386_BOOT_COM_ISO = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/i386/installation/cdrom/boot-com.iso";
        sha512 = "1298f68a8d52d8081a5a4d463b10daee3ab94c78f6d2f5ac2793fc5cbcd92b9369d032820fe6736d7018e7c43317000916d61d326a7cb0958d53c3754b4c502a";
      }}";
      CROSS_NETBSD_I386_BASE_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/i386/binary/sets/base.tgz";
        sha512 = "ee1c4be9bb749df31a8d286e697a4506b3b22782a642c78ceda7c3b110cd562f28ce68cf81204cc3a246dae109273edd3f401ccffdff7a97aa09ef1e08189cb9";
      }}";
      CROSS_NETBSD_I386_ETC_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/i386/binary/sets/etc.tgz";
        sha512 = "359b0cb87c281305ec614b35005748b457584ef56f60304da68421b40d5c274e91b8384142bb7ac036dc75ab6afb109135c02cdde50662db230d4def29eafe2d";
      }}";
      CROSS_NETBSD_I386_COMP_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/i386/binary/sets/comp.tgz";
        sha512 = "942f4d3a2b2f9582acab73a03ab67454ac952f1b0e6d390b369d68ac7d5ba5b6e732f67674dde42c308a782cdbf22502c00e5ad698aa286c3c398fbd4e31e93f";
      }}";
      CROSS_NETBSD_I386_MISC_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/i386/binary/sets/misc.tgz";
        sha512 = "f68143c88d1d88b292f42df2071e85b6cefd26f874b3a1df6e7550ea894af8819dc87ce2a4e88aff15807e1777f774700c2f15e5ac02fd879f8c4974be2ebac7";
      }}";
      CROSS_NETBSD_I386_MODULES_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/i386/binary/sets/modules.tgz";
        sha512 = "73fdec04211e6f89b0c60b923801c0347fce1d08ab41c859ed64700f5f0fc568aa12743beaeb05aaff1414a8f48c416190ee1cf4d43079b214eb137b58343dc7";
      }}";
      CROSS_NETBSD_I386_KERN_GENERIC_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/i386/binary/sets/kern-GENERIC.tgz";
        sha512 = "123d37ee796e19d53f980955154dfb54f74996bf6b3c9192875e82a609430a5da78301f42fa825a0223d1c9121b9cee68ac19ad78cdeb53cf5155e6375914a1c";
      }}";
      CROSS_OPENBSD_AMD64_ISO = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/install78.iso";
        sha256 = "a228d0a1ef558b4d9ec84c698f0d3ffd13cd38c64149487cba0f1ad873be07b2";
      }}";
      CROSS_OPENBSD_I386_ISO = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/i386/install78.iso";
        sha256 = "c1ec4c3965dac8bb0fbf605d008bf33efc7f1785f74bf7221ef2c78a4781cd16";
      }}";
      CROSS_OPENBSD_ARM64_ISO = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/arm64/install78.iso";
        sha256 = "29ce7eda86ee14a5a30776f18523b416a5572db03ee32d9a1109c446cb3949b3";
      }}";
      CROSS_OPENBSD_MACPPC_ISO = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/macppc/install78.iso";
        sha256 = "f51a7aa13d41169569a3df551ce5a508342973681bf1adf61b4fdf2575b410ab";
      }}";
      CROSS_OPENBSD_RISCV64_IMG = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/riscv64/install78.img";
        sha256 = "866742226f967bcb91be75eca48b55b7a042a5965d71ed759d84b96d3fb6ebd1";
      }}";
      CROSS_NETBSD_AARCH64EB_RAW = "${pkgs.fetchurl {
        name = "NetBSD-11.0-arm64eb.img";
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-aarch64eb/binary/gzimg/arm64mbr.img.gz";
        sha512 = "d958fd65bde1a260efb6638a10c603e61bb8e78ad125ed7b6f8505eb9ddeaf3714f77c9c0f0025f0abd875c3f59dfa1d16c8e9728b9b4a7e5c23513ac55346bf";
        postFetch = ''
          ${pkgs.gzip}/bin/gzip -dc "$out" > image.raw
          mv image.raw "$out"
        '';
      }}";
      CROSS_NETBSD_AARCH64EB_KERNEL_GZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-aarch64eb/binary/kernel/netbsd-GENERIC64.img.gz";
        sha512 = "c6a507702e59c3b680cc9c13db19a1d1e329ae1f860f9205b6786a4770fa1059d0d6dc56bf07b977804233081f3221d52fe2eae685bd92c34fc4b2be057a79eb";
      }}";
      # Anita's Versatile Express recipe consumes the board's public DTB.
      # Compile it from nixpkgs' pinned Linux source; no untracked host file.
      CROSS_NETBSD_ARMV7HF_DTB = "${pkgs.runCommand "vexpress-v2p-ca15-tc1.dtb" {
        nativeBuildInputs = [ pkgs.dtc pkgs.stdenv.cc pkgs.xz ];
      } ''
        tar -xf ${pkgs.linuxPackages.kernel.src}
        cd linux-*
        cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
          -I include -I arch/arm/boot/dts/arm \
          arch/arm/boot/dts/arm/vexpress-v2p-ca15-tc1.dts |
          dtc -I dts -O dtb -o "$out"
      ''}";
      CROSS_OPENBSD_RISCV64_SETS = "${pkgs.linkFarm "OpenBSD-7.8-riscv64-sets" [
        {
          name = "bsd";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/riscv64/bsd";
            sha256 = "3801ace808eee81bb87f080747421bcc941c7766831ce1485520069bf8399561";
          };
        }
        {
          name = "bsd.mp";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/riscv64/bsd.mp";
            sha256 = "ba0be7f3c8ca8042a92c846644a6e3e960e44cde7fcafcf7e50f5a50f4dcaee6";
          };
        }
        {
          name = "base78.tgz";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/riscv64/base78.tgz";
            sha256 = "5017b5cfdaf74b57d41ee862b27829493e70bc5098a9ae3ef210db4879f2703b";
          };
        }
        {
          name = "INSTALL.riscv64";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/riscv64/INSTALL.riscv64";
            sha256 = "02ab2422da879802c790f81b8a5a3d53401edd2dbea7ed340933cedf49f540c2";
          };
        }
      ]}";
      CROSS_NETBSD_ARMV7HF_RAW = "${pkgs.fetchurl {
        name = "NetBSD-11.0-armv7.img";
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-earmv7hf/binary/gzimg/armv7.img.gz";
        sha512 = "32f511ed7bddf2565e210c60549fd3fd3a45e6c29567c358f386c9397ba7879809f4be98f1ab5810df057912ea19040e456928244b481f91530a33158831c2a6";
        postFetch = ''
          ${pkgs.gzip}/bin/gzip -dc "$out" > image.raw
          mv image.raw "$out"
        '';
      }}";
      CROSS_NETBSD_ARMV7HF_KERNEL_GZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-earmv7hf/binary/kernel/netbsd-GENERIC.ub.gz";
        sha512 = "85f8ba3660f64669f1b67ff938dc8c401e39866f0d40cf45329d23295cd11c9f941c3ec58849d2b73a7a3178ce8c27aeafe9a9a8a5dbb25ae9868a15bba1fcd8";
      }}";
      CROSS_NETBSD_ARMV7HFEB_RAW = "${pkgs.fetchurl {
        name = "NetBSD-11.0-armv7hfeb.img";
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-earmv7hfeb/binary/gzimg/armv7.img.gz";
        sha512 = "5f9b789bac7929b1d8095ee84c9a8d361b1699675f9a8b792554778244058141c0f0e76f9352728f6eee9e2d4872d58689d152dbc5c4ea50df89595fa1046204";
        postFetch = ''
          ${pkgs.gzip}/bin/gzip -dc "$out" > image.raw
          mv image.raw "$out"
        '';
      }}";
      CROSS_NETBSD_ARMV7HFEB_KERNEL_GZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-earmv7hfeb/binary/kernel/netbsd-GENERIC.ub.gz";
        sha512 = "d3f4f98a66d8e78510024bf769ec16be3a66865dce7df90527fb7113eb2f0374e76185712b7858b7b6ccb19b0978a24d711c5211e4cbc3ea0f7b4d7752d9d622";
      }}";
      CROSS_NETBSD_MACPPC_INSTALL_KERNEL_GZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/macppc/binary/kernel/netbsd-INSTALL.gz";
        sha512 = "ead8797ec2ccd76eff79b29080919019c72ecabc482acddc2c58dcc8d1f2836563a1811bb373293747653bf53303e4c6a45263782e60c6fef567049603a70018";
      }}";
      CROSS_NETBSD_MACPPC_GENERIC_KERNEL_GZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/macppc/binary/kernel/netbsd-GENERIC.gz";
        sha512 = "045bcf9408c816519b5a1905075ce6a5f46307bfb3c592a9a9ee10616a02856148db19d38f39b13105871e3082d8a3a56e03a20a6e393768267c69ccc35df968";
      }}";
      CROSS_NETBSD_MACPPC_BASE_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/macppc/binary/sets/base.tgz";
        sha512 = "cad532a747d54aa0ba0f9af84a887450915a1b51674afccaaaa4402c36e240e07cdfc9049974cd6a0b3be251462c55d3790073e39975e359dfd3011b6699f4a0";
      }}";
      CROSS_NETBSD_MACPPC_ETC_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/macppc/binary/sets/etc.tgz";
        sha512 = "39b2be11ecf012e08bc3ed71bbfd4f8e94f710c145c3066a7eb153fd46763079cc5018bd8ba792ef42f09b963fef656cb070269bda0ac7108b1ab30f2fec4b8b";
      }}";
      CROSS_NETBSD_MACPPC_COMP_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/macppc/binary/sets/comp.tgz";
        sha512 = "2785769499da7578680348f2006c02466f60663f5124f69dd9ffad56ea0dc3dfd290122bdcd699cf5fc2ed6a374206d67a8e8d23d5c4c9dc254f69edb260653a";
      }}";
      CROSS_NETBSD_MACPPC_MISC_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/macppc/binary/sets/misc.tgz";
        sha512 = "f68143c88d1d88b292f42df2071e85b6cefd26f874b3a1df6e7550ea894af8819dc87ce2a4e88aff15807e1777f774700c2f15e5ac02fd879f8c4974be2ebac7";
      }}";
      CROSS_NETBSD_MACPPC_MODULES_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/macppc/binary/sets/modules.tgz";
        sha512 = "3a86389c351b72d473f3455ce2999df5a1672979be905c063361a90e553cba2a0c9c060a3ac6b8707535fe7b49d04d6f0e141d6c5feffffc69896627fb9509f9";
      }}";
      CROSS_NETBSD_MACPPC_KERN_GENERIC_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/macppc/binary/sets/kern-GENERIC.tgz";
        sha512 = "7a419af8bab195e4a24e458cb64e239e4ba7d28cdf9db057e78be57c36ee18b2e8656bd019e4e8784ddaeffad90b9b9837648cb600551538b04cf6c321450c89";
      }}";
      CROSS_NETBSD_MIPS_MALTA_KERNEL_GZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbmips-mipseb/binary/kernel/netbsd-MALTA.gz";
        sha512 = "526a042dfdf5b27db873c653247118596c7c7ab3ff72156ebcc3e5d7975be44441a5a52555fc4c735eee72f871055b8a3a0a92425cbb257a6883eae8f2fa8754";
      }}";
      CROSS_NETBSD_MIPS_KERN_MALTA_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbmips-mipseb/binary/sets/kern-MALTA.tgz";
        sha512 = "03f342a5daf30a03100cba4a0398c121ea3102e707f5d3fb1323dd8406071843bd5a43e83427341b0246cd52ec887a0d798b3fc7741d8d4aa84d3e4c557b8a70";
      }}";
      CROSS_NETBSD_MIPS_BASE_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbmips-mipseb/binary/sets/base.tgz";
        sha512 = "f4d5f9594cdfe69da31787e05ab5d109cb198427e5b0b222c11bdd8d4d3ac1694a39bf0823a14c671e339d0156fea02ab571f9e6a8e9db48e7c743fcbefd427e";
      }}";
      CROSS_NETBSD_MIPS_ETC_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbmips-mipseb/binary/sets/etc.tgz";
        sha512 = "13a88c04981a4eb56d0e4a51148fb7a6877f1a780be12839f519dada47fb961d487ff5fbe6f51ca10d59c1875c0f7b1e75b72fcbd33e5a323123c351c338a118";
      }}";
      CROSS_NETBSD_MIPSEL_MALTA_KERNEL_GZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbmips-mipsel/binary/kernel/netbsd-MALTA.gz";
        sha512 = "cb2e3e611992bc4cf79ba501ed9f6e9e01c4f5eeda88816c7a7bd09414f7046fdbd3e7d043cf5bf273033748dedc187583218620ff973d7134364d9d8d46a31d";
      }}";
      CROSS_NETBSD_MIPSEL_KERN_MALTA_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbmips-mipsel/binary/sets/kern-MALTA.tgz";
        sha512 = "feaf382d2c27a2ddcd8b4ffe502ee862921487976e9a33c4694fbbcd8f1282be51a69e2c8cab0b7611ef542f4ed1e5fb9c06282afce2ec147f0903a3c9a46300";
      }}";
      CROSS_NETBSD_MIPSEL_BASE_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbmips-mipsel/binary/sets/base.tgz";
        sha512 = "17a340356267f94e61725b8fa3cefd43d38923687e24d1de697913119b022bf35f24ec22ada27543f2ae07449407e9bf43425576ca688605694f04e5bb668311";
      }}";
      CROSS_NETBSD_MIPSEL_ETC_TGZ = "${pkgs.fetchurl {
        url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbmips-mipsel/binary/sets/etc.tgz";
        sha512 = "cb0bbb69eac95c1ae6724492f7f7bd735d218bb6a03a4af23dbc01caea9c6b5ecc7308fcf4014483fa48031071034a2796bb8f24d26e645b6756a29b5586603a";
      }}";
      CROSS_OPENBSD_POWERPC64_ISO = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/powerpc64/install78.iso";
        sha256 = "e78fa62503caaa212ba58d2770699b5900e0aded28e07f4eba82f56e277e0cd3";
      }}";
      CROSS_OPENBSD_MACPPC_SETS = "${pkgs.linkFarm "OpenBSD-7.8-macppc-sets" [
        {
          name = "bsd";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/macppc/bsd";
            sha256 = "bcb0cc29116b20b36ceb933263140070b6f49f0ef91bce5c838ab7112ebb56ab";
          };
        }
        {
          name = "bsd.mp";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/macppc/bsd.mp";
            sha256 = "99fb8887a1304a678aceb3629789ea57eb9e3dfd633e83f129407ee760cd865a";
          };
        }
        {
          name = "base78.tgz";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/macppc/base78.tgz";
            sha256 = "ec12fe5cae13cb8d1cdace787e627547969eaba0bb8704ff6367e1a65f0ec49d";
          };
        }
        {
          name = "INSTALL.macppc";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/macppc/INSTALL.macppc";
            sha256 = "001a43b64c5efdc906099e9c9bb58efd1b2f95af7f1fc7d48273c54855042566";
          };
        }
      ]}";
      CROSS_OPENBSD_ARMV7_IMG = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/armv7/miniroot-nitrogen-78.img";
        sha256 = "ef1eb7c7b49e3170c00610069cd16eeb1c710fd2a9c3ddab53bd42016a9dc1cc";
      }}";
      CROSS_OPENBSD_ARMV7_BOOT_EFI = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/armv7/BOOTARM.EFI";
        sha256 = "3c721d290a76546a73a4e85a9e978245b73724dc34766728a504008d6c82b549";
      }}";
      CROSS_OPENBSD_ARMV7_RD = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/armv7/bsd.rd";
        sha256 = "026e3870984838163286b2299ed382826fc4bde7d2337ae7b19700cc76e729ff";
      }}";
      CROSS_OPENBSD_ARMV7_SETS = "${pkgs.linkFarm "OpenBSD-7.8-armv7-sets" [
        {
          name = "bsd";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/armv7/bsd";
            sha256 = "fffe18a82ed4474c94ba91258483a8fe57ca13768b695ea9ccad21007b7ef185";
          };
        }
        {
          name = "base78.tgz";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/armv7/base78.tgz";
            sha256 = "d6d680d89cbd0a5d4c26c2e14ab07fa04deffa6ba1b3a762fd0b6b390a4f84e4";
          };
        }
        {
          name = "INSTALL.armv7";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/armv7/INSTALL.armv7";
            sha256 = "bc7f03c2972d43e823ba1420327c8b44d7c9a54da2212afbf53bed22fce3bb8c";
          };
        }
      ]}";
      CROSS_OPENBSD_LOONGSON_RD = "${pkgs.fetchurl {
        url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/loongson/bsd.rd";
        sha256 = "69f7a6c637083a44d66c9a6c4968b89b8a88b3a24e9cc26b2cbaa705e40747f4";
      }}";
      CROSS_OPENBSD_LOONGSON_SETS = "${pkgs.linkFarm "OpenBSD-7.8-loongson-sets" [
        {
          name = "bsd";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/loongson/bsd";
            sha256 = "fc227f3844b296112b60c76374ff1c9005988b61b45a06d08cb662da991965ec";
          };
        }
        {
          name = "base78.tgz";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/loongson/base78.tgz";
            sha256 = "c9929579387b59e54f49dc2305333a7e93d8c84c6d2fc1f7458ea59351a092c0";
          };
        }
        {
          name = "INSTALL.loongson";
          path = pkgs.fetchurl {
            url = "https://cdn.openbsd.org/pub/OpenBSD/7.8/loongson/INSTALL.loongson";
            sha256 = "6727e659af3c2f07edad7deafde6c83534360a00acb6742fe8903127baf7827a";
          };
        }
      ]}";
    };
  };

  env = {
    # One root, one answer per variable, and no second copy of a path
    # anywhere in this file. A command run from this shell writes
    # temporary files, cache entries, downloaded toolchains and interop
    # captures under `scratchRoot` and nowhere else.
    TMPDIR = scratch.tmp;
    TMP = scratch.tmp;
    TEMP = scratch.tmp;

    # The shim stages a download in its appdata directory before unpacking
    # it, and appdata is the one path the shim reads from no variable a
    # project can set through zig. Left at the default it lands on
    # $HOME/.local/share, which here is an NFS export, and the staged
    # archive does not survive the round trip: extraction aborts with
    # "illegal file type 'unknown'" and the shim exits 1 in silence, so
    # every documented command fails for a reason no message names.
    XDG_DATA_HOME = scratch.data;

    # The Zig pair is split because the two have different lifetimes. The
    # global cache also holds `p/`, the toolchains the shim downloads, so it
    # is the slow-growing one; the local cache holds objects `zig build`
    # rebuilds from the manifest, so it is the disposable one. Both are
    # named here rather than left to a default, so the directory a cache
    # lives in is a fact of this file and not of a shell it was started
    # from.
    ZIG_GLOBAL_CACHE_DIR = scratch.zigGlobal;
    ZIG_LOCAL_CACHE_DIR = scratch.zigLocal;

    XDG_CACHE_HOME = scratch.cache;
    PYTHONDONTWRITEBYTECODE = "1";

    # Wine's registry, drives and service state belong to this project's cache,
    # not to the account's shared ~/.wine directory.
    WINEPREFIX = "${scratch.cache}/wine-cross";

    # The peers read their pin file from this path, so a run cannot silently
    # pick up a different record than the one the pins were written against.
    ZIG_AGENT_PROTO_SDK_PINS = "test/interop/sdk-pins.json";

    # The house gate finds the project's Zig sources with `find`, and
    # `GATE_EXCLUDE` REPLACES the gate's built-in default list rather than
    # extending it, so a project that sets it carries the whole list itself.
    # These are its four default patterns plus this checkout's own leftover
    # toolchain cache: `/zig-global-cache/` does not match `/.zig-global-cache/`,
    # and that directory holds an unpacked Zig toolchain whose own sources are
    # `.zig` files. Measured on this tree, discovery without that fifth pattern
    # returns 1968 files, 1938 of them from that cache. With the list below the
    # gate's file list is exactly the thirty sources this repository owns:
    # `build.zig`, `src/*.zig` and `test/*.zig`, and nothing from a cache or an
    # install prefix. Nothing is deleted to get there; the caches stay where they
    # are and the gate stops reading them.
    GATE_EXCLUDE = "/[.]zig-cache/ /zig-out/ /zig-cache/ /zig-global-cache/ /.zig-global-cache/";
  };

  # The shim exits 1 with no output when it cannot resolve a toolchain, so a
  # broken pin looks like a mysterious silent build failure. Report the
  # version on entry instead. The directories the environment above names
  # are created first and under a 077 umask, because they are per-account
  # directories on a mount every account on the node can read, and because a
  # cache root that does not exist yet makes the shim download the toolchain
  # again on every entry.
  enterShell = ''
    (umask 077
    mkdir -p ${builtins.concatStringsSep " " (builtins.attrValues scratch)})

    ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      # Wine deliberately drops the Unix TMPDIR while importing the host
      # environment. Preserve its caller-selected value in this project's own
      # prefix instead of falling back to Wine's TEMP or the host's /tmp.
      wine_tmpdir=$(WINEDEBUG=-all winepath -w "$TMPDIR") || exit 1
      WINEDEBUG=-all wine reg add 'HKCU\Environment' /v TMPDIR /t REG_SZ /d "$wine_tmpdir" /f || exit 1
    ''}

    echo "scratch root: ${scratchRoot}"
    echo "zig $(zig version 2>/dev/null || echo '<unresolved: check .minimum_zig_version>')"

    # The shim downloads the pinned toolchain into <global>/p/<hash> on first
    # use. Say which of the two states this root is in, because the other
    # state's failure mode is a silent exit 1.
    if [ -n "$(ls -A ${scratch.zigGlobal}/p 2>/dev/null)" ]; then
      echo "toolchain store: ${scratch.zigGlobal}/p"
    else
      echo "toolchain store: empty; the shim downloads the pinned toolchain on first use"
    fi

    # Named, not aliased over `python3`: the system interpreter is what a
    # stray `python3 script.py` would find, and it has neither SDK. The peers
    # are started by absolute path in the run commands, so this entry is a
    # report rather than the mechanism.
    echo "interop python: $(command -v interop-python || echo '<not on PATH>')"
  '';

  # The house gate: fmt, build, test, ast-check, ziglint, zlint, zbc, zwanzig
  # and cross-test, plus coverage on request. The version cross-check runs first
  # because every later step is meaningless against a toolchain the manifest
  #
  # `ZBC` and `ZLINT` are this repository's two wrappers around the analyzers,
  # and they are named here rather than in `env` so that they are the GATE's
  # zbc and zlint and nothing else's: a bare `zbc` or `zlint` stays the raw
  # analyzer, and `ZBC=zbc ZLINT=zlint zig-gate` runs the host tool exactly as
  # it ships.
  #
  # The two reach a green gate by different means, which is why the preface
  # below tells them apart. ziglint's Z026 and zwanzig's empty-catch-engine
  # are silenced by SAFETY comments that stay in the source and that the
  # analyzers themselves read. Everything else zlint reports stays open unless
  # the source carries one exact-statement annotation naming one reviewed
  # statement, and such an annotation is a human's reading of one line, not an
  # analysis any tool performed: the wrapper checks the shape of that record
  # and never the truth of the comment above it.
  #
  # `ZBC` is the escape analyzer's wrapper. It adjudicates one finding — the
  # recursion in `json.Reader.skipValue`, whose nesting is bounded by
  # `json.max_depth` through `enterContainer` in both container arms — and only
  # while `src/json.zig` carries the annotation that says so. Every other
  # finding is reported as the analyzer reported it, and the wrapper refuses to
  # guess: analyzer output it cannot read, an annotation that maps to no
  # finding, and any other recursive parse function all fail the run. It is
  # Python standard library only, and it is development tooling like the peers:
  # the library itself keeps its zero-dependency guarantee.
  scripts.gate.exec = ''
    set -eu
    compiler="''${ZIG:-zig}"
    version="$("$compiler" version)"
    pin="$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)"
    test "$version" = "$pin" || {
      echo "zig $version does not match .minimum_zig_version $pin" >&2
      exit 1
    }

    # Resolve the shim while the project's toolchain cache is still selected.
    # cross-test sources the host scratch policy, which may select a different
    # cache; the already-checked executable must survive that change.
    compiler_info="$("$compiler" env)"
    exe_pattern='[.]zig_exe = "([^"\\]+)",'
    if [[ ! $compiler_info =~ $exe_pattern ]] || \
        [[ ! -x ''${BASH_REMATCH[1]} ]]; then
      echo "cannot resolve the real Zig executable from zig env" >&2
      exit 1
    fi
    export ZIG="''${BASH_REMATCH[1]}"
    # zbc queries `zig env` by name rather than honoring ZIG.
    export PATH="''${ZIG%/*}:$PATH"

    # Analyzer policy and guest receipts decide whether evidence is accepted.
    # Check all three readers before using their verdicts. Their fixtures stay
    # under approved scratch; pytest writes no cache into the NFS checkout.
    echo "gate: analyzer-policy and guest-receipt tests"
    fixture_root="''${TMPDIR:?TMPDIR is unset, so there is no approved fixture root}"
    rm -rf "$fixture_root/gate-analysis"
    pytest -q -p no:cacheprovider --basetemp "$fixture_root/gate-analysis" \
      test/gate_analysis_test.py test/gate_zlint_test.py test/cross_guest_test.py

    # The house gate hides zero-open analyzer output, including review records.
    # State the mechanisms on every run. The wrapper computes review counts
    # from current source and reports each reviewed file:line on stderr.
    echo "zlint: unsafe-undefined natively honors source SAFETY comments."
    echo "    suppressed-errors closes only exact source-annotated statements on"
    echo "    manual review, not automatic proof. Every unreviewed finding stays open."
    echo "    ziglint Z026 and zwanzig empty-catch-engine use their own named line directives."
    echo "    A rule this wrapper does not adjudicate stays open and is never waived."
    echo "    tools/gate_zlint.py is the wrapper; ZLINT=zlint zig-gate runs the raw analyzer."

    # A run whose only finding was adjudicated reports `zbc: OK`, because the
    # gate counts open findings and the wrapper's reviewed line is not one of
    # them. Say what is adjudicated before the run, so the waiver is on the
    # record of every gate rather than only of the runs that happen to have
    # another finding to print.
    echo "zbc: one finding is adjudicated by source annotation, reviewed and reported:"
    echo "    src/json.zig json.Reader.skipValue, rule recursive-parse-fn-without-stack-check,"
    echo "    bounded by json.max_depth through enterContainer in both container arms."
    echo "    tools/gate_zbc.py is the wrapper; ZBC=zbc zig-gate runs the raw analyzer."

    ZLINT="$(pwd)/tools/gate_zlint.py" ZBC="$(pwd)/tools/gate_zbc.py" zig-gate "$@"
  '';

  # A wrapper rather than a bare `python3` on PATH: the peers import `mcp` and
  # `a2a`, and only the interpreter above has them. It exists so a run command
  # reads the same whether or not the caller remembered to use the full store
  # path, and it fails with the interpreter's own message rather than a
  # confusing ImportError when the environment was not entered.
  scripts.interop-python.exec = ''
    exec ${interopPython}/bin/python3 "$@"
  '';

  scripts.interop-mcp = {
    description = "Drive the MCP 2025-11-25 interop peer against the Zig client";
    exec = ''
      set -eu
      exec ${interopPython}/bin/python3 test/interop/mcp_peer.py \
        --role supervise \
        --zig-binary "''${ZIG_AGENT_PROTO_MCP_INTEROP:-zig-out/bin/zig-agent-proto-mcp-interop}" \
        "$@"
    '';
  };

  scripts.interop-a2a = {
    description = "Drive both A2A 1.0 unary exchanges against the pinned SDK";
    exec = ''
      set -eu
      exec ${interopPython}/bin/python3 test/interop/a2a_peer.py \
        --role zig-interop \
        --zig-binary "''${ZIG_AGENT_PROTO_A2A_INTEROP:-zig-out/bin/zig-agent-proto-a2a-interop}" \
        "$@"
    '';
  };
}
