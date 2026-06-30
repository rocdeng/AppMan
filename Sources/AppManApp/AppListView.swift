import AppManCore
import AppKit
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case apps = "App"
    case settings = "设置"

    var id: String { rawValue }
}

private enum AppLayout {
    static let titlebarHeight: CGFloat = 29
    static let toolbarHeight: CGFloat = 27
    static let headerHeight: CGFloat = 25
    static let chromeHeight = titlebarHeight + toolbarHeight + headerHeight
    static let tableTopInset = chromeHeight
}

private enum AppTableColumnLayout {
    static let nameWidth: CGFloat = 222
    static let sourceWidth: CGFloat = 115
    static let currentVersionWidth: CGFloat = 328
    static let latestVersionWidth: CGFloat = 220
    static let nameLeadingPadding: CGFloat = 29
    static let cellHorizontalPadding: CGFloat = 8
}

struct AppListView: View {
    @StateObject private var viewModel: AppListViewModel
    @State private var selectedSection: AppSection = .apps
    @State private var selectedAppID: AppRecord.ID?
    @State private var didScanOnAppear = false
    @State private var searchText = ""

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
            Color.white
                .ignoresSafeArea()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .background(
            WindowChromeConfigurator(
                chromeHeight: selectedSection == .apps
                    ? AppLayout.chromeHeight
                    : AppLayout.titlebarHeight + AppLayout.toolbarHeight,
                chromeContent: AppChromeView(
                    selectedSection: $selectedSection,
                    searchText: $searchText,
                    showsHeader: selectedSection == .apps,
                    canCheckUpdates: !viewModel.apps.isEmpty,
                    isScanning: viewModel.isScanning,
                    isCheckingUpdates: viewModel.isCheckingUpdates,
                    scan: {
                        await viewModel.scan()
                    },
                    checkUpdates: {
                        await viewModel.checkUpdates()
                    }
                )
            )
        )
        .overlay {
            if viewModel.isScanning || viewModel.isCheckingUpdates {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView(viewModel.isScanning ? "正在扫描..." : "正在检查更新...")
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
            guard !viewModel.hasCachedApps else {
                return
            }

            Task {
                await viewModel.scan()
            }
        }
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
        AppCatalogView(
            apps: viewModel.apps,
            selectedAppID: $selectedAppID,
            searchText: $searchText
        )
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
        .padding(.top, AppLayout.titlebarHeight + AppLayout.toolbarHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AppChromeView: View {
    @Binding var selectedSection: AppSection
    @Binding var searchText: String
    let showsHeader: Bool
    let canCheckUpdates: Bool
    let isScanning: Bool
    let isCheckingUpdates: Bool
    let scan: () async -> Void
    let checkUpdates: () async -> Void
    @State private var isSearchExpanded = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                AppToolbarTitleView(selectedSection: selectedSection)
                    .offset(x: 108, y: 8)

                HStack(spacing: 13.5) {
                    LiquidIconButtonGroup(horizontalPadding: 5) {
                        LiquidIconButton(
                            systemImage: "xmark.octagon",
                            help: "扫描 App",
                            isDisabled: isScanning,
                            action: scan
                        )

                        LiquidIconButton(
                            systemImage: "info.circle",
                            help: "检查更新",
                            isDisabled: isScanning || isCheckingUpdates || !canCheckUpdates,
                            action: checkUpdates
                        )
                    }

                    LiquidIconButtonGroup(horizontalPadding: 3) {
                        LiquidIconButton(
                            systemImage: "ellipsis.circle",
                            trailingSystemImage: "chevron.down",
                            help: "更多操作",
                            isDisabled: false,
                            action: {}
                        )
                    }

                    LiquidSegmentedTabs(selection: $selectedSection)
                }
                .offset(x: 257, y: 8)

                LiquidSearchControl(text: $searchText, isExpanded: $isSearchExpanded)
                    .position(x: proxy.size.width - 24, y: 23)

                if showsHeader {
                    AppCatalogHeader()
                        .frame(width: proxy.size.width, height: AppLayout.headerHeight)
                        .offset(y: AppLayout.titlebarHeight + AppLayout.toolbarHeight)
                }
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
            Text(selectedSection == .apps ? "所有 App" : "设置")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(width: 220, height: 36, alignment: .leading)
    }
}

private struct LiquidIconButton: View {
    let systemImage: String
    var trailingSystemImage: String?
    let help: String
    let isDisabled: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task {
                await action()
            }
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
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isExpanded || !text.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("搜索 App", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
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
                .padding(.horizontal, 11)
                .frame(width: 220, height: 42)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onAppear {
                    isFocused = true
                }
            } else {
                Button {
                    isExpanded = true
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
    }

    private func configure(window: NSWindow?, context: Context) {
        guard let window else {
            return
        }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.toolbarStyle = .unifiedCompact
        window.sharingType = .readOnly
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .clear
        window.isOpaque = false

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

        let trafficLightOverlay: TrafficLightOverlayView
        if let existingOverlay = context.coordinator.trafficLightOverlay {
            trafficLightOverlay = existingOverlay
        } else {
            trafficLightOverlay = TrafficLightOverlayView(frame: .zero)
            trafficLightOverlay.identifier = NSUserInterfaceItemIdentifier("AppManTrafficLightOverlayView")
            trafficLightOverlay.autoresizingMask = [.maxXMargin, .minYMargin]
            context.coordinator.trafficLightOverlay = trafficLightOverlay
        }

        if trafficLightOverlay.superview === frameView {
            trafficLightOverlay.removeFromSuperview()
        }
        frameView.addSubview(trafficLightOverlay, positioned: .above, relativeTo: hostingView)

        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonType) else {
                continue
            }

            button.alphaValue = 0
            button.isHidden = true
            button.frame.origin = NSPoint(x: -1000, y: -1000)
        }

        let frameBounds = frameView.bounds
        hostingView.frame = NSRect(
            x: 0,
            y: max(0, frameBounds.height - chromeHeight),
            width: frameBounds.width,
            height: chromeHeight
        )
        context.coordinator.trafficLightOverlay?.frame = NSRect(
            x: 0,
            y: max(0, frameBounds.height - 40),
            width: 170,
            height: 40
        )
    }

    final class Coordinator {
        var hostingView: ChromeHostingView?
        var trafficLightOverlay: TrafficLightOverlayView?
    }

    final class ChromeHostingView: NSHostingView<AnyView> {
        override var mouseDownCanMoveWindow: Bool {
            true
        }
    }

    final class TrafficLightOverlayView: NSView {
        override var isFlipped: Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            light(at: point) == nil ? nil : self
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            switch light(at: point) {
            case .close:
                window?.performClose(nil)
            case .minimize:
                window?.miniaturize(nil)
            case .zoom:
                window?.zoom(nil)
            case nil:
                break
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            let lights: [(NSColor, CGFloat)] = [
                (NSColor(calibratedRed: 1.0, green: 0.33, blue: 0.35, alpha: 1.0), Light.close.centerX),
                (NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.08, alpha: 1.0), Light.minimize.centerX),
                (NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.30, alpha: 1.0), Light.zoom.centerX),
            ]

            for (color, centerX) in lights {
                let rect = NSRect(x: centerX - 7, y: Light.centerY - 7, width: 14, height: 14)
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                NSColor.black.withAlphaComponent(0.12).setStroke()
                let strokePath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                strokePath.lineWidth = 0.7
                strokePath.stroke()
            }
        }

        private func light(at point: NSPoint) -> Light? {
            Light.allCases.first { light in
                let dx = point.x - light.centerX
                let dy = point.y - Light.centerY
                return dx * dx + dy * dy <= 81
            }
        }

        private enum Light: CaseIterable {
            case close
            case minimize
            case zoom

            static var centerY: CGFloat { 26 }

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
        }
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

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: pixelSize))

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
            topInset: AppLayout.tableTopInset
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .ignoresSafeArea(.container, edges: .top)
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

    private func latestVersionText(for app: AppRecord) -> String {
        switch app.updateStatus {
        case .notChecked:
            return "未检查"
        case .upToDate:
            return currentVersionText(for: app)
        case let .updateAvailable(_, latestVersion):
            return latestVersion
        case .unsupported:
            return "不支持"
        case .checkFailed:
            return "检查失败"
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

private struct AppCatalogTableView: NSViewRepresentable {
    let apps: [AppRecord]
    @Binding var selectedAppID: AppRecord.ID?
    @Binding var searchText: String
    let topInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedAppID: $selectedAppID)
    }

    func makeNSView(context: Context) -> NSView {
        let containerView = AppTableContainerView()
        containerView.wantsLayer = true
        containerView.appearance = NSAppearance(named: .aqua)
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.needsDisplay = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.appearance = NSAppearance(named: .aqua)
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)

        let documentView = AppTableDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.appearance = NSAppearance(named: .aqua)

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.appearance = NSAppearance(named: .aqua)
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

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
        context.coordinator.tableView?.reloadData()
        context.coordinator.updateTableFrame(topInset: topInset)
        context.coordinator.syncSelection()
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
        weak var scrollView: NSScrollView?
        weak var documentView: AppTableDocumentView?
        weak var tableView: NSTableView?

        init(selectedAppID: Binding<AppRecord.ID?>) {
            self.selectedAppID = selectedAppID
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            apps.count
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
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
                return textCell(Self.sourceText(for: app.installSource))
            case "currentVersion":
                return textCell(Self.currentVersionText(for: app))
            case "latestVersion":
                return textCell(Self.latestVersionText(for: app), color: Self.latestVersionColor(for: app.updateStatus))
            default:
                return nil
            }
        }

        func syncSelection() {
            guard let tableView else {
                return
            }

            guard let selectedID = selectedAppID.wrappedValue,
                  let row = apps.firstIndex(where: { $0.id == selectedID }) else {
                tableView.deselectAll(nil)
                return
            }

            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        func updateTableFrame(topInset: CGFloat) {
            guard let tableView,
                  let documentView,
                  let scrollView else {
                return
            }

            let contentWidth = max(scrollView.contentView.bounds.width, tableView.tableColumns.reduce(0) { $0 + $1.width })
            let rowsHeight = CGFloat(apps.count) * tableView.rowHeight
            let visibleHeight = scrollView.contentView.bounds.height
            let documentHeight = max(visibleHeight, topInset + rowsHeight)
            documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: documentHeight)
            tableView.frame = NSRect(x: 0, y: topInset, width: contentWidth, height: max(rowsHeight, visibleHeight - topInset))
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

        private static func sourceText(for installSource: InstallSource) -> String {
            switch installSource {
            case .macAppStore:
                return "MAS"
            case .homebrewCask:
                return "BREW"
            case .manual, .sparkle:
                return "SELF"
            }
        }

        private static func currentVersionText(for app: AppRecord) -> String {
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

        private static func latestVersionText(for app: AppRecord) -> String {
            switch app.updateStatus {
            case .notChecked:
                return "未检查"
            case .upToDate:
                return currentVersionText(for: app)
            case let .updateAvailable(_, latestVersion):
                return latestVersion
            case .unsupported:
                return "不支持"
            case .checkFailed:
                return "检查失败"
            }
        }

        private static func latestVersionColor(for status: AppUpdateStatus) -> NSColor {
            switch status {
            case .updateAvailable:
                return .systemOrange
            case .checkFailed:
                return .systemRed
            case .upToDate:
                return .systemGreen
            case .notChecked, .unsupported:
                return .secondaryLabelColor
            }
        }

        private static func normalized(_ value: String?) -> String? {
            guard let value else {
                return nil
            }

            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : trimmedValue
        }
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

        let tableColumnsWidth = tableView.tableColumns.reduce(0) { $0 + $1.width }
        let visibleWidth = superview?.bounds.width ?? bounds.width
        let contentWidth = max(visibleWidth, tableColumnsWidth)
        if frame.width != contentWidth {
            frame.size.width = contentWidth
        }
        tableView.frame.size.width = contentWidth
    }

    override func draw(_ dirtyRect: NSRect) {
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
            NSColor.controlBackgroundColor.withSystemEffect(.pressed).withAlphaComponent(0.35).setFill()
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
        HStack(spacing: 0) {
            Text("App 名称")
                .frame(width: AppTableColumnLayout.nameWidth - AppTableColumnLayout.nameLeadingPadding, alignment: .leading)
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
        .padding(.trailing, 14)
        .overlay(alignment: .topLeading) {
            ForEach(Self.dividerOffsets, id: \.self) { offset in
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1, height: 16)
                    .offset(x: offset, y: 4)
            }
        }
    }

    private static var dividerOffsets: [CGFloat] {
        [
            AppTableColumnLayout.nameWidth,
            AppTableColumnLayout.nameWidth + AppTableColumnLayout.sourceWidth,
            AppTableColumnLayout.nameWidth + AppTableColumnLayout.sourceWidth + AppTableColumnLayout.currentVersionWidth,
        ]
    }
}

private extension AppRecord {
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
}

private extension InstallSource {
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
