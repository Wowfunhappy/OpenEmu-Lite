#!/bin/bash
set -e

cd "$(dirname "$0")"

CLEAN=0
TARGETS=()

for arg in "$@"; do
    case "$arg" in
        clean) CLEAN=1 ;;
        *) TARGETS+=("$arg") ;;
    esac
done

ALL_TARGETS=(openemu gambatte genesisplus nestopia snes9x mgba fake08)

for target in "${TARGETS[@]}"; do
    valid=0
    for t in "${ALL_TARGETS[@]}"; do
        [ "$target" = "$t" ] && valid=1
    done
    if [ "$valid" -eq 0 ]; then
        echo "Error: unknown target '$target'"
        echo "Valid targets: ${ALL_TARGETS[*]}"
        exit 1
    fi
done

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

find_app() {
    OE_APP=$(find "$DERIVED_DATA" -path "*/OpenEmu-*/Build/Products/Release/OpenEmu.app" -print -quit)
}

should_build() {
    [ ${#TARGETS[@]} -eq 0 ] && return 0
    for t in "${TARGETS[@]}"; do [ "$t" = "$1" ] && return 0; done
    return 1
}

# Clean a single Xcode target from the workspace's DerivedData
clean_xcode_target() {
    local project="$1" target="$2"
    local workspace_dd
    workspace_dd=$(find "$DERIVED_DATA" -maxdepth 1 -name "OpenEmu-*" -type d -print -quit)
    if [ -n "$workspace_dd" ]; then
        xcodebuild -project "$project" -target "$target" -configuration Release \
            -derivedDataPath "$workspace_dd" clean
    else
        xcodebuild -project "$project" -target "$target" -configuration Release clean
    fi
}

# Clean phase
if [ "$CLEAN" -eq 1 ]; then
    if [ ${#TARGETS[@]} -eq 0 ]; then
        echo "=== Cleaning OpenEmu workspace ==="
        xcodebuild -workspace OpenEmu.xcworkspace -scheme "Build All" clean
        (cd FAKE08 && make clean)
    else
        for target in "${TARGETS[@]}"; do
            echo "=== Cleaning $target ==="
            case "$target" in
                openemu)     clean_xcode_target OpenEmu/OpenEmu.xcodeproj OpenEmu ;;
                gambatte)    clean_xcode_target Gambatte/Gambatte.xcodeproj Gambatte ;;
                genesisplus) clean_xcode_target GenesisPlus/GenesisPlus.xcodeproj GenesisPlus ;;
                nestopia)    clean_xcode_target Nestopia/Nestopia.xcodeproj Nestopia ;;
                snes9x)      clean_xcode_target SNES9x/SNES9x.xcodeproj SNES9x ;;
                mgba)        clean_xcode_target mGBA/mGBA.xcodeproj mGBA ;;
                fake08)      (cd FAKE08 && make clean) ;;
            esac
        done
    fi
fi

# Build phase — use "Build All" for Xcode targets (incremental; only cleaned targets rebuild)
if should_build openemu || should_build gambatte || should_build genesisplus \
    || should_build nestopia || should_build snes9x || should_build mgba; then
    echo "=== Building OpenEmu workspace ==="
    xcodebuild -workspace OpenEmu.xcworkspace -scheme "Build All" build
fi

if should_build fake08; then
    find_app
    if [ -z "$OE_APP" ]; then
        echo "Error: OpenEmu.app not found in DerivedData. Build openemu first."
        exit 1
    fi
    echo "=== Building FAKE08 core ==="
    (cd FAKE08 && make)
    echo "=== Installing FAKE08 core ==="
    rm -rf "$OE_APP/Contents/PlugIns/Cores/FAKE08.oecoreplugin"
    cp -R FAKE08/FAKE08.oecoreplugin "$OE_APP/Contents/PlugIns/Cores/FAKE08.oecoreplugin"
fi

find_app
echo "=== Done ==="
echo "$OE_APP"
