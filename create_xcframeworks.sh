#!/bin/bash

LIBS_DIR="libs"
TEMP_DIR=".xcframework_temp"

LIBRARIES=(
    "libavcodec"
    "libavfilter"
    "libavformat"
    "libavutil"
    "libswresample"
    "libswscale"
)

mkdir -p "$TEMP_DIR"

for LIB in "${LIBRARIES[@]}"; do
    echo "Processing $LIB..."

    mkdir -p "$TEMP_DIR/$LIB/device"
    mkdir -p "$TEMP_DIR/$LIB/simulator_x86"   # ✅ 이 줄이 빠져있었음
    mkdir -p "$TEMP_DIR/$LIB/simulator"

    lipo "$LIBS_DIR/$LIB.a" -extract arm64 -output "$TEMP_DIR/$LIB/device/$LIB.a"
    lipo "$LIBS_DIR/$LIB.a" -extract x86_64 -output "$TEMP_DIR/$LIB/simulator_x86/$LIB.a"

    cp "$TEMP_DIR/$LIB/simulator_x86/$LIB.a" "$TEMP_DIR/$LIB/simulator/$LIB.a"

    xcodebuild -create-xcframework \
        -library "$TEMP_DIR/$LIB/device/$LIB.a" \
        -library "$TEMP_DIR/$LIB/simulator/$LIB.a" \
        -output "$LIBS_DIR/$LIB.xcframework"

    echo "✅ $LIB.xcframework created"
done

rm -rf "$TEMP_DIR"

echo "🎉 All xcframeworks created!"
