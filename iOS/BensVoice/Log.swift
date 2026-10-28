import Foundation

/// Appends timestamped lines to Documents/bensvoice.log, so problems on the phone can be read back over USB.
enum Log {
    private static let url = URL.documentsDirectory.appending(path: "bensvoice.log")
    private static let queue = DispatchQueue(label: "bensvoice.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
