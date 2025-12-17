//
//  PlaybackClock.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 12/17/2568 BE.
//

import Foundation
import QuartzCore
import AVFAudio

final class PlaybackClock {

    private var startTime: CFTimeInterval = 0
    private var pausedTime: CFTimeInterval = 0
    private var accumulatedPause: CFTimeInterval = 0
    private var isPaused = true
    private var audioTime: Double = 0

    // MARK: - Control

    func reset() {
        startTime = CACurrentMediaTime()
        pausedTime = 0
        accumulatedPause = 0
        audioTime = 0
        isPaused = true
    }

    func play() {
        guard isPaused else { return }
        startTime = CACurrentMediaTime()
        isPaused = false
    }

    func pause() {
        guard !isPaused else { return }
        pausedTime = CACurrentMediaTime()
        isPaused = true
    }

    // MARK: - Time

    /// Audio render loop에서 호출
    func updateFromAudio(_ buffer: AVAudioPCMBuffer) {
        let duration =
            Double(buffer.frameLength) /
            buffer.format.sampleRate

        audioTime += duration
    }

    /// Video render loop에서 사용
    func currentTime() -> Double {
        return audioTime
    }
}
