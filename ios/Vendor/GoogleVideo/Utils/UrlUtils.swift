import Foundation

struct ByteRange: Equatable, Sendable {
    var start: Int
    var end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

extension URL {
    func searchParam(_ name: String) -> String? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        return components.percentEncodedQueryItems?.first { $0.name == name }?.value?.removingPercentEncoding
    }

    func settingSearchParam(_ name: String, _ value: String) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var items = components.percentEncodedQueryItems ?? []
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
        if let index = items.firstIndex(where: { $0.name == name }) {
            items[index].value = encoded
        } else {
            items.append(URLQueryItem(name: name, value: encoded))
        }
        components.percentEncodedQueryItems = items
        return components.url ?? self
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return allowed
    }()
}

func parseRangeHeader(_ rangeHeaderValue: String?) -> ByteRange? {
    guard let rangeHeaderValue, !rangeHeaderValue.isEmpty else { return nil }

    let halves = rangeHeaderValue.split(separator: "=", omittingEmptySubsequences: false)
    guard halves.count > 1 else { return nil }

    let parts = halves[1].split(separator: "-", omittingEmptySubsequences: false)
    if !parts.isEmpty {
        let start = Int(parts[0]) ?? 0
        let end = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return ByteRange(start: start, end: end)
    }

    return nil
}

func getBroadcastId(_ url: URL) -> String? {
    guard let idParam = url.searchParam("id"), !idParam.isEmpty else { return nil }
    let parts = idParam.components(separatedBy: ".")
    return parts.count == 2 ? parts[1] : nil
}

func getNextFallbackUrl(_ input: URL) -> URL? {
    let fvip = input.searchParam("fvip")
    let mnRaw = input.searchParam("mn")
    let fallbackCount = Int(input.searchParam("fallback_count") ?? "0") ?? 0

    if let fvip, !fvip.isEmpty, let mnRaw, !mnRaw.isEmpty {
        let mn = mnRaw.components(separatedBy: ",")
        let nextIndex = fallbackCount + 1

        if nextIndex < mn.count && !mn[nextIndex].isEmpty {
            let nextNode = mn[nextIndex]
            guard var components = URLComponents(url: input, resolvingAgainstBaseURL: false),
                  let currentHost = components.host else { return nil }
            let suffix = currentHost.replacingOccurrences(of: "^[^.]*", with: "", options: .regularExpression)
            let prefix = currentHost.hasPrefix("rr") ? "rr" : "r"

            components.host = "\(prefix)\(fvip)---\(nextNode)\(suffix)"
            guard let url = components.url else { return nil }

            return url.settingSearchParam("fallback_count", String(fallbackCount + 1))
        }
    }

    return nil
}
