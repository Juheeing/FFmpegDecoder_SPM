//
//  PlaybackClock.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 12/17/2568 BE.
//

import Foundation
import QuartzCore

final class PlaybackClock {
    private var startTime: Double = 0
    private var pauseTime: Double = 0
    private(set) var isPaused = true

    func play() {
        startTime = CACurrentMediaTime() - pauseTime
        isPaused = false
    }

    func pause() {
        pauseTime = currentTime()
        isPaused = true
    }

    func currentTime() -> Double {
        isPaused
            ? pauseTime
            : CACurrentMediaTime() - startTime
    }

    func reset() {
        startTime = 0
        pauseTime = 0
        isPaused = true
    }
}
