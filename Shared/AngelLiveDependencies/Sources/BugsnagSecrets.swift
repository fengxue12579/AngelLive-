// Bugsnag API key 读取入口。
//
// 真实 key 不写在 Swift 代码里,改读 Resources/ 下的 plist:
//   - BugsnagSecrets.local.plist    git 忽略,本地/CI 注入真 key
//   - BugsnagSecrets.plist          git 跟踪,占位空字符串
// 两份都不存在或值为空时,Bugsnag 启动会被 BugsnagBootstrap 静默跳过,
// 不影响编译与运行。

import Foundation

enum BugsnagSecrets {

    static func apiKey(for platform: BugsnagPlatform) -> String? {
        let dict = loadDict("BugsnagSecrets.local") ?? loadDict("BugsnagSecrets")
        let raw = dict?[platform.rawValue] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadDict(_ resource: String) -> [String: String]? {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return nil }
        return plist
    }
}
