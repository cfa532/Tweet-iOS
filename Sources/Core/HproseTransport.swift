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

    static func invoke(
        _ method: String,
        using client: HproseClient,
        args: [Any],
        priority: DispatchQoS.QoSClass = .userInitiated
    ) async -> Any? {
        // Claim the client for the duration of the call. Pooled clients are shared,
        // so another code path can retire (and invalidate the NSURLSession of) the
        // client we were handed at any moment; invoking on an invalidated session
        // raises an uncatchable NSGenericException. A retired client is reported
        // here as a failed RPC, which callers already handle as a nil response.
        guard HproseClientPool.shared.beginInvocation(on: client) else { return nil }

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
