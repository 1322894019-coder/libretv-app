import SwiftUI
import WebKit
import AVFoundation

// MARK: - Route configuration (LAN / IPv6 / public)

enum RouteConfig {
    // Public Funnel address, kept unchanged and used as the final fallback.
    static let defaultPublic = "https://libretv.tailee3645.ts.net"

    // LAN direct candidates (the PC's fixed Wi-Fi addresses).
    static let lan = [
        "http://192.168.1.5:8080",
        "http://192.168.1.22:8080"
    ]

    // IPv6 direct candidates (the PC's stable global IPv6 addresses).
    static let ipv6 = [
        "http://[240e:314:b818:28d:a7b6:1f23:2d61:f241]:8080",
        "http://[240e:314:b818:200:905f:546c:4484:7176]:8080",
        "http://[240e:314:b818:28d:97e7:f51a:7497:b9f]:8080",
        "http://[240e:314:b818:200:2f72:4a42:e4d3:35e3]:8080"
    ]

    // Lower raw value wins: LAN (0) > IPv6 (1) > public (2).
    static func candidates() -> [(base: String, kind: Int)] {
        var list: [(String, Int)] = []
        lan.forEach { list.append(($0, 0)) }
        ipv6.forEach { list.append(($0, 1)) }
        list.append((defaultPublic, 2))
        return list
    }

    static func label(for kind: Int, elapsed: Int) -> String {
        switch kind {
        case 0: return "局域网直连 · \(elapsed)ms"
        case 1: return "IPv6 直连 · \(elapsed)ms"
        default: return elapsed > 0 ? "公网安全回退 · \(elapsed)ms" : "公网安全回退"
        }
    }
}

@MainActor
enum RouteProbe {
    private static func measure(_ base: String) async -> Int? {
        guard let url = URL(string: base + "/api/status") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 1.0)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                return max(1, Int(Date().timeIntervalSince(start) * 1000))
            }
            return nil
        } catch {
            return nil
        }
    }

    static func select() async -> (base: String, kind: Int, elapsed: Int) {
        let result = await withTaskGroup(of: (base: String, kind: Int, elapsed: Int?).self) { group -> (String, Int, Int)? in
            for entry in candidates() {
                group.addTask { (entry.base, entry.kind, await measure(entry.base)) }
            }
            var best: (String, Int, Int)?
            for await item in group {
                guard let ms = item.elapsed else { continue }
                if best == nil || item.kind < best!.1 || (item.kind == best!.1 && ms < best!.2) {
                    best = (item.base, item.kind, ms)
                }
            }
            return best
        }
        if let result { return result }
        return (RouteConfig.defaultPublic, 2, 0)
    }
}

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
            webView.load(URLRequest(url: url))
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

struct ContentView: View {
    // autoRoute=true: pick the fastest of LAN/IPv6/public. false: use the manual address.
    @AppStorage("autoRoute") private var autoRoute = true
    @AppStorage("manualURL") private var manualURL = ""
    @State private var resolvedURL = ""
    @State private var routeKind = 2
    @State private var routeElapsed = 0
    @State private var showSettings = false
    @State private var probing = true

    private var activeURL: String {
        autoRoute ? resolvedURL : (manualURL.isEmpty ? RouteConfig.defaultPublic : manualURL)
    }

    var body: some View {
        Group {
            if probing && autoRoute {
                bootView
            } else {
                NavigationStack {
                    BrowserView(urlString: activeURL, routeLabel: currentLabel, showSettings: $showSettings)
                }
                .id(activeURL)
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        SettingsView(autoRoute: $autoRoute, manualURL: $manualURL)
                    }
                }
            }
        }
        .task {
            if autoRoute { await runProbe() }
            probing = false
        }
    }

    private var currentLabel: String {
        autoRoute ? RouteConfig.label(for: routeKind, elapsed: routeElapsed) : "手动模式 · 自定义地址"
    }

    private var bootView: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.cyan)
            ProgressView()
            Text("正在检测最快线路…").foregroundStyle(.secondary)
            Text("局域网直连 · IPv6 直连 · 公网兜底").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func runProbe() async {
        let result = await RouteProbe.select()
        resolvedURL = result.base
        routeKind = result.kind
        routeElapsed = result.elapsed
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
                Button(action: { store.webView.reload() }) { Image(systemName: "arrow.clockwork") }
                Button(action: { showSettings = true }) { Image(systemName: "gearshape") }
            }
        }
    }
}

struct SettingsView: View {
    @Binding var autoRoute: Bool
    @Binding var manualURL: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var error = ""

    var body: some View {
        Form {
            Section("连接方式") {
                Toggle("自动选择最快线路（局域网 / IPv6 / 公网）", isOn: $autoRoute)
            } footer: {
                Text("默认开启。公网地址保持不变作为兜底，局域网和 IPv6 直连优先，网页打开更快。")
            }

            Section("手动服务器地址") {
                TextField("https://… 或 http://…", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("保存手动地址") { save() }
                Button("恢复自动直连") {
                    autoRoute = true
                    dismiss()
                }
            } footer: {
                Text("保存手动地址后会切换为手动模式，可随时用上面的开关恢复自动直连。")
            }

            Section("关于") {
                LabeledContent("客户端", value: "LibreTV iOS 2.2.0")
                Text("基于系统 WKWebView；影视搜索与播放由你的 LibreTV 服务提供。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("服务器设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        }
        .onAppear { draft = manualURL }
    }

    private func save() {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else {
            error = "地址不对，检查一下"
            return
        }
        manualURL = text
        autoRoute = false
        dismiss()
    }
}
