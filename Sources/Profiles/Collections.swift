import Foundation

struct RuleCollection: Codable, Equatable {
    let name: String
    var target: RuleTarget
    var enabled: Bool
    var domains: [String]
    var networks: [String]

    private static let titles: [String: (chinese: String, english: String)] = [
        "claude": ("Claude", "Claude"),
        "openai": ("OpenAI", "OpenAI"),
        "apple-relay": ("Apple 中继", "Apple Relay"),
        "direct-services": ("常用直连服务", "Direct Services"),
        "local-network": ("局域网", "Local Network"),
        "international-services": ("国际服务", "International Services")
    ]
    private static let previousTitles = ["claude": "Claude 服务", "openai": "OpenAI 服务"]

    var title: String {
        guard let labels = Self.titles[name] else { return name }
        return localized(labels.chinese, labels.english)
    }

    var searchNames: [String] {
        guard let labels = Self.titles[name] else { return [name] }
        return labels.chinese == labels.english ? [name, labels.english] : [name, labels.chinese, labels.english]
    }

    var lookupNames: [String] {
        guard let previous = Self.previousTitles[name] else { return searchNames }
        return searchNames + [previous]
    }

    func matchesSearch(_ query: String) -> Bool {
        query.isEmpty || searchNames.contains { $0.localizedCaseInsensitiveContains(query) } ||
            Self.previousTitles[name]?.caseInsensitiveCompare(query) == .orderedSame
    }

    static func index(matching name: String, in groups: [RuleCollection]) -> Int? {
        if let index = groups.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return index
        }
        let matches = groups.indices.filter { index in
            groups[index].lookupNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return matches.count == 1 ? matches.first : nil
    }

    var builtIn: Bool { Preset(rawValue: name) != nil }

    private static let prefix = "proxyctl-preset:"
    static let fallbackMarker = "proxyctl-explicit-default"

    var tag: String { "\(Self.prefix)\(target.identifier):\(name)" }

    static func validName(_ value: String) -> Bool {
        Profile.validName(value) && value.utf8.count <= 80 && !value.contains(":") &&
            !Preset.allCases.contains { $0.rawValue != value && $0.rawValue.lowercased() == value.lowercased() }
    }

    static func defaults(_ enabled: [Preset]) -> [RuleCollection] {
        Preset.allCases.map {
            RuleCollection(name: $0.rawValue, target: .proxy, enabled: enabled.contains($0),
                           domains: $0.domains, networks: [])
        }
    }

    static func decode(_ sets: [[String: Any]], routes: [[String: Any]], targets: [RuleTarget]) throws -> [RuleCollection] {
        let identifiers = Dictionary(uniqueKeysWithValues: targets.map { ($0.identifier, $0) })
        var collections: [RuleCollection] = []
        for set in sets {
            guard let tag = set["tag"] as? String, tag.hasPrefix(prefix) else { continue }
            let parts = tag.dropFirst(prefix.count).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let target = identifiers[parts[0]], validName(parts[1]),
                  Preset(rawValue: parts[1]) == nil || target.usesManagedProxy,
                  set["type"] as? String == "inline", let entries = entries(in: set),
                  entries.count <= 2, entries.allSatisfy({ $0.count == 1 }),
                  entries.flatMap(\.keys).allSatisfy({ RuleMatch(rawValue: $0) != nil }),
                  Set(entries.flatMap(\.keys)).count == entries.count else { throw invalid }
            let name = parts[1]
            guard !collections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw invalid }
            let active = routes.contains { $0["rule_set"] as? [String] == [tag] && $0["outbound"] as? String == target.outbound }
            let domains = entries.compactMap { $0[RuleMatch.domain.rawValue] }.flatMap { $0 }
            let networks = entries.compactMap { $0[RuleMatch.network.rawValue] }.flatMap { $0 }
            collections.append(RuleCollection(name: name, target: target, enabled: active,
                                               domains: try canonical(domains, .domain),
                                               networks: try canonical(networks, .network)))
        }
        if !collections.isEmpty && Array(collections.prefix(Preset.allCases.count)).map(\.name) != Preset.allCases.map(\.rawValue) {
            throw invalid
        }
        return collections
    }

    static var invalid: UserError {
        UserError(localized("预设集合格式无效。", "Invalid preset collection."))
    }

    private static func canonical(_ values: [String], _ match: RuleMatch) throws -> [String] {
        let normalized = try values.map(match.normalize)
        guard normalized == values, Set(values).count == values.count else { throw invalid }
        return values
    }

    // Inline rule-sets require a rule. This one cannot match any flow.
    static let emptyEntry: [String: Any] = [
        "type": "logical", "mode": "and",
        "rules": [
            ["domain_suffix": ["proxyctl-placeholder.invalid"]],
            ["domain_suffix": ["proxyctl-placeholder.invalid"], "invert": true]
        ]
    ]

    private static func entries(in set: [String: Any]) -> [[String: [String]]]? {
        if let special = set["rules"] as? [[String: Any]], special.count == 1,
           NSDictionary(dictionary: special[0]).isEqual(to: emptyEntry) { return [] }
        return set["rules"] as? [[String: [String]]]
    }

    var definition: [String: Any] {
        var rules: [[String: Any]] = []
        if !domains.isEmpty { rules.append([RuleMatch.domain.rawValue: domains]) }
        if !networks.isEmpty { rules.append([RuleMatch.network.rawValue: networks]) }
        return ["type": "inline", "tag": tag, "rules": rules.isEmpty ? [Self.emptyEntry] : rules]
    }

    mutating func edit(_ value: String, add: Bool) throws {
        let match = RuleMatch(value)
        let member = try match.normalize(value)
        let keyPath: WritableKeyPath<RuleCollection, [String]> = match == .domain ? \.domains : \.networks
        if add {
            if !self[keyPath: keyPath].contains(member) { self[keyPath: keyPath].append(member) }
        } else {
            self[keyPath: keyPath].removeAll { $0 == member }
        }
    }
}

func matchesDomain(_ host: String, _ suffixes: [String]) -> Bool {
    suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
}
