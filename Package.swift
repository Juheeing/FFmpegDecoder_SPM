// swift-tools-version: 6.1

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

        // ObjC 브릿지 타겟 (va_list 로그 콜백 등 Swift에서 구현 불가한 C 코드)
        .target(
            name: "FFmpegCBridge",
            dependencies: [
                "FFmpegHeaders",
                "libavcodec", "libavfilter", "libavformat",
                "libavutil", "libswresample", "libswscale"
            ],
            path: "Sources/FFmpegCBridge",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("../FFmpegHeaders")
            ]
        ),

        // Swift FFmpegDecoder 타겟
        .target(
            name: "FFmpegDecoder",
            dependencies: [
                "FFmpegHeaders",
                "FFmpegCBridge",
                "libavcodec", "libavfilter", "libavformat",
                "libavutil", "libswresample", "libswscale"
            ],
            path: "Sources/FFmpegDecoder",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),

        // 테스트 타겟
        .testTarget(
            name: "FFmpegDecoderTests",
            dependencies: ["FFmpegDecoder"]
        )
    ]
)
