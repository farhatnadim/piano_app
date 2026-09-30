import Foundation
import Observation
import PianoCoachCore
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Hosts the YouTube IFrame player in a WKWebView and exposes it as an observable Swift object.
///
/// The page (`youtube_player.html`) is loaded with a base URL of `https://<bundle id>` and the same
/// value as the player's `origin`, which is how YouTube identifies embeds inside apps (without it
/// videos fail with error 152/153 "Video player configuration error").
@MainActor
@Observable
final class YouTubePlayerController {
    enum PlaybackState: Int, Equatable {
        case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3, cued = 5
    }

    private(set) var isReady = false
    private(set) var state: PlaybackState = .unstarted
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Double = 1
    private(set) var availableRates: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private(set) var isMuted = false
    private(set) var errorMessage: String?
    /// YouTube refused to start playback without a tap on the video itself.
    private(set) var autoplayBlocked = false
    private(set) var videoID: String?

    /// True while the video is playing or buffering in order to play.
    var isPlaying: Bool { state == .playing || state == .buffering }

    /// Called after every position/state report (about 10 times per second while ready).
    @ObservationIgnored var onUpdate: (() -> Void)?

    let webView: WKWebView
    private let messageProxy = ScriptMessageProxy()
    private let tapProxy = AudioTapMessageProxy()
    private let navigationHandler = NavigationHandler()
    @ObservationIgnored private var pageTemplate: String?
    /// The YouTube player's frame, once its audio tap script has said hello.
    @ObservationIgnored private var tapFrame: WKFrameInfo?
    /// Receives the video's own sound while the audio tap runs: samples, their rate, the video's time at
    /// the last sample, and whether the video was playing.
    @ObservationIgnored var onTapAudio: (([Float], Double, Double, Bool) -> Void)?

    /// The script world the audio tap runs in, apart from the page's and YouTube's own scripts.
    private static let tapWorld = WKContentWorld.world(name: "PianoCoachAudioTap")
    /// Put away: WebKit hands Web Audio only silence for YouTube's streamed (MediaSource) video — checked
    /// in the iOS 26.5 simulator: the tap ran and received blocks, all zero. `WebAssets/audio_tap.js` stays
    /// for a WebKit that allows it.
    static let tapsAudio = false

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isTextInteractionEnabled = false
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        configuration.userContentController.add(messageProxy, name: "youtube")
        if Self.tapsAudio, let url = Bundle.main.url(forResource: "audio_tap", withExtension: "js", subdirectory: "WebAssets"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.tapWorld))
            configuration.userContentController.add(tapProxy, contentWorld: Self.tapWorld, name: "pianoAudio")
        }

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 360), configuration: configuration)
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        webView.navigationDelegate = navigationHandler
        webView.uiDelegate = navigationHandler
        #if DEBUG
        webView.isInspectable = true
        #endif

        messageProxy.onMessage = { [weak self] body in
            self?.handle(body)
        }
        tapProxy.onMessage = { [weak self] body, frame in
            self?.handleTap(body, frame: frame)
        }
        if let url = Bundle.main.url(forResource: "youtube_player", withExtension: "html", subdirectory: "WebAssets") {
            pageTemplate = try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The app's identity for YouTube: `https://<bundle id>` (lower-cased, no trailing slash).
    /// YouTube's Required Minimum Functionality asks WebView apps to send this as the HTTP Referer.
    static var origin: String {
        "https://" + (Bundle.main.bundleIdentifier ?? "com.example.pianocoach").lowercased()
    }

    /// Base URL for the player page; WebKit derives the Referer of the YouTube iframe from it.
    static var baseURL: URL {
        URL(string: origin + "/") ?? URL(string: "https://com.example.pianocoach/")!
    }

    // MARK: - Loading

    func load(videoID: String, startTime: Double = 0, muted: Bool = false) {
        guard YouTubeLink.isValidVideoID(videoID) else {
            errorMessage = YouTubePlayerController.describeError(2)
            return
        }
        guard let template = pageTemplate else {
            errorMessage = "The video player page is missing from the app."
            return
        }
        let config: [String: Any] = [
            "videoId": videoID,
            "start": max(0, startTime),
            "origin": Self.origin,
            "muted": muted,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: config),
              let rawJSON = String(data: json, encoding: .utf8) else { return }
        // Never let data close the <script> element.
        let jsonString = rawJSON.replacingOccurrences(of: "<", with: "\\u003c")
        self.videoID = videoID
        isReady = false
        state = .unstarted
        currentTime = max(0, startTime)
        duration = 0
        rate = 1
        isMuted = muted
        errorMessage = nil
        autoplayBlocked = false
        tapFrame = nil
        navigationHandler.allowedHost = Self.baseURL.host
        webView.loadHTMLString(template.replacingOccurrences(of: "__PIANO_COACH_CONFIG__", with: jsonString),
                               baseURL: Self.baseURL)
    }

    // MARK: - Commands

    func play() {
        autoplayBlocked = false
        run("PianoPlayer.play()")
    }

    func pause() {
        run("PianoPlayer.pause()")
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.2) : seconds)
        currentTime = target
        run("PianoPlayer.seek(\(target))")
    }

    /// Requests a playback rate; the player may round it (the applied rate is reported back in `rate`).
    func setRate(_ newRate: Double) {
        guard newRate.isFinite, newRate > 0 else { return }
        webView.callAsyncJavaScript("return PianoPlayer.setRate(r);", arguments: ["r": newRate],
                                    in: nil, in: .page) { [weak self] result in
            if case .success(let value) = result, let applied = (value as? NSNumber)?.doubleValue {
                self?.rate = applied
            }
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        run("PianoPlayer.setMuted(\(muted ? "true" : "false"))")
    }

    private func run(_ script: String) {
        guard isReady else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - The video's own sound

    /// Whether the player's frame has loaded the audio tap (`WebAssets/audio_tap.js`).
    var canTapAudio: Bool { tapFrame != nil }

    /// Starts sending the video's sound to `onTapAudio`. Returns the script's answer ("ok running 48000",
    /// "no video"…), or nil when the player's frame isn't known yet or didn't answer.
    func startAudioTap() async -> String? {
        await callTap("return PianoAudioTap.start();")
    }

    #if DEBUG
    /// What the audio tap sees (JSON), for checking it.
    func audioTapStats() async -> String? {
        await callTap("return PianoAudioTap.stats();")
    }
    #endif

    func stopAudioTap() {
        Task { _ = await callTap("return PianoAudioTap.stop();") }
    }

    private func callTap(_ body: String) async -> String? {
        guard let frame = tapFrame else { return nil }
        return (try? await webView.callAsyncJavaScript(body, in: frame, contentWorld: Self.tapWorld)) as? String
    }

    private func handleTap(_ body: Any, frame: WKFrameInfo) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "hello":
            tapFrame = frame
        case "audio":
            guard let onTapAudio, let rate = (message["rate"] as? NSNumber)?.doubleValue,
                  let videoTime = (message["videoTime"] as? NSNumber)?.doubleValue,
                  let encoded = message["pcm"] as? String, let data = Data(base64Encoded: encoded) else { return }
            var pcm = [Int16](repeating: 0, count: data.count / 2)
            _ = pcm.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            let playing = (message["playing"] as? NSNumber)?.boolValue ?? false
            onTapAudio(pcm.map { Float($0) / 32768 }, rate, videoTime, playing)
        default:
            break
        }
    }

    // MARK: - Messages from the page

    private func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            errorMessage = nil
            duration = (message["duration"] as? NSNumber)?.doubleValue ?? duration
            if let rates = message["rates"] as? [NSNumber], !rates.isEmpty {
                availableRates = rates.map(\.doubleValue).sorted()
            }
            isMuted = (message["muted"] as? NSNumber)?.boolValue ?? isMuted
        case "time":
            if let t = (message["time"] as? NSNumber)?.doubleValue { currentTime = t }
            if let d = (message["duration"] as? NSNumber)?.doubleValue, d > 0 { duration = d }
            if let r = (message["rate"] as? NSNumber)?.doubleValue, r > 0 { rate = r }
            if let m = (message["muted"] as? NSNumber)?.boolValue { isMuted = m }
            if let s = (message["state"] as? NSNumber)?.intValue { updateState(s) }
        case "state":
            if let t = (message["time"] as? NSNumber)?.doubleValue { currentTime = t }
            if let s = (message["state"] as? NSNumber)?.intValue { updateState(s) }
        case "rate":
            if let r = (message["rate"] as? NSNumber)?.doubleValue, r > 0 { rate = r }
        case "autoplayBlocked":
            autoplayBlocked = true
        case "error":
            let code = (message["code"] as? NSNumber)?.intValue ?? 0
            errorMessage = Self.describeError(code)
        default:
            break
        }
        onUpdate?()
    }

    private func updateState(_ raw: Int) {
        guard let newState = PlaybackState(rawValue: raw), newState != state else { return }
        state = newState
    }

    static func describeError(_ code: Int) -> String {
        switch code {
        case -1: return "Couldn't reach YouTube. Check the internet connection."
        case 2: return "That doesn't look like a valid YouTube video."
        case 5: return "This video can't be played in the app's player."
        case 100: return "This video was removed or is private."
        case 101, 150: return "The video's owner doesn't allow it to be played inside other apps. Try a different video."
        case 152, 153: return "YouTube rejected the player setup (error \(code)). Make sure the app has a bundle identifier and try again."
        default: return "The video couldn't be played (error \(code))."
        }
    }
}

// MARK: - WebKit helpers

/// Forwards script messages without WKUserContentController retaining the controller (avoids a cycle).
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only our own page (the main frame) talks to the app; ignore anything from the YouTube iframe.
        guard message.frameInfo.isMainFrame else { return }
        onMessage?(message.body)
    }
}

/// Forwards the audio tap's messages with the frame they came from. Only the tap's own script world can
/// post them, and only YouTube's frames run the tap.
@MainActor
private final class AudioTapMessageProxy: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any, WKFrameInfo) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let host = message.frameInfo.securityOrigin.host.lowercased()
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else { return }
        onMessage?(message.body, message.frameInfo)
    }
}

/// Keeps the player page in place: YouTube frames load normally, but links that would navigate the
/// whole page (the YouTube logo, "watch on YouTube") open in the browser instead.
@MainActor
private final class NavigationHandler: NSObject, WKNavigationDelegate, WKUIDelegate {
    var allowedHost: String?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrame, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "about" || url.host?.lowercased() == allowedHost {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            openExternally(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openExternally(url) }
        return nil
    }

    private func openExternally(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

extension YouTubePlayerController {
    /// Where the video is on the screen, as fractions (0...1) of the screen from its top-left corner, with
    /// a little margin; nil when it isn't on screen. Screen recordings use it to find the video.
    var rectOnScreen: CGRect? {
        #if os(iOS)
        guard let window = webView.window, window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let frame = webView.convert(webView.bounds, to: nil)
        let screen = window.bounds
        let rect = CGRect(x: frame.minX / screen.width, y: frame.minY / screen.height,
                          width: frame.width / screen.width, height: frame.height / screen.height)
        #else
        guard let window = webView.window, let screen = window.screen else { return nil }
        let inWindow = webView.convert(webView.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let display = screen.frame
        let rect = CGRect(x: (onScreen.minX - display.minX) / display.width,
                          y: (display.maxY - onScreen.maxY) / display.height,
                          width: onScreen.width / display.width, height: onScreen.height / display.height)
        #endif
        let padded = rect.insetBy(dx: -0.02, dy: -0.02).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return padded.isNull || padded.width < 0.05 ? nil : padded
    }
}
