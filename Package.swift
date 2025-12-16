// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

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
        // FFmpeg C 헤더 target
        .target(
            name: "FFmpegHeaders",
            path: "Sources/FFmpegHeaders",
            publicHeadersPath: "."
        ),
        // ObjC FFmpegDecoder target
        .target(
            name: "FFmpegDecoder",
            dependencies: ["FFmpegHeaders"],
            path: "Sources/FFmpegDecoder",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("../FFmpegHeaders") // 헤더 참조
            ],
            linkerSettings: [
                // 필수 시스템 라이브러리
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("lzma"),
                .linkedLibrary("resolv"),
                // FFmpeg 정적 라이브러리
                .unsafeFlags([
                    "-L\((#filePath as NSString).deletingLastPathComponent)/libs",
                    "-lavcodec",
                    "-lavfilter",
                    "-lavformat",
                    "-lavutil",
                    "-lswresample",
                    "-lswscale"
                ])
            ]
        )
    ]
)


