import WebKit

/// A shared host-independent rule list blocks remote image requests for tabs whose site policy denies them.
@MainActor enum ImageBlocking {
    private static var task: Task<WKContentRuleList, Error>?
    private static var compiled: WKContentRuleList?

    static func list() async throws -> WKContentRuleList {
        if let compiled { return compiled }
        if task == nil {
            task = Task {
                guard
                    let list = try await WKContentRuleListStore.default().compileContentRuleList(
                        forIdentifier: "browser-image-policy",
                        encodedContentRuleList:
                            #"[{"trigger":{"url-filter":"^https?://","resource-type":["image"]},"action":{"type":"block"}}]"#)
                else { throw NSError(domain: "ImagePolicy", code: 1) }
                return list
            }
        }
        do { let value = try await task!.value; compiled = value; return value } catch { task = nil; throw error }
    }

    static func remove(from controller: WKUserContentController) { if let compiled { controller.remove(compiled) } }
}
