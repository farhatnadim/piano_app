import Foundation
import Observation
import WebKit

/// Renders MusicXML with OpenSheetMusicDisplay (bundled, works offline) in a WKWebView and moves a
/// green cursor to where the child is. See `WebAssets/sheet.html` for the JavaScript side (`window.PianoSheet`).
/// `WebAssets` is copied into the app bundle as a folder, so the page loads the script next to it.
@MainActor
@Observable
final class SheetMusicController {
    private(set) var isPageReady = false
    private(set) var isLoaded = false
    private(set) var measureCount = 0
    private(set) var errorMessage: String?
    private(set) var zoom: Double = 1

    /// Called when the child/parent taps a measure (source measure index, 0-based).
    @ObservationIgnored var onTapMeasure: ((Int) -> Void)?

    let webView: WKWebView
    private let messageProxy = SheetMessageProxy()
    @ObservationIgnored private var pendingXML: String?
    @ObservationIgnored private var loadedXML: String?
    @ObservationIgnored private var pendingPosition: SheetPosition?
    @ObservationIgnored private var lastSentPosition: SheetPosition?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(messageProxy, name: "sheet")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif
        messageProxy.onMessage = { [weak self] body in self?.handle(body) }
        if let page = Bundle.main.url(forResource: "sheet", withExtension: "html", subdirectory: "WebAssets") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            errorMessage = "The sheet-music page is missing from the app."
        }
    }

    /// Shows MusicXML text. Safe to call before the page has finished loading.
    func load(musicXML: String) {
        guard musicXML != loadedXML else { return }
        pendingXML = musicXML
        isLoaded = false
        errorMessage = nil
        lastSentPosition = nil
        if isPageReady { sendPendingXML() }
    }

    /// Moves the cursor (nil hides it).
    func setPosition(_ position: SheetPosition?) {
        guard isLoaded else {
            pendingPosition = position
            return
        }
        guard position != lastSentPosition else { return }
        lastSentPosition = position
        if let position {
            webView.callAsyncJavaScript("PianoSheet.moveTo(m, b); return null;",
                                        arguments: ["m": position.sourceMeasureIndex, "b": position.beatInMeasure],
                                        in: nil, in: .page, completionHandler: nil)
        } else {
            webView.evaluateJavaScript("PianoSheet.hideCursor(); null;", completionHandler: nil)
        }
    }

    func setZoom(_ value: Double) {
        let clamped = max(0.3, min(3, value))
        zoom = clamped
        guard isLoaded else { return }
        webView.callAsyncJavaScript("PianoSheet.setZoom(z); return null;", arguments: ["z": clamped],
                                    in: nil, in: .page, completionHandler: nil)
    }

    private func sendPendingXML() {
        guard let xml = pendingXML else { return }
        pendingXML = nil
        loadedXML = xml
        // Arguments are passed as data, so no escaping of the XML is needed.
        webView.callAsyncJavaScript("await PianoSheet.load(xml); return null;", arguments: ["xml": xml],
                                    in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result, self.errorMessage == nil {
                self.errorMessage = "Couldn't show this music: \(error.localizedDescription)"
                self.loadedXML = nil
            }
        }
    }

    private func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isPageReady = true
            sendPendingXML()
        case "loaded":
            isLoaded = true
            measureCount = (message["measures"] as? NSNumber)?.intValue ?? 0
            if zoom != 1 { setZoom(zoom) }
            let position = pendingPosition
            pendingPosition = nil
            setPosition(position)
        case "error":
            isLoaded = false
            loadedXML = nil
            errorMessage = "Couldn't show this music: \(message["message"] as? String ?? "unknown error")"
        case "tapMeasure":
            if let m = (message["measureIndex"] as? NSNumber)?.intValue { onTapMeasure?(m) }
        default:
            break
        }
    }
}

@MainActor
private final class SheetMessageProxy: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        onMessage?(message.body)
    }
}
