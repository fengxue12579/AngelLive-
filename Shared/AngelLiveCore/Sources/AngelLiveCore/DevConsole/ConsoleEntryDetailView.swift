//
//  ConsoleEntryDetailView.swift
//  AngelLiveCore
//
//  控制台日志条目详情。跨端复用,通过 ConsolePasteboard 屏蔽剪贴板差异。
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
struct ConsoleEntryDetailView: View {
    let entry: PluginConsoleEntry
    @Environment(\.dismiss) private var dismiss
    @State private var copiedIndex: Int? = nil

    var body: some View {
        NavigationStack {
            List {
                Section("基本信息") {
                    row("插件", entry.tag)
                    row("方法", entry.method)
                    row("时间", consoleTimeFormatter.string(from: entry.timestamp))
                    if let duration = entry.duration {
                        row("耗时", String(format: "%.1fms", duration * 1000))
                    }
                    HStack {
                        Text("状态")
                            .foregroundStyle(.secondary)
                        Spacer()
                        statusLabel
                    }
                }

                if let body = entry.requestBody, !body.isEmpty, body != "{}" {
                    Section("调用参数") {
                        Text(prettyJSON(body))
                            .font(.system(.caption, design: .monospaced))
                            .consoleSelectableText()
                    }
                }

                if let response = entry.responseBody {
                    Section("返回数据") {
                        Text(prettyJSON(response))
                            .font(.system(.caption, design: .monospaced))
                            .consoleSelectableText()
                            .lineLimit(50)
                    }
                }

                if let error = entry.errorMessage {
                    Section("错误信息") {
                        Text(error)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .consoleSelectableText()
                    }
                }

                ForEach(Array(entry.httpRecords.enumerated()), id: \.element.id) { index, record in
                    httpRecordSection(record, index: index)
                }
            }
            .navigationTitle("\(entry.tag).\(entry.method)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func httpRecordSection(_ record: PluginConsoleHTTPRecord, index: Int) -> some View {
        let isCopied = copiedIndex == index

        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.method)
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.blue.opacity(0.8), in: Capsule())

                    if let code = record.statusCode {
                        Text("\(code)")
                            .font(.system(.caption2, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(httpStatusColor(code).opacity(0.8), in: Capsule())
                    }

                    if let duration = record.duration {
                        Text(String(format: "%.0fms", duration * 1000))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(record.url)
                    .font(.system(.caption, design: .monospaced))
                    .consoleSelectableText()
                    .lineLimit(3)
            }

            ConsoleDisclosure("请求头") {
                ForEach(record.headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key)
                            .font(.system(.caption2, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.system(.caption2, design: .monospaced))
                            .consoleSelectableText()
                            .lineLimit(2)
                    }
                }
            }

            if let body = record.body, !body.isEmpty {
                ConsoleDisclosure("请求体") {
                    Text(prettyJSON(body))
                        .font(.system(.caption2, design: .monospaced))
                        .consoleSelectableText()
                }
            }

            if let respHeaders = record.responseHeaders, !respHeaders.isEmpty {
                ConsoleDisclosure("响应头") {
                    ForEach(respHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key)
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Text(value)
                                .font(.system(.caption2, design: .monospaced))
                                .consoleSelectableText()
                                .lineLimit(2)
                        }
                    }
                }
            }

            if let respBody = record.responseBody {
                ConsoleDisclosure("响应体") {
                    Text(prettyJSON(respBody))
                        .font(.system(.caption2, design: .monospaced))
                        .consoleSelectableText()
                        .lineLimit(30)
                }
            }

            if let error = record.error {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
            }

            if ConsolePasteboard.isAvailable {
                Button {
                    ConsolePasteboard.copy(buildCurl(for: record))
                    copiedIndex = index
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedIndex == index { copiedIndex = nil }
                    }
                } label: {
                    HStack {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "已复制" : "复制 cURL")
                    }
                    .font(.system(.caption))
                    .foregroundStyle(isCopied ? .green : .accentColor)
                    .frame(maxWidth: .infinity)
                }
            }
        } header: {
            Text("HTTP 请求 #\(index + 1)")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch entry.status {
        case .loading:
            Label("加载中", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.orange)
        case .success:
            Label("成功", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Label("失败", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
        }
    }

    private func httpStatusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: .green
        case 300..<400: .orange
        default: .red
        }
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return str
    }

    private func buildCurl(for record: PluginConsoleHTTPRecord) -> String {
        let escaped = { (s: String) in s.replacingOccurrences(of: "'", with: "'\\''") }
        var parts = ["curl -X \(record.method) '\(escaped(record.url))'"]

        for (key, value) in record.headers.sorted(by: { $0.key < $1.key }) {
            parts.append("  -H '\(key): \(escaped(value))'")
        }

        if let body = record.body, !body.isEmpty {
            parts.append("  -d '\(escaped(body))'")
        }

        return parts.joined(separator: " \\\n")
    }
}
