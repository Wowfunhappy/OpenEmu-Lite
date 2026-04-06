#!/bin/bash
set -e

cd "$(dirname "$0")"

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        clean) CLEAN=1 ;;
    esac
done

if [ "$CLEAN" -eq 1 ]; then
    echo "=== Cleaning OpenEmu workspace ==="
    xcodebuild -workspace OpenEmu.xcworkspace -scheme "Build All" clean
fi

echo "=== Building OpenEmu workspace ==="
xcodebuild -workspace OpenEmu.xcworkspace -scheme "Build All" build

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
OE_APP=$(find "$DERIVED_DATA" -path "*/OpenEmu-*/Build/Products/Release/OpenEmu.app" -print -quit)

echo "=== Building FAKE08 core ==="
cd FAKE08
if [ "$CLEAN" -eq 1 ]; then
    make clean
fi
make

echo "=== Installing FAKE08 core ==="
rm -rf "$OE_APP/Contents/PlugIns/Cores/FAKE08.oecoreplugin"
cp -R FAKE08.oecoreplugin "$OE_APP/Contents/PlugIns/Cores/FAKE08.oecoreplugin"

echo "=== Done ==="
echo "$OE_APP"
