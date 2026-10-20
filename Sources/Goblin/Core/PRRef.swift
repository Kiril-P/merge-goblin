//  PRRef.swift — "2456", "#2456", "acme/widgets#2456" or a PR URL, as a value.
//
//  This is the Swift twin of ref_parse in lib/review.sh, and they must agree: the
//  app uses it to give instant feedback while you type, and the CLI re-parses the
//  canonical form it is handed. tests/run.sh and tests/GoblinTests/PRRefTests.swift
//  pin the same table.

import Foundation

struct PRRef: Equatable, Hashable {
    /// owner/name, when the input said which repo. nil for a bare number.
    let slug: String?
    let number: Int

    /// What the CLI is given: never starts with "-", never contains a space.
    var canonical: String { slug.map { "\($0)#\(number)" } ?? String(number) }

    /// "acme/widgets#2456", or "#2456" when the repo is not known yet.
    var display: String { slug.map { "\($0)#\(number)" } ?? "#\(number)" }

    static func parse(_ input: String) -> PRRef? {
        let r = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, r.count <= 300 else { return nil }

        var slug: String? = nil
        var numberText: Substring

        if let range = r.range(of: "github.com/") {
            // https://github.com/owner/name/pull/123[/files][?x][#y]
            var path = r[range.upperBound...]
            if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<q] }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 4, parts[2] == "pull" else { return nil }
            slug = "\(parts[0])/\(parts[1])"
            numberText = parts[3]
        } else if let hash = r.firstIndex(of: "#") {
            let before = r[..<hash]
            slug = before.isEmpty ? nil : String(before)
            numberText = r[r.index(after: hash)...]
        } else {
            numberText = r[...]
        }

        guard !numberText.isEmpty, numberText.count <= 7,
              numberText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(numberText), n >= 1 else { return nil }
        if let s = slug, !Pattern.repoSlug.accepts(s) { return nil }
        return PRRef(slug: slug, number: n)
    }

    /// The first pull request link found anywhere in some text — for the clipboard,
    /// where the thing copied is usually a URL with other words around it. A bare
    /// number is deliberately NOT found this way: any number on the clipboard would
    /// otherwise look like a PR.
    static func firstLink(in text: String) -> PRRef? {
        guard text.count < 20_000, let range = text.range(of: "github.com/") else { return nil }
        var rest = text[range.lowerBound...]
        while true {
            let end = rest.firstIndex(where: { $0.isWhitespace || $0 == ")" || $0 == "]" || $0 == ">" || $0 == "\"" }) ?? rest.endIndex
            if let ref = parse(String(rest[..<end])), ref.slug != nil { return ref }
            guard let next = rest[rest.index(after: rest.startIndex)...].range(of: "github.com/") else { return nil }
            rest = rest[next.lowerBound...]
        }
    }
}
