// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FFmpegDecoder",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "FFmpegDecoder",
            targets: ["FFmpegDecoder"]
        )
    ],
    targets: [
        // FFmpeg 바이너리 타겟
        .binaryTarget(name: "libavcodec",    path: "libs/libavcodec.xcframework"),
        .binaryTarget(name: "libavfilter",   path: "libs/libavfilter.xcframework"),
        .binaryTarget(name: "libavformat",   path: "libs/libavformat.xcframework"),
        .binaryTarget(name: "libavutil",     path: "libs/libavutil.xcframework"),
        .binaryTarget(name: "libswresample", path: "libs/libswresample.xcframework"),
        .binaryTarget(name: "libswscale",    path: "libs/libswscale.xcframework"),

        // FFmpeg 헤더 타겟
        .target(
            name: "FFmpegHeaders",
            path: "Sources/FFmpegHeaders",
            publicHeadersPath: "."
        ),

        // ObjC FFmpegDecoder 타겟
        .target(
            name: "FFmpegDecoder",
            dependencies: [
                "FFmpegHeaders",
                "libavcodec", "libavfilter", "libavformat",
                "libavutil", "libswresample", "libswscale"
            ],
            path: "Sources/FFmpegDecoder",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("../FFmpegHeaders")
            ],
            linkerSettings: [
                // 시스템 라이브러리 (unsafeFlags 없이 가능)
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("lzma"),
                .linkedLibrary("resolv")
            ]
        )
    ]
)


