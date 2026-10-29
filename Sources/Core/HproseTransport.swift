import Foundation
@preconcurrency import hprose

/// Async boundary for the legacy Objective-C Hprose client.
///
/// Keep direct `HproseClient.invoke` calls here so the rest of the app does not
/// need to know how the blocking Objective-C API is moved off the caller actor.
enum HproseTransport {
    private struct Invocation: @unchecked Sendable {
        let client: HproseClient
        let method: String
        let args: [Any]
        let priority: DispatchQoS.QoSClass
    }

    private static let foregroundLock = NSLock()
    nonisolated(unsafe) private static var foregroundCount = 0

    /// RPCs in flight at any QoS above `.background`, i.e. everything except read-ahead
    /// and housekeeping. BackgroundTweetPrefetcher waits for this to reach zero so its
    /// pages never compete with a feed load, a comment or any other request the user
    /// is waiting on.
    static var foregroundInFlightCount: Int {
        foregroundLock.lock(); defer { foregroundLock.unlock() }
        return foregroundCount
    }

    private static func adjustForeground(_ priority: DispatchQoS.QoSClass, by delta: Int) {
        guard priority != .background else { return }
        foregroundLock.lock(); foregroundCount += delta; foregroundLock.unlock()
    }

    static func invoke(
        _ method: String,
        using client: HproseClient,
        args: [Any],
        priority: DispatchQoS.QoSClass = .userInitiated
    ) async -> Any? {
        guard !Task.isCancelled else { return nil }
        // Claim the client for the duration of the call. Pooled clients are shared,
        // so another code path can retire (and invalidate the NSURLSession of) the
        // client we were handed at any moment; invoking on an invalidated session
        // raises an uncatchable NSGenericException. A retired client is reported
        // here as a failed RPC, which callers already handle as a nil response.
        guard HproseClientPool.shared.beginInvocation(on: client) else { return nil }
        adjustForeground(priority, by: 1)

        let invocation = Invocation(
            client: client,
            method: method,
            args: args,
            priority: priority
        )

        return await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            DispatchQueue.global(qos: invocation.priority).async {
                let response = invocation.client.invoke(invocation.method, withArgs: invocation.args)
                HproseClientPool.shared.endInvocation(on: invocation.client)
                adjustForeground(invocation.priority, by: -1)
                continuation.resume(returning: response)
            }
        }
    }

    static func invokeRunMApp(
        using client: HproseClient,
        entry: String,
        params: [String: Any],
        priority: DispatchQoS.QoSClass = .userInitiated
    ) async -> Any? {
        await invoke(
            "runMApp",
            using: client,
            args: [entry, params],
            priority: priority
        )
    }
}
