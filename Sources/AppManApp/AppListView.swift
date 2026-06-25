import AppManCore
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case apps = "App"
    case settings = "设置"

    var id: String { rawValue }
}

struct AppListView: View {
    @StateObject private var viewModel: AppListViewModel
    @State private var selectedSection: AppSection? = .apps
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
            List(AppSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: iconName(for: section))
                    .tag(section)
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
            switch selectedSection ?? .apps {
            case .apps:
                appsSection
            case .settings:
                settingsSection
            }
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
    private var appsSection: some View {
        AppCatalogView(apps: viewModel.apps, selectedAppID: $selectedAppID)
    }

    @ViewBuilder
    private var settingsSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("设置")
                .font(.title3)
            Text("后续会在这里放清理、更新和行为偏好。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconName(for section: AppSection) -> String {
        switch section {
        case .apps:
            return "app"
        case .settings:
            return "gearshape"
        }
    }
}

private struct AppCatalogView: View {
    let apps: [AppRecord]
    @Binding var selectedAppID: AppRecord.ID?

    var body: some View {
        List(apps, selection: $selectedAppID) { app in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.name)
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(updateVersionText(for: app))
                        .font(.subheadline)
                        .foregroundStyle(updateVersionColor(for: app))
                }

                HStack(spacing: 12) {
                    Text(app.installSource.displayName)
                    Text("当前 \(currentVersionText(for: app))")
                    Text(app.path.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .tag(app.id)
        }
        .navigationTitle("App")
    }

    private func currentVersionText(for app: AppRecord) -> String {
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

    private func updateVersionText(for app: AppRecord) -> String {
        if let version = normalized(app.shortVersion) {
            return version
        }
        return "无更新"
    }

    private func updateVersionColor(for app: AppRecord) -> Color {
        normalized(app.shortVersion) == nil ? .secondary : .primary
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
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
