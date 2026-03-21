import WebKit

/// Controls the Smart TV WKWebView — search, play, pause.
@MainActor
class SmartTVController {
    static let shared = SmartTVController()
    weak var webView: WKWebView?

    /// True while a search navigation is in progress — suppresses play/pause
    /// from Combine observers to avoid fighting with page load.
    var isNavigating = false

    /// Pending search query — set when searchAndPlay is called before the webView exists.
    /// Consumed by the SmartTVView coordinator after initial page load.
    var pendingQuery: String?

    /// Navigate to YouTube Shorts search results for the given query.
    func searchAndPlay(query: String) {
        guard let webView else {
            // WebView not ready yet — store for later
            log("SmartTV: searchAndPlay deferred (webView nil) — query: \(query.prefix(50))")
            pendingQuery = query
            return
        }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://m.youtube.com/results?search_query=\(encoded)&sp=EgIYAQ%3D%3D")
        else { return }
        pendingQuery = nil
        isNavigating = true
        log("SmartTV: searchAndPlay — navigating to: \(query.prefix(50))")
        webView.load(URLRequest(url: url))
    }

    func pauseVideo(source: String = "") {
        guard !isNavigating else {
            log("SmartTV: pauseVideo SKIPPED (navigating) source=\(source)")
            return
        }
        log("SmartTV: pauseVideo source=\(source)")
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())")
    }

    func playVideo(source: String = "") {
        log("SmartTV: playVideo source=\(source)")
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.play())")
    }

    /// Called when navigation completes and the Shorts player is ready.
    func navigationFinished() {
        isNavigating = false
    }
}
