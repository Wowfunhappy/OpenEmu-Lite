#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Building OpenEmu workspace ==="
xcodebuild -workspace OpenEmu.xcworkspace -scheme "Build All" build

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
OE_APP=$(find "$DERIVED_DATA" -path "*/OpenEmu-*/Build/Products/Release/OpenEmu.app" -print -quit)

echo "=== Building FAKE08 core ==="
cd FAKE08
make

echo "=== Installing FAKE08 core ==="
rm -rf "$OE_APP/Contents/PlugIns/Cores/FAKE08.oecoreplugin"
cp -R FAKE08.oecoreplugin "$OE_APP/Contents/PlugIns/Cores/FAKE08.oecoreplugin"

echo "=== Done ==="
echo "$OE_APP"
