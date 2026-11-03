import Foundation

let mgnovVersion = "1.0.0"

enum Clock {
    /// Monotonic seconds.
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

/// A Double rounded to `digits` decimal places.
func num(_ x: Double, _ digits: Int = 1) -> Double {
    let p = pow(10.0, Double(digits))
    return (x * p).rounded() / p
}

func short(_ id: String) -> String {
    id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
      .replacingOccurrences(of: "com.apple.inputmethod.", with: "")
}

/// Run `f` on the main thread synchronously (the event tap and all agent state live there).
func onMain<T>(_ f: () -> T) -> T {
    if Thread.isMainThread { return f() }
    return DispatchQueue.main.sync(execute: f)
}

enum Log {
    private static let lock = NSLock()
    private static var ring: [String] = []
    private static var handle: FileHandle?
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return d }()

    /// Log file size at which it is rotated to `<name>.1` on the next start (one old file is kept).
    static let rotateAtBytes = 5 * 1024 * 1024
    private static var toStderr = true

    static func setup(file: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > rotateAtBytes {
            let old = file.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: file)
        handle?.seekToEndOfFile()
        // Under launchd stderr is a file too; writing the same lines there would double the disk use.
        toStderr = handle == nil || isatty(2) != 0
    }
    static func info(_ m: String) { write("INFO", m) }
    static func warn(_ m: String) { write("WARN", m) }
    static func error(_ m: String) { write("ERR ", m) }
    private static func write(_ level: String, _ m: String) {
        let line = "\(df.string(from: Date())) [\(level)] \(m)"
        lock.lock()
        ring.append(line)
        if ring.count > 3000 { ring.removeFirst(1000) }
        lock.unlock()
        if let d = (line + "\n").data(using: .utf8) {
            handle?.write(d)
            if toStderr { FileHandle.standardError.write(d) }
        }
    }
    static func recent(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring.suffix(n))
    }
}
