# Builds the PIA Desktop client, daemon, CLI and helpers from source using the
# upstream rake build system, then makes the result run on NixOS by patchelf-ing
# the prebuilt helper binaries and wrapping the Qt GUI apps.
#
# The source is fetched straight from the upstream repo (pia-foss/desktop) at a
# pinned tag; this repo carries no upstream code. The handful of build-script
# tweaks needed to compile against nixpkgs' newer Qt/clang live as patches under
# ./patches and are applied to the pristine upstream tree.
{
  lib,
  stdenvNoCC,
  callPackage,
  fetchFromGitHub,
  ruby,
  rake,
  llvmPackages_18,
  git,
  which,
  patchelf,
  makeWrapper,
  glibc,
  gcc,
  libnl,
  libGL,
  libcap_ng,
  libnsl,
  icu,
  qt6,
  # Runtime tools the daemon shells out to. Kept here so a bare `pia-daemon`
  # from the store is runnable; the NixOS module also sets these on PATH.
  iproute2,
  iptables,
  procps,
  psmisc,
  kmod,
  libcap,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  findutils,
  e2fsprogs,
  util-linux,
}:
let
  qtroot = callPackage ./qtroot.nix { };
  qtVersion = qtroot.version;
  qtMerged = qtroot.merged;

  version = "3.7.2";

  clang = llvmPackages_18.clang;
  llvm = llvmPackages_18.llvm;

  # gcc provides libstdc++/libgcc_s/libatomic that the clang-built binaries and
  # the prebuilt OpenSSL link against.
  ccLib = gcc.cc.lib;

  # Libraries the prebuilt helper binaries (pia-openvpn, pia-wireguard-go,
  # pia-unbound, pia-hnsd, pia-ss-local) and the bundled libssl/libcrypto need
  # beyond the ones bundled next to them in lib/.
  prebuiltLibs = [ glibc ccLib libcap_ng libnsl ];

  # Tools the daemon execs at runtime (see the NixOS module for the full story).
  runtimePath = lib.makeBinPath [
    iproute2 iptables procps psmisc kmod libcap
    coreutils gawk gnugrep gnused findutils e2fsprogs util-linux
  ];

  # Server-list JSON vendored in this repo so the build needs no network
  # (the rake build would otherwise fetch these from PIA's web API).
  serverData = ./server-data;
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pia-desktop";
  inherit version;

  # Pristine upstream source at the matching release tag. fetchLFS is required:
  # the helper binaries (pia-openvpn, pia-wireguard-go, pia-unbound, pia-hnsd,
  # pia-ss-local) and bundled OpenSSL ship as Git LFS objects under deps/, and a
  # plain tarball fetch would leave them as pointer files.
  src = fetchFromGitHub {
    owner = "pia-foss";
    repo = "desktop";
    rev = version; # upstream tag "3.7.2"
    fetchLFS = true;
    hash = "sha256-xqJDOQJPR4T+vi+kkd+YDfKnP7yEnFY2bjLV/vKfF0U=";
  };

  # Build-script adaptations for nixpkgs' toolchain/Qt, applied to upstream.
  # See ./patches for what each one does and why.
  patches = [
    ./patches/0001-llvm-ar-path-fallback.patch
    ./patches/0002-demote-werror-for-newer-qt.patch
    ./patches/0003-libnl3-include-and-serverdata-fixes.patch
    # The daemon authorizes client connections by exact-matching the peer's
    # /proc/<pid>/exe against {pia-client, piactl} in its bin dir. makeWrapper
    # renames the real GUI binaries to .<app>-unwrapped, so the wrapped client
    # is rejected and the GUI hangs on an endless connect spinner. Trust the
    # unwrapped siblings too (same read-only store bin dir, identical trust).
    ./patches/0004-authorize-wrapped-client-binaries.patch
    # Stop forwarding the daemon's (huge, /nix/store) PATH to the OpenVPN
    # up/down script via repeated --path args. On NixOS that produced enough
    # tokens that OpenVPN truncated the up/down command line, dropping the
    # trailing "--dns"/"--" terminator; the script then parsed OpenVPN's own
    # positional args and aborted under `set -e`, so every OpenVPN connection
    # failed right after the tunnel came up. The script now sets its own PATH
    # (see postPatch).
    ./patches/0005-linux-updown-no-path-forwarding.patch
  ];

  # The OpenVPN up/down script no longer receives a PATH from the daemon (see
  # patch 0005), so bake one in with the tools it calls (ip, awk, realpath,
  # lsattr, ...). Needs store paths, so it can't be a static patch.
  # (The daemon's hard-coded /bin/bash is handled by the NixOS module's mount
  # namespace, not here.)
  postPatch = ''
    substituteInPlace extras/openvpn/linux/updown.sh \
      --replace-fail 'function warn() {' \
        'export PATH="${runtimePath}:$PATH"

function warn() {'
  '';

  nativeBuildInputs = [
    ruby rake clang llvm git which patchelf makeWrapper
  ];

  # Avoid the rake build's network/bundler steps and pin version/timestamp.
  GITHUB_CI = "1";
  PIA_OVERRIDE_VERSION = "v${version}";
  SOURCE_DATE_EPOCH = "1";
  BRAND = "pia";
  VARIANT = "release";
  ARCHITECTURE = "x86_64";

  # rake passes `-target x86_64-linux-gnu`, which makes the nix cc-wrapper skip
  # NIX_CFLAGS_COMPILE injection, so we feed the GL headers via CPATH (honoured
  # by clang directly). libnl3's headers are pointed at explicitly.
  CPATH = "${libGL.dev}/include";
  LIBNL3_INCLUDE = "${libnl.dev}/include/libnl3";

  QTROOT = "${qtroot}/${qtVersion}";
  # Use the vendored server lists instead of fetching from the web.
  SERVER_DATA_DIR = serverData;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    rake stage
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    stage="out/pia_''${VARIANT}_''${ARCHITECTURE}/stage"
    mkdir -p "$out"
    cp -r "$stage/bin" "$stage/lib" "$stage/share" "$out/"

    # --- Make the prebuilt helper binaries run on NixOS -------------------
    interp="${glibc}/lib/ld-linux-x86-64.so.2"
    prebuiltRpath='$ORIGIN/../lib:${lib.makeLibraryPath prebuiltLibs}'
    for b in pia-openvpn pia-wireguard-go pia-unbound pia-hnsd pia-ss-local; do
      patchelf --set-interpreter "$interp" --set-rpath "$prebuiltRpath" "$out/bin/$b"
    done

    # The bundled libssl/libcrypto reference each other from the same dir.
    libRpath='$ORIGIN:${lib.makeLibraryPath [ glibc ccLib ]}'
    for so in "$out"/lib/libssl.so.3 "$out"/lib/libcrypto.so.3; do
      patchelf --set-rpath "$libRpath" "$so"
    done

    # --- Wrap the Qt GUI apps with plugin/qml/runtime paths ---------------
    # The built binaries already RPATH the Qt libs; they still need the QPA
    # platform plugins and QML imports at runtime.
    for app in pia-client pia-support-tool; do
      mv "$out/bin/$app" "$out/bin/.$app-unwrapped"
      makeWrapper "$out/bin/.$app-unwrapped" "$out/bin/$app" \
        --set QT_PLUGIN_PATH "${qtMerged}/plugins" \
        --set QML2_IMPORT_PATH "${qtMerged}/qml" \
        --set QML_IMPORT_PATH "${qtMerged}/qml" \
        --prefix PATH : "${runtimePath}"
    done

    runHook postInstall
  '';

  # The built binaries already carry correct RPATHs; don't let nix strip/shrink
  # break the $ORIGIN-relative ones we just set on the prebuilt helpers.
  dontPatchELF = true;
  dontStrip = true;

  passthru = { inherit qtroot qtMerged runtimePath; };

  meta = {
    description = "Private Internet Access VPN desktop client (Qt6), packaged for NixOS";
    homepage = "https://github.com/pia-foss/desktop";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "piactl";
  };
})
