//
//  PlatformSessionManager.swift
//  AngelLiveCore
//
//  Created by Codex on 2026/2/17.
//

import Foundation
import Security

public enum PlatformSessionState: String, Codable, Sendable {
    case anonymous
    case authenticated
    case expired
    case invalid
}

public enum PlatformSessionSource: String, Codable, Sendable {
    case local
    case iCloud
    case bonjour
    case manual
    case legacy
}

public enum PlatformSessionValidationResult: Sendable {
    case valid
    case invalid(reason: String)
    case expired
    case networkError(String)
}

/// 插件侧 `validateCredential` / `getCredentialStatus` 的标准返回结构。
public struct CredentialStatus: Codable, Sendable {
    public let state: String
    public let expireAt: Double?
    public let userId: String?
    public let userName: String?
    public let message: String?

    public init(
        state: String,
        expireAt: Double? = nil,
        userId: String? = nil,
        userName: String? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.expireAt = expireAt
        self.userId = userId
        self.userName = userName
        self.message = message
    }
}

public struct PlatformSession: Codable, Sendable {
    public let pluginId: String
    /// 关联的 liveType（rawValue），便于 UI 层查 manifest/icon。
    public var liveType: String?
    public var cookie: String?
    public var csrf: String?
    public var refreshToken: String?
    public var uid: String?
    public var expireAt: Date?
    public var source: PlatformSessionSource
    public var state: PlatformSessionState
    public var updatedAt: Date

    public init(
        pluginId: String,
        liveType: String? = nil,
        cookie: String?,
        csrf: String? = nil,
        refreshToken: String? = nil,
        uid: String? = nil,
        expireAt: Date? = nil,
        source: PlatformSessionSource = .local,
        state: PlatformSessionState = .anonymous,
        updatedAt: Date = Date()
    ) {
        self.pluginId = pluginId
        self.liveType = liveType
        self.cookie = cookie
        self.csrf = csrf
        self.refreshToken = refreshToken
        self.uid = uid
        self.expireAt = expireAt
        self.source = source
        self.state = state
        self.updatedAt = updatedAt
    }
}

public struct PlatformSessionData: Sendable {
    public var cookie: String?
    public var csrf: String?
    public var refreshToken: String?
    public var uid: String?
    public var expireAt: Date?
    public var source: PlatformSessionSource
    public var state: PlatformSessionState
    public var liveType: String?

    public init(
        cookie: String?,
        csrf: String? = nil,
        refreshToken: String? = nil,
        uid: String? = nil,
        expireAt: Date? = nil,
        source: PlatformSessionSource,
        state: PlatformSessionState,
        liveType: String? = nil
    ) {
        self.cookie = cookie
        self.csrf = csrf
        self.refreshToken = refreshToken
        self.uid = uid
        self.expireAt = expireAt
        self.source = source
        self.state = state
        self.liveType = liveType
    }
}

public actor PlatformSessionManager {
    public static let shared = PlatformSessionManager()

    private let store = SessionStore()

    private init() {}

    public func getSession(pluginId: String) -> PlatformSession? {
        store.loadSession(for: pluginId)
    }

    @discardableResult
    public func loginWithCookie(
        pluginId: String,
        cookie: String,
        uid: String? = nil,
        liveType: String? = nil,
        source: PlatformSessionSource = .local,
        validateBeforeSave: Bool = true
    ) async -> PlatformSessionValidationResult {
        let consoleEntryId = await MainActor.run {
            PluginConsoleService.shared.log(tag: "Credential", method: "login", status: .loading)
        }
        let consoleStart = Date()
        let normalizedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieLength = normalizedCookie.count
        await MainActor.run {
            PluginConsoleService.shared.updateRequest(
                id: consoleEntryId,
                body: """
                pluginId: \(pluginId)
                uid: \(uid ?? "-")
                liveType: \(liveType ?? "-")
                source: \(source)
                validateBeforeSave: \(validateBeforeSave)
                cookieLength: \(cookieLength)
                """
            )
        }
        guard !normalizedCookie.isEmpty else {
            await Self.finishCredentialEntry(
                id: consoleEntryId,
                start: consoleStart,
                status: .error,
                errorMessage: "Cookie 为空"
            )
            return .invalid(reason: "Cookie 为空")
        }

        let validationResult: PlatformSessionValidationResult
        if validateBeforeSave {
            validationResult = await validateCookie(pluginId: pluginId, cookie: normalizedCookie)
        } else {
            validationResult = .valid
        }

        switch validationResult {
        case .valid:
            let sessionData = PlatformSessionData(
                cookie: normalizedCookie,
                uid: uid,
                source: source,
                state: .authenticated,
                liveType: liveType
            )
            updateSession(pluginId: pluginId, data: sessionData)
        case .expired:
            let sessionData = PlatformSessionData(
                cookie: normalizedCookie,
                uid: uid,
                source: source,
                state: .expired,
                liveType: liveType
            )
            updateSession(pluginId: pluginId, data: sessionData)
        case .invalid, .networkError:
            break
        }

        let consoleSummary = Self.credentialDescription(for: validationResult)
        let consoleStatus: PluginConsoleEntryStatus
        switch validationResult {
        case .valid, .expired:
            consoleStatus = .success
        case .invalid, .networkError:
            consoleStatus = .error
        }
        await Self.finishCredentialEntry(
            id: consoleEntryId,
            start: consoleStart,
            status: consoleStatus,
            responseBody: consoleStatus == .success ? consoleSummary : nil,
            errorMessage: consoleStatus == .error ? consoleSummary : nil
        )

        return validationResult
    }

    public func updateSession(pluginId: String, data: PlatformSessionData) {
        let session = PlatformSession(
            pluginId: pluginId,
            liveType: data.liveType,
            cookie: data.cookie,
            csrf: data.csrf,
            refreshToken: data.refreshToken,
            uid: data.uid,
            expireAt: data.expireAt,
            source: data.source,
            state: data.state,
            updatedAt: Date()
        )
        store.saveSession(session)
        PlatformSessionLiveParseBridge.syncSessionToLiveParse(session)
    }

    public func clearSession(pluginId: String) {
        store.clearSession(for: pluginId)
        PlatformSessionLiveParseBridge.clearForPlatform(pluginId: pluginId)
        let snapshot = pluginId
        Task { @MainActor in
            let id = PluginConsoleService.shared.log(tag: "Credential", method: "logout", status: .loading)
            PluginConsoleService.shared.updateRequest(id: id, body: "pluginId: \(snapshot)")
            PluginConsoleService.shared.updateStatus(
                id: id,
                status: .success,
                responseBody: "已清除本地会话与共享凭证池"
            )
        }
    }

    public func validateSession(pluginId: String) async -> PlatformSessionValidationResult {
        let consoleEntryId = await MainActor.run {
            PluginConsoleService.shared.log(tag: "Credential", method: "validate", status: .loading)
        }
        let consoleStart = Date()
        await MainActor.run {
            PluginConsoleService.shared.updateRequest(id: consoleEntryId, body: "pluginId: \(pluginId)")
        }
        guard let session = getSession(pluginId: pluginId),
              let cookie = session.cookie,
              !cookie.isEmpty else {
            await Self.finishCredentialEntry(
                id: consoleEntryId,
                start: consoleStart,
                status: .error,
                errorMessage: "本地无有效会话"
            )
            return .invalid(reason: "Cookie 为空")
        }

        let result = await validateCookie(pluginId: pluginId, cookie: cookie)
        let summary = Self.credentialDescription(for: result)
        let consoleStatus: PluginConsoleEntryStatus
        switch result {
        case .valid, .expired:
            consoleStatus = .success
        case .invalid, .networkError:
            consoleStatus = .error
        }
        await Self.finishCredentialEntry(
            id: consoleEntryId,
            start: consoleStart,
            status: consoleStatus,
            responseBody: consoleStatus == .success ? summary : nil,
            errorMessage: consoleStatus == .error ? summary : nil
        )
        return result
    }

    private static func credentialDescription(for result: PlatformSessionValidationResult) -> String {
        switch result {
        case .valid:
            return "valid"
        case .expired:
            return "expired"
        case .invalid(let reason):
            return "invalid: \(reason)"
        case .networkError(let reason):
            return "networkError: \(reason)"
        }
    }

    private static func finishCredentialEntry(
        id: UUID,
        start: Date,
        status: PluginConsoleEntryStatus,
        responseBody: String? = nil,
        errorMessage: String? = nil
    ) async {
        let duration = Date().timeIntervalSince(start)
        await MainActor.run {
            PluginConsoleService.shared.updateStatus(
                id: id,
                status: status,
                duration: duration,
                responseBody: responseBody,
                errorMessage: errorMessage
            )
        }
    }

    /// 返回所有已持久化会话（按 pluginId 去重后的最新版本）。
    public func allSessions() -> [PlatformSession] {
        store.loadAllSessions()
    }

    /// 调用插件 `validateCredential`，返回完整的 CredentialStatus（含 userId / userName / message / state）。
    /// 与 `validateSession` 的区别：后者把插件返回值归一化成 valid/expired/invalid/networkError，丢掉 userName。
    /// UI 需要展示昵称时用这个。
    public func fetchCredentialStatus(pluginId: String) async -> CredentialStatus? {
        guard let session = getSession(pluginId: pluginId),
              let cookie = session.cookie,
              !cookie.isEmpty else {
            return nil
        }

        LiveParsePlatformSessionVault.update(platformId: pluginId, cookie: cookie, uid: nil)

        let payload: [String: Any] = [
            "credential": ["cookie": cookie]
        ]

        do {
            return try await LiveParsePlugins.shared.callDecodable(
                pluginId: pluginId,
                function: "validateCredential",
                payload: payload
            )
        } catch {
            return nil
        }
    }

    // MARK: - 插件驱动的凭证校验

    private func validateCookie(pluginId: String, cookie: String) async -> PlatformSessionValidationResult {
        // 写入共享会话池，确保插件后续发 HTTP 请求可通过 authMode: "platform_cookie" 使用。
        LiveParsePlatformSessionVault.update(platformId: pluginId, cookie: cookie, uid: nil)

        let payload: [String: Any] = [
            "credential": ["cookie": cookie]
        ]

        do {
            let status: CredentialStatus = try await LiveParsePlugins.shared.callDecodable(
                pluginId: pluginId,
                function: "validateCredential",
                payload: payload
            )
            return mapStatus(status, cookieFallback: cookie)
        } catch let error as LiveParsePluginError {
            switch error {
            case .pluginNotFound:
                // 插件尚未安装：cookie 暂无法校验，但保留本地会话（下次插件就绪再复验）。
                return .valid
            case .jsException(let message), .invalidReturnValue(let message), .invalidManifest(let message):
                if message.lowercased().contains("network") {
                    return .networkError(message)
                }
                // JS 未实现 validateCredential / 返回异常：按未知处理，不阻断登录。
                return .valid
            case .standardized(let std):
                switch std.code {
                case .network, .timeout:
                    return .networkError(std.message)
                case .authRequired:
                    return .expired
                case .blocked:
                    return .invalid(reason: std.message)
                default:
                    return .valid
                }
            default:
                return .networkError(error.localizedDescription)
            }
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    private func mapStatus(_ status: CredentialStatus, cookieFallback: String) -> PlatformSessionValidationResult {
        switch status.state.lowercased() {
        case "valid":
            return .valid
        case "expired":
            return .expired
        case "invalid", "missing", "risk_control":
            return .invalid(reason: status.message ?? status.state)
        case "unknown":
            // 插件无法判定：只要 cookie 非空就暂按有效处理（由上层业务 401 触发再登录）。
            return cookieFallback.isEmpty ? .invalid(reason: "Cookie 为空") : .valid
        default:
            return .valid
        }
    }
}

// MARK: - SessionStore

private final class SessionStore {
    private enum Constants {
        static let keychainService = "com.angellive.session"
    }

    private struct SessionMetadata: Codable {
        let uid: String?
        let source: PlatformSessionSource
        let state: PlatformSessionState
        let expireAt: Date?
        let updatedAt: Date
        let liveType: String?
    }

    private struct SessionSensitivePayload: Codable {
        let cookie: String?
        let csrf: String?
        let refreshToken: String?
    }

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keychain = KeychainStore(service: Constants.keychainService)

    func loadSession(for pluginId: String) -> PlatformSession? {
        migrateLegacyIfNeeded(for: pluginId)

        guard let metadataData = defaults.data(forKey: metadataKey(for: pluginId)),
              let metadata = try? decoder.decode(SessionMetadata.self, from: metadataData) else {
            return nil
        }

        let sensitive = loadSensitivePayload(for: pluginId)
        return PlatformSession(
            pluginId: pluginId,
            liveType: metadata.liveType,
            cookie: sensitive?.cookie,
            csrf: sensitive?.csrf,
            refreshToken: sensitive?.refreshToken,
            uid: metadata.uid,
            expireAt: metadata.expireAt,
            source: metadata.source,
            state: metadata.state,
            updatedAt: metadata.updatedAt
        )
    }

    func loadAllSessions() -> [PlatformSession] {
        // 遍历已安装插件 + manifest 可发现插件（防止插件暂时卸载时会话丢失）
        let manifestPluginIds = LiveParseJSPlatformManager.availablePlatforms.map(\.pluginId)
        let pluginIds = Set(SandboxPluginCatalog.installedPluginIds() + manifestPluginIds)
        return pluginIds.compactMap { loadSession(for: $0) }
    }

    func saveSession(_ session: PlatformSession) {
        let metadata = SessionMetadata(
            uid: session.uid,
            source: session.source,
            state: session.state,
            expireAt: session.expireAt,
            updatedAt: session.updatedAt,
            liveType: session.liveType
        )
        if let metadataData = try? encoder.encode(metadata) {
            defaults.set(metadataData, forKey: metadataKey(for: session.pluginId))
        }

        let sensitive = SessionSensitivePayload(
            cookie: session.cookie,
            csrf: session.csrf,
            refreshToken: session.refreshToken
        )
        if let sensitiveData = try? encoder.encode(sensitive) {
            keychain.write(sensitiveData, account: keychainAccount(for: session.pluginId))
        }

        defaults.set(true, forKey: migrationKey(for: session.pluginId))
    }

    func clearSession(for pluginId: String) {
        defaults.removeObject(forKey: metadataKey(for: pluginId))
        keychain.delete(account: keychainAccount(for: pluginId))
    }

    private func migrateLegacyIfNeeded(for pluginId: String) {
        guard !defaults.bool(forKey: migrationKey(for: pluginId)) else { return }
        defer { defaults.set(true, forKey: migrationKey(for: pluginId)) }

        guard let platform = LiveParseJSPlatformManager.platform(forPluginId: pluginId) else { return }
        let migration = platform.sessionMigration

        for legacyRaw in migration?.legacyPluginIds ?? [] where !legacyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            migrateLegacyRawKeyed(from: legacyRaw, to: pluginId)
        }

        if let migration {
            migrateLegacyUserDefaults(for: platform, migration: migration)
        }
    }

    private func migrateLegacyRawKeyed(from legacyRaw: String, to pluginId: String) {
        let legacyMetadataKey = "AngelLive.SessionStore.\(legacyRaw).metadata"
        let legacyKeychainAccount = "session.\(legacyRaw)"

        if let legacyMetadataData = defaults.data(forKey: legacyMetadataKey) {
            defaults.set(legacyMetadataData, forKey: metadataKey(for: pluginId))
            defaults.removeObject(forKey: legacyMetadataKey)
        }

        if let legacyData = keychain.read(account: legacyKeychainAccount) {
            keychain.write(legacyData, account: keychainAccount(for: pluginId))
            keychain.delete(account: legacyKeychainAccount)
        }
    }

    private func migrateLegacyUserDefaults(for platform: LiveParseJSPlatform, migration: ManifestSessionMigration) {
        let legacyCookie = firstString(forKeys: migration.userDefaultsCookieKeys) ?? ""
        let legacyUid = firstString(forKeys: migration.userDefaultsUIDKeys)
        guard !legacyCookie.isEmpty else {
            return
        }

        let migrated = PlatformSession(
            pluginId: platform.pluginId,
            liveType: platform.liveType.rawValue,
            cookie: legacyCookie,
            uid: legacyUid,
            source: .legacy,
            state: legacyCookie.matchesAnyMarker(migration.authCookieMarkers) ? .authenticated : .invalid,
            updatedAt: Date()
        )
        saveSession(migrated)
    }

    private func firstString(forKeys keys: [String]?) -> String? {
        keys?
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { self.defaults.string(forKey: $0) }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func loadSensitivePayload(for pluginId: String) -> SessionSensitivePayload? {
        guard let data = keychain.read(account: keychainAccount(for: pluginId)) else { return nil }
        return try? decoder.decode(SessionSensitivePayload.self, from: data)
    }

    private func metadataKey(for pluginId: String) -> String {
        "AngelLive.SessionStore.\(pluginId).metadata"
    }

    private func migrationKey(for pluginId: String) -> String {
        "AngelLive.SessionStore.\(pluginId).migrated.v2"
    }

    private func keychainAccount(for pluginId: String) -> String {
        "session.\(pluginId)"
    }
}

private extension String {
    func matchesAnyMarker(_ markers: [String]?) -> Bool {
        guard let markers, !markers.isEmpty else {
            return !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return markers.contains { marker in
            let normalized = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && localizedCaseInsensitiveContains(normalized)
        }
    }
}

private struct KeychainStore {
    let service: String

    func write(_ data: Data, account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(item as CFDictionary, nil)
    }

    func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
