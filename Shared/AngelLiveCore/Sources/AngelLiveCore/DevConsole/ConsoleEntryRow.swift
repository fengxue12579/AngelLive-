//
//  ConsoleEntryRow.swift
//  AngelLiveCore
//
//  控制台单条日志行 + 详情 sheet。跨端复用。
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
struct ConsoleEntryRow: View {
    let entry: PluginConsoleEntry
    @State private var showDetail = false

    var body: some View {
        Button {
            if entry.status != .loading {
                showDetail = true
            }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(statusColor)
                    .frame(width: 3, height: 36)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.tag)
                            .font(.system(.caption2, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(ConsoleColorPalette.color(forTag: entry.tag).opacity(0.9), in: Capsule())

                        Text(entry.method)
                            .font(.system(.subheadline, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        Text(consoleTimeFormatter.string(from: entry.timestamp))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        if let duration = entry.duration {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(String(format: "%.0fms", duration * 1000))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    statusBadge

                    if entry.status != .loading {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            ConsoleEntryDetailView(entry: entry)
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .loading: .orange
        case .success: .green
        case .error: .red
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch entry.status {
        case .loading:
            ProgressView().controlSize(.small)
        case .success:
            Text("成功")
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.12), in: Capsule())
        case .error:
            Text("失败")
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red.opacity(0.12), in: Capsule())
        }
    }
}
