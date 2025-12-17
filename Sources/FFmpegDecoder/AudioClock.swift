//
//  AudioClock.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 12/17/2568 BE.
//

import Foundation

final class AudioClock {
    private(set) var current: Double = 0
    func update(_ t: Double) { current = t }
}
