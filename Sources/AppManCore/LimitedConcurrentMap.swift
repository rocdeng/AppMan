import Foundation

enum LimitedConcurrentMap {
    static func map<T, U>(
        _ values: [T],
        limit: Int,
        transform: @escaping @Sendable (T) throws -> U
    ) throws -> [U] {
        try map(values, limit: limit, onResult: { _ in }, transform: transform)
    }

    static func map<T, U>(
        _ values: [T],
        limit: Int,
        onResult: @escaping @Sendable (U) -> Void,
        transform: @escaping @Sendable (T) throws -> U
    ) throws -> [U] {
        guard values.count > 1, limit > 1 else {
            return try values.map { value in
                let result = try transform(value)
                onResult(result)
                return result
            }
        }

        let workerCount = min(limit, values.count)
        let lock = NSLock()
        var nextIndex = 0
        var results = Array<U?>(repeating: nil, count: values.count)
        var firstError: Error?

        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            while true {
                let index: Int?
                lock.lock()
                if firstError != nil || nextIndex >= values.count {
                    index = nil
                } else {
                    index = nextIndex
                    nextIndex += 1
                }
                lock.unlock()

                guard let index else {
                    return
                }

                do {
                    let result = try transform(values[index])
                    lock.lock()
                    results[index] = result
                    lock.unlock()
                    onResult(result)
                } catch {
                    lock.lock()
                    if firstError == nil {
                        firstError = error
                    }
                    lock.unlock()
                    return
                }
            }
        }

        if let firstError {
            throw firstError
        }

        return results.compactMap { $0 }
    }
}
