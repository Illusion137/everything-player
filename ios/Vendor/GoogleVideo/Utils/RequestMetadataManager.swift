import Foundation

final class RequestMetadataManager: @unchecked Sendable {
    var metadataMap: [String: SabrRequestMetadata]
    private var lastCleanup: Double
    private let CLEANUP_INTERVAL: Double = 30000
    private let ENTRY_EXPIRATION_TIME: Double = 1000 * 60 * 3

    init() {
        self.metadataMap = [:]
        self.lastCleanup = nowMs()
    }

    func getRequestMetadata(_ url: String, _ del: Bool = false) -> SabrRequestMetadata? {
        let requestNumber = URL(string: url)?.searchParam("rn") ?? ""

        let streamingContext = metadataMap[requestNumber]

        if let streamingContext, nowMs() - streamingContext.timestamp > ENTRY_EXPIRATION_TIME {
            metadataMap.removeValue(forKey: requestNumber)
            return nil
        }

        if del {
            metadataMap.removeValue(forKey: requestNumber)
        }

        conditionalCleanUp()

        return streamingContext
    }

    func setRequestMetadata(_ url: String, _ context: SabrRequestMetadata) {
        if let requestNumber = URL(string: url)?.searchParam("rn"), !requestNumber.isEmpty {
            metadataMap[requestNumber] = context
            conditionalCleanUp()
        }
    }

    private func conditionalCleanUp() {
        let now = nowMs()
        if now - lastCleanup > CLEANUP_INTERVAL {
            cleanUp()
            lastCleanup = now
        }
    }

    private func cleanUp() {
        for (key, context) in metadataMap {
            if nowMs() - context.timestamp > ENTRY_EXPIRATION_TIME {
                metadataMap.removeValue(forKey: key)
            }
        }
    }
}
