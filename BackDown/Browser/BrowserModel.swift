import UIKit
import WebKit

/// WKWebView 하나를 소유하고, 페이지에서 발생한 다운로드를 가로채 DownloadManager로 넘긴다.
final class BrowserModel: NSObject, ObservableObject {
    static let homeURL = URL(string: "https://www.google.com")!
    /// WebKit이 표시는 할 수 있어도 보통 받으려는 타입
    private static let forcedDownloadMIME: Set<String> = [
        "application/octet-stream",
        "application/zip",
        "application/x-zip-compressed",
        "application/x-itunes-ipa",
        "application/vnd.android.package-archive",
        "application/x-apple-diskimage",
        "application/x-7z-compressed",
        "application/x-rar-compressed",
        "application/vnd.rar",
    ]

    let webView: WKWebView

    @Published var addressText = ""
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var toast: String?

    private var observations: [NSKeyValueObservation] = []
    private var userAgent: String?
    private var lastMainFrameRequest: URLRequest?
    private var committedURL: URL?
    private var toastWork: DispatchWorkItem?
    private var foregroundDownloads: [ObjectIdentifier: (id: UUID, destination: URL)] = [:]
    private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        observations = [
            webView.observe(\.url) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.addressText = wv.url?.absoluteString ?? "" }
            },
            webView.observe(\.title) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.title = wv.title ?? "" }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.isLoading = wv.isLoading }
            },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.progress = wv.estimatedProgress }
            },
        ]

        webView.load(URLRequest(url: Self.homeURL))
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            self?.userAgent = result as? String
        }
    }

    // MARK: - Navigation

    func go(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var target: URL?
        if text.contains("://") {
            target = URL(string: text)
        } else if text.contains("."), !text.contains(" ") {
            target = URL(string: "https://" + text)
        }
        if target == nil {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            target = components.url
        }
        if let target { webView.load(URLRequest(url: target)) }
    }

    func goHome() {
        webView.load(URLRequest(url: Self.homeURL))
    }

    func showToast(_ message: String) {
        toastWork?.cancel()
        toast = message
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - Download handoff

    /// 웹뷰의 쿠키/UA/Referer를 붙여 background 다운로드로 넘긴다.
    func download(url: URL, suggestedName: String?, referer: URL?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            showToast("이 링크는 백그라운드 다운로드를 지원하지 않아요")
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            // 리다이렉트(CDN 등)에서도 쿠키가 붙도록 공유 저장소에도 넣는다
            cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
            let matching = cookies.filter { Self.cookie($0, matches: url) }

            var request = URLRequest(url: url)
            for (key, value) in HTTPCookie.requestHeaderFields(with: matching) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let ua = self.userAgent {
                request.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
            if let referer, referer.scheme?.hasPrefix("http") == true {
                request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }
            DispatchQueue.main.async {
                DownloadManager.shared.enqueue(request: request, suggestedFileName: suggestedName)
                self.showToast("다운로드 시작: \(suggestedName ?? DownloadManager.fallbackName(for: url))")
            }
        }
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        let domainOK = host == domain || host.hasSuffix("." + domain)
        let path = url.path.isEmpty ? "/" : url.path
        let pathOK = path.hasPrefix(cookie.path)
        let secureOK = !cookie.isSecure || url.scheme?.lowercased() == "https"
        return domainOK && pathOK && secureOK
    }

    private static func isReplayable(_ request: URLRequest?) -> Bool {
        guard let request, let scheme = request.url?.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && (request.httpMethod ?? "GET").uppercased() == "GET"
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - WKNavigationDelegate

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame ?? true {
            lastMainFrameRequest = navigationAction.request
        }

        if navigationAction.shouldPerformDownload {
            if Self.isReplayable(navigationAction.request), let url = navigationAction.request.url {
                download(url: url, suggestedName: nil, referer: committedURL)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.download)
            }
            return
        }

        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        let response = navigationResponse.response
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isAttachment = disposition.hasPrefix("attachment")
        let forced = Self.forcedDownloadMIME.contains(response.mimeType?.lowercased() ?? "")

        guard isAttachment || forced || !navigationResponse.canShowMIMEType else {
            decisionHandler(.allow)
            return
        }

        if let url = response.url, Self.isReplayable(lastMainFrameRequest) {
            download(url: url, suggestedName: response.suggestedFilename, referer: committedURL)
            decisionHandler(.cancel)
        } else {
            // POST/blob 등 다시 요청할 수 없는 경우: 앱 내 WKDownload (포그라운드 전용)
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedURL = webView.url
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - WKDownloadDelegate (fallback)

extension BrowserModel: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let manager = DownloadManager.shared
        let destination = manager.uniqueDestination(for: suggestedFilename)
        let id = manager.addForegroundItem(fileName: destination.lastPathComponent, url: response.url, totalBytes: response.expectedContentLength)
        let key = ObjectIdentifier(download)
        foregroundDownloads[key] = (id, destination)
        progressObservations[key] = download.progress.observe(\.completedUnitCount) { progress, _ in
            DispatchQueue.main.async {
                manager.updateForegroundItem(id, received: progress.completedUnitCount, total: progress.totalUnitCount)
            }
        }
        showToast("앱 내 다운로드 시작 (앱을 나가면 중단될 수 있음)")
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        progressObservations[key] = nil
        if let entry = foregroundDownloads.removeValue(forKey: key) {
            DownloadManager.shared.finishForegroundItem(entry.id, fileURL: entry.destination)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        progressObservations[key] = nil
        if let entry = foregroundDownloads.removeValue(forKey: key) {
            DownloadManager.shared.failForegroundItem(entry.id, message: error.localizedDescription)
        }
    }
}

// MARK: - WKUIDelegate

extension BrowserModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open → 같은 창에서 연다
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: url.absoluteString, children: [
                UIAction(title: "BackDown으로 다운로드", image: UIImage(systemName: "arrow.down.circle")) { _ in
                    self?.download(url: url, suggestedName: nil, referer: self?.committedURL)
                },
                UIAction(title: "열기", image: UIImage(systemName: "safari")) { _ in
                    self?.webView.load(URLRequest(url: url))
                },
                UIAction(title: "링크 복사", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = url
                },
            ])
        }
        completionHandler(config)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let top = topViewController() else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler() })
        top.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let top = topViewController() else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler(true) })
        top.present(alert, animated: true)
    }
}
