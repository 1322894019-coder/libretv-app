import SwiftUI
import WebKit
import AVFoundation

// MARK: - Route configuration (LAN / IPv6 / public)

enum RouteKind: Int, CaseIterable {
    case lan = 0
    case ipv6 = 1
    case publicRoute = 2

    var label: String {
        switch self {
        case .lan: return "局域网直连"
        case .ipv6: return "IPv6 直连"
        case .publicRoute: return "公网中转"
        }
    }

    var icon: String {
        switch self {
        case .lan: return "wifi"
        case .ipv6: return "network"
        case .publicRoute: return "globe"
        }
    }
}

struct RouteCandidate {
    let base: String
    let kind: RouteKind
    let name: String
}

// One row per built-in line. `latency == nil` means probing/unknown or
// unreachable after the probe finishes.
struct RouteProbeResult: Identifiable, Equatable {
    let base: String
    let kind: RouteKind
    let name: String
    var latency: Int?
    var probing: Bool

    var id: String { base }
    var reachable: Bool { latency != nil }
}

enum RouteConfig {
    // ngrok free fixed domain (does not change on restart).
    static let newPublic = "https://revivable-outsell-perch.ngrok-free.dev"
    // Tailscale Funnel, kept as a backup public line.
    static let backupPublic = "https://libretv.tailee3645.ts.net"
    static let defaultPublic = newPublic

    // Built-in lines, updated to the machine's current addresses. A stale line
    // is simply reported as unreachable; it never breaks the rest of the list.
    static func candidates() -> [RouteCandidate] {
        [
            RouteCandidate(base: "http://192.168.2.238:8080", kind: .lan, name: "局域网直连 · 以太网"),
            RouteCandidate(base: "http://192.168.1.22:8080", kind: .lan, name: "局域网直连 · 无线"),

            RouteCandidate(base: "http://[240e:314:b818:28d:a7b6:1f23:2d61:f241]:8080",
                           kind: .ipv6, name: "IPv6 直连 · 以太网"),
            RouteCandidate(base: "http://[240e:314:b818:200:905f:546c:4484:7176]:8080",
                           kind: .ipv6, name: "IPv6 直连 · 以太网备用"),
            RouteCandidate(base: "http://[240e:314:b818:200:2f72:4a42:e4d3:35e3]:8080",
                           kind: .ipv6, name: "IPv6 直连 · 无线"),

            RouteCandidate(base: newPublic, kind: .publicRoute, name: "公网中转 · ngrok"),
            RouteCandidate(base: backupPublic, kind: .publicRoute, name: "公网中转 · Tailscale")
        ]
    }

    static func initial(probing: Bool = false) -> [RouteProbeResult] {
        candidates().map {
            RouteProbeResult(base: $0.base, kind: $0.kind, name: $0.name,
                             latency: nil, probing: probing)
        }
    }

    static func isValid(_ base: String) -> Bool {
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else {
            return false
        }
        return url.user == nil && url.password == nil
    }
}

// MARK: - Latency probe

// Non-isolated so each measurement runs concurrently on background threads
// instead of hopping onto the main actor.
enum RouteProbe {
    static func measure(_ base: String) async -> (String, Int?) {
        guard let url = URL(string: base + "/api/status") else { return (base, nil) }
        var request = URLRequest(url: url, timeoutInterval: 1.2)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                return (base, max(1, Int(Date().timeIntervalSince(start) * 1000)))
            }
            return (base, nil)
        } catch {
            return (base, nil)
        }
    }
}

// Observable route table shared by the boot screen and the settings sheet.
@MainActor
final class RouteMonitor: ObservableObject {
    @Published private(set) var results: [RouteProbeResult] = RouteConfig.initial()
    @Published private(set) var isProbing = false
    @Published private(set) var fastestBase: String?

    // Probe every line, update rows live, then sort so the fastest reachable
    // line is first. Returns the base URL the app should connect to.
    func probe() async -> String {
        isProbing = true
        fastestBase = nil
        results = RouteConfig.initial(probing: true)

        await withTaskGroup(of: (String, Int?).self) { group in
            for entry in RouteConfig.candidates() {
                group.addTask { await RouteProbe.measure(entry.base) }
            }
            for await (base, ms) in group {
                guard let index = results.firstIndex(where: { $0.base == base }) else { continue }
                results[index].latency = ms
                results[index].probing = false
            }
        }

        for index in results.indices { results[index].probing = false }

        // Reachable first by measured latency (fastest pinned to top);
        // unreachable lines sink to the bottom.
        results.sort { lhs, rhs in
            switch (lhs.latency, rhs.latency) {
            case let (left?, right?):
                if left != right { return left < right }
                return lhs.kind.rawValue < rhs.kind.rawValue
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
        }

        fastestBase = results.first { $0.latency != nil }?.base
        isProbing = false

        if let best = results.first(where: { $0.latency != nil }) {
            return best.base
        }
        // Every direct line failed: keep the app usable via the public default.
        return RouteConfig.defaultPublic
    }

    func label(for base: String) -> String {
        if let route = results.first(where: { $0.base == base }) {
            if let ms = route.latency { return "\(route.name) · \(ms)ms" }
            return route.name
        }
        return "自定义地址 · 手动模式"
    }
}

// MARK: - App entry

@main
struct LibreTVApp: App {
    init() {
        // Activate the playback audio session so the hardware volume keys control
        // media volume (including WKWebView HTML5 video) instead of the ringer.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Keep the default audio behavior if configuration fails.
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - WKWebView store

final class WebViewStore: ObservableObject {
    let webView: WKWebView
    @Published var estimatedProgress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
    }
}

struct WebView: UIViewRepresentable {
    @ObservedObject var store: WebViewStore
    let urlString: String

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = store.webView
        webView.navigationDelegate = context.coordinator
        context.coordinator.startObserving(webView: webView)
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        if let url = URL(string: urlString) {
            var request = URLRequest(url: url)
            // ngrok free top-level navigation needs this header or the first
            // screen is its browser-warning page.
            if urlString.hasPrefix(RouteConfig.newPublic) {
                request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
            }
            webView.load(request)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let store: WebViewStore
        private var progressObservation: NSKeyValueObservation?

        init(store: WebViewStore) { self.store = store }

        func startObserving(webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.store.estimatedProgress = webView.estimatedProgress
                    self?.store.isLoading = webView.isLoading
                }
            }
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            store.webView.reload()
            sender.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            store.canGoBack = webView.canGoBack
            store.canGoForward = webView.canGoForward
            store.isLoading = false
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            store.canGoBack = webView.canGoBack
            store.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            store.isLoading = false
        }
    }
}

// MARK: - Root content

struct ContentView: View {
    @StateObject private var monitor = RouteMonitor()
    @AppStorage("autoRoute") private var autoRoute = true
    @AppStorage("manualURL") private var manualURL = ""
    @State private var resolvedURL = ""
    @State private var showSettings = false
    @State private var booting = true

    private var activeURL: String {
        if autoRoute {
            return resolvedURL.isEmpty ? RouteConfig.defaultPublic : resolvedURL
        }
        return manualURL.isEmpty ? RouteConfig.defaultPublic : manualURL
    }

    var body: some View {
        Group {
            if booting && autoRoute {
                bootView
            } else {
                NavigationStack {
                    BrowserView(urlString: activeURL,
                                routeLabel: monitor.label(for: activeURL),
                                showSettings: $showSettings)
                }
                .id(activeURL)
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        SettingsView(monitor: monitor,
                                     autoRoute: $autoRoute,
                                     manualURL: $manualURL,
                                     resolvedURL: $resolvedURL)
                    }
                }
            }
        }
        .task {
            if autoRoute {
                resolvedURL = await monitor.probe()
            }
            booting = false
        }
    }

    private var bootView: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.cyan)
            ProgressView()
            Text("正在检测所有线路延迟…").foregroundStyle(.secondary)
            Text("局域网直连 · IPv6 直连 · 公网兜底").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct BrowserView: View {
    let urlString: String
    let routeLabel: String
    @Binding var showSettings: Bool
    @StateObject private var store = WebViewStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LibreTV").font(.subheadline.bold())
                    Text(routeLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            if store.isLoading {
                ProgressView(value: store.estimatedProgress).progressViewStyle(.linear)
            }
            WebView(store: store, urlString: urlString)
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(action: { store.webView.goBack() }) { Image(systemName: "chevron.left") }
                    .disabled(!store.canGoBack)
                Button(action: { store.webView.goForward() }) { Image(systemName: "chevron.right") }
                    .disabled(!store.canGoForward)
                Spacer()
                Button(action: { store.webView.reload() }) { Image(systemName: "arrow.clockwise") }
                Button(action: { showSettings = true }) { Image(systemName: "gearshape") }
            }
        }
    }
}

// MARK: - Settings with the live latency table

struct SettingsView: View {
    @ObservedObject var monitor: RouteMonitor
    @Binding var autoRoute: Bool
    @Binding var manualURL: String
    @Binding var resolvedURL: String

    @Environment(\.dismiss) private var dismiss
    @State private var customDraft = ""
    @State private var error = ""

    private var currentBase: String {
        autoRoute ? resolvedURL : manualURL
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor.isProbing ? "正在检测所有线路…" : "检测完成，已按延迟排序")
                            .font(.subheadline)
                        if let fastest = fastestRoute {
                            Text("最快：\(fastest.name)（\(fastest.latency ?? 0)ms）已置顶")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await runAutoProbe() }
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .disabled(monitor.isProbing)
                }
                .padding(.vertical, 2)

                ForEach(monitor.results) { route in
                    RouteRow(
                        route: route,
                        isSelected: route.base == currentBase,
                        isFastest: route.base == monitor.fastestBase
                    ) {
                        useManual(route.base)
                    }
                }
            } header: {
                Text("线路延迟检测")
            } footer: {
                Text("并行测试局域网、IPv6 与公网线路并显示具体延迟（毫秒）。最快可用线路自动置顶；点击任意线路即手动切换，失效线路显示超时并排在最后。")
            }

            Section {
                HStack(alignment: .top) {
                    TextField("https://你的服务地址", text: $customDraft, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !customDraft.isEmpty {
                        Button { customDraft = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                Button("连接自定义地址") { applyCustom() }
                if !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("自定义服务器地址")
            } footer: {
                Text("地址只保存在本机，不会发给任何人。手动连接后进入手动模式，可随时用上面的“重新检测”恢复自动选最快。")
            }

            Section("连接提示") {
                Label("本机部署时，电脑需要保持开机并运行 LibreTV。", systemImage: "desktopcomputer")
                Label("局域网连接需手机与电脑在同一网络，首次请允许访问本地网络。", systemImage: "wifi")
                Label("IPv6 直连需两端网络均支持 IPv6，且家庭网关未拦截入站。", systemImage: "network")
                Label("公网中转作为出门或直连失败时的兜底线路。", systemImage: "globe")
            }
            .font(.subheadline)

            Section("关于") {
                LabeledContent("客户端", value: "LibreTV iOS")
                Link("LibreTV 开源项目", destination: URL(string: "https://github.com/LibreSpark/LibreTV")!)
                Text("非官方自用客户端，基于系统 WKWebView；影视搜索与播放由你的 LibreTV 服务提供。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("服务器地址")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
        .onAppear { customDraft = currentBase }
    }

    private var fastestRoute: RouteProbeResult? {
        guard let base = monitor.fastestBase else { return nil }
        return monitor.results.first { $0.base == base }
    }

    private func runAutoProbe() async {
        let best = await monitor.probe()
        resolvedURL = best
        autoRoute = true
        dismiss()
    }

    private func useManual(_ base: String) {
        manualURL = base
        autoRoute = false
        dismiss()
    }

    private func applyCustom() {
        var text = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { error = "请填写地址"; return }
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            text = "https://" + text
        }
        guard RouteConfig.isValid(text) else {
            error = "地址不对，检查一下"
            return
        }
        customDraft = text
        manualURL = text
        autoRoute = false
        dismiss()
    }
}

private struct RouteRow: View {
    let route: RouteProbeResult
    let isSelected: Bool
    let isFastest: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: route.kind.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(route.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if isFastest {
                            Text("最快")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text(route.base)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                trailing
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var trailing: some View {
        if route.probing {
            ProgressView()
        } else if let ms = route.latency {
            Text("\(ms)ms")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isFastest ? Color.green : Color.cyan)
        } else {
            Text("超时")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if isSelected {
            Image(systemName: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.cyan)
        }
    }

    private var iconColor: Color {
        switch route.kind {
        case .lan: return .blue
        case .ipv6: return .purple
        case .publicRoute: return .orange
        }
    }

    private var accessibilityText: String {
        if let ms = route.latency { return "\(route.name)，延迟 \(ms) 毫秒" }
        return "\(route.name)，不可达"
    }
}
