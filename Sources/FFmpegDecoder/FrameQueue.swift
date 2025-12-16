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

    func push(_ item: T) {
        lock.lock()
        if queue.count < maxSize {
            queue.append(item)
        }
        lock.unlock()
    }

    func pop() -> T? {
        lock.lock()
        let item = queue.isEmpty ? nil : queue.removeFirst()
        lock.unlock()
        return item
    }

    func clear() {
        lock.lock()
        queue.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        let c = queue.count
        lock.unlock()
        return c
    }
}


