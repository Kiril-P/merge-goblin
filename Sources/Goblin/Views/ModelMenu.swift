//  ModelMenu.swift — choose a model from the ones the provider actually offers.
//
//  A menu, never a text field: a model name typed by hand is a typo waiting to happen.
//  A long list (Cursor has hundreds) is grouped by vendor, then by model, with the
//  effort/speed variants of one model together. The first entry is always the
//  provider's own default.

import SwiftUI

struct ModelMenu: View {
    let store: AppStore
    let provider: String
    @Binding var selection: String
    var defaultLabel = "Provider default"

    private var options: [ModelOption] { store.modelCatalog[provider] ?? [] }

    var body: some View {
        Menu {
            Button { selection = "" } label: { check("", defaultLabel) }
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
                Text(verbatim: ModelCatalog.label(for: selection, in: options, defaultLabel: defaultLabel))
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

    private func item(_ option: ModelOption) -> some View {
        Button { selection = option.id } label: { check(option.id, option.label) }
    }

    @ViewBuilder private func check(_ id: String, _ label: String) -> some View {
        if selection == id { Label(label, systemImage: "checkmark") } else { Text(verbatim: label) }
    }
}
