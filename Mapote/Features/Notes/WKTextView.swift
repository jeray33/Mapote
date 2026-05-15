import SwiftUI
import WebKit
import ObjectiveC.runtime

// MARK: - Outgoing from JS → Swift (mirrors types.ts OutgoingMessage)

struct EditorMessage: Decodable {
    let type: String
    let markdown: String?
    let blocks: [AnyBlock]?
    let mention: MentionInfo?
    let focused: Bool?
    let placeId: String?
    let message: String?

    struct AnyBlock: Decodable {
        let id: String
    }

    struct MentionInfo: Decodable {
        let query: String?
        let rect: MentionRect?
    }

    struct MentionRect: Decodable {
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
    }

    var isContentChanged: Bool { type == "contentChanged" }
    var isFocusChanged: Bool { type == "focusChanged" }
    var isReady: Bool { type == "ready" }
    var isPlaceTap: Bool { type == "placeTap" }
    var isError: Bool { type == "error" }
    var isRequestImagePicker: Bool { type == "requestImagePicker" }
}

// MARK: - WKWebView wrapper

struct WKTextView: UIViewRepresentable {
    let markdown: String
    let blocks: Data?
    let places: [Place]
    let isLocked: Bool
    let contentDebounceMs: Int
    let insertCommand: Binding<EditorInsertCommand?>
    let imageInsertion: Binding<EditorImageInsertion?>
    let insertPlaceRequest: Binding<PlaceInsertionRequest?>
    let onMarkdownChanged: (String, Data) -> Void
    let onMentionCheck: (String, CGRect?) -> Void
    let onPlaceTap: (String) -> Void
    let onFocusChange: (Bool) -> Void
    let onRequestImagePicker: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(EditorImageSchemeHandler(), forURLScheme: EditorImageStorage.scheme)

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "editor")
        config.userContentController = controller

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = true
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.showsHorizontalScrollIndicator = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.keyboardDismissMode = .none
        wv.inputAssistantItem.leadingBarButtonGroups = []
        wv.inputAssistantItem.trailingBarButtonGroups = []
        wv.navigationDelegate = context.coordinator
        wv.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleWebViewTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        wv.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap
        context.coordinator.webView = wv

        // Single-file HTML bundled by vite-plugin-singlefile
        guard let url = Bundle.main.url(forResource: "editor", withExtension: "html") else {
            let html = "<html><body><p style='color:red;padding:20px'>Editor resource missing. Run `npm run build`.</p></body></html>"
            wv.loadHTMLString(html, baseURL: Bundle.main.bundleURL)
            return wv
        }
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self

        // JSON blocks are the editing SoT. Only fall back to markdown when
        // blocks are absent (legacy notes).
        let hasContent: Bool = {
            if let blocks {
                return context.coordinator.lastSentBlocks != blocks
            }
            return context.coordinator.lastSentMarkdown != markdown
        }()

        if hasContent, context.coordinator.ready {
            setContent(wv, coordinator: context.coordinator)
        }

        if context.coordinator.lastSentLocked != isLocked {
            setLocked(wv, coordinator: context.coordinator, locked: isLocked)
        }

        if let cmd = insertCommand.wrappedValue {
            applyCommand(wv, coordinator: context.coordinator, kind: cmd.kind)
            insertCommand.wrappedValue = nil
        }

        if let img = imageInsertion.wrappedValue {
            insertImage(wv, coordinator: context.coordinator, url: img.url)
            imageInsertion.wrappedValue = nil
        }

        if let req = insertPlaceRequest.wrappedValue {
            insertPlace(wv, coordinator: context.coordinator, place: req.place)
            insertPlaceRequest.wrappedValue = nil
        }
    }

    static func dismantleUIView(_ wv: WKWebView, coordinator: Coordinator) {
        coordinator.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
    }

    // MARK: - Swift → JS helpers

    private func setContent(_ wv: WKWebView, coordinator: Coordinator, force: Bool = false) {
        if !force, !coordinator.ready { return }
        coordinator.lastSentMarkdown = markdown
        coordinator.lastSentBlocks = blocks
        let placesJSON = places.map { placeDict($0) }
        let json: [String: Any] = [
            "markdown": markdown,
            "blocks": blocks.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [Any] } ?? NSNull(),
            "places": placesJSON,
            "locked": isLocked,
            "timing": [
                "contentDebounceMs": contentDebounceMs,
            ],
        ]
        post(wv, method: "setContent", payload: json)
    }

    private func setLocked(_ wv: WKWebView, coordinator: Coordinator, locked: Bool) {
        coordinator.lastSentLocked = locked
        post(wv, method: "setLocked", payload: locked)
    }

    private func applyCommand(_ wv: WKWebView, coordinator: Coordinator, kind: EditorCommandKind) {
        post(wv, method: "applyCommand", payload: commandDict(kind))
    }

    private func insertPlace(_ wv: WKWebView, coordinator: Coordinator, place: Place) {
        post(wv, method: "insertPlace", payload: placeDict(place))
    }

    private func insertImage(_ wv: WKWebView, coordinator: Coordinator, url: String) {
        post(wv, method: "insertImage", payload: ["url": url])
    }

    private func post(_ wv: WKWebView, method: String, payload: Any) {
        // JSONSerialization only accepts array/dictionary as top-level object.
        // Wrap payload in a single-item array so bool/string payloads (e.g. setLocked)
        // remain valid and can be unwrapped in JS as array[0].
        let wrapped: [Any] = [payload]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let escaped = json.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "'", with: "\\'")
        wv.evaluateJavaScript(
            "(function(){const __args=JSON.parse('\(escaped)');window.editorBridge?.\(method)?.(__args[0]);})()"
        )
    }

    private func placeDict(_ p: Place) -> [String: Any] {
        [
            "id": p.id,
            "name": p.name,
            "address": p.address,
            "category": p.category?.rawValue ?? "other",
        ]
    }

    private func commandDict(_ kind: EditorCommandKind) -> [String: Any] {
        switch kind {
        case .insertText(let s):
            return ["kind": ["type": "insertText", "text": s]]
        case .toggleBold:
            return ["kind": ["type": "toggleBold"]]
        case .heading(let level):
            return ["kind": ["type": "heading", "level": level]]
        case .bulletList:
            return ["kind": ["type": "bulletList"]]
        case .orderedList:
            return ["kind": ["type": "orderedList"]]
        case .taskList:
            return ["kind": ["type": "taskList"]]
        case .divider:
            return ["kind": ["type": "divider"]]
        case .undo:
            return ["kind": ["type": "undo"]]
        case .redo:
            return ["kind": ["type": "redo"]]
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WKTextView
        weak var webView: WKWebView?
        weak var tapRecognizer: UITapGestureRecognizer?
        var ready = false
        var lastSentMarkdown: String?
        var lastSentBlocks: Data?
        var lastSentLocked: Bool?
        var lastIncomingSeq: Int = -1

        init(parent: WKTextView) {
            self.parent = parent
        }

        @objc
        func handleWebViewTap() {
            guard !parent.isLocked, let webView else { return }
            webView.evaluateJavaScript("window.editorBridge?.focusEditor?.()")
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // ready is set by the JS bridge's `reportReady()` call
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            // Drop stale/out-of-order bridge messages.
            if let seq = body["seq"] as? Int {
                if seq <= lastIncomingSeq { return }
                lastIncomingSeq = seq
            }

            switch type {
            case "ready":
                ready = true
                if let webView {
                    parent.setContent(webView, coordinator: self)
                }

            case "contentChanged":
                let md = body["markdown"] as? String ?? parent.markdown
                if let blocksArray = body["blocks"] as? [Any],
                   let blocksData = try? JSONSerialization.data(withJSONObject: blocksArray, options: []) {
                    // Mark as already in-sync to avoid Swift updateUIView re-sending
                    // the exact same content back into the editor (caret jump).
                    lastSentMarkdown = md
                    lastSentBlocks = blocksData
                    parent.onMarkdownChanged(md, blocksData)
                } else {
                    // Selection-only events may omit blocks; never overwrite content
                    // with empty data.
                    lastSentMarkdown = md
                }

                if let mentionDict = body["mention"] as? [String: Any] {
                    let query = mentionDict["query"] as? String ?? ""
                    var rect: CGRect? = nil
                    if let r = mentionDict["rect"] as? [String: Any] {
                        rect = CGRect(
                            x: (r["x"] as? Double) ?? 0,
                            y: (r["y"] as? Double) ?? 0,
                            width: (r["width"] as? Double) ?? 1,
                            height: (r["height"] as? Double) ?? 18
                        )
                    }
                    parent.onMentionCheck(rect != nil ? query : "", rect)
                } else {
                    parent.onMentionCheck("", nil)
                }

            case "focusChanged":
                parent.onFocusChange(body["focused"] as? Bool ?? false)

            case "placeTap":
                if let id = body["placeId"] as? String {
                    parent.onPlaceTap(id)
                }

            case "error":
                break

            case "requestImagePicker":
                parent.onRequestImagePicker()

            default:
                break
            }
        }
    }
}

/// Store old `PlaceInsertionRequest` — moved from deleted TiptapEditorView.swift
struct PlaceInsertionRequest: Identifiable, Equatable {
    let id = UUID()
    var place: Place
}

/// Subclass to stop safe-area insets from adding extra padding inside the webview.
private final class WebView: WKWebView {
    private var cleanedAssistant = false
    private var strippedInputAccessory = false

    override var safeAreaInsets: UIEdgeInsets { .zero }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !cleanedAssistant else { return }
        cleanedAssistant = true
        suppressInputAssistant(in: self)
        stripInputAccessory()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        suppressInputAssistant(in: self)
        stripInputAccessory()
    }

    private func suppressInputAssistant(in view: UIView) {
        if let responder = view as? UIResponder {
            responder.inputAssistantItem.leadingBarButtonGroups = []
            responder.inputAssistantItem.trailingBarButtonGroups = []
        }
        for subview in view.subviews {
            suppressInputAssistant(in: subview)
        }
    }

    @objc
    private var noInputAccessoryView: UIView? { nil }

    private func stripInputAccessory() {
        guard !strippedInputAccessory else { return }
        guard let contentView = scrollView.subviews.first(where: {
            NSStringFromClass(type(of: $0)).hasPrefix("WKContent")
        }) else { return }
        let baseClass: AnyClass = object_getClass(contentView) ?? type(of: contentView)
        let subclassName = "\(NSStringFromClass(baseClass))_NoInputAccessory"
        let subclass: AnyClass
        if let existing = NSClassFromString(subclassName) {
            subclass = existing
        } else {
            guard let name = (subclassName as NSString).utf8String,
                  let allocated = objc_allocateClassPair(baseClass, name, 0),
                  let method = class_getInstanceMethod(WebView.self, #selector(getter: WebView.noInputAccessoryView)) else { return }
            class_addMethod(
                allocated,
                #selector(getter: UIResponder.inputAccessoryView),
                method_getImplementation(method),
                method_getTypeEncoding(method)
            )
            objc_registerClassPair(allocated)
            subclass = allocated
        }
        object_setClass(contentView, subclass)
        contentView.reloadInputViews()
        strippedInputAccessory = true
    }
}
