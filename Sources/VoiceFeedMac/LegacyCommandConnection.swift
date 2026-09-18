import Foundation
import Security

// Retire only the short-lived 1.6.0 command credential. No command execution or
// polling remains in this product, and capture credentials are not touched.
func retireLegacyCommandConnection() {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.fairystack.mac-commands", kSecAttrAccount as String: "connection"]
    var lookup = query; lookup[kSecReturnData as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return }
    SecItemDelete(query as CFDictionary)
    guard let data = result as? Data,
          let saved = try? JSONSerialization.jsonObject(with: data) as? [String:String],
          let value = saved["token"], value.hasPrefix("fs_mac_"),
          let origin = saved["origin"].flatMap(URL.init(string:)), origin.scheme == "https",
          origin.user == nil, origin.password == nil else { return }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
    let session = URLSession(configuration: config)
    var request = URLRequest(url: origin.appendingPathComponent("api/companions/device/revoke"))
    request.httpMethod = "POST"; request.timeoutInterval = 8
    request.setValue(value, forHTTPHeaderField: "X-FairyStack-Agent-Token")
    session.dataTask(with: request) { _,_,_ in session.finishTasksAndInvalidate() }.resume()
}
