//
//  FrameQueue.swift
//  FFmpegDecoder
//
//  Created by 김주희 on 12/17/2568 BE.
//

import Foundation

final class FrameQueue<T> {
    private var queue: [T] = []
    private let lock = NSLock()
    let maxSize: Int

    init(maxSize: Int) {
        self.maxSize = maxSize
    }

    @discardableResult
    func push(_ item: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if queue.count >= maxSize { return false }
        queue.append(item)
        return true
    }

    func pop() -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    func clear(_ free: (T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        for item in queue { free(item) }
        queue.removeAll()
    }
    
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }
}


