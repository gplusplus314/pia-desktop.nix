# Builds a Qt root laid out the way PIA's rake build system (rake/model/qt.rb)
# expects: a directory whose basename is the Qt version (6.X.Y), containing a
# `gcc_64` toolchain subdir with the usual bin/ libexec/ lib/ include/ mkspecs/
# qml/ plugins/ tree. nixpkgs splits Qt across many store paths, so we merge the
# modules we need into one tree with symlinkJoin and expose it under that layout.
{ lib, qt6, icu, symlinkJoin, runCommand }:
let
  qt = qt6;
  version = qt.qtbase.version; # e.g. 6.10.2

  # All Qt modules the client, daemon and support tool compile/link against or
  # load at runtime.
  modules = [
    qt.qtbase
    qt.qtdeclarative
    qt.qttools
    qt.qtsvg
    qt.qtwayland
    qt.qtshadertools
    qt.qt5compat
    qt.qtimageformats
    # Qt links the system ICU; PIA's deploy logic (rake/product/linux.rb) and
    # the runtime closure both expect libicu*.so next to the Qt libs.
    icu
  ];

  merged = symlinkJoin {
    name = "pia-qt-merged-${version}";
    paths = modules;
  };
in
runCommand "pia-qtroot-${version}" { passthru = { inherit version merged modules; }; } ''
  mkdir -p "$out/${version}"
  ln -s ${merged} "$out/${version}/gcc_64"
''
