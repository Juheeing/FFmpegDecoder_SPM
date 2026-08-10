# FFmpeg iOS Patch – IPv4 Literal Fast-Path for tcp_open()

This repository provides a local patch for **FFmpeg 5.1** used in an iOS environment.

The patch modifies `libavformat/tcp.c` to improve connection stability when opening
RTSP/TCP streams to **IPv4 literal addresses** (e.g. `192.168.x.x`) on certain
carrier networks.

---

## Background

In some iOS network environments (observed on specific carrier base stations),
`getaddrinfo()` may return **IPv6 addresses synthesized via DNS64/NAT64**
even when the input is an IPv4 literal address.

When FFmpeg attempts to connect using such synthesized IPv6 addresses,
RTSP/TCP connections to local devices (RFC1918 addresses) may fail.

This issue was observed in:
- North America (e.g. Rogers)
- Australia (e.g. Telstra, specific base stations)

while not reproducible in typical domestic networks.

---

## Patch Overview

The patch introduces an **IPv4 literal fast-path** in `tcp_open()`:

- If the hostname is detected as an IPv4 literal using `inet_pton(AF_INET, ...)`
  - `getaddrinfo()` is bypassed
  - A direct `AF_INET` socket address is constructed and used
- For non-literal hostnames, the original `getaddrinfo()` behavior is preserved
- Memory ownership is handled safely to avoid invalid `freeaddrinfo()` calls

This approach:
- Avoids DNS64/NAT64 side effects
- Minimizes behavioral changes
- Preserves FFmpeg’s original resolver logic for non-literal hostnames

---

## Files

- `tcp_ipv4_literal_fastpath.patch`  
  Patch file against FFmpeg **5.1** (`libavformat/tcp.c`)

---

## How to Apply

From the FFmpeg source root:

```bash
patch -p1 < tcp_ipv4_literal_fastpath.patch
```

---

# Installation

## Swift Package Manager

```swift
dependencies: [
    .package(url: "https://bitbucket.org/tw-itdev/ffmpeg-decoder.git", .exact: "x.x.x")
]
```

## Manual

### 1. Add import

```swift
import FFmpegDecoder
```

### 2. Add delegate

```swift
@objc
protocol PlayerDelegate: AnyObject {
    @objc optional func playerController(state: PlayerState)
    @objc optional func playerController(currentTime: String, totalTime: String)
    @objc optional func playerController(videoSize: CGSize)
    @objc optional func playerController(finish error: Error?)
    @objc optional func playerController(seek: TimeInterval)
    @objc optional func playerController(progress: Float)
}
```

```swift
func receivedDecodedCIImage(_ ciImage: CIImage!) {
    // Receives decoded frame data as a CIImage and renders it to the UIImageView on the main thread.
}

func receivedCurrentTime(_ currentTime: Int64, duration: Int64) {
    // Receives current playback position and total duration in seconds, then forwards them to PlayerDelegate as formatted time strings.
}

func receivedSeekingState(_ success: Bool) {
    // Indicates whether a seek operation succeeded.
}

func receivedState(_ state: PlayerState) {
    // Receives the current playback state from the decoder and forwards it to PlayerDelegate.
}

func receivedVideoSize(_ videoSize: CGSize) {
    // Receives the video's resolution as a CGSize from the decoder.
}
```

## Delegates

- **`PlayerDelegate`** — An output delegate through which `PlayerUIView` propagates events to external consumers such as a UI layer or `ViewController`.
- **`DecoderDelegate`** — An input delegate through which `FFmpegDecoder` delivers decoded results into `PlayerUIView` internally.
