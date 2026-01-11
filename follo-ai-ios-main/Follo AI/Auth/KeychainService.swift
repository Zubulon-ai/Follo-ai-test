//
//  KeychainService.swift
//  Follo AI
//
//  Created by Henry on 10/30/25.
//

import Foundation
import Security

/// Keychain服务，用于安全存储敏感信息（如Token）
class KeychainService {
    static let shared = KeychainService()

    private init() {}

    private let service = "com.follo.ai.keychain"

    /// 在Keychain中存储字符串值
    func set(_ value: String, forKey key: String) -> Bool {
        let data = value.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        // 删除已存在的项目
        SecItemDelete(query as CFDictionary)

        // 添加新项目
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 从Keychain中获取字符串值
    func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess {
            if let data = dataTypeRef as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    /// 从Keychain中删除值
    func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }

    /// 清除所有Keychain数据
    func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Token相关方法

    func setAccessToken(_ token: String) -> Bool {
        return set(token, forKey: "access_token")
    }

    func getAccessToken() -> String? {
        return get("access_token")
    }

    func setRefreshToken(_ token: String) -> Bool {
        return set(token, forKey: "refresh_token")
    }

    func getRefreshToken() -> String? {
        return get("refresh_token")
    }

    func clearTokens() -> Bool {
        let success1 = delete("access_token")
        let success2 = delete("refresh_token")
        return success1 && success2
    }
}
