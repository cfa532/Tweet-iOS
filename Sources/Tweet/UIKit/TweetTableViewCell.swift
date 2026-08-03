//
//  TweetTableViewCell.swift
//  Tweet
//
//  Pure UIKit tweet cell — no UIHostingController.
//  Uses TweetCellContentView for layout and data binding.
//
import UIKit
import Darwin

/// TEMPORARY (Aug 2026 scroll-stall investigation) — samples the MAIN THREAD's call stack
/// whenever it stops servicing its run loop for longer than `thresholdSeconds`.
///
/// A run-loop observer on the main thread stamps a heartbeat on every run-loop activity.
/// A background thread watches that heartbeat; when it goes stale the main thread is
/// mid-callback (exactly the state that produces a scroll hitch), so we suspend it just
/// long enough to copy its frame-pointer chain, resume it, and symbolicate afterwards.
///
/// Safety: while the main thread is suspended we ONLY read memory via vm_read_overwrite
/// (which returns an error rather than trapping on a bad address) and never allocate —
/// allocating here would deadlock on the malloc lock the suspended thread may hold.
/// Symbolication (dladdr, String) happens after thread_resume.
final class MainThreadStallSampler: @unchecked Sendable {
    static let shared = MainThreadStallSampler()

    private var mainThreadPort: thread_t = 0
    private var lastHeartbeat = CFAbsoluteTimeGetCurrent()
    private let heartbeatLock = NSLock()
    private var didReportCurrentStall = false
    private var mainRunLoopIsIdle = false
    private var started = false
    private var thresholdSeconds: CFTimeInterval = 0.12

    /// Call from the main thread once at startup.
    func startIfNeeded(threshold: CFTimeInterval = 0.12) {
        guard Thread.isMainThread, !started else { return }
        started = true
        thresholdSeconds = threshold
        mainThreadPort = mach_thread_self()

        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            0
        ) { [weak self] _, activity in
            // beforeWaiting means the run loop is about to sleep with nothing to do; no
            // further observer callback fires until an event wakes it, so the heartbeat
            // legitimately goes stale. Without this the sampler reports every idle
            // moment as a stall and every stack is just mach_msg in __CFRunLoopRun.
            self?.beat(isGoingIdle: activity == .beforeWaiting)
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        Thread.detachNewThread { [weak self] in
            Thread.current.name = "MainThreadStallSampler"
            while let self, self.started {
                usleep(20_000)
                self.checkForStall()
            }
        }
        print("🩺 [STALL SAMPLER] started (threshold \(Int(threshold * 1000))ms)")
    }

    private func beat(isGoingIdle: Bool) {
        heartbeatLock.lock()
        lastHeartbeat = CFAbsoluteTimeGetCurrent()
        didReportCurrentStall = false
        mainRunLoopIsIdle = isGoingIdle
        heartbeatLock.unlock()
    }

    private func checkForStall() {
        heartbeatLock.lock()
        let elapsed = CFAbsoluteTimeGetCurrent() - lastHeartbeat
        let alreadyReported = didReportCurrentStall
        let isIdle = mainRunLoopIsIdle
        let shouldReport = elapsed > thresholdSeconds && !alreadyReported && !isIdle
        if shouldReport {
            didReportCurrentStall = true
        }
        heartbeatLock.unlock()

        guard shouldReport else { return }
        captureAndLogMainThreadStack(elapsedMs: elapsed * 1000)
    }

    // arm_thread_state64_t is not exposed to Swift by the iOS SDK, so the state is read
    // into a raw 64-bit register buffer. Layout of __darwin_arm_thread_state64:
    //   x[0...28] then fp, lr, sp, pc, then cpsr+pad (one 64-bit slot) = 34 words.
    private static let armThreadState64 = thread_state_flavor_t(6) // ARM_THREAD_STATE64
    private static let armThreadState64WordCount = 34
    private static let framePointerIndex = 29
    private static let linkRegisterIndex = 30
    private static let programCounterIndex = 32

    private func captureAndLogMainThreadStack(elapsedMs: Double) {
        guard mainThreadPort != 0 else { return }

        // Fixed-size buffers: no allocation while the main thread is suspended.
        var frames = [UInt64](repeating: 0, count: 48)
        var frameCount = 0
        var registers = [UInt64](repeating: 0, count: Self.armThreadState64WordCount)

        guard thread_suspend(mainThreadPort) == KERN_SUCCESS else { return }

        var stateCount = mach_msg_type_number_t(
            Self.armThreadState64WordCount * MemoryLayout<UInt64>.size / MemoryLayout<natural_t>.size
        )
        let stateResult = registers.withUnsafeMutableBufferPointer { buffer -> kern_return_t in
            buffer.baseAddress!.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { rebound in
                thread_get_state(mainThreadPort, Self.armThreadState64, rebound, &stateCount)
            }
        }

        if stateResult == KERN_SUCCESS {
            frames[0] = Self.stripPAC(registers[Self.programCounterIndex])
            frames[1] = Self.stripPAC(registers[Self.linkRegisterIndex])
            frameCount = 2

            var framePointer = registers[Self.framePointerIndex]
            while frameCount < frames.count, framePointer != 0 {
                var linkRegister: UInt64 = 0
                var nextFramePointer: UInt64 = 0
                guard Self.readWord(at: framePointer, into: &nextFramePointer),
                      Self.readWord(at: framePointer &+ 8, into: &linkRegister),
                      linkRegister != 0 else { break }
                frames[frameCount] = Self.stripPAC(linkRegister)
                frameCount += 1
                // Stacks grow downward: each caller's frame must sit at a higher address.
                guard nextFramePointer > framePointer else { break }
                framePointer = nextFramePointer
            }
        }

        thread_resume(mainThreadPort)

        // Symbolication is safe now that the main thread is running again.
        var lines: [String] = []
        for index in 0..<frameCount {
            let address = frames[index]
            guard address != 0, let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else { continue }
            var info = Dl_info()
            if dladdr(pointer, &info) != 0 {
                let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
                let image = info.dli_fname
                    .map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                lines.append("  \(index)  \(image)  \(symbol)")
            } else {
                lines.append("  \(index)  0x\(String(address, radix: 16))")
            }
        }

        guard !lines.isEmpty else { return }
        print("🩺 [MAIN THREAD STALL] blocked \(Int(elapsedMs))ms\n\(lines.joined(separator: "\n"))")
    }

    /// Clears arm64e pointer-authentication bits so dladdr can resolve the address.
    private static func stripPAC(_ address: UInt64) -> UInt64 {
        address & 0x0000_FFFF_FFFF_FFFF
    }

    /// Reads 8 bytes without trapping on an invalid address.
    private static func readWord(at address: UInt64, into value: inout UInt64) -> Bool {
        var outSize: vm_size_t = 0
        var scratch: UInt64 = 0
        let result = withUnsafeMutablePointer(to: &scratch) { destination -> kern_return_t in
            vm_read_overwrite(
                mach_task_self_,
                vm_address_t(address),
                vm_size_t(MemoryLayout<UInt64>.size),
                vm_address_t(bitPattern: destination),
                &outSize
            )
        }
        guard result == KERN_SUCCESS, outSize == UInt(MemoryLayout<UInt64>.size) else { return false }
        value = scratch
        return true
    }
}

// TEMPORARY (Jul 2026 fling-scroll stall investigation) — logs when a call on this
// instrumented path takes long enough to plausibly cause a dropped-frame/catch-up-jump
// scroll stall. Remove once the stall is root-caused.
enum StallLog {
    static let thresholdMs: Double = 4
    @inline(__always)
    static func measure<T>(_ label: String, _ extra: @autoclosure () -> String = "", _ block: () -> T) -> T {
        let start = CACurrentMediaTime()
        let result = block()
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        if elapsedMs >= thresholdMs {
            print("⏱️ [STALL] \(label) took \(String(format: "%.1f", elapsedMs))ms \(extra())")
        }
        return result
    }
}

class TweetTableViewCell: UITableViewCell {
    static let reuseIdentifier = "TweetTableViewCell"
    static let pinnedTweetsDividerHeight: CGFloat = 25

    let tweetContentView = TweetCellContentView()
    private let pinnedTweetsDivider = PinnedTweetsDividerView()
    private var currentTweetId: String?

    var onContentExpanded: (() -> Void)?
    var onContentDidChangeHeightAsync: (() -> Void)?
    var onRetweetUnavailable: ((String) -> Void)?

    // Padding constraints (updated per-configure to match list-level padding)
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var pinnedTweetsDividerHeightConstraint: NSLayoutConstraint!
    private var interfaceStyleTraitRegistration: UITraitChangeRegistration?

    /// Publicly accessible tweet ID for video orchestration
    var tweetId: String? {
        return currentTweetId
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCell()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCell() {
        selectionStyle = .none
        applyTheme()
        interfaceStyleTraitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: TweetTableViewCell, _) in
            cell.applyTheme()
        }

        tweetContentView.translatesAutoresizingMaskIntoConstraints = false
        pinnedTweetsDivider.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tweetContentView)
        contentView.addSubview(pinnedTweetsDivider)

        leadingConstraint = tweetContentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailingConstraint = tweetContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)

        let bottomConstraint = pinnedTweetsDivider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        // Use high priority (not required) so the estimated row height
        // (UIView-Encapsulated-Layout-Height) doesn't conflict during initial layout.
        // The cell will still self-size correctly.
        bottomConstraint.priority = .defaultHigh

        pinnedTweetsDividerHeightConstraint = pinnedTweetsDivider.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tweetContentView.topAnchor.constraint(equalTo: contentView.topAnchor),
            leadingConstraint,
            trailingConstraint,
            tweetContentView.bottomAnchor.constraint(equalTo: pinnedTweetsDivider.topAnchor),
            pinnedTweetsDivider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pinnedTweetsDivider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pinnedTweetsDividerHeightConstraint,
            bottomConstraint
        ])
    }

    func applyTheme() {
        backgroundColor = XTheme.background
        contentView.backgroundColor = XTheme.background
        selectedBackgroundView?.backgroundColor = XTheme.background
        tweetContentView.applyTheme()
        pinnedTweetsDivider.applyTheme()
    }

    func configure(
        with tweet: Tweet,
        hproseInstance: HproseInstance,
        isPinned: Bool,
        isLastPinnedTweet: Bool = false,
        isLastItem: Bool,
        parentViewController: UIViewController,
        leadingPadding: CGFloat,
        trailingPadding: CGFloat,
        rowWidth: CGFloat,
        videoCoordinator: VideoPlaybackCoordinator?,
        onAvatarTap: ((User) -> Void)?,
        onTweetTap: ((Tweet) -> Void)?,
        onShowLogin: (() -> Void)?,
        onShowToast: ((String, Bool) -> Void)?,
        allowDeleteAll: Bool = false,
        commentParentTweet: Tweet? = nil,
        savedParentTweetId: String? = nil
    ) {
        isHidden = false
        currentTweetId = tweet.mid
        applyTheme()
        pinnedTweetsDivider.isHidden = !isLastPinnedTweet
        pinnedTweetsDividerHeightConstraint.constant = isLastPinnedTweet ? Self.pinnedTweetsDividerHeight : 0

        // Apply list-level padding to the cell content
        leadingConstraint.constant = leadingPadding
        trailingConstraint.constant = -trailingPadding
        tweetContentView.cellHorizontalPadding = leadingPadding + trailingPadding
        tweetContentView.rowWidth = rowWidth

        tweetContentView.videoCoordinator = videoCoordinator
        tweetContentView.onAvatarTap = onAvatarTap
        tweetContentView.onTweetTap = onTweetTap
        tweetContentView.onShowLogin = onShowLogin
        tweetContentView.onShowToast = onShowToast
        tweetContentView.onContentExpanded = { [weak self] in self?.onContentExpanded?() }
        tweetContentView.onRetweetUnavailable = { [weak self] tweetId in
            self?.onRetweetUnavailable?(tweetId)
        }
        tweetContentView.onContentDidChangeHeightAsync = { [weak self] in
            guard let self else { return }
            self.onContentDidChangeHeightAsync?()
        }

        StallLog.measure("TweetTableViewCell.configure", "tweetId=\(tweet.mid)") {
            tweetContentView.configure(
                tweet: tweet,
                hproseInstance: hproseInstance,
                isPinned: isPinned,
                isLastItem: isLastItem,
                parentViewController: parentViewController,
                allowDeleteAll: allowDeleteAll,
                commentParentTweet: commentParentTweet,
                savedParentTweetId: savedParentTweetId
            )
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onContentExpanded = nil
        onContentDidChangeHeightAsync = nil
        onRetweetUnavailable = nil
        tweetContentView.onContentDidChangeHeightAsync = nil
        tweetContentView.onRetweetUnavailable = nil
        currentTweetId = nil
        tweetContentView.prepareForReuse()
        pinnedTweetsDivider.isHidden = true
        pinnedTweetsDividerHeightConstraint.constant = 0
    }
}

private final class PinnedTweetsDividerView: UIView {
    private let leftLine = UIView()
    private let dot = UIView()
    private let rightLine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        isUserInteractionEnabled = false

        [leftLine, dot, rightLine].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        dot.layer.cornerRadius = 3
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalTo: dot.widthAnchor),

            leftLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftLine.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -8),
            leftLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftLine.heightAnchor.constraint(equalToConstant: 1),

            rightLine.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            rightLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightLine.heightAnchor.constraint(equalToConstant: 1)
        ])

        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme() {
        backgroundColor = XTheme.background
        let color = XTheme.secondaryText.withAlphaComponent(0.65)
        leftLine.backgroundColor = color
        dot.backgroundColor = color
        rightLine.backgroundColor = color
    }
}
