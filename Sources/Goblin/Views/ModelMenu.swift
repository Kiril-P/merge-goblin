//  ModelMenu.swift — choose a model from the ones the provider actually offers.
//
//  A menu, never a text field: a model name typed by hand is a typo waiting to happen.
//  A long list (Cursor has hundreds) is grouped by vendor, then by model, with the
//  effort/speed variants of one model together. The first entry is always the
//  provider's own default.
//
//  Claude and Codex take effort as a separate setting rather than as model names, so
//  when an `effort` binding is given each of their models opens onto its effort levels,
//  exactly as a Cursor model opens onto its variants. One menu, one choice.

import SwiftUI

struct ModelMenu: View {
    let store: AppStore
    let provider: String
    @Binding var selection: String
    var effort: Binding<String>? = nil
    /// When set, a model+effort pick goes here as ONE change instead of through the two
    /// bindings (which would write the config twice, concurrently).
    var onPick: ((String, String) -> Void)? = nil
    var defaultLabel = "Provider default"

    private var options: [ModelOption] { store.modelCatalog[provider] ?? [] }
    private var levels: [String] { effort == nil ? [] : ProviderInfo.effortLevels(provider) }

    var body: some View {
        Menu {
            item(ModelOption(id: "", label: defaultLabel))
            Divider()
            if options.count > ModelCatalog.groupingThreshold {
                ForEach(ModelCatalog.grouped(options)) { group in
                    Menu(group.vendor) {
                        ForEach(group.families) { family in
                            if family.options.count == 1, let only = family.options.first {
                                item(only)
                            } else {
                                Menu(family.title) { ForEach(family.options) { item($0) } }
                            }
                        }
                    }
                }
            } else {
                ForEach(options) { item($0) }
            }
            if !selection.isEmpty, !options.contains(where: { $0.id == selection }) {
                Divider()
                item(ModelOption(id: selection, label: selection))
            }
        } label: {
            HStack(spacing: 6) {
                if store.isLoadingModels(provider) { ProgressView().controlSize(.mini) }
                Text(verbatim: ModelEffort.label(model: ModelCatalog.label(for: selection, in: options, defaultLabel: defaultLabel),
                                                 effort: levels.isEmpty ? "" : (effort?.wrappedValue ?? "")))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .task(id: provider) { await store.loadModels(provider) }
    }

    @ViewBuilder private func item(_ option: ModelOption) -> some View {
        if levels.isEmpty {
            Button { selection = option.id } label: { check(selection == option.id, option.label) }
        } else {
            ModelEffort.Variants(option: option, levels: levels, model: selection, effort: effort?.wrappedValue ?? "") { m, e in
                if let onPick { onPick(m, e) } else { selection = m; effort?.wrappedValue = e }
            }
        }
    }

    @ViewBuilder private func check(_ on: Bool, _ label: String) -> some View {
        if on { Label(label, systemImage: "checkmark") } else { Text(verbatim: label) }
    }
}

/// A model and its effort, shown and chosen as one thing.
enum ModelEffort {
    /// "GPT-6-Luna High", the way a Cursor variant reads; just the model when the
    /// provider decides the effort.
    static func label(model: String, effort: String) -> String {
        effort.isEmpty ? model : "\(model) \(ProviderInfo.effortLabel(effort))"
    }

    /// One model as a submenu of its effort levels.
    struct Variants: View {
        let option: ModelOption
        let levels: [String]
        let model: String
        let effort: String
        let pick: (String, String) -> Void

        var body: some View {
            let isCurrent = model == option.id
            Menu {
                row("", "Default effort", isCurrent)
                Divider()
                ForEach(levels, id: \.self) { row($0, ProviderInfo.effortLabel($0), isCurrent) }
            } label: {
                if isCurrent { Label(option.label, systemImage: "checkmark") } else { Text(verbatim: option.label) }
            }
        }

        @ViewBuilder private func row(_ level: String, _ text: String, _ isCurrent: Bool) -> some View {
            Button { pick(option.id, level) } label: {
                if isCurrent && effort == level { Label(text, systemImage: "checkmark") } else { Text(verbatim: text) }
            }
        }
    }
}
