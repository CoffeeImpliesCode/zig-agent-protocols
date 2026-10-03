{ pkgs, lib, ... }:

# The interface library has no system library dependencies. Development inputs
# are the house gate, cross-target runners and the interoperability SDKs.
# `packages` stays free of `zig`: `zig` on this host is the anyzig shim, which
# resolves the toolchain by reading `.minimum_zig_version` from build.zig.zon.
# A nixpkgs `zig` here would shadow the shim and build with whatever version
# nixpkgs ships, which the manifest does not pin.
#
# Python supplies development SDK peers and analyzer-policy tests only.
# Neither is a library dependency: no Zig file imports Python, and the peers
# are separate processes speaking real wire bytes. Four peers run over three
# interpreters — MCP at the previous revision and at the current one, ACP, and
# A2A — because one interpreter cannot hold one distribution at two versions,
# and the point of a pin is that it states a version rather than resolving one.
# SDK versions, hashes and the API facts each peer uses are recorded in
# `test/interop/sdk-pins.json`, and every peer reads that file and refuses to
# run against an environment that does not match it.
let
  inherit (pkgs) python3;
  # Nix already provides `python3Packages`; the override is built from it so
  # every transitive dependency is a pinned nixpkgs package rather than
  # something a resolver would fetch at shell entry.
  inherit (pkgs.python3.pkgs)
    anyio
    buildPythonPackage
    cryptography
    google-api-core
    googleapis-common-protos
    hatchling
    httpx
    json-rpc
    jsonschema
    packaging
    protobuf
    pydantic
    pyjwt
    sse-starlette
    starlette
    uvicorn
    pytest
    ;

  # nixpkgs spells these with hyphens, which a Nix identifier cannot carry.
  # They are bound under names that can, so that every use below is a package
  # and not a string: a quoted name is a valid attribute in `inherit` and a
  # bare string anywhere else, and a dependency list full of strings builds
  # nothing and says nothing.
  pythonHatchFancyReadme = pkgs.python3.pkgs."hatch-fancy-pypi-readme";
  pythonPdmBackend = pkgs.python3.pkgs."pdm-backend";
  pythonPydanticCore = pkgs.python3.pkgs."pydantic-core";
  pythonOpenTelemetry = pkgs.python3.pkgs."opentelemetry-api";
  pythonMultipart = pkgs.python3.pkgs."python-multipart";
  pythonTypingExtensions = pkgs.python3.pkgs."typing-extensions";
  pythonTypingInspection = pkgs.python3.pkgs."typing-inspection";

  # uv-dynamic-versioning 0.14.1 requires dunamai~=1.26.1. Keep that
  # requirement intact instead of relaxing it to nixpkgs' 1.25.0.
  dunamaiPinned = pkgs.python3.pkgs.dunamai.overridePythonAttrs (_: {
    version = "1.26.1";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/9f/67/d5611975faaa5e4a920f4b19e4caccd5df0facb925687850f1e45f5876f2/dunamai-1.26.1.tar.gz";
      hash = "sha256-O0YAe9ZbALSCTq0KGu42X9ItDsK5whlJfU/Uj1KGDIs=";
    };
  });

  # uv-dynamic-versioning 0.14.1 over the 0.13.0 this nixpkgs revision carries.
  # Not a preference: every package in this file that injects its version at
  # publish time does it through this plugin, `fallback-version` is the key it
  # reads when there is no `.git` to read a tag from, and that key does not
  # exist in 0.13.0. httpx2 and httpcore2 additionally declare
  # `uv-dynamic-versioning>=0.14.1` in their own build-system.
  uvDynamicVersioning = pkgs.python3.pkgs.uv-dynamic-versioning.overridePythonAttrs (old: {
    version = "0.14.1";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/6f/c8/fa500ee29af69cfeeea5ff6d6597919f1989b2e3f1a236c3006bdb21d320/uv_dynamic_versioning-0.14.1.tar.gz";
      hash = "sha256-hkLbaGzlxQQXA156JXrHO35cOnoywz5FvX42uiLutkg=";
    };
    dependencies = map (
      dependency: if lib.getName dependency == "dunamai" then dunamaiPinned else dependency
    ) old.dependencies;
    # The sdist has no Git history, but tests/conftest.py tags HEAD in the
    # unpacked source. Give that private build fixture one commit; run every
    # upstream test rather than disabling the VCS-dependent cases.
    preCheck = (old.preCheck or "") + ''
      export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
      git init --quiet --initial-branch=main
      git config --local user.name fixture
      git config --local user.email fixture@invalid
      git add .
      git commit --quiet -m "sdist test fixture"
    '';
  });

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

    build-system = [ hatchling uvDynamicVersioning ];

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

  # One interpreter carrying the previous-revision MCP SDK and A2A, so a peer
  # process spawned by another peer process resolves the same `mcp` and the
  # same `a2a` as its parent. The MCP SDK is the pinned nixpkgs package.
  #
  # 1.29.0 is held here as the PREVIOUS revision, not because it is the newest:
  # 1.30 exists and speaks the same 2025-11-25 protocol line. What fixes this
  # version is that `sdks["mcp"]` names 1.29.0 and the previous-revision peer
  # asserts that version at run time, so the repository pins a revision rather
  # than picking whichever newest one would satisfy the protocol line.
  interopPython = python3.withPackages (ps: [
    ps.mcp
    a2aSdk
  ]);

  # agent-client-protocol 1.0.0rc2, built from the exact PyPI sdist: no
  # nixpkgs attribute exists for this distribution at the revision
  # devenv.lock pins, so this is the shape a2aSdk above uses — a
  # fixed-output fetch, a pinned build backend, and nothing a resolver
  # picks at shell entry.
  #
  # The published sdist already declares version 1.0.0rc2. The tag's older
  # project version is not the artifact built here, so no version patch is needed.
  # This prerelease supplies stable wire 1 and an opt-in experimental wire 2.
  # It stays isolated from the MCP interpreters and never falls back to 0.12.1.
  acpSdk = buildPythonPackage {
    pname = "agent-client-protocol";
    version = "1.0.0rc2";
    pyproject = true;

    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/57/ac/53520d32dd6afb8cef77bf2b731f9eb451d4a8dffbf0df104a1148724eed/agent_client_protocol-1.0.0rc2.tar.gz";
      hash = "sha256-yDuHXv0DapUnPVgtrwKymlCQJNAjKir9YYfOjVVkJ30=";
    };

    build-system = [ pythonPdmBackend ];


    # Both declared runtime dependencies. The optional logfire and HTTP extras
    # are not requested by this stdio peer.
    dependencies = [
      pydantic
      pythonPydanticCore
    ];

    # Importing the package is the check that matters here; the upstream test
    # suite needs pytest and a network, and a peer does not carry either.
    pythonImportsCheck = [ "acp" ];
    doCheck = false;

    meta = {
      description = "Agent Client Protocol SDK, the 1.0.0rc2 wire-1 build with opt-in wire-2 alpha";
      homepage = "https://agentclientprotocol.com";
      license = lib.licenses.asl20;
    };
  };

  # Its own interpreter, like the other two: a peer process spawned by another
  # peer process has to resolve the same `acp` as its parent, and the pins file
  # has to be able to say which distribution that is.
  acpPython = python3.withPackages (ps: [ acpSdk ]);

  # httpx2 2.12.0 and httpcore2 2.12.0, built from the publisher's own bytes
  # over the nixpkgs packages of the same names.
  #
  # mcp 2.3.0 declares `httpx2>=2.10.0`; the nixpkgs revision devenv.lock pins
  # carries httpx2 2.9.1. Relaxing that floor would suppress a real
  # prerequisite with no compatibility proof, so the floor is met with the
  # exact release instead. httpx2 pins httpcore2 exactly, so that one is
  # overridden the same way rather than left at 2.9.1.
  #
  # 2.12.0 rather than 2.10.0 because 2.10.0 is the first version that clears
  # the floor and it carries three published advisories — CVE-2026-84379
  # (CRLF injection into multipart part headers), CVE-2026-84380 (a
  # Content-Length/Transfer-Encoding conflict usable for request smuggling)
  # and CVE-2026-84382 (unbounded decompression), the latter two fixed in
  # 2.11.0 and 2.12.0. `>=2.10.0` is satisfied by 2.12.0, and it is not
  # satisfied by anything that still carries them.
  #
  # Every other floor this pair declares is met by the nixpkgs revision
  # devenv.lock pins, read out of its own package definitions rather than
  # assumed: idna 3.18 against `>=3.18`, h11 0.16.0 against `>=0.16`, and
  # truststore 0.10.4 against `>=0.10`. None of them needs an override here,
  # and none of them is relaxed.
  # The published sdists omit tests. Use the matching release's complete
  # test tree instead of retaining nixpkgs paths that do not exist in them.
  httpx2Tests = pkgs.fetchFromGitHub {
    owner = "pydantic";
    repo = "httpx2";
    rev = "71ae23be5448f859c2b4e21d9972ddfa7b8d759d"; # v2.12.0
    hash = "sha256-mEJHlG6skKkV90SfjTg+MHGkL7gnf3QLKLbWlTtEb9Q=";
  };
  httpx2TestTree = ''
    cp -R ${httpx2Tests}/tests .
    chmod -R u+w tests
  '';

  httpcore2Pinned = pkgs.python3.pkgs.httpcore2.overridePythonAttrs (_: {
    pname = "httpcore2";
    version = "2.12.0";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/be/ad/f4f0e57345f1870f3e8cb624e058d7eca6e5a27d33bcc3311d9b618734cd/httpcore2-2.12.0.tar.gz";
      hash = "sha256-kpNSK7oKp8TI6ePwQMFldb2IaOFVp3+jDHqQhaXq5kg=";
    };
    # Its own build-system, read out of its sdist:
    #   requires = ["hatchling", "hatch-fancy-pypi-readme", "uv-dynamic-versioning>=0.14.1"]
    # The version is injected at publish time and its pyproject carries
    # `fallback-version = "0.0.0"`, which is what an sdist with no tag would
    # otherwise install; naming it here is what makes the installed version
    # the one this pin claims.
    build-system = [
      hatchling
      pythonHatchFancyReadme
      uvDynamicVersioning
    ];
    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail 'fallback-version = "0.0.0"' 'fallback-version = "2.12.0"'
    '';
    # The nixpkgs source is a workspace whose postPatch pushes a directory.
    # This artifact is already the package root; its tests need no matching popd.
    # Copy release tests into the sdist root; no workspace pushd was run.
    preCheck = httpx2TestTree;
    # httpcore2 2.12.0 declares exactly these two.
    dependencies = [
      pkgs.python3.pkgs.h11
      pkgs.python3.pkgs.truststore
    ];
  });

  httpx2Pinned = pkgs.python3.pkgs.httpx2.overridePythonAttrs (_: {
    pname = "httpx2";
    version = "2.12.0";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/7f/f8/579a8b51e42e38ee32647df9f08aa25643ae788e275cc625b199829c4671/httpx2-2.12.0.tar.gz";
      hash = "sha256-djH+mIeooidfSiVA4FOqZw/MUHQoZKmufGbmCf3PEs8=";
    };
    build-system = [
      hatchling
      pythonHatchFancyReadme
      uvDynamicVersioning
    ];
    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail 'fallback-version = "0.0.0"' 'fallback-version = "2.12.0"'
    '';
    preCheck = httpx2TestTree;
    # httpx2 2.12.0's own list, with the markers already resolved for a Linux
    # CPython 3.14 build: `httpx2-jsfetch` is emscripten-only and
    # `typing-extensions` is `python_version < "3.13"`. httpcore2 is the
    # override above, because httpx2 pins it with `==`, not a floor.
    dependencies = [
      anyio
      httpcore2Pinned
      pkgs.python3.pkgs.idna
      pkgs.python3.pkgs.truststore
    ];
  });

  # mcp-types 2.3.0 and mcp 2.3.0, built from the exact PyPI sdists.
  #
  # They are two derivations because mcp 2.3.0 declares `mcp-types==2.3.0` as
  # one of its own runtime requirements: the types package is installed
  # separately, from its own published sdist, at the version mcp pins. Building
  # it here rather than taking whatever the interpreter happens to resolve is
  # what makes that requirement true rather than incidental, and the peer's
  # `importlib.metadata.version("mcp-types")` then has exactly one answer.
  mcpTypesCurrentSdk = buildPythonPackage {
    pname = "mcp-types";
    version = "2.3.0";
    pyproject = true;

    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/9e/2d/7c251e34207f6c51000312fc8839111ac45cfe02023f90b44e7f1051dd8e/mcp_types-2.3.0.tar.gz";
      hash = "sha256-0eRlSe2zXuGalJQPzubRrd1+WJq36pLdqD9dhHgfw2I=";
    };

    # Read out of this release's own pyproject, not inferred from mcp's:
    #   requires = ["hatchling", "uv-dynamic-versioning"]
    #   build-backend = "hatchling.build"
    #   [tool.hatch.version] source = "uv-dynamic-versioning"
    # `version = "2.3.0"` is absent because the version is injected at publish
    # time and the sdist carries no `.git` for the plugin to read it from, so
    # it is named here and `--replace-fail` keeps that claim honest.
    build-system = [ hatchling uvDynamicVersioning ];

    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail 'style = "pep440"' 'style = "pep440"
      fallback-version = "2.3.0"'
    '';

    dependencies = [
      pydantic
      pythonTypingExtensions
    ];

    pythonImportsCheck = [ "mcp_types" ];
    doCheck = false;

    meta = {
      description = "MCP wire types, the 2026-07-28 line";
      homepage = "https://modelcontextprotocol.io";
      license = lib.licenses.mit;
    };
  };

  mcpCurrentSdk = buildPythonPackage {
    pname = "mcp";
    version = "2.3.0";
    pyproject = true;

    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/9d/8d/e0d339616f4810e9051d4aba6887afab289ab1f81875fe908b606cdfd0e3/mcp-2.3.0.tar.gz";
      hash = "sha256-ixR6UEQc8FnciMaE4K7tNofwqg85xs3nuQMw7/0rNNg=";
    };

    build-system = [ hatchling uvDynamicVersioning ];

    # The same released-sdist problem a2aSdk above has, and the same answer:
    # the version is injected at publish time and the sdist carries no `.git`
    # for the plugin to read it from, so it is named here. `--replace-fail`
    # keeps the claim honest — a pyproject that no longer carries the line
    # fails the build instead of quietly installing an unversioned package.
    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail 'style = "pep440"' 'style = "pep440"
      fallback-version = "2.3.0"'
    '';

    # Exactly the distribution set its metadata declares, minus the two extras
    # the peer does not use (`cli`, `rich`). `pyjwt[crypto]` is NOT among them:
    # the SDK declares the extra, so the requirement behind it — cryptography
    # — is listed here rather than assumed away on the grounds that a stdio run
    # never verifies a token. A declared requirement is satisfied or reported,
    # not dropped because this particular run would not reach it.
    dependencies = [
      anyio
      httpx2Pinned
      jsonschema
      mcpTypesCurrentSdk
      pythonOpenTelemetry
      cryptography
      pydantic
      pyjwt
      pythonMultipart
      sse-starlette
      starlette
      pythonTypingExtensions
      pythonTypingInspection
      uvicorn
    ];

    pythonImportsCheck = [ "mcp" "mcp_types" ];
    doCheck = false;

    meta = {
      description = "Model Context Protocol SDK, the 2026-07-28 line";
      homepage = "https://modelcontextprotocol.io";
      license = lib.licenses.mit;
    };
  };

  # A third interpreter, beside the 1.29.0 one rather than merged into it: the
  # previous-revision peer reads `sdks["mcp"]` and must keep resolving 1.29.0,
  # and one interpreter cannot hold both distributions at two versions.
  mcpCurrentPython = python3.withPackages (ps: [
    mcpCurrentSdk
    mcpTypesCurrentSdk
  ]);

  # The gate analysis tests are development tooling as well, and `gate` runs
  # them before the house gate because they decide what the gate is allowed to
  # waive. They get their own interpreter rather than an import in the peer one:
  # the pinned SDKs are the peers' business and stay exactly as
  # `test/interop/sdk-pins.json` records them, and a test-only package has no
  # business in the environment that drives an exchange.
  gateTestPython = python3.withPackages (ps: [ pytest ps.pexpect ]);

  # User-mode QEMU covers the published Linux architectures. WoW64 is selected
  # for x86 and x86_64 PE files without a 32-bit host environment; availability
  # is not proof of successful execution. The matrix records each result.
  # These runners are development processes, never library dependencies.
  crossRunners = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    (pkgs.qemu.override { userOnly = true; })
    pkgs.wineWow64Packages.minimal
  ];

  # The interpreters the scripts exec by absolute path, named as a list so
  # each SDK line is one binding above and one entry here.
  #
  # `interopPython` is the previous-revision MCP 1.29.0 (2025-11-25) plus A2A
  # 1.2.1 and stays exactly that, because `sdks["mcp"]` names those versions
  # and the peer that reads it has not moved. `acpPython` carries the one ACP
  # distribution under `sdks["agent-client-protocol"]`, and
  # `mcpCurrentPython` carries mcp 2.3.0 and mcp-types 2.3.0 under
  # `sdks["mcp-current"]`. One interpreter cannot hold `mcp` at two versions,
  # so a newer revision is a new binding rather than an import added to an old
  # one: an SDK version is a fact the pins file states, never one a resolver
  # picks at run time, and nothing here falls back to another version.
  interpreters = [ interopPython acpPython mcpCurrentPython gateTestPython ];

  # Gate and cross-audit tools remain development dependencies.
  #
  # `lsof` is here because `tools/safe-rm-dir.sh` requires it. The helper
  # refuses to remove anything it cannot establish is unreferenced, and the
  # /proc walk it pairs lsof with already covers this account's processes —
  # lsof is a second reading of the same ground, not a wider one: it reads the
  # same procfs under the same permissions, so on a host that forbids it lsof
  # sees no more than the walk does, and no package this repository builds
  # imports it.
  #
  # `util-linux` is here for `mountpoint`, which `.envrc`'s scratch bootstrap
  # calls to require a candidate volume to be a mount in its own right rather
  # than an autofs stub, and which `test/devenv_enter_shell_test.py` resolves
  # as one of the remover's tools. It was previously satisfied by whatever the
  # host happened to have. The remover reads /proc/self/mountinfo: a nonzero
  # mountpoint status cannot distinguish an absent mount from a failed check
  # or a missing command.
  #
  # `nettools` supplies `hostname`, which cross-test records in its receipt.
  packages = interpreters ++ crossRunners ++ [ pkgs.lsof pkgs.util-linux pkgs.nettools ];

  # Where this environment's tools come from when nixpkgs does not carry
  # them. The pinned compiler is the anyzig shim, which resolves
  # `.minimum_zig_version` out of `build.zig.zon`; `zig-gate` and the four
  # analyzers it drives are host builds under the caller's own account. They
  # are not added to `packages` and they are not built here: a nixpkgs `zig`
  # would shadow the shim with a version the manifest does not pin, and
  # wrapping the analyzers again would put a second, drifted copy of each
  # next to the first.
  #
  # Read from the caller's environment for the same reason `scratchUser` is:
  # it is the caller's account that owns the directory, and this file
  # publishes no account name. Not checked for existence here — evaluation
  # has to succeed for `devenv print-dev-env` and for the profile modules on
  # a host where the shell is never entered. `enterShell` is where a missing
  # tool is a sentence naming it.
  hostBin = let home = builtins.getEnv "HOME"; in "${home}/.local/bin";

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
  # account evaluates it. The four mounts are named once, here, because the
  # project root and the shared toolchain store below are both derived from
  # them and a second copy of the list is a second answer to give.
  scratchMounts = [
    "/home/tmp2"
    "/home/tmp"
    "/vol/tmp2"
    "/vol/tmp"
  ];
  scratchUser =
    let u = builtins.getEnv "USER";
    in if u != "" then u else builtins.getEnv "LOGNAME";
  scratchCandidates =
    if scratchUser == "" then
      throw "zig-agent-proto: USER and LOGNAME are both unset, so this environment cannot name its per-account scratch directory; export USER before evaluating."
    else
      builtins.map (mount: "${mount}/${scratchUser}/zig-agent-proto") scratchMounts;

  # Downloaded toolchains are shared; build caches are not. The shim unpacks
  # each toolchain into `<zigGlobal>/p/<hash>` and records that hash under
  # `$XDG_DATA_HOME/anyzig/hashstore/`, so a second scratch root downloads the
  # same toolchain again unless it can see the first one's `p`. The store is
  # therefore a sibling of the project root, searched on the same mounts in
  # the same order under the same per-account name: this file names no
  # account and no mount of its own, which is what the hard-coded
  # `/home/tmp2/<account>/zig-global-cache/p` it replaces got wrong. A store
  # is optional. A node without one is not a failure — the shim unpacks the
  # pinned toolchain itself — so the list is handed to the shell whole and
  # the first entry that is still there when the shell starts wins.
  toolchainStores =
    builtins.map (mount: "${mount}/${scratchUser}/zig-global-cache/p") scratchMounts;

  scratchRoot =
    let present = builtins.filter builtins.pathExists scratchCandidates;
    in
    if present == [ ] then
      throw "zig-agent-proto: no approved scratch mount is present, so this environment has nowhere to put its caches, its temporary directory or an interoperability capture; expected one of ${builtins.concatStringsSep ", " scratchCandidates}. See README.md."
    else
      builtins.head present;

  # Every path this environment writes through, named once. `zigGlobal/p` is
  # linked to `toolchainStores` at shell entry when one of them is present,
  # and is otherwise a directory the shim fills on first use, so a node that
  # has never run this project still needs no store prepared for it.
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

    # No `__pycache__` anywhere in this checkout. The peers and the gate's
    # python tests are development tooling that runs with the project as its
    # working directory, so an unset bytecode cache would write compiled
    # modules into an NFS export the gate is otherwise careful not to touch,
    # and into a working tree no reader asked to be dirty. Off entirely is
    # stronger than relocating it: there is no local prefix that is both
    # approved for this account and inside the gate's own rules by accident.
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

  # Shell entry does three things in order, and each one is a step the next
  # depends on: put the caller's tool directory on PATH, point the toolchain
  # store at a shared one when this account has one, and resolve the pinned
  # compiler once so the rest of the session runs the toolchain that was
  # checked. The last step is the point of the sequence, and the only one that
  # stops entry.
  #
  # The host analyzers are deliberately NOT one of those three. They are the
  # gate's inputs and the gate checks for them, because a missing analyzer
  # says nothing about whether this shell can resolve the pinned compiler,
  # run one interoperability peer, or read a build log — and refusing entry for
  # it would make an account that has not built this account's tools unable to
  # use any part of the environment. The gate is not relaxed by this: it names
  # every missing tool and fails before it runs a section that would silently
  # skip.
  #
  # The shim exits 1 with no output when it cannot resolve a toolchain, and
  # `zig` was reaching it through whatever PATH the caller happened to carry.
  # Nix runs this environment inside a sandbox whose PATH is the container's
  # own — no `$HOME/.local/bin`, no project host tools — so on a fresh node
  # the pinned compiler was simply not on PATH, `zig version` exited 127, and
  # `2>/dev/null` turned that into one soft line that named the wrong thing.
  # Everything below reports the real state and stops on it instead.
  #
  # The directories the environment above names are created first and under a
  # 077 umask, because they are per-account directories on a mount every
  # account on the node can read, and because a cache root that does not exist
  # yet makes the shim download the toolchain again on every entry. Each is
  # checked before it is created, and a path that is a symlink or belongs to
  # another account is refused rather than written through — `.envrc` applies
  # the same rule for the same directories, and this is the path that covers
  # `devenv shell`, which never sources it.
  enterShell = ''
    # The caller's own tool directory, declared here rather than inherited.
    # Appended, never prepended: `packages` is this file's statement about
    # which Python and which runners win, and a host tool directory must not
    # quietly replace the `pytest` that carries this project's test-only
    # dependencies. Added only when it is not already there, because
    # `enterShell` runs again on every `direnv reload`.
    case ":''${PATH}:" in
      *:"${hostBin}":*) ;;
      *) PATH="''${PATH}:${hostBin}"; export PATH ;;
    esac

    for _zap_path in ${builtins.concatStringsSep " " (builtins.attrValues scratch)}; do
      if [ -e "$_zap_path" ] || [ -L "$_zap_path" ]; then
        if [ ! -d "$_zap_path" ] || [ -L "$_zap_path" ] || [ ! -O "$_zap_path" ]; then
          echo "zig-agent-proto: refusing $_zap_path: not a directory this account owns." >&2
          exit 1
        fi
      fi
    done
    (umask 077
    mkdir -p ${builtins.concatStringsSep " " (builtins.attrValues scratch)})

    # `<zigGlobal>/p` is where the shim looks for every toolchain. Point it at
    # the first shared store this account has, so a second scratch root does
    # not download the same toolchain again; leave it alone entirely when
    # there is none, because the shim fills a real directory on first use and
    # a node that has never run this project needs no store prepared for it.
    #
    # Nothing here deletes. A link is made only when the name is entirely
    # absent — `[ -e ]` and `[ -L ]` both have to say so — so an existing
    # entry is never re-pointed, and a link whose target is gone is not
    # repaired either: that is the case the hard-coded target this replaces
    # used to cause on every host but this one, and unlinking a path is not a
    # decision this file takes on a path it did not create. It stops instead,
    # and `tools/safe-rm-dir.sh --link` is how a person removes one: that
    # checks the link's owner, the volume its directory is on, whether it is
    # a mount point, and what its target is, before it unlinks anything.
    _zap_p="${scratch.zigGlobal}/p"
    if [ ! -e "$_zap_p" ] && [ ! -L "$_zap_p" ]; then
      for _zap_store in ${builtins.concatStringsSep " " toolchainStores}; do
        [ -d "$_zap_store" ] || continue
        ln -s "$_zap_store" "$_zap_p" 2>/dev/null && break
      done
    fi
    if [ -L "$_zap_p" ] && [ ! -d "$_zap_p" ]; then
      echo "zig-agent-proto: $_zap_p is a link to nothing ($(readlink -- "$_zap_p"))." >&2
      echo "  The shim looks for every toolchain through that path, so nothing" >&2
      echo "  resolves until the link is gone, and this file will not remove it" >&2
      echo "  for you. Inspect it, then:" >&2
      echo "    readlink -- $_zap_p" >&2
      echo "    ''${DEVENV_ROOT:-$PWD}/tools/safe-rm-dir.sh --link $_zap_p" >&2
      exit 1
    fi

    ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      # Wine deliberately drops the Unix TMPDIR while importing the host
      # environment. Preserve its caller-selected value in this project's own
      # prefix instead of falling back to Wine's TEMP or the host's /tmp.
      # Guarded on the tools existing: direnv evaluates enterShell through
      # `devenv direnvrc` in the host shell, where wine is not installed,
      # and an unguarded call aborts entry with `winepath: command not found`.
      if command -v winepath >/dev/null 2>&1 && command -v wine >/dev/null 2>&1; then
        wine_tmpdir=$(WINEDEBUG=-all winepath -w "$TMPDIR") || exit 1
        WINEDEBUG=-all wine reg add 'HKCU\Environment' /v TMPDIR /t REG_SZ /d "$wine_tmpdir" /f || exit 1
      fi
    ''}

    # The pin is the manifest's. The shim reads it out of `build.zig.zon` and
    # the gate re-reads the same line on every run; neither this file nor the
    # host states a version anywhere. `DEVENV_ROOT` rather than `$PWD`, because
    # direnv evaluates this from wherever the caller happened to be.
    _zap_root="''${DEVENV_ROOT:-$PWD}"
    _zap_pin=$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' "$_zap_root/build.zig.zon")
    if [ -z "$_zap_pin" ]; then
      echo "zig-agent-proto: $_zap_root/build.zig.zon names no .minimum_zig_version," >&2
      echo "  so there is no pinned toolchain to resolve and no answer to check one against." >&2
      exit 1
    fi
    if ! _zap_version=$(zig version); then
      echo "zig-agent-proto: zig is $(command -v zig) and it could not resolve $_zap_pin." >&2
      echo "  The shim reads the pin from build.zig.zon and unpacks the toolchain into" >&2
      echo "  $ZIG_GLOBAL_CACHE_DIR/p, and it exits without a message when that download" >&2
      echo "  fails. That silence is what this message replaces; see README.md." >&2
      exit 1
    fi
    if [ "$_zap_version" != "$_zap_pin" ]; then
      echo "zig-agent-proto: zig $_zap_version is not the pinned $_zap_pin." >&2
      echo "  $(command -v zig) is the shim, which takes its version from the manifest;" >&2
      echo "  something ahead of it on PATH is answering instead." >&2
      exit 1
    fi

    # Resolve once and keep. `zig env` names the executable the shim actually
    # selected; from here `zig` IS that executable and `ZIG` points at it, so
    # the rest of the session cannot be moved onto another toolchain by
    # anything that changes a cache directory underneath it. `cross-test`
    # sources the host scratch policy, which repoints ZIG_GLOBAL_CACHE_DIR,
    # and the gate script below does the same resolution for the same reason.
    _zap_env=$(zig env) || exit 1
    _zap_exe=$(printf '%s\n' "$_zap_env" | sed -n 's/.*\.zig_exe = "\([^"\\]*\)".*/\1/p')
    if [ -z "$_zap_exe" ] || [ ! -x "$_zap_exe" ]; then
      echo "zig-agent-proto: 'zig env' named no runnable .zig_exe for $_zap_pin." >&2
      echo "  '$_zap_exe'" >&2
      exit 1
    fi
    ZIG="$_zap_exe"
    export ZIG
    case ":''${PATH}:" in
      *:"''${_zap_exe%/*}":*) ;;
      *) PATH="''${_zap_exe%/*}:''${PATH}"; export PATH ;;
    esac

    echo "scratch root: ${scratchRoot}"
    echo "zig: $_zap_version, pinned by build.zig.zon, selected at $_zap_exe"

    # Which of the two states this root is in, because the other state's
    # failure mode is a silent exit 1.
    if [ -n "$(ls -A "$_zap_p" 2>/dev/null)" ]; then
      echo "toolchain store: $_zap_p"
    else
      echo "toolchain store: $_zap_p is empty; the shim downloads the pinned toolchain on first use"
    fi

    # Named, not aliased over `python3`: the system interpreter is what a
    # stray `python3 script.py` would find, and it has neither SDK. The peers
    # are started by absolute path in the run commands, so this entry is a
    # report rather than the mechanism.
    echo "interop python: $(command -v interop-python || echo '<not on PATH>')"

    unset _zap_path _zap_p _zap_store _zap_root _zap_pin \
      _zap_version _zap_env _zap_exe
  '';

  # The house gate: fmt, build, test, ast-check, ziglint, zlint, zbc, zwanzig
  # and cross-test, plus coverage on request. The version cross-check runs first
  # because every later step is meaningless against a toolchain the manifest
  # does not pin, and enterShell has already resolved and exported that
  # toolchain, so this check re-reads the same line against the same `ZIG`
  # rather than resolving anything a second time.
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

    # Every host tool the gate runs is checked here, at the gate, rather than at
    # shell entry. `tools/gate_zbc.py` and `tools/gate_zlint.py` resolve their
    # analyzer with `shutil.which`, so PATH is the only place that decision can
    # be made; `zig-gate` looks the rest up under `$HOME/.local/bin` by
    # absolute path and falls back to PATH, and is itself called by bare name
    # from the last line below. A missing one is named and the run stops, so no
    # section is silently skipped.
    gate_missing=
    for gate_tool in zig zig-gate ziglint zlint zbc zwanzig cross-test; do
      command -v "$gate_tool" >/dev/null 2>&1 || gate_missing="$gate_missing $gate_tool"
    done
    if [ -n "$gate_missing" ]; then
      echo "zig-gate: not on PATH, and this environment does not install them:" >&2
      echo "  ''${gate_missing# }" >&2
      echo "  PATH searched: ''${PATH}" >&2
      echo "  They are host tools, not nixpkgs packages, and the gate cannot run" >&2
      echo "  a section whose analyzer is absent." >&2
      exit 1
    fi

    # Analyzer policy and guest receipts decide whether evidence is accepted.
    # Check all three readers before using their verdicts. Their fixtures stay
    # under approved scratch; pytest writes no cache into the NFS checkout.
    #
    # One private directory per run, created by mktemp. A fixed name is a path
    # any other process on this approved mount can fill in before this run
    # reaches it, and deleting one by name deletes whatever is there then
    # rather than what this run put there.
    #
    # Nothing removes it here. `tools/safe-rm-dir.sh` does, and it removes it
    # only after checking that the tree belongs to this account, is mode 0700
    # so no other account has a path into it, sits on an approved volume with
    # no filesystem mounted at or under it, and holds no device, socket or fifo
    # out of which a recursive delete could mean something other than removing
    # the entry. An owned symlink inside it is removed as itself and nothing
    # more: `rm` unlinks a link and does not follow it.
    #
    # Liveness is checked too, and the honest scope of that check is stated
    # rather than implied: no process OF THIS ACCOUNT holds it — cwd, root,
    # executable, open descriptor or mapping — and `lsof` reports nothing under
    # it, as a second witness over the same ground. It is not a claim about
    # every process on the node, which no account can make from /proc; the
    # 0700 mode is what turns that limitation into a precondition the helper
    # can actually verify.
    #
    # The check runs after pytest, not from a trap, so a failing run leaves
    # its fixtures where a reader can look at them; and a refusal leaves them
    # too, and fails the gate with the path named, because an unverified
    # recursive delete is not worth the evidence it would remove.
    #
    # `devenv_enter_shell_test.py` is here for the same reason the gate runs
    # before the sources: it reads the `enterShell` body out of this file and
    # runs it, so a shell that cannot resolve the pinned compiler is caught by
    # a test that needs no nix evaluation and no download.
    # `safe_rm_dir_test.py` is here because the line above hands a removal to
    # a helper, and a removal nobody has checked is a removal nobody should
    # trust: its cases are every way the tree can be unsafe to delete.
    echo "gate: analyzer-policy and guest-receipt tests"
    fixture_root="''${TMPDIR:?TMPDIR is unset, so there is no approved fixture root}"
    fixture_dir="$(mktemp -d "$fixture_root/gate-analysis.XXXXXXXX")"
    pytest -q -p no:cacheprovider --basetemp "$fixture_dir" \
      test/gate_analysis_test.py test/gate_zlint_test.py test/cross_guest_test.py \
      test/devenv_enter_shell_test.py test/safe_rm_dir_test.py \
      test/interop/process_guard_test.py
    if ! "$(pwd)/tools/safe-rm-dir.sh" "$fixture_dir"; then
      echo "gate: leaving this run's fixtures in place: $fixture_dir" >&2
      exit 1
    fi

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

  # The ACP peer runs on its own interpreter, not on `interopPython`: the
  # distribution it imports is a different one, and a peer that spawned
  # another peer process has to resolve the same `acp` as its parent.
  # `--protocol-version` is passed through, so the stable wire and the
  # explicitly opt-in experimental wire-2 alpha are both reachable from the
  # same script; nothing here switches distribution if one of them fails.
  scripts.interop-acp = {
    description = "Drive the ACP wire-1 exchange, or wire-2 alpha with --protocol-version 2";
    exec = ''
      set -eu
      exec ${acpPython}/bin/python3 test/interop/acp_peer.py \
        --role supervise \
        --zig-binary "''${ZIG_AGENT_PROTO_ACP_INTEROP:-zig-out/bin/zig-agent-proto-acp-interop}" \
        "$@"
    '';
  };

  # The 2026-07-28 MCP peer, on its own interpreter. It is a sibling of
  # `interop-mcp`, not a replacement: the previous-revision peer reads
  # `sdks["mcp"]` and must keep resolving mcp 1.29.0, and one environment
  # cannot carry `mcp` at two versions. `--role` is passed through, so
  # `refusals` and `selftest` are reachable here too.
  scripts.interop-mcp-current = {
    description = "Drive the MCP 2026-07-28 interop peer against the Zig client";
    exec = ''
      set -eu
      exec ${mcpCurrentPython}/bin/python3 test/interop/mcp_current_peer.py \
        --role supervise \
        --zig-binary "''${ZIG_AGENT_PROTO_MCP_CURRENT_INTEROP:-zig-out/bin/zig-agent-proto-mcp-current-interop}" \
        "$@"
    '';
  };
}
