import Foundation
import Security

public enum KeychainRootSecret {
    private static let service = "com.local.safari-history-sync.ipc"
    private static let account = "root-v1"

    public static func load(createIfMissing: Bool) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        guard status == errSecItemNotFound, createIfMissing else {
            throw IPCError.keyUnavailable(status)
        }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let insert: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw IPCError.keyUnavailable(addStatus)
        }
        if addStatus == errSecDuplicateItem { return try load(createIfMissing: false) }
        return data
    }
}
