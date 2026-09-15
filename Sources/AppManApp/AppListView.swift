import AppManCore
import AppKit
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case apps = "应用程序"
    case settings = "设置"

    var id: String { rawValue }
}

private enum AppLayout {
    static let titlebarHeight: CGFloat = 29
    static let toolbarHeight: CGFloat = 27
    static let headerHeight: CGFloat = 25
    static let chromeHeight = titlebarHeight + toolbarHeight + headerHeight
    static let tableTopInset = titlebarHeight + toolbarHeight - 12
}

private enum AppTableColumnLayout {
    static let nameWidth: CGFloat = 222
    static let sourceWidth: CGFloat = 115
    static let currentVersionWidth: CGFloat = 328
    static let latestVersionWidth: CGFloat = 220
    static let scrollerWidth: CGFloat = 16
    static let nameLeadingPadding: CGFloat = 29
    static let cellHorizontalPadding: CGFloat = 8

    static func nameWidth(for tableWidth: CGFloat) -> CGFloat {
        let fixedWidth = sourceWidth + currentVersionWidth + latestVersionWidth
        return max(nameWidth, tableWidth - fixedWidth)
    }
}

struct AppListView: View {
    @StateObject private var viewModel: AppListViewModel
    @State private var selectedSection: AppSection = .apps
    @State private var selectedAppID: AppRecord.ID?
    @State private var didScanOnAppear = false
    @State private var searchText = ""
    @State private var searchFocusToken = 0
    @State private var isShowingAppInfo = false
    @State private var appPendingUninstall: AppRecord?
    @State private var appPendingSelfUpdateURL: AppRecord?
    @State private var selectedIgnoredAppPath: URL?

    private var selectedApp: AppRecord? {
        guard let selectedAppID else {
            return nil
        }

        return viewModel.apps.first { $0.id == selectedAppID }
    }

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: AppListViewModel())
    }

    @MainActor
    init(viewModel: AppListViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            SystemWindowConfigurator(
                subtitle: selectedSection == .apps ? "所有应用程序" : "设置"
            )
        )
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    ControlGroup {
                    Button {
                        isShowingAppInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 36, height: 36)
                    }
                    .disabled(isBusy || selectedApp == nil)
                    .help("App 信息")

                    Button {
                        guard let selectedApp else {
                            return
                        }
                        Task {
                            await viewModel.checkUpdates(for: selectedApp)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 36, height: 36)
                    }
                    .disabled(isBusy || selectedApp == nil)
                    .help("检查更新")
                    }

                    ControlGroup {
                    Menu {
                        Button("更新 App 列表") {
                            Task {
                                await viewModel.scan()
                            }
                        }
                        Button("检查所有更新") {
                            Task {
                                await viewModel.scan()
                                await viewModel.checkUpdates()
                            }
                        }
                        Button("更新所有") {
                            Task {
                                await viewModel.updateAll { url in
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 36, height: 36)
                    }
                    .disabled(isBusy)
                    .help("更多更新操作")

                    Button {
                        appPendingUninstall = selectedApp
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .regular))
                            .frame(width: 36, height: 36)
                    }
                    .disabled(isBusy || selectedApp == nil)
                    .help("卸载")
                    }

                    ZStack {
                        ToolbarSectionControl(selection: $selectedSection)
                        HStack(spacing: 0) {
                            ForEach(AppSection.allCases) { section in
                                Text(section.rawValue)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(width: 230)
                }
                .controlSize(.large)
            }

            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(
                    text: $searchText,
                    focusToken: searchFocusToken
                )
                .frame(width: 205)
            }
        }
        .background {
            Button("搜索") {
                searchFocusToken += 1
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .overlay {
            if viewModel.isScanning || viewModel.isCheckingUpdates || viewModel.isUpdatingApp || viewModel.isUninstalling {
                ProgressOverlay(text: progressText) {
                    viewModel.cancelUpdate()
                }
            }
        }
        .alert(
            "操作失败",
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
        .alert(
            "下载失败",
            isPresented: Binding(
                get: { viewModel.downloadFailurePrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissDownloadFailurePrompt()
                    }
                }
            )
        ) {
            Button("访问官网") {
                viewModel.openDownloadFailureWebsite { url in
                    NSWorkspace.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {
                viewModel.dismissDownloadFailurePrompt()
            }
        } message: {
            if let prompt = viewModel.downloadFailurePrompt {
                Text("\(prompt.message)\n\n是否访问 \(prompt.appName) 官网手工下载？")
            }
        }
        .alert(
            "Recipe 校验",
            isPresented: Binding(
                get: { viewModel.recipeValidationNotice != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.recipeValidationNotice = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.recipeValidationNotice ?? "")
        }
        .alert(
            "部分关联项未清理",
            isPresented: Binding(
                get: { viewModel.uninstallWarningMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.uninstallWarningMessage = nil
                    }
                }
            )
        ) {
            Button("显示 AppMan 并打开设置") {
                openFullDiskAccessSettings()
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.uninstallWarningMessage ?? "")
        }
        .overlay(alignment: .top) {
            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .onAppear {
                        Task {
                            try? await Task.sleep(nanoseconds: 1_600_000_000)
                            await MainActor.run {
                                viewModel.clearStatusMessage()
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $isShowingAppInfo) {
            if let selectedApp {
                AppInfoDialog(app: selectedApp)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.recipeValidationPresentation != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissRecipeValidation()
                    }
                }
            )
        ) {
            if let presentation = viewModel.recipeValidationPresentation {
                RecipeValidationDialog(presentation: presentation) {
                    viewModel.dismissRecipeValidation()
                }
            }
        }
        .sheet(item: $appPendingSelfUpdateURL) { app in
            SelfUpdateURLDialog(app: app) { url in
                await viewModel.saveSelfUpdateURL(url, for: app)
                appPendingSelfUpdateURL = nil
            }
        }
        .sheet(item: $appPendingUninstall) { app in
            UninstallReviewDialog(app: app) { selectedCandidates in
                let didUninstall = await viewModel.uninstall(app, candidates: selectedCandidates)
                if didUninstall {
                    appPendingUninstall = nil
                    selectedAppID = nil
                }
            }
        }
        .onAppear {
            guard !didScanOnAppear else {
                return
            }

            didScanOnAppear = true

            if viewModel.hasCachedApps {
                if viewModel.automaticallyChecksUpdatesOnLaunch {
                    Task {
                        await viewModel.checkUpdates()
                    }
                }
                return
            }

            Task {
                await viewModel.scan()
                if viewModel.automaticallyChecksUpdatesOnLaunch {
                    await viewModel.checkUpdates()
                }
            }
        }
    }

    private func openFullDiskAccessSettings() {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
            viewModel.errorMessage = "当前通过 swift run 启动的 AppMan 不是标准 .app，无法添加到“完全磁盘访问权限”列表。请退出后运行 Scripts/open_app.sh，再重新授权。"
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([appURL])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(settingsURL)
            }
        }
    }

    private var progressText: String {
        if viewModel.isScanning {
            return "正在扫描..."
        }
        if viewModel.isCheckingUpdates {
            return viewModel.updateProgressText ?? "正在检查更新..."
        }
        if viewModel.isUpdatingApp {
            return viewModel.updateProgressText ?? "正在更新..."
        }
        return "正在卸载..."
    }

    private var isBusy: Bool {
        viewModel.isScanning
            || viewModel.isCheckingUpdates
            || viewModel.isUpdatingApp
            || viewModel.isUninstalling
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .apps:
            appsSection
        case .settings:
            settingsSection
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        VStack(spacing: 0) {
            AppCatalogHeader()
                .frame(height: AppLayout.headerHeight)

            AppCatalogView(
                apps: viewModel.apps,
                selectedAppID: $selectedAppID,
                searchText: $searchText,
                showInfo: {
                    isShowingAppInfo = true
                },
                validateRecipe: { app in
                    Task {
                        await viewModel.validateRecipe(for: app)
                    }
                },
                updateApp: { app in
                    await viewModel.update(app) { url in
                        NSWorkspace.shared.open(url)
                    }
                },
                editSelfUpdateURL: { app in
                    appPendingSelfUpdateURL = app
                },
                ignoreUpdates: { app in
                    viewModel.ignoreUpdates(for: app)
                }
            )
        }
    }

    @ViewBuilder
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(
                "启动 App 时自动检查更新",
                isOn: Binding(
                    get: { viewModel.automaticallyChecksUpdatesOnLaunch },
                    set: { viewModel.setAutomaticallyChecksUpdatesOnLaunch($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 6) {
                Text("TinyFish API Key")
                    .font(.system(size: 13, weight: .semibold))
                SecureField(
                    "未设置时使用 Google 搜索",
                    text: Binding(
                        get: { viewModel.tinyFishAPIKey },
                        set: { viewModel.setTinyFishAPIKey($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .frame(maxWidth: 420)
            }

            Divider()

            Text("忽略更新检查")
                .font(.system(size: 13, weight: .semibold))

            IgnoredAppsList(
                ignoredApps: viewModel.ignoredApps,
                selectedIgnoredAppPath: $selectedIgnoredAppPath
            )

            HStack {
                Spacer()
                Button("删除") {
                    if let selectedIgnoredAppPath {
                        viewModel.removeIgnoredApp(path: selectedIgnoredAppPath)
                        self.selectedIgnoredAppPath = nil
                    }
                }
                .disabled(selectedIgnoredAppPath == nil)
            }
        }
        .padding(.top, 26)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProgressOverlay: View {
    let text: String
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
            VStack(spacing: 12) {
                ProgressView()
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 260)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .background(EscapeKeyCatcher(action: cancel).frame(width: 0, height: 0))
    }
}

private struct EscapeKeyCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> EscapeKeyView {
        let view = EscapeKeyView()
        view.action = action
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: EscapeKeyView, context: Context) {
        nsView.action = action
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class EscapeKeyView: NSView {
    var action: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            action?()
            return
        }
        super.keyDown(with: event)
    }
}

private struct AppChromeView: View {
    @Binding var selectedSection: AppSection
    @Binding var searchText: String
    let showsHeader: Bool
    let hasSelection: Bool
    let isScanning: Bool
    let isCheckingUpdates: Bool
    let isUpdatingApp: Bool
    let isUninstalling: Bool
    let showInfo: () -> Void
    let checkSelectedAppUpdates: () async -> Void
    let refreshAppList: () async -> Void
    let checkAllUpdates: () async -> Void
    let updateAll: () async -> Void
    let uninstall: () -> Void
    @State private var isSearchExpanded = false
    @State private var searchFocusToken = 0

    private var isBusy: Bool {
        isScanning || isCheckingUpdates || isUpdatingApp || isUninstalling
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                AppToolbarTitleView(selectedSection: selectedSection)
                    .offset(x: 108, y: 8)

                HStack(spacing: 13.5) {
                    LiquidIconButtonGroup(horizontalPadding: 5) {
                        LiquidIconButton(
                            systemImage: "info.circle",
                            help: "App 信息",
                            isDisabled: isBusy || !hasSelection,
                            action: showInfo
                        )

                        LiquidSplitMenuButton(
                            systemImage: "arrow.clockwise.circle",
                            help: "检查更新",
                            isPrimaryDisabled: isBusy || !hasSelection,
                            isMenuDisabled: isBusy,
                            primaryAction: checkSelectedAppUpdates,
                            menuItems: [
                                LiquidSplitMenuButton.Item(title: "更新 App 列表", action: refreshAppList),
                                LiquidSplitMenuButton.Item(title: "检查所有更新", action: checkAllUpdates),
                                LiquidSplitMenuButton.Item(title: "更新所有", action: updateAll),
                            ]
                        )

                        LiquidIconButton(
                            systemImage: "trash",
                            help: "卸载",
                            isDisabled: isBusy || !hasSelection,
                            action: uninstall
                        )
                    }

                    LiquidSegmentedTabs(selection: $selectedSection)
                }
                .offset(x: 257, y: 8)

                LiquidSearchControl(
                    text: $searchText,
                    isExpanded: $isSearchExpanded,
                    focusToken: searchFocusToken
                )
                .position(
                    x: proxy.size.width - (isSearchExpanded ? 143 : 24),
                    y: 20
                )

                if showsHeader {
                    AppCatalogHeader()
                        .frame(width: proxy.size.width, height: AppLayout.headerHeight)
                        .offset(y: AppLayout.titlebarHeight + AppLayout.toolbarHeight)
                }

                Button("搜索") {
                    isSearchExpanded = true
                    searchFocusToken += 1
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
        }
        .frame(height: showsHeader ? AppLayout.chromeHeight : AppLayout.titlebarHeight + AppLayout.toolbarHeight)
        .frame(maxWidth: .infinity)
        .background {
            VisualEffectBlur(material: .titlebar, blendingMode: .withinWindow)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct AppInfoDialog: View {
    let app: AppRecord
    @Environment(\.dismiss) private var dismiss
    private var details: AppInfoDetails {
        AppInfoDetails(app: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AppIconImage(path: app.path)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 18, weight: .semibold))
                    Text(app.bundleIdentifier ?? "无 Bundle ID")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                AppInfoRow(title: "来源", value: app.installSource.shortDisplayName)
                AppInfoRow(title: "当前版本", value: details.currentVersion)
                AppInfoRow(title: "最新版本", value: details.latestVersion)
                AppInfoLinkRow(title: "App 网站", label: details.websiteTitle, url: details.websiteURL)
                AppInfoLinkRow(title: "最新版链接", label: details.latestVersionLinkTitle, url: details.latestVersionURL)
                AppInfoRow(title: "大小", value: ByteCountFormatter.string(fromByteCount: app.sizeBytes, countStyle: .file))
                AppInfoRow(title: "路径", value: app.path.path)
            }

            HStack {
                Spacer()
                Button("好") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct RecipeValidationDialog: View {
    let presentation: RecipeValidationPresentation
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppIconImage(path: presentation.app.path)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recipe 校验：\(presentation.app.name)")
                        .font(.system(size: 16, weight: .semibold))
                    Text(presentation.recipe.id)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            GroupBox("校验结果") {
                validationResult
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }

            GroupBox("Recipe JSON") {
                ScrollView([.horizontal, .vertical]) {
                    Text(presentation.recipeJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 290)
            }

            HStack {
                Spacer()
                Button("好", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 600)
    }

    @ViewBuilder
    private var validationResult: some View {
        switch presentation.state {
        case .validating:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在提取最新版本并校验安装包地址...")
            }
            .font(.system(size: 13))
        case let .completed(result):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                RecipeResultRow(title: "最新版", value: result.latestVersion ?? "未获取到")
                RecipeResultRow(title: "安装包", value: result.packageURL?.absoluteString ?? "未获取到")
                GridRow {
                    Text("下载校验")
                        .foregroundStyle(.secondary)
                    Label(
                        result.downloadValidationMessage,
                        systemImage: result.downloadIsValid ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(result.downloadIsValid ? Color.green : Color.red)
                    .textSelection(.enabled)
                }
            }
            .font(.system(size: 13))
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

private struct RecipeResultRow: View {
    let title: String
    let value: String

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

private struct AppInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .font(.system(size: 13))
    }
}

private struct AppInfoLinkRow: View {
    let title: String
    let label: String
    let url: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)

            if let url {
                Button {
                    openURL(url)
                } label: {
                    Text(label)
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .help(url.absoluteString)
                .textSelection(.enabled)
            } else {
                Text(label)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13))
    }
}

private struct SelfUpdateURLDialog: View {
    let app: AppRecord
    let save: (URL) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String
    @State private var validationMessage: String?

    init(app: AppRecord, save: @escaping (URL) async -> Void) {
        self.app = app
        self.save = save
        switch app.updateStatus {
        case let .needsOfficialWebsiteConfirmation(candidateURL):
            _urlText = State(initialValue: candidateURL.absoluteString)
        default:
            _urlText = State(initialValue: app.updateURL?.absoluteString ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text(app.name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("https://example.com/download", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存并检查") {
                    guard let url = normalizedURL else {
                        validationMessage = "请输入有效的网址"
                        return
                    }

                    Task {
                        await save(url)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var title: String {
        switch app.updateStatus {
        case .needsOfficialWebsiteConfirmation:
            return "确认官网 / 检查更新网址"
        default:
            return "需手动输入检查更新网址"
        }
    }

    private var normalizedURL: URL? {
        let trimmedText = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return nil
        }

        let urlTextWithScheme = trimmedText.contains("://") ? trimmedText : "https://\(trimmedText)"
        guard let url = URL(string: urlTextWithScheme),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host(percentEncoded: false) != nil else {
            return nil
        }
        return url
    }
}

private struct IgnoredAppsList: View {
    let ignoredApps: [IgnoredAppRecord]
    @Binding var selectedIgnoredAppPath: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("名称")
                    .frame(width: 180, alignment: .leading)
                Text("来源")
                    .frame(width: 80, alignment: .leading)
                Text("路径")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.primary.opacity(0.04))

            List(selection: $selectedIgnoredAppPath) {
                ForEach(ignoredApps) { app in
                    HStack(spacing: 0) {
                        Text(app.name)
                            .frame(width: 180, alignment: .leading)
                        Text(app.sourceName)
                            .frame(width: 80, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(app.path.path)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .tag(app.path)
                }
            }
            .listStyle(.plain)
        }
        .frame(minHeight: 180)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct UninstallReviewDialog: View {
    let app: AppRecord
    let remove: ([UninstallCandidate]) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [UninstallCandidate] = []
    @State private var selectedCandidateIDs = Set<UninstallCandidate.ID>()
    @State private var isLoading = true
    @State private var isRemoving = false
    @State private var errorMessage: String?

    private var selectedCandidates: [UninstallCandidate] {
        candidates.filter { selectedCandidateIDs.contains($0.id) }
    }

    private var selectedSizeBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ZStack {
                candidateList

                if isLoading {
                    ProgressView("正在查找关联文件...")
                        .font(.system(size: 12))
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(height: 330)

            Divider()

            footer
        }
        .frame(width: 640)
        .task {
            await loadCandidates()
        }
        .alert(
            "查找失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Text("\(selectedCandidates.count) files were found")
                .font(.system(size: 17, weight: .regular))

            Text("·")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            Text(ByteCountFormatter.string(fromByteCount: selectedSizeBytes, countStyle: .file))
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.blue)

            Spacer()

            Button {
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 21, weight: .regular))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("帮助")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(candidates) { candidate in
                    UninstallCandidateRow(
                        candidate: candidate,
                        isSelected: Binding(
                            get: { selectedCandidateIDs.contains(candidate.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedCandidateIDs.insert(candidate.id)
                                } else if !candidate.isRequired {
                                    selectedCandidateIDs.remove(candidate.id)
                                }
                            }
                        )
                    )
                }

                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.045))
                        .frame(height: 42)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 13))
            .keyboardShortcut(.cancelAction)
            .disabled(isRemoving)

            Button {
                Task {
                    isRemoving = true
                    await remove(selectedCandidates)
                    isRemoving = false
                }
            } label: {
                if isRemoving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 68)
                } else {
                    Text("Remove")
                        .font(.system(size: 13))
                        .frame(width: 68)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isRemoving || selectedCandidates.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.035))
    }

    private func loadCandidates() async {
        isLoading = true
        errorMessage = nil

        do {
            let app = self.app
            let loadedCandidates = try await Task.detached(priority: .userInitiated) {
                try UninstallCandidateFinder().findCandidates(for: app)
            }.value

            candidates = loadedCandidates
            selectedCandidateIDs = Set(loadedCandidates.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private struct UninstallCandidateRow: View {
    let candidate: UninstallCandidate
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(candidate.isRequired)
                .frame(width: 22)

            CandidateIcon(candidate: candidate)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Text(displayPath(candidate.url))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            Text(ByteCountFormatter.string(fromByteCount: candidate.sizeBytes, countStyle: .file))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(minWidth: 68, alignment: .trailing)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
            } label: {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("在 Finder 中显示")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func displayPath(_ url: URL) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(homePath) else {
            return path
        }

        return "~" + path.dropFirst(homePath.count)
    }
}

private struct CandidateIcon: NSViewRepresentable {
    let candidate: UninstallCandidate

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        imageView.image = NSWorkspace.shared.icon(forFile: candidate.url.path)
    }
}

private struct AppIconImage: NSViewRepresentable {
    let path: URL

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        imageView.image = NSWorkspace.shared.icon(forFile: path.path)
    }
}

private struct LiquidIconButtonGroup<Content: View>: View {
    let horizontalPadding: CGFloat
    @ViewBuilder var content: () -> Content

    init(horizontalPadding: CGFloat = 9, @ViewBuilder content: @escaping () -> Content) {
        self.horizontalPadding = horizontalPadding
        self.content = content
    }

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: 36)
        .liquidGlassCapsule()
    }
}

private struct AppToolbarTitleView: View {
    let selectedSection: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text("AppMan")
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(.primary)
            Text(selectedSection == .apps ? "所有应用程序" : "设置")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(width: 220, height: 36, alignment: .leading)
    }
}

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = "搜索"
        searchField.controlSize = .large
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.searchFieldChanged(_:))
        searchField.delegate = context.coordinator
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if searchField.stringValue != text {
            searchField.stringValue = text
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                searchField.window?.makeFirstResponder(searchField)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var lastFocusToken = 0

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func searchFieldChanged(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }
            text.wrappedValue = searchField.stringValue
        }
    }
}

private struct ToolbarSectionControl: NSViewRepresentable {
    @Binding var selection: AppSection

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: AppSection.allCases.map { _ in " " },
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentStyle = .automatic
        control.controlSize = .large
        control.font = .systemFont(ofSize: 13)
        control.selectedSegmentBezelColor = .controlAccentColor
        control.selectedSegment = selectedIndex
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        if control.selectedSegment != selectedIndex {
            control.selectedSegment = selectedIndex
        }
    }

    private var selectedIndex: Int {
        AppSection.allCases.firstIndex(of: selection) ?? 0
    }

    final class Coordinator: NSObject {
        var selection: Binding<AppSection>

        init(selection: Binding<AppSection>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard AppSection.allCases.indices.contains(sender.selectedSegment) else {
                return
            }
            selection.wrappedValue = AppSection.allCases[sender.selectedSegment]
        }
    }
}

private struct LiquidIconButton: View {
    let systemImage: String
    var trailingSystemImage: String?
    let help: String
    let isDisabled: Bool
    let action: () -> Void

    init(
        systemImage: String,
        trailingSystemImage: String? = nil,
        help: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.trailingSystemImage = trailingSystemImage
        self.help = help
        self.isDisabled = isDisabled
        self.action = action
    }

    init(
        systemImage: String,
        trailingSystemImage: String? = nil,
        help: String,
        isDisabled: Bool,
        action: @escaping () async -> Void
    ) {
        self.init(
            systemImage: systemImage,
            trailingSystemImage: trailingSystemImage,
            help: help,
            isDisabled: isDisabled
        ) {
            Task {
                await action()
            }
        }
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16.5, weight: .regular))

                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(width: trailingSystemImage == nil ? 30 : 42, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? .tertiary : .primary)
        .disabled(isDisabled)
        .help(help)
    }
}

private struct LiquidSplitMenuButton: View {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let action: () async -> Void
    }

    let systemImage: String
    let help: String
    let isPrimaryDisabled: Bool
    let isMenuDisabled: Bool
    let primaryAction: () async -> Void
    let menuItems: [Item]

    var body: some View {
        HStack(spacing: 0) {
            Button {
                Task {
                    await primaryAction()
                }
            } label: {
                Image(systemName: systemImage)
                    .font(.system(size: 16.5, weight: .regular))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isPrimaryDisabled ? .tertiary : .primary)
            .disabled(isPrimaryDisabled)
            .help(help)

            Menu {
                ForEach(menuItems) { item in
                    Button(item.title) {
                        Task {
                            await item.action()
                        }
                    }
                }
            } label: {
                Color.clear
                    .frame(width: 8, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(isMenuDisabled ? .tertiary : .primary)
            .disabled(isMenuDisabled)
            .help("更多更新操作")
        }
    }
}

private struct LiquidSegmentedTabs: View {
    @Binding var selection: AppSection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 92, height: 28)
                        .background {
                            if selection == section {
                                Capsule()
                                    .fill(Color.primary.opacity(0.145))
                                    .overlay {
                                        Capsule()
                                            .stroke(Color.white.opacity(0.78), lineWidth: 0.65)
                                    }
                                    .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)

                if section != AppSection.allCases.last {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1, height: 24)
                }
            }
        }
        .padding(4)
        .frame(height: 36)
        .liquidSegmentedGlassCapsule()
    }
}

private struct LiquidSearchControl: View {
    @Binding var text: String
    @Binding var isExpanded: Bool
    let focusToken: Int
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isExpanded {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("搜索 App", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isFocused)
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: 238, height: 36)
                .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isFocused ? Color.accentColor.opacity(0.78) : Color.primary.opacity(0.08), lineWidth: isFocused ? 3 : 1)
                }
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 3)
                .onAppear {
                    focusSearchField()
                }
                .onChange(of: focusToken) { _ in
                    isExpanded = true
                    focusSearchField()
                }
                .onChange(of: isFocused) { focused in
                    if !focused {
                        text = ""
                        isExpanded = false
                    }
                }
            } else {
                Button {
                    isExpanded = true
                    focusSearchField()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20.5, weight: .regular))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .liquidGlassCircle()
                .help("搜索 App")
            }
        }
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isFocused = true
        }
    }
}

private extension View {
    func liquidGlassCapsule() -> some View {
        background(.ultraThinMaterial, in: Capsule())
            .background(Color.white.opacity(0.30), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.98),
                                Color.white.opacity(0.54),
                                Color.primary.opacity(0.10),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.65
                    )
            }
            .overlay(alignment: .top) {
                Capsule()
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.65)
                    .blur(radius: 0.6)
                    .offset(y: 0.5)
                    .mask(alignment: .top) {
                        Capsule().frame(height: 18)
                    }
            }
            .shadow(color: Color.black.opacity(0.055), radius: 18, x: 0, y: 7)
    }

    func liquidGlassCircle() -> some View {
        background(.ultraThinMaterial, in: Circle())
            .background(Color.white.opacity(0.30), in: Circle())
            .overlay {
                Circle().stroke(Color.white.opacity(0.98), lineWidth: 0.65)
            }
            .shadow(color: Color.black.opacity(0.055), radius: 18, x: 0, y: 7)
    }

    func liquidSegmentedGlassCapsule() -> some View {
        background(.ultraThinMaterial, in: Capsule())
            .background(Color.white.opacity(0.34), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(1.0),
                                Color.white.opacity(0.58),
                                Color.primary.opacity(0.09),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.65
                    )
            }
            .overlay(alignment: .top) {
                Capsule()
                    .stroke(Color.white.opacity(0.30), lineWidth: 0.65)
                    .blur(radius: 0.5)
                    .offset(y: 0.5)
                    .mask(alignment: .top) {
                        Capsule().frame(height: 18)
                    }
            }
            .shadow(color: Color.black.opacity(0.052), radius: 18, x: 0, y: 7)
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

private struct WindowChromeConfigurator<ChromeContent: View>: NSViewRepresentable {
    let chromeHeight: CGFloat
    let chromeContent: ChromeContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window, context: context)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.hostingView?.removeFromSuperview()
        coordinator.hostingView = nil
        coordinator.trafficLightOverlay?.removeFromSuperview()
        coordinator.trafficLightOverlay = nil
    }

    private func configure(window: NSWindow?, context: Context) {
        guard let window else {
            return
        }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.toolbarStyle = .unifiedCompact
        window.sharingType = .readOnly
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.acceptsMouseMovedEvents = true

        installChrome(in: window, context: context)

        if CommandLine.arguments.contains("--ui-snapshot") {
            window.setContentSize(NSSize(width: 960, height: 640))
            installChrome(in: window, context: context)
        }

        AppUISnapshotter.scheduleIfNeeded(for: window)
    }

    private func installChrome(in window: NSWindow, context: Context) {
        guard let frameView = window.contentView?.superview else {
            return
        }

        let hostingView: ChromeHostingView
        if let existingHostingView = context.coordinator.hostingView {
            hostingView = existingHostingView
            hostingView.rootView = AnyView(chromeContent)
        } else {
            hostingView = ChromeHostingView(rootView: AnyView(chromeContent))
            hostingView.identifier = NSUserInterfaceItemIdentifier("AppManChromeHostingView")
            hostingView.translatesAutoresizingMaskIntoConstraints = true
            hostingView.autoresizingMask = [.width, .minYMargin]
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            context.coordinator.hostingView = hostingView
        }

        if hostingView.superview === frameView {
            hostingView.removeFromSuperview()
        }
        frameView.addSubview(hostingView, positioned: .above, relativeTo: nil)

        context.coordinator.trafficLightOverlay?.removeFromSuperview()

        let frameBounds = frameView.bounds
        hostingView.frame = NSRect(
            x: 0,
            y: max(0, frameBounds.height - chromeHeight),
            width: frameBounds.width,
            height: chromeHeight
        )
        positionSystemTrafficLights(in: window, above: hostingView)
        installTrafficLightGlyphOverlay(in: frameView, context: context)

    }

    private func positionSystemTrafficLights(in window: NSWindow, above hostingView: NSView) {
        let placements: [(NSWindow.ButtonType, CGFloat)] = [
            (.closeButton, 19),
            (.miniaturizeButton, 42),
            (.zoomButton, 65),
        ]

        for (buttonType, originX) in placements {
            guard let button = window.standardWindowButton(buttonType),
                  let frameView = window.contentView?.superview else {
                continue
            }

            button.isHidden = false
            button.isEnabled = true
            button.alphaValue = 1
            button.refusesFirstResponder = true
            button.autoresizingMask = [.maxXMargin, .minYMargin]
            if button.superview !== frameView {
                button.removeFromSuperview()
                frameView.addSubview(button)
            }
            button.frame.origin = NSPoint(
                x: originX,
                y: max(0, frameView.bounds.height - 31)
            )
            frameView.addSubview(button, positioned: .above, relativeTo: nil)
        }
    }

    private func installTrafficLightGlyphOverlay(in frameView: NSView, context: Context) {
        let overlay: TrafficLightGlyphOverlayView
        if let existingOverlay = context.coordinator.trafficLightOverlay {
            overlay = existingOverlay
        } else {
            overlay = TrafficLightGlyphOverlayView(frame: .zero)
            overlay.identifier = NSUserInterfaceItemIdentifier("AppManTrafficLightGlyphOverlayView")
            overlay.autoresizingMask = [.maxXMargin, .minYMargin]
            context.coordinator.trafficLightOverlay = overlay
        }

        if overlay.superview !== frameView {
            overlay.removeFromSuperview()
            frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
        } else {
            frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
        }

        overlay.frame = NSRect(
            x: 0,
            y: max(0, frameView.bounds.height - 40),
            width: 96,
            height: 40
        )
    }

    final class Coordinator {
        var hostingView: ChromeHostingView?
        var trafficLightOverlay: TrafficLightGlyphOverlayView?
    }

    final class ChromeHostingView: NSHostingView<AnyView> {
        override var mouseDownCanMoveWindow: Bool {
            true
        }
    }

    final class TrafficLightGlyphOverlayView: NSView {
        private var isHoveringLights = false
        private var localMouseMonitor: Any?
        private var globalMouseMonitor: Any?

        override var isFlipped: Bool {
            true
        }

        override var mouseDownCanMoveWindow: Bool {
            false
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMouseMonitors()
        }

        deinit {
            removeMouseMonitors()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            for trackingArea in trackingAreas {
                removeTrackingArea(trackingArea)
            }

            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            updateHoverState(with: event)
        }

        override func mouseExited(with event: NSEvent) {
            isHoveringLights = false
            needsDisplay = true
        }

        override func mouseMoved(with event: NSEvent) {
            updateHoverState(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            if isHoveringLights {
                drawHoverSymbols()
            }
        }

        private func light(at point: NSPoint) -> Light? {
            if let circularHit = Light.allCases.first(where: { light in
                let dx = point.x - light.centerX
                let dy = point.y - Light.centerY
                return dx * dx + dy * dy <= 144
            }) {
                return circularHit
            }

            guard lightsHitBounds.contains(point) else {
                return nil
            }

            switch point.x {
            case ..<37.5:
                return .close
            case ..<60.5:
                return .minimize
            default:
                return .zoom
            }
        }

        private var lightsBounds: NSRect {
            NSRect(x: Light.close.centerX - 9, y: Light.centerY - 9, width: Light.zoom.centerX - Light.close.centerX + 18, height: 18)
        }

        private var lightsHitBounds: NSRect {
            NSRect(x: 10, y: Light.centerY - 18, width: 82, height: 36)
        }

        private func installMouseMonitors() {
            removeMouseMonitors()

            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                self?.updateHoverState(with: event)
                return event
            }

            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                self?.updateHoverState(with: event)
            }
        }

        private func removeMouseMonitors() {
            if let localMouseMonitor {
                NSEvent.removeMonitor(localMouseMonitor)
                self.localMouseMonitor = nil
            }

            if let globalMouseMonitor {
                NSEvent.removeMonitor(globalMouseMonitor)
                self.globalMouseMonitor = nil
            }
        }

        private func updateHoverState(with event: NSEvent) {
            guard let window else {
                setHoveringLights(false)
                return
            }

            let windowPoint: NSPoint
            if event.window === window {
                windowPoint = event.locationInWindow
            } else {
                windowPoint = window.convertPoint(fromScreen: event.locationInWindow)
            }

            setHoveringLights(lightsBounds.contains(convert(windowPoint, from: nil)))
        }

        private func setHoveringLights(_ isHovering: Bool) {
            guard isHoveringLights != isHovering else {
                return
            }

            isHoveringLights = isHovering
            needsDisplay = true
        }

        private func drawHoverSymbols() {
            NSColor.black.withAlphaComponent(0.58).setStroke()

            let closePath = NSBezierPath()
            closePath.lineWidth = 1.2
            closePath.move(to: NSPoint(x: Light.close.centerX - 3, y: Light.centerY - 3))
            closePath.line(to: NSPoint(x: Light.close.centerX + 3, y: Light.centerY + 3))
            closePath.move(to: NSPoint(x: Light.close.centerX + 3, y: Light.centerY - 3))
            closePath.line(to: NSPoint(x: Light.close.centerX - 3, y: Light.centerY + 3))
            closePath.stroke()

            let minimizePath = NSBezierPath()
            minimizePath.lineWidth = 1.4
            minimizePath.move(to: NSPoint(x: Light.minimize.centerX - 4, y: Light.centerY))
            minimizePath.line(to: NSPoint(x: Light.minimize.centerX + 4, y: Light.centerY))
            minimizePath.stroke()

            let zoomPath = NSBezierPath()
            zoomPath.lineWidth = 1.35
            zoomPath.move(to: NSPoint(x: Light.zoom.centerX - 4, y: Light.centerY))
            zoomPath.line(to: NSPoint(x: Light.zoom.centerX + 4, y: Light.centerY))
            zoomPath.move(to: NSPoint(x: Light.zoom.centerX, y: Light.centerY - 4))
            zoomPath.line(to: NSPoint(x: Light.zoom.centerX, y: Light.centerY + 4))
            zoomPath.stroke()
        }

        enum Light: Int, CaseIterable {
            case close
            case minimize
            case zoom

            static var centerY: CGFloat { 24 }

            var centerX: CGFloat {
                switch self {
                case .close:
                    return 26
                case .minimize:
                    return 49
                case .zoom:
                    return 72
                }
            }

            var hitRect: NSRect {
                NSRect(x: centerX - 10, y: Light.centerY - 10, width: 20, height: 20)
            }
        }
    }

}

private struct SystemWindowConfigurator: NSViewRepresentable {
    let subtitle: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else {
            return
        }

        window.title = "AppMan"
        window.subtitle = subtitle
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar?.sizeMode = .regular
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.sharingType = .readOnly
        window.acceptsMouseMovedEvents = true

        if CommandLine.arguments.contains("--ui-snapshot") {
            window.setContentSize(NSSize(width: 960, height: 640))
        }

        AppUISnapshotter.scheduleIfNeeded(for: window)
    }
}

private enum AppUISnapshotter {
    private static var didScheduleSnapshot = false

    @MainActor
    static func scheduleIfNeeded(for window: NSWindow) {
        guard !didScheduleSnapshot,
              let outputPath = snapshotOutputPath else {
            return
        }

        didScheduleSnapshot = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            do {
                try writeSnapshot(of: window, to: outputPath)
                NSApp.terminate(nil)
            } catch {
                fputs("APP_MAN_UI_SNAPSHOT_ERROR=\(error)\n", stderr)
                NSApp.terminate(nil)
            }
        }
    }

    private static var snapshotOutputPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--ui-snapshot"),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }

        return arguments[arguments.index(after: index)]
    }

    @MainActor
    private static func writeSnapshot(of window: NSWindow, to outputPath: String) throws {
        guard let view = window.contentView else {
            throw SnapshotError.missingContentView
        }

        applySnapshotScrollOffset(in: view)
        let snapshotView = view.superview ?? view
        snapshotView.layoutSubtreeIfNeeded()
        snapshotView.displayIfNeeded()

        let bounds = snapshotView.bounds
        guard bounds.width > 0, bounds.height > 0,
              let cachedRepresentation = snapshotView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.invalidContentBounds
        }

        snapshotView.cacheDisplay(in: bounds, to: cachedRepresentation)

        let scale = window.backingScaleFactor
        let pixelSize = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width.rounded()),
            pixelsHigh: Int(pixelSize.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: representation)?.cgContext else {
            throw SnapshotError.invalidContentBounds
        }

        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(origin: .zero, size: pixelSize))
        }

        guard let cachedImage = cachedRepresentation.cgImage else {
            throw SnapshotError.pngEncodingFailed
        }
        let windowRect = CGRect(origin: .zero, size: pixelSize)
        context.saveGState()
        context.addPath(CGPath(
            roundedRect: windowRect,
            cornerWidth: 22 * scale,
            cornerHeight: 22 * scale,
            transform: nil
        ))
        context.clip()
        context.draw(cachedImage, in: windowRect)
        context.restoreGState()

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngEncodingFailed
        }

        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("APP_MAN_UI_SNAPSHOT_PATH=\(outputPath)")
    }

    @MainActor
    private static func applySnapshotScrollOffset(in view: NSView) {
        guard let offset = snapshotScrollOffset,
              let scrollView = firstScrollView(in: view) else {
            return
        }

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()

        guard let tableView = firstTableView(in: view),
              tableView.numberOfRows > 0 else {
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.layoutSubtreeIfNeeded()
    }

    private static var snapshotScrollOffset: CGFloat? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--ui-snapshot-scroll"),
              arguments.indices.contains(arguments.index(after: index)),
              let offset = Double(arguments[arguments.index(after: index)]) else {
            return nil
        }

        return CGFloat(offset)
    }

    @MainActor
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }

        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }

        return nil
    }

    @MainActor
    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView {
            return tableView
        }

        for subview in view.subviews {
            if let tableView = firstTableView(in: subview) {
                return tableView
            }
        }

        return nil
    }

    private enum SnapshotError: Error {
        case missingContentView
        case invalidContentBounds
        case pngEncodingFailed
    }
}

private struct AppCatalogView: View {
    let apps: [AppRecord]
    @Binding var selectedAppID: AppRecord.ID?
    @Binding var searchText: String
    let showInfo: () -> Void
    let validateRecipe: (AppRecord) -> Void
    let updateApp: (AppRecord) async -> Void
    let editSelfUpdateURL: (AppRecord) -> Void
    let ignoreUpdates: (AppRecord) -> Void

    private var filteredApps: [AppRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return apps
        }

        return apps.filter { app in
            app.matchesSearchQuery(query)
        }
    }

    var body: some View {
        AppCatalogTableView(
            apps: filteredApps,
            selectedAppID: $selectedAppID,
            searchText: $searchText,
            topInset: 0,
            showInfo: showInfo,
            validateRecipe: validateRecipe,
            updateApp: updateApp,
            editSelfUpdateURL: editSelfUpdateURL,
            ignoreUpdates: ignoreUpdates
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct AppCatalogTableView: NSViewRepresentable {
    let apps: [AppRecord]
    @Binding var selectedAppID: AppRecord.ID?
    @Binding var searchText: String
    let topInset: CGFloat
    let showInfo: () -> Void
    let validateRecipe: (AppRecord) -> Void
    let updateApp: (AppRecord) async -> Void
    let editSelfUpdateURL: (AppRecord) -> Void
    let ignoreUpdates: (AppRecord) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedAppID: $selectedAppID,
            showInfo: showInfo,
            validateRecipe: validateRecipe,
            updateApp: updateApp,
            editSelfUpdateURL: editSelfUpdateURL,
            ignoreUpdates: ignoreUpdates
        )
    }

    func makeNSView(context: Context) -> NSView {
        let containerView = AppTableContainerView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.needsDisplay = true

        let scrollView = AppTableScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.alternatingContentBackgroundColors[0]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)

        let documentView = AppTableDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        let tableView = AppCatalogNSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = NSColor.alternatingContentBackgroundColors[0]
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.showSelectedAppInfo(_:))
        tableView.contextMenuProvider = { [weak coordinator = context.coordinator, weak tableView] row in
            guard let tableView else {
                return nil
            }
            return coordinator?.contextMenu(forRow: row, in: tableView)
        }

        for column in Self.makeColumns() {
            tableView.addTableColumn(column)
        }

        documentView.addSubview(tableView)
        documentView.tableView = tableView
        scrollView.documentView = documentView

        containerView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        context.coordinator.scrollView = scrollView
        context.coordinator.documentView = documentView
        context.coordinator.tableView = tableView
        scrollView.layoutHandler = { [weak coordinator = context.coordinator] in
            coordinator?.updateTableFrame()
        }
        context.coordinator.apps = apps
        context.coordinator.updateTableFrame(topInset: topInset)
        return containerView
    }

    func updateNSView(_ containerView: NSView, context: Context) {
        guard let scrollView = context.coordinator.scrollView else {
            return
        }

        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        context.coordinator.apps = apps
        context.coordinator.selectedAppID = $selectedAppID
        context.coordinator.showInfo = showInfo
        context.coordinator.validateRecipe = validateRecipe
        context.coordinator.updateApp = updateApp
        context.coordinator.editSelfUpdateURLHandler = editSelfUpdateURL
        context.coordinator.ignoreUpdates = ignoreUpdates
        context.coordinator.reloadData()
        context.coordinator.updateTableFrame(topInset: topInset)
        context.coordinator.syncSelection(scrollToSelection: true)
    }

    private static func makeColumns() -> [NSTableColumn] {
        [
            makeColumn(id: "name", width: AppTableColumnLayout.nameWidth),
            makeColumn(id: "source", width: AppTableColumnLayout.sourceWidth),
            makeColumn(id: "currentVersion", width: AppTableColumnLayout.currentVersionWidth),
            makeColumn(id: "latestVersion", width: AppTableColumnLayout.latestVersionWidth),
        ]
    }

    private static func makeColumn(id: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.width = width
        column.minWidth = id == "name" ? 200 : 80
        column.resizingMask = id == "name" ? .autoresizingMask : .userResizingMask
        return column
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var apps: [AppRecord] = []
        var selectedAppID: Binding<AppRecord.ID?>
        var showInfo: () -> Void
        var validateRecipe: (AppRecord) -> Void
        var updateApp: (AppRecord) async -> Void
        var editSelfUpdateURLHandler: (AppRecord) -> Void
        var ignoreUpdates: (AppRecord) -> Void
        weak var scrollView: NSScrollView?
        weak var documentView: AppTableDocumentView?
        weak var tableView: NSTableView?
        private var isSyncingSelection = false
        private var topInset: CGFloat = 0

        init(
            selectedAppID: Binding<AppRecord.ID?>,
            showInfo: @escaping () -> Void,
            validateRecipe: @escaping (AppRecord) -> Void,
            updateApp: @escaping (AppRecord) async -> Void,
            editSelfUpdateURL: @escaping (AppRecord) -> Void,
            ignoreUpdates: @escaping (AppRecord) -> Void
        ) {
            self.selectedAppID = selectedAppID
            self.showInfo = showInfo
            self.validateRecipe = validateRecipe
            self.updateApp = updateApp
            self.editSelfUpdateURLHandler = editSelfUpdateURL
            self.ignoreUpdates = ignoreUpdates
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            apps.count
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else {
                return
            }

            guard let tableView = notification.object as? NSTableView else {
                return
            }

            let selectedRow = tableView.selectedRow
            selectedAppID.wrappedValue = apps.indices.contains(selectedRow) ? apps[selectedRow].id : nil
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = PlainAppTableRowView()
            rowView.isOddRow = row % 2 == 1
            return rowView
        }

        func tableView(_ tableView: NSTableView, menuForRows rows: IndexSet) -> NSMenu? {
            guard let row = rows.first else {
                return nil
            }

            return contextMenu(forRow: row, in: tableView)
        }

        func contextMenu(forRow row: Int, in tableView: NSTableView) -> NSMenu? {
            guard apps.indices.contains(row) else {
                return nil
            }

            let app = apps[row]
            selectedAppID.wrappedValue = app.id
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

            let menu = NSMenu()
            let ignoreItem = NSMenuItem(title: "忽略更新检查", action: #selector(ignoreSelectedApp(_:)), keyEquivalent: "")
            ignoreItem.target = self
            ignoreItem.representedObject = app.path
            ignoreItem.isEnabled = app.updateStatus != .ignored
            menu.addItem(ignoreItem)
            return menu
        }

        func reloadData() {
            isSyncingSelection = true
            tableView?.reloadData()
            isSyncingSelection = false
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard apps.indices.contains(row), let columnID = tableColumn?.identifier.rawValue else {
                return nil
            }

            let app = apps[row]
            switch columnID {
            case "name":
                let cell = AppNameCellView()
                cell.configure(app: app)
                return cell
            case "source":
                return textCell(app.installSource.shortDisplayName)
            case "currentVersion":
                return textCell(app.currentVersionDisplayText)
            case "latestVersion":
                if app.updateStatus.requiresSelfUpdateURLInput {
                    return selfUpdateLinkCell(app.latestVersionDisplayText, app: app)
                }
                if app.updateStatus.canRunUpdateAction {
                    return updateChannelLinkCell(
                        app.latestVersionDisplayText,
                        app: app,
                        color: Self.latestVersionColor(for: app.updateStatus)
                    )
                }
                return textCell(app.latestVersionDisplayText, color: Self.latestVersionColor(for: app.updateStatus))
            default:
                return nil
            }
        }

        func syncSelection(scrollToSelection: Bool = false) {
            guard let tableView else {
                return
            }

            guard let selectedID = selectedAppID.wrappedValue,
                  let row = apps.firstIndex(where: { $0.id == selectedID }) else {
                isSyncingSelection = true
                tableView.deselectAll(nil)
                isSyncingSelection = false
                return
            }

            isSyncingSelection = true
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            isSyncingSelection = false

            if scrollToSelection {
                tableView.scrollRowToVisible(row)
            }
        }

        func updateTableFrame(topInset: CGFloat? = nil) {
            guard let tableView,
                  let documentView,
                  let scrollView else {
                return
            }

            if let topInset {
                self.topInset = topInset
            }

            let visibleWidth = scrollView.contentView.bounds.width
            if let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) {
                nameColumn.width = AppTableColumnLayout.nameWidth(for: visibleWidth)
            }

            let contentWidth = max(visibleWidth, tableView.tableColumns.reduce(0) { $0 + $1.width })
            let rowsHeight = CGFloat(apps.count) * tableView.rowHeight
            let visibleHeight = scrollView.contentView.bounds.height
            let documentHeight = max(visibleHeight, self.topInset + rowsHeight)
            documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: documentHeight)
            tableView.frame = NSRect(
                x: 0,
                y: self.topInset,
                width: contentWidth,
                height: max(rowsHeight, visibleHeight - self.topInset)
            )
        }

        @objc private func ignoreSelectedApp(_ sender: NSMenuItem) {
            guard let appPath = sender.representedObject as? URL,
                  let app = apps.first(where: { $0.path == appPath }) else {
                return
            }

            ignoreUpdates(app)
        }

        @objc func showSelectedAppInfo(_ sender: NSTableView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard apps.indices.contains(row) else {
                return
            }

            selectedAppID.wrappedValue = apps[row].id
            sender.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if (sender as? AppCatalogNSTableView)?.lastDoubleClickModifierFlags.contains(.option) == true {
                validateRecipe(apps[row])
            } else {
                showInfo()
            }
        }

        @objc private func editSelfUpdateURL(_ sender: NSButton) {
            guard let appPath = (sender as? SelfUpdateLinkButton)?.appPath,
                  let app = apps.first(where: { $0.path == appPath }) else {
                return
            }

            selectedAppID.wrappedValue = app.id
            editSelfUpdateURLHandler(app)
        }

        @objc private func updateSelectedApp(_ sender: NSButton) {
            guard let appPath = (sender as? UpdateChannelLinkButton)?.appPath,
                  let app = apps.first(where: { $0.path == appPath }) else {
                return
            }

            selectedAppID.wrappedValue = app.id
            Task {
                await updateApp(app)
            }
        }

        private func textCell(_ text: String, color: NSColor = .labelColor) -> NSTableCellView {
            let cell = NSTableCellView()
            let textField = NSTextField(labelWithString: text)
            textField.textColor = color
            textField.font = .systemFont(ofSize: 12)
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: AppTableColumnLayout.cellHorizontalPadding),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -AppTableColumnLayout.cellHorizontalPadding),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func selfUpdateLinkCell(_ text: String, app: AppRecord) -> NSTableCellView {
            let cell = NSTableCellView()
            let button = SelfUpdateLinkButton(title: text, target: self, action: #selector(editSelfUpdateURL(_:)))
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.alignment = .left
            button.font = .systemFont(ofSize: 12)
            button.contentTintColor = .systemBlue
            button.translatesAutoresizingMaskIntoConstraints = false
            button.appPath = app.path
            cell.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: AppTableColumnLayout.cellHorizontalPadding - 3),
                button.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -AppTableColumnLayout.cellHorizontalPadding),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func updateChannelLinkCell(_ text: String, app: AppRecord, color: NSColor) -> NSTableCellView {
            let cell = NSTableCellView()
            let button = UpdateChannelLinkButton(title: text, target: self, action: #selector(updateSelectedApp(_:)))
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.alignment = .left
            button.font = .systemFont(ofSize: 12)
            button.contentTintColor = color
            button.translatesAutoresizingMaskIntoConstraints = false
            button.appPath = app.path
            cell.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: AppTableColumnLayout.cellHorizontalPadding - 3),
                button.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -AppTableColumnLayout.cellHorizontalPadding),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private static func latestVersionColor(for status: AppUpdateStatus) -> NSColor {
            switch status {
            case .updateAvailable:
                return .systemOrange
            case .checkFailed:
                return .systemRed
            case .upToDate:
                return .systemGreen
            case .needsOfficialWebsiteConfirmation, .needsManualUpdateURL:
                return .systemBlue
            case .ignored, .notChecked, .unsupported, .undetectable:
                return .secondaryLabelColor
            }
        }
    }
}

private final class AppTableScrollView: NSScrollView {
    var layoutHandler: (() -> Void)?

    override func layout() {
        super.layout()
        layoutHandler?()
    }
}

private final class AppTableContainerView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
    }
}

private final class AppTableDocumentView: NSView {
    weak var tableView: NSTableView?

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        guard let tableView else {
            return
        }

        let visibleWidth = superview?.bounds.width ?? bounds.width
        if let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) {
            nameColumn.width = AppTableColumnLayout.nameWidth(for: visibleWidth)
        }

        let tableColumnsWidth = tableView.tableColumns.reduce(0) { $0 + $1.width }
        let contentWidth = max(visibleWidth, tableColumnsWidth)
        if frame.width != contentWidth {
            frame.size.width = contentWidth
        }
        tableView.frame.size.width = contentWidth
    }

    override func draw(_ dirtyRect: NSRect) {
    }
}

private final class AppCatalogNSTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    private(set) var lastDoubleClickModifierFlags: NSEvent.ModifierFlags = []

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            lastDoubleClickModifierFlags = event.modifierFlags
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else {
            return nil
        }

        return contextMenuProvider?(row) ?? super.menu(for: event)
    }
}

private final class PlainAppTableRowView: NSTableRowView {
    var isOddRow = false

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if !isSelected && isOddRow {
            NSColor.alternatingContentBackgroundColors[1].setFill()
            dirtyRect.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else {
            return
        }

        NSColor.controlAccentColor.setFill()
        bounds.fill()
    }
}

private final class SelfUpdateLinkButton: NSButton {
    var appPath: URL?
}

private final class UpdateChannelLinkButton: NSButton {
    var appPath: URL?
}

private final class AppNameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(app: AppRecord) {
        iconView.image = NSWorkspace.shared.icon(forFile: app.path.path)
        nameField.stringValue = app.name
    }

    private func setup() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 12)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 27),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 13),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private struct AppCatalogHeader: View {
    var body: some View {
        GeometryReader { proxy in
            let nameWidth = AppTableColumnLayout.nameWidth(for: proxy.size.width + AppTableColumnLayout.scrollerWidth)
            HStack(spacing: 0) {
                Text("App 名称")
                    .frame(width: nameWidth - AppTableColumnLayout.nameLeadingPadding, alignment: .leading)
                    .padding(.leading, AppTableColumnLayout.nameLeadingPadding)
                Text("来源")
                    .frame(width: AppTableColumnLayout.sourceWidth - AppTableColumnLayout.cellHorizontalPadding, alignment: .leading)
                    .padding(.leading, AppTableColumnLayout.cellHorizontalPadding)
                Text("当前版本")
                    .frame(width: AppTableColumnLayout.currentVersionWidth - AppTableColumnLayout.cellHorizontalPadding, alignment: .leading)
                    .padding(.leading, AppTableColumnLayout.cellHorizontalPadding)
                Text("最新版本")
                    .frame(width: AppTableColumnLayout.latestVersionWidth - AppTableColumnLayout.cellHorizontalPadding, alignment: .leading)
                    .padding(.leading, AppTableColumnLayout.cellHorizontalPadding)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.primary.opacity(0.92))
            .overlay(alignment: .topLeading) {
                ForEach(Self.dividerOffsets(nameWidth: nameWidth), id: \.self) { offset in
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1, height: 16)
                        .offset(x: offset, y: 4)
                }
            }
        }
    }

    private static func dividerOffsets(nameWidth: CGFloat) -> [CGFloat] {
        [
            nameWidth,
            nameWidth + AppTableColumnLayout.sourceWidth,
            nameWidth + AppTableColumnLayout.sourceWidth + AppTableColumnLayout.currentVersionWidth,
        ]
    }
}

extension AppRecord {
    var currentVersionDisplayText: String {
        let shortVersion = normalized(shortVersion)
        let buildVersion = normalized(buildVersion)

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

    var latestVersionDisplayText: String {
        switch updateStatus {
        case .notChecked:
            return "未检查"
        case .upToDate:
            return currentVersionDisplayText
        case let .updateAvailable(_, latestVersion):
            return latestVersion
        case .ignored:
            return "已忽略"
        case .needsOfficialWebsiteConfirmation:
            return "待确认"
        case .needsManualUpdateURL:
            return "需手动输入"
        case .undetectable:
            return "无法检测"
        case .unsupported:
            return "不支持"
        case .checkFailed:
            return "检查失败"
        }
    }

    func matchesSearchQuery(_ query: String) -> Bool {
        let normalizedQuery = query.localizedLowercase
        return searchableText.contains(normalizedQuery)
    }

    private var searchableText: String {
        [
            name,
            bundleIdentifier ?? "",
            path.path,
            installSource.searchText,
            shortVersion ?? "",
            buildVersion ?? "",
        ]
        .joined(separator: " ")
        .localizedLowercase
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

private extension AppUpdateStatus {
    var requiresSelfUpdateURLInput: Bool {
        switch self {
        case .needsOfficialWebsiteConfirmation, .needsManualUpdateURL:
            return true
        default:
            return false
        }
    }

    var canRunUpdateAction: Bool {
        switch self {
        case .updateAvailable:
            return true
        default:
            return false
        }
    }
}

private extension InstallSource {
    var shortDisplayName: String {
        switch self {
        case .macAppStore:
            return "MAS"
        case .homebrewCask:
            return "BREW"
        case .manual, .sparkle:
            return "SELF"
        }
    }

    var searchText: String {
        switch self {
        case .macAppStore:
            return "MAS Mac App Store"
        case .homebrewCask:
            return "BREW Homebrew Cask"
        case .sparkle:
            return "SELF Sparkle"
        case .manual:
            return "SELF"
        }
    }
}
