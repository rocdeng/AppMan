import AppManCore
import SwiftUI

struct AppListView: View {
    @StateObject private var viewModel: AppListViewModel
    @State private var selectedAppID: AppRecord.ID?
    @State private var didScanOnAppear = false

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: AppListViewModel())
    }

    @MainActor
    init(viewModel: AppListViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationSplitView {
            List(viewModel.apps, selection: $selectedAppID) { app in
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.headline)
                    Text(app.installSource.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .tag(app.id)
            }
            .navigationTitle("AppMan")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task {
                            await viewModel.scan()
                        }
                    } label: {
                        Label("扫描", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isScanning)
                }
            }
        } detail: {
            detailView
        }
        .overlay {
            if viewModel.isScanning {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView("正在扫描...")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .alert(
            "扫描失败",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.errorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "未知错误")
        }
        .onAppear {
            guard !didScanOnAppear else {
                return
            }

            didScanOnAppear = true
            Task {
                await viewModel.scan()
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let app = selectedApp {
            AppDetailView(app: app)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "app.dashed")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("选择一个 App")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedApp: AppRecord? {
        viewModel.apps.first { $0.id == selectedAppID }
    }
}

private struct AppDetailView: View {
    let app: AppRecord

    var body: some View {
        Form {
            LabeledContent("名称", value: app.name)
            LabeledContent("Bundle ID", value: app.bundleIdentifier ?? "未知")
            LabeledContent("版本", value: versionText)
            LabeledContent("安装渠道", value: app.installSource.displayName)
            LabeledContent("路径", value: app.path.path)
            LabeledContent("大小", value: byteCountFormatter.string(fromByteCount: app.sizeBytes))
        }
        .formStyle(.grouped)
        .navigationTitle(app.name)
    }

    private var versionText: String {
        let shortVersion = normalized(app.shortVersion)
        let buildVersion = normalized(app.buildVersion)

        switch (shortVersion, buildVersion) {
        case let (short?, build?):
            return "\(short) (\(build))"
        case let (short?, nil):
            return short
        case let (nil, build?):
            return build
        case (nil, nil):
            return "未知"
        }
    }

    private var byteCountFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
