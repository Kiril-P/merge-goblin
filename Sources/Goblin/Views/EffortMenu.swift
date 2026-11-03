//  EffortMenu.swift — how hard the model thinks, chosen from the levels its CLI accepts.
//
//  Claude and Codex have a reasoning-effort setting; Cursor does not (its efforts are
//  separate models in the model list). A provider without levels shows nothing.

import SwiftUI

struct EffortMenu: View {
    let provider: String
    @Binding var selection: String
    var defaultLabel = "Provider default"

    private var levels: [String] { ProviderInfo.effortLevels(provider) }

    var body: some View {
        if !levels.isEmpty {
            Menu {
                Button { selection = "" } label: { check("", defaultLabel) }
                Divider()
                ForEach(levels, id: \.self) { level in
                    Button { selection = level } label: { check(level, ProviderInfo.effortLabel(level)) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: selection.isEmpty ? defaultLabel : ProviderInfo.effortLabel(selection)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
    }

    @ViewBuilder private func check(_ id: String, _ label: String) -> some View {
        if selection == id { Label(label, systemImage: "checkmark") } else { Text(verbatim: label) }
    }
}
