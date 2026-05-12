import Foundation

enum AIParsingService {
    static func filterBroadNames(_ places: [AIExtractPlace]) -> [AIExtractPlace] {
        let broadWords: Set<String> = ["市中心", "老城区", "郊区", "城里", "附近", "旁边", "对面"]
        let placeSuffixes = ["站", "塔", "寺", "馆", "山", "园", "城", "楼", "桥", "街", "路", "场", "机场", "公园", "博物馆"]
        let areaSuffixes = ["国", "省", "市", "区", "县", "州", "郡"]

        return places.filter { item in
            if item.name.count <= 1 { return false }
            if item.kind == "broad_area" { return false }
            if broadWords.contains(item.name) { return false }
            if placeSuffixes.contains(where: { item.name.hasSuffix($0) }) { return true }
            if (item.searchQuery.count - item.name.count) > 1 { return true }
            if areaSuffixes.contains(where: { item.name.hasSuffix($0) }) { return false }
            return item.kind == "specific_place" || item.kind == nil
        }
    }

    static func parsePlaceBlocks(_ content: String) -> [AIPlaceGroup] {
        let dayRegex = try! NSRegularExpression(pattern: #"\*\*(Day\s*\d+:[^\n*]+|推荐地点)\*\*"#)
        let blockRegex = try! NSRegularExpression(pattern: #"```json:places\s*([\s\S]*?)```"#)
        let ns = content as NSString
        let dayMatches = dayRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        let blockMatches = blockRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))

        var groups: [AIPlaceGroup] = []
        for (i, day) in dayMatches.enumerated() {
            let title = ns.substring(with: day.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = day.range.location + day.range.length
            let end = i + 1 < dayMatches.count ? dayMatches[i + 1].range.location : ns.length
            let dayRange = NSRange(location: start, length: end - start)
            let intro = ns.substring(with: dayRange)
                .replacingOccurrences(of: #"```json:places[\s\S]*?```"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let dayBlocks = blockMatches.filter { NSIntersectionRange($0.range, dayRange).length > 0 }
            var cards: [AIPlaceCard] = []
            for block in dayBlocks {
                let text = ns.substring(with: block.range(at: 1))
                if let data = text.data(using: .utf8),
                   let arr = try? JSONDecoder().decode([AIPlaceCard].self, from: data) {
                    cards.append(contentsOf: arr)
                }
            }
            groups.append(AIPlaceGroup(title: title, intro: intro, places: cards))
        }

        if groups.isEmpty, let block = blockMatches.first {
            let text = ns.substring(with: block.range(at: 1))
            if let data = text.data(using: .utf8),
               let cards = try? JSONDecoder().decode([AIPlaceCard].self, from: data) {
                groups = [AIPlaceGroup(title: "推荐地点", intro: "", places: cards)]
            }
        }
        return groups
    }
}

