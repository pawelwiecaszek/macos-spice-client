import Foundation

extension SpiceSession {
    /// Cached availability for presentation; actual admission checks wire-owned
    /// negotiation and lifecycle observations on the main channel.
    public var clipboardSupported: Bool {
        !clipboardFailed && guestAgentCaps.contains(AgentCapability.clipboardByDemand.rawValue)
    }

    public var clipboardAuthorization: ClipboardAgentAuthorization? {
        get async { await main?.clipboardAuthorization }
    }

    /// Native clients pass a revocable local sharing lifetime. Admission performs
    /// no socket writes on the caller's task and never returns guest clipboard data.
    @discardableResult
    public func submitClipboard(_ action: AgentClipboardAction, authorization: ClipboardAgentAuthorization,
                                sharing: ClipboardSharingAuthorization) async -> Bool {
        guard let main, state == .connected else { return false }
        return await main.enqueueClipboard(action, authorization: authorization, sharing: sharing)
    }

    /// Explicit SDK offer. Callers of the convenience API own their clipboard
    /// consent/focus policy; the native app uses submitClipboard with revocation.
    public func offerClipboard(_ types: [ClipboardDataType]) async { await explicitClipboard(.offer(types)) }
    public func provideClipboard(_ type: ClipboardDataType, data: [UInt8]) async { await explicitClipboard(.provide(type, data)) }
    public func requestClipboard(_ type: ClipboardDataType) async { await explicitClipboard(.request(type)) }
    public func releaseClipboard() async { await explicitClipboard(.release) }

    private func explicitClipboard(_ action: AgentClipboardAction) async {
        guard let authorization = await clipboardAuthorization else { return }
        _ = await submitClipboard(action, authorization: authorization, sharing: ClipboardSharingAuthority().current)
    }
}
