import SwiftUI
import WebKit

/// WKWebView wrapper that loads YouTube Shorts with a mobile user-agent
/// for a full vertical reel experience.
struct SmartTVView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator

        // Register with controller so it can be controlled externally
        SmartTVController.shared.webView = webView

        // If there's a pending search query, go straight to search instead of /shorts
        if let pending = SmartTVController.shared.pendingQuery {
            SmartTVController.shared.searchAndPlay(query: pending)
        } else {
            if let url = URL(string: "https://m.youtube.com/shorts") {
                webView.load(URLRequest(url: url))
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No dynamic updates needed
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        /// JavaScript that disables video looping and auto-scrolls to the next Short when one ends.
        static let autoAdvanceJS = """
        (function() {
            document.querySelectorAll('video').forEach(v => v.muted = true);
            if (!window.__fazmAutoAdvance) {
                window.__fazmAutoAdvance = true;
                function attachEndedListener(video) {
                    if (video.__fazmEnded) return;
                    video.__fazmEnded = true;
                    video.loop = false;
                    video.addEventListener('ended', function() {
                        var container = document.querySelector('#shorts-container') ||
                                        document.querySelector('ytm-shorts-player') ||
                                        document.scrollingElement || document.body;
                        container.scrollBy({ top: window.innerHeight, behavior: 'smooth' });
                    });
                }
                document.querySelectorAll('video').forEach(attachEndedListener);
                new MutationObserver(function(mutations) {
                    document.querySelectorAll('video').forEach(function(v) {
                        v.muted = true;
                        attachEndedListener(v);
                    });
                }).observe(document.body, { childList: true, subtree: true });
            }
        })();
        """

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? ""
            log("SmartTV: didFinish — url=\(url.prefix(80))")

            if url.contains("/results") {
                // On search results page: click the first Shorts result
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    log("SmartTV: clicking first Shorts result")
                    let js = """
                    (function() {
                        var links = document.querySelectorAll('a[href*="/shorts/"]');
                        if (links.length > 0) {
                            links[0].click();
                        }
                    })();
                    """
                    webView.evaluateJavaScript(js)

                    // Inject auto-advance after click (SPA navigation won't trigger didFinish)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        SmartTVController.shared.navigationFinished()
                        webView.evaluateJavaScript(Self.autoAdvanceJS)
                        log("SmartTV: injected auto-advance after search→shorts SPA nav")
                    }
                }
            } else if url.contains("/shorts/") {
                // On Shorts player page: navigation done, let YouTube autoplay
                SmartTVController.shared.navigationFinished()
                webView.evaluateJavaScript(Self.autoAdvanceJS)
                log("SmartTV: on Shorts player, navigation finished (muted, auto-advance enabled)")
            } else {
                SmartTVController.shared.navigationFinished()
            }
        }
    }
}
