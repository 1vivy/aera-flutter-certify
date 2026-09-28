#!/usr/bin/env bash
# Build and run this app for AERA Recovery.
#
#   tool/aera.sh sim [simulator options]   run it on this PC in AERA's bridge
#   tool/aera.sh package                   build build/aera/<name>-<version>.aerap
#   tool/aera.sh fetch                     only download the kits
#
# The kits come from github.com/1vivy/aera-flutter-embedder releases and must
# match your Flutter release. Set AERA_KIT_DIR to a folder holding the .tar.xz files to skip the
# download. `sim` passes its options to aera-host-sim, for example
# `--until 5000 --tap 180,350@1000 --save-at 3000`.
#
# AERA_RENDERER picks how the app draws: gl (default, Skia on OpenGL ES),
# vulkan (Skia on Vulkan) or impeller (Impeller on Vulkan). `package` bakes
# it into the .aerap and adds it to the file name when it is not gl.
#
# AERA_MODE picks the build `package` makes: release (default; AOT-compiled
# Dart on a release engine), profile, or debug (JIT, like `sim`). Modes other
# than release are added to the file name.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
crate=aera_app_core
out=build/aera
renderer=${AERA_RENDERER:-gl}
case $renderer in gl|vulkan|impeller) ;; *) echo "AERA_RENDERER must be gl, vulkan or impeller" >&2; exit 2 ;; esac
mode=${AERA_MODE:-release}
case $mode in debug|profile|release) ;; *) echo "AERA_MODE must be release, profile or debug" >&2; exit 2 ;; esac

flutter_version=$(flutter --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')
kits=.aera/$flutter_version
release=${AERA_KIT_URL:-https://github.com/1vivy/aera-flutter-embedder/releases/download/flutter-$flutter_version}

manifest() { python3 -c "import json; print(json.load(open('aera.json'))['$1'])"; }

fetch_kit() { # kit-name -> extracted directory
    local name=$1 dir=$kits/$1
    if [ ! -f "$dir/flutter-version" ]; then
        local file=aera-flutter-$name-$flutter_version.tar.xz
        mkdir -p "$kits"
        if [ -n "${AERA_KIT_DIR:-}" ] && [ -f "$AERA_KIT_DIR/$file" ]; then
            cp "$AERA_KIT_DIR/$file" "$kits/$file"
        else
            echo "Downloading $file" >&2
            curl -fL --retry 3 -o "$kits/$file" "$release/$file" || {
                echo "No $name kit for Flutter $flutter_version. Use the Flutter release a kit exists for." >&2
                exit 1
            }
        fi
        rm -rf "$dir.new" && mkdir -p "$dir.new"
        tar -C "$dir.new" -xJf "$kits/$file"
        rm -f "$kits/$file"
        mv "$dir.new" "$dir"
    fi
    if [ "$(cat "$dir/flutter-version")" != "$flutter_version" ]; then
        echo "$dir was made for Flutter $(cat "$dir/flutter-version"), not $flutter_version" >&2
        exit 1
    fi
    echo "$dir"
}

# The app can show which build it is: String.fromEnvironment('AERA_APP_VERSION'),
# 'AERA_APP_BUILD' (commit, time and mode) and 'AERA_RENDERER'.
defines() { # mode
    local commit
    commit=$(git rev-parse --short HEAD 2>/dev/null || echo local)
    echo "AERA_APP_VERSION=$(manifest version)"
    echo "AERA_APP_BUILD=$commit $(date -u +%Y-%m-%dT%H:%MZ) $1"
    echo "AERA_RENDERER=$renderer"
}

bundle() { # debug bundle in build/flutter_assets
    local args=()
    while IFS= read -r define; do args+=("--dart-define=$define"); done < <(defines debug)
    flutter build bundle --debug "${args[@]}" >&2
}

case ${1:-} in
fetch)
    fetch_kit runtime-arm64 >/dev/null
    fetch_kit simkit-x64 >/dev/null
    [ "$mode" = debug ] || fetch_kit engine-arm64-$mode >/dev/null
    ;;

sim)
    shift
    kit=$(fetch_kit simkit-x64)
    bundle
    cargo build --release --manifest-path rust/Cargo.toml >&2
    stage=$out/sim
    rm -rf "$stage" && mkdir -p "$stage/usr/lib" "$stage/usr/share/flutter"
    cp "$kit/usr/lib/libflutter_engine.so" "rust/target/release/lib$crate.so" "$stage/usr/lib/"
    cp "$kit/usr/share/flutter/icudtl.dat" "$stage/usr/share/flutter/"
    cp -r build/flutter_assets "$stage/usr/share/flutter/flutter_assets"
    mkdir -p "$out/frames"
    # llvmpipe's threads crash under the embedder on some PCs; softpipe is
    # slow but steady. On the phone AERA uses Zink on the GPU instead.
    AERA_FLUTTER_RENDERER=$renderer GALLIUM_DRIVER=${GALLIUM_DRIVER:-softpipe} "$kit/bin/aera-host-sim" \
        --worker "$kit/bin/aera-browser-worker" --root "$stage" --out "$out/frames" "$@"
    echo "Frames are in $out/frames" >&2
    ;;

package)
    kit=$(fetch_kit runtime-arm64)
    if [ "$mode" = debug ]; then
        bundle
        assets=build/flutter_assets
    else
        engine=$(fetch_kit engine-arm64-$mode)
        mapfile -t app_defines < <(defines "$mode")
        tool/build_aot_app.sh "$mode" "$engine" build/aera/aot "${app_defines[@]}" >&2
        assets=build/aera/aot/flutter_assets
    fi
    cargo build --release --target aarch64-unknown-linux-gnu --manifest-path rust/Cargo.toml >&2
    library=rust/target/aarch64-unknown-linux-gnu/release/lib$crate.so
    stage=$out/stage
    rm -rf "$stage" && mkdir -p "$out" && cp -a "$kit" "$stage"
    rm -f "$stage/flutter-version" "$stage/engine-revision"
    rm -rf "$stage/usr/share/flutter/flutter_assets"
    cp -r "$assets" "$stage/usr/share/flutter/flutter_assets"
    cp "$library" "$stage/usr/lib/"
    if [ "$mode" != debug ]; then
        # The embedder loads libapp.so when the engine runs AOT code.
        cp "$engine/usr/lib/libflutter_engine.so" build/aera/aot/libapp.so "$stage/usr/lib/"
        cp "$engine/usr/share/flutter/icudtl.dat" "$stage/usr/share/flutter/"
    fi
    echo "$renderer" > "$stage/usr/share/flutter/renderer"
    # Anything the Rust library links must already be in the runtime.
    readelf=$(command -v aarch64-linux-gnu-readelf || command -v readelf)
    for lib in $("$readelf" -d "$library" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
        if [ ! -e "$stage/usr/lib/$lib" ] && [ ! -e "$stage/lib/$lib" ]; then
            echo "lib$crate.so needs $lib, which the AERA runtime does not ship" >&2
            exit 1
        fi
    done
    name=$(manifest name) version=$(manifest version) suffix=
    [ "$mode" = release ] || suffix=-$mode
    [ "$renderer" = gl ] || suffix=$suffix-$renderer
    python3 tool/make_aerap.py --stage "$stage" --name "$name" --version "$version" \
        --description "$(manifest description)" --out "$out/${name// /-}-$version$suffix.aerap"
    ;;

*)
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
