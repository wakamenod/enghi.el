// record-window.swift --- Record one window, whatever is in front of it
//
//   record-window --title "ecc demo" --out demo/x.mp4 [--fps 10] [--width 1456]
//   record-window --title "ecc demo" --shot /tmp/x.png
//   record-window --list
//
// `--shot' is one picture rather than a recording, and is how a window
// that has stopped redrawing is looked at: a stream only hands over a
// frame when the content changes, so a frozen window records nothing at
// all.  `screencapture -l<id>' cannot do it -- the window-server way of
// taking one window died with the older macOS releases (2026-09-17).
//
// ScreenCaptureKit composites a window's own content, so the recording
// is of that window alone: nothing that covers it is in the picture, the
// window does not have to be in front, and two of these can run at once
// without recording each other.  `ffmpeg -f avfoundation' can do none of
// that -- it records a screen, and demo/record.sh used to crop a
// rectangle out of it and hold the frame inside that rectangle by force.
//
// A window that is MINIMISED is not drawn and so cannot be recorded; one
// that is covered, on another Space, or off the edge of the screen, can.
//
// The process needs Screen Recording permission (System Settings ->
// Privacy & Security -> Screen Recording) -- the same permission the
// ffmpeg recording needed, granted to whatever runs this.
//
// Stops on SIGINT or SIGTERM, and finishes writing the file before it
// exits, so `kill -INT' is how the recorder ends it.
//
// Built and used by demo/record.sh; see demo/README.md.

import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Arguments

struct Options {
    var title = "ecc demo"
    var app: String? = "Emacs"
    var out = "window.mp4"
    var fps: Int = 10
    var width: Int = 1456
    var list = false
    var shot: String?
}

func parseArguments() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let argument = arguments.first {
        arguments.removeFirst()
        func value() -> String {
            guard let next = arguments.first else {
                FileHandle.standardError.write("\(argument) needs a value\n".data(using: .utf8)!)
                exit(2)
            }
            arguments.removeFirst()
            return next
        }
        switch argument {
        case "--title": options.title = value()
        case "--app": options.app = value()
        case "--out": options.out = value()
        case "--fps": options.fps = Int(value()) ?? 10
        case "--width": options.width = Int(value()) ?? 1456
        case "--list": options.list = true
        case "--shot": options.shot = value()
        default:
            FileHandle.standardError.write("unknown argument: \(argument)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return options
}

func note(_ message: String) {
    FileHandle.standardError.write("record-window: \(message)\n".data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: - Writing the file

// The stream hands frames over on a queue of its own; the writer is
// touched only there and in `finish', which waits for it.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "record-window.frames")
    private var started = false
    private var frames = 0
    private var last: CMSampleBuffer?
    private var lastTime: CMTime = .invalid
    private var reported = false
    private var drewSinceTick = false
    private let step: CMTime

    /// Called when the stream stops of its own accord.
    var onStop: (() -> Void)?

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        step = CMTime(value: 1, timescale: CMTimeScale(fps))
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "record-window", code: 1)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(buffer),
              CMSampleBufferGetNumSamples(buffer) > 0 else { return }
        // A frame the window did not redraw carries no image: it says
        // only that nothing changed.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              CMSampleBufferGetImageBuffer(buffer) != nil else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if !started {
            writer.startSession(atSourceTime: time)
            started = true
            lastTime = time
        }
        guard input.isReadyForMoreMediaData else { return }
        // Strictly forward, always.  A frame that does not land after
        // the one in front of it fails the writer for good: every
        // append after that is refused, and the file it finishes has no
        // index and will not open (2026-09-17).
        if CMTimeCompare(time, lastTime) > 0 {
            if input.append(buffer) {
                frames += 1
                last = buffer
                lastTime = time
                drewSinceTick = true
            } else {
                report("a frame was refused")
            }
        } else {
            append(buffer, at: CMTimeAdd(lastTime, step))
        }
    }

    /// Append the image of BUFFER at TIME, which the caller has made
    /// sure is later than anything written so far.
    private func append(_ buffer: CMSampleBuffer, at time: CMTime) {
        guard input.isReadyForMoreMediaData,
              let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var format: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescriptionOut: &format) == noErr,
              let format else { return }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescription: format, sampleTiming: &timing,
                sampleBufferOut: &copy) == noErr,
              let copy else { return }
        if input.append(copy) {
            frames += 1
            last = copy
            lastTime = time
            drewSinceTick = true
        } else {
            report("a repeat was refused")
        }
    }

    /// Say what the writer thinks, once.
    private func report(_ what: String) {
        guard !reported else { return }
        reported = true
        note("\(what): status \(writer.status.rawValue), "
             + (writer.error?.localizedDescription ?? "no error"))
    }

    /// Write the last frame again, so that a window which is not
    /// redrawing is still time in the video rather than a gap.  A stream
    /// hands a frame over only when the content changes, and a
    /// demonstration holds still for seconds at a time.
    ///
    /// The time is counted on from what was last written rather than
    /// read off a clock: the host clock and the stream's are not the
    /// same timebase, and a repeat that lands before the frame in front
    /// of it takes the recording down with it.
    func repeatLastFrame() {
        queue.async { [self] in
            guard started, let buffer = last else { return }
            // Only where the window drew nothing: a repeat on top of a
            // real frame would put two frames where one second of time
            // belongs, and the video comes out at half speed.
            if drewSinceTick {
                drewSinceTick = false
                return
            }
            append(buffer, at: CMTimeAdd(lastTime, step))
            drewSinceTick = false
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The window went away -- the application quit, or something
        // else took a capture of it.  What was recorded up to here is
        // worth keeping, and a writer left open writes no index at all.
        note("the stream stopped: \(error.localizedDescription)")
        onStop?()
    }

    func finish(_ done: @escaping (Int) -> Void) {
        queue.async { [self] in
            input.markAsFinished()
            let written = frames
            writer.finishWriting { done(written) }
        }
    }

    var outputQueue: DispatchQueue { queue }
}

// MARK: - Finding the window

func windows(_ options: Options) async throws -> [SCWindow] {
    // `onScreenWindowsOnly: false' is the point of this: a window that
    // is covered is still a window to record.
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
    return content.windows.filter { window in
        guard let title = window.title, !title.isEmpty else { return false }
        if let app = options.app,
           window.owningApplication?.applicationName != app { return false }
        return title.contains(options.title)
    }
}

// MARK: - Running

@main
struct Main {
    static func main() async {
        let options = parseArguments()

        // Taking frames needs a connection to the window server, and a
        // program started from a shell has none: `SCStream.startCapture'
        // dies in CGS_REQUIRE_INIT without this.  `.prohibited' keeps it
        // out of the Dock and out of the way of whatever is in front.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        if options.list {
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            for window in content?.windows ?? [] {
                let app = window.owningApplication?.applicationName ?? "?"
                let title = window.title ?? ""
                if title.isEmpty { continue }
                print("\(window.windowID)\t\(app): \(title)  \(Int(window.frame.width))x\(Int(window.frame.height))")
            }
            exit(0)
        }

        let found: [SCWindow]
        do {
            found = try await windows(options)
        } catch {
            fail("""
                cannot see the windows: \(error.localizedDescription)
                Screen Recording permission is what this usually is: System \
                Settings -> Privacy & Security -> Screen Recording, for whatever \
                runs this.
                """)
        }
        guard let window = found.first else {
            fail("no window of \(options.app ?? "any application") is called \(options.title)")
        }

        if let path = options.shot {
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width) * 2
            configuration.height = Int(window.frame.height) * 2
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 6
            configuration.capturesAudio = false
            configuration.showsCursor = false
            configuration.scalesToFit = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration)
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    fail("cannot encode the picture")
                }
                try data.write(to: URL(fileURLWithPath: path))
                note("wrote \(path)")
                exit(0)
            } catch {
                fail("cannot take the picture: \(error.localizedDescription)")
            }
        }

        // H.264 wants even numbers, and the window is measured in points:
        // two pixels to the point on this kind of display, and the capture
        // is taken at that scale and then written at --width.
        let aspect = window.frame.height / window.frame.width
        let width = max(2, options.width - options.width % 2)
        let height = max(2, Int((Double(width) * aspect).rounded()) & ~1)

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1,
                                                    timescale: CMTimeScale(options.fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.queueDepth = 6
        configuration.capturesAudio = false

        let recorder: Recorder
        do {
            recorder = try Recorder(url: URL(fileURLWithPath: options.out),
                                    width: width, height: height,
                                    fps: options.fps)
        } catch {
            fail("cannot write \(options.out): \(error.localizedDescription)")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration,
                              delegate: recorder)
        do {
            try stream.addStreamOutput(recorder, type: .screen,
                                       sampleHandlerQueue: recorder.outputQueue)
        } catch {
            fail("cannot take the frames: \(error.localizedDescription)")
        }

        // The signal handlers are set to ignore and the work done on a
        // dispatch source: a Swift closure is not what a C signal handler
        // may run.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let stopping = DispatchQueue(label: "record-window.stop")
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: stopping)
            source.setEventHandler {
                Task {
                    try? await stream.stopCapture()
                    recorder.finish { frames in
                        if frames == 0 {
                            // An mp4 with no frames has no index and
                            // will not open at all; saying so beats
                            // leaving one to be found later.  A screen
                            // that went to sleep or a Mac that locked
                            // itself is what this usually means: a
                            // window that is not drawn hands nothing
                            // over (2026-09-17).
                            try? FileManager.default.removeItem(
                                atPath: options.out)
                            note("""
                                nothing was drawn, so nothing was \
                                recorded -- a locked Mac or a sleeping \
                                display does that.  No file was written.
                                """)
                            exit(3)
                        }
                        note("wrote \(frames) frames to \(options.out)")
                        exit(0)
                    }
                }
            }
            source.resume()
            sources.append(source)
        }

        // The recording is finished by whichever comes first: a signal,
        // or the stream stopping because the window went away.
        recorder.onStop = {
            recorder.finish { frames in
                if frames == 0 {
                    try? FileManager.default.removeItem(atPath: options.out)
                    note("nothing had been drawn, so there was nothing to keep")
                    exit(3)
                }
                note("kept \(frames) frames in \(options.out)")
                exit(0)
            }
        }

        do {
            try await stream.startCapture()
        } catch {
            fail("cannot record that window: \(error.localizedDescription)")
        }
        let tick = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        tick.schedule(deadline: .now() + 1.0,
                      repeating: 1.0 / Double(options.fps))
        tick.setEventHandler { recorder.repeatLastFrame() }
        tick.resume()

        note("recording \(options.title) at \(width)x\(height)")

        // Everything from here happens on the stream's queue and on the
        // signal source; this only keeps the process alive.
        while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }
}
