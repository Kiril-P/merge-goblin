//  ModelCatalog.swift — the models a provider offers, arranged so a long list stays usable.
//
//  `goblin provider models <id>` returns the CLI's own list. Claude and Codex give a
//  handful; Cursor gives a couple of hundred, most of them one model in several effort,
//  speed and context variants. The menu is therefore two levels: vendor, then model, and
//  a model with variants becomes a submenu of them. Nothing here is typed by a person.

import Foundation

struct ModelOption: Identifiable, Equatable, Hashable {
    let id: String
    let label: String

    init?(json: JSON) {
        guard let id = json["id"].string, Pattern.model.accepts(id), !id.isEmpty, !id.hasPrefix("-") else { return nil }
        self.id = id
        let label = json["label"].string("")
        self.label = label.isEmpty ? id : label
    }
    init(id: String, label: String) { self.id = id; self.label = label }
}

/// One entry in the menu: a model, or a model with several variants.
struct ModelFamily: Identifiable, Equatable {
    let title: String
    let options: [ModelOption]
    var id: String { title }
}

struct ModelGroup: Identifiable, Equatable {
    let vendor: String
    let families: [ModelFamily]
    var id: String { vendor }
}

enum ModelCatalog {
    /// Past this many models a flat list is hard to scan, so group it.
    static let groupingThreshold = 14

    static func parse(_ json: JSON) -> [ModelOption] {
        var seen = Set<String>()
        return json.array.compactMap(ModelOption.init(json:)).filter { seen.insert($0.id).inserted }
    }

    static func vendor(of id: String) -> String {
        let lower = id.lowercased()
        let table: [(String, String)] = [
            ("claude", "Claude"), ("sonnet", "Claude"), ("opus", "Claude"), ("haiku", "Claude"),
            ("gpt", "GPT"), ("codex", "GPT"), ("o1", "GPT"), ("o3", "GPT"), ("o4", "GPT"),
            ("gemini", "Gemini"), ("cursor-grok", "Grok"), ("grok", "Grok"), ("composer", "Cursor"),
            ("cursor", "Cursor"), ("auto", "Cursor"), ("muse", "Muse"), ("kimi", "Kimi"), ("glm", "GLM"),
        ]
        return table.first { lower.hasPrefix($0.0) }?.1 ?? "Other"
    }

    /// Words that mark a variant of a model rather than a different model.
    private static let variantWords: Set<String> = [
        "thinking", "fast", "low", "medium", "high", "xhigh", "max", "minimal", "none", "extra", "1m", "ultra",
    ]

    /// "claude-opus-5-thinking-high-fast" -> "claude-opus-5". Looks at the id only.
    static func familyKey(of id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        while parts.count > 1, let last = parts.last?.lowercased(), variantWords.contains(last) { parts.removeLast() }
        return parts.joined(separator: "-")
    }

    private static func title(for members: [ModelOption]) -> String {
        guard let base = members.min(by: { $0.id.count < $1.id.count }) else { return "" }
        var words = base.label.split(separator: " ").map(String.init)
        while words.count > 1, let last = words.last?.lowercased(), variantWords.contains(last) || last.hasPrefix("(") {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// vendor -> families -> variants, in the order the CLI listed them.
    static func grouped(_ options: [ModelOption]) -> [ModelGroup] {
        var vendors: [String] = []
        var families: [String: [String]] = [:]       // vendor -> family keys in order
        var members: [String: [ModelOption]] = [:]   // "vendor|family" -> options
        for option in options {
            let v = vendor(of: option.id), f = familyKey(of: option.id)
            if !vendors.contains(v) { vendors.append(v) }
            if !(families[v] ?? []).contains(f) { families[v, default: []].append(f) }
            members["\(v)|\(f)", default: []].append(option)
        }
        return vendors.map { v in
            ModelGroup(vendor: v, families: (families[v] ?? []).map { f in
                let m = members["\(v)|\(f)"] ?? []
                return ModelFamily(title: title(for: m), options: m)
            })
        }
    }

    /// What to show for the saved value: the CLI's label for it, "Default" when none is
    /// set, or the raw id when the list does not know it (a hand-edited config).
    static func label(for id: String, in options: [ModelOption], defaultLabel: String = "Provider default") -> String {
        if id.isEmpty { return defaultLabel }
        return options.first { $0.id == id }?.label ?? id
    }
}
