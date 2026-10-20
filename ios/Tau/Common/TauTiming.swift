import UIKit
import Display

/// Performance logging for development, on with the TAU_TIMING environment variable: row layout costs, and frames
/// that missed the display's refresh, appended to /tmp/tau-timing.log (the simulator writes the Mac's /tmp).
enum TauTiming {
    static let isEnabled = ProcessInfo.processInfo.environment["TAU_TIMING"] != nil
    private static let queue = DispatchQueue(label: "tau.timing")

    static func log(_ line: String) {
        guard self.isEnabled else {
            return
        }
        let stamped = String(format: "%.3f ", CACurrentMediaTime()) + line + "\n"
        self.queue.async {
            if let handle = FileHandle(forWritingAtPath: "/tmp/tau-timing.log") {
                handle.seekToEndOfFile()
                handle.write(stamped.data(using: .utf8)!)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: "/tmp/tau-timing.log", contents: stamped.data(using: .utf8))
            }
        }
    }

    /// Once a second: frames drawn, and frames that took longer than 1.5 refresh intervals.
    static func startFrameMonitor() {
        guard self.isEnabled, self.monitor == nil else {
            return
        }
        let monitor = FrameMonitor()
        self.monitor = monitor
        monitor.start()
    }

    private static var monitor: FrameMonitor?

    private final class FrameMonitor: NSObject {
        private var link: CADisplayLink?
        private var last = CACurrentMediaTime()
        private var windowStart = CACurrentMediaTime()
        private var frames = 0
        private var slow = 0
        private var worst = 0.0

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
            let maxFps = Float(UIScreen.main.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: maxFps, maximum: maxFps, preferred: maxFps)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            let delta = now - self.last
            self.last = now
            self.frames += 1
            if delta > (link.targetTimestamp - link.timestamp) * 1.5 + 0.001 {
                self.slow += 1
            }
            self.worst = max(self.worst, delta)
            if now - self.windowStart >= 1.0 {
                TauTiming.log(String(format: "frames %d slow %d worst %.1f ms", self.frames, self.slow, self.worst * 1000.0))
                self.windowStart = now
                self.frames = 0
                self.slow = 0
                self.worst = 0.0
            }
        }
    }
}
