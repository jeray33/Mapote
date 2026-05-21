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
    let placeSearchResponse: Binding<PlaceSearchResponse?>
    let flushRequest: Binding<EditorFlushRequest?>
    let onMarkdownChanged: (String, Data) -> Void
    let onMentionCheck: (String, CGRect?) -> Void
    let onPlaceTap: (String) -> Void
    let onFocusChange: (Bool) -> Void
    let onRequestImagePicker: () -> Void
    let onPlaceSearchRequest: (String, String) -> Void
    let onPlaceCandidateSelected: (PlaceCandidate, Bool) -> Void
    let onEditorModeChange: (String, Int) -> Void
    let onToolbarStateChange: (EditorToolbarState) -> Void
    let onContentFlush: (UUID) -> Void

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
        let incomingBlocksSignature = blocks.flatMap { canonicalJSONSignature(data: $0) }
        let hasContent: Bool = {
            if blocks != nil {
                return context.coordinator.lastSentBlocksSignature != incomingBlocksSignature
            }
            return context.coordinator.lastSentMarkdown != markdown
        }()

        if hasContent, context.coordinator.ready, !context.coordinator.webIsFocused {
            setContent(wv, coordinator: context.coordinator)
        }

        if context.coordinator.lastSentLocked != isLocked {
            setLocked(wv, coordinator: context.coordinator, locked: isLocked)
        }

        if let cmd = insertCommand.wrappedValue {
            applyCommand(wv, coordinator: context.coordinator, command: cmd)
            DispatchQueue.main.async {
                if insertCommand.wrappedValue?.id == cmd.id {
                    insertCommand.wrappedValue = nil
                }
            }
        }

        if let img = imageInsertion.wrappedValue {
            insertImage(wv, coordinator: context.coordinator, insertion: img)
            DispatchQueue.main.async {
                if imageInsertion.wrappedValue?.id == img.id {
                    imageInsertion.wrappedValue = nil
                }
            }
        }

        if let req = insertPlaceRequest.wrappedValue {
            insertPlace(wv, coordinator: context.coordinator, request: req)
            DispatchQueue.main.async {
                if insertPlaceRequest.wrappedValue?.id == req.id {
                    insertPlaceRequest.wrappedValue = nil
                }
            }
        }

        if let response = placeSearchResponse.wrappedValue {
            post(
                wv,
                method: "placeSearchResults",
                payload: [
                    "requestId": response.requestId,
                    "results": response.results.map { mapPlaceDict($0) },
                ]
            )
            DispatchQueue.main.async {
                if placeSearchResponse.wrappedValue?.id == response.id {
                    placeSearchResponse.wrappedValue = nil
                }
            }
        }

        if let request = flushRequest.wrappedValue {
            post(wv, method: "flushContent", payload: ["requestId": request.id.uuidString])
            DispatchQueue.main.async {
                if flushRequest.wrappedValue?.id == request.id {
                    flushRequest.wrappedValue = nil
                }
            }
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
        coordinator.lastSentBlocksSignature = blocks.flatMap { canonicalJSONSignature(data: $0) }
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

    private func applyCommand(_ wv: WKWebView, coordinator: Coordinator, command: EditorInsertCommand) {
        guard coordinator.sentCommandIDs.insert(command.id).inserted else { return }
        var payload = commandDict(command.kind)
        payload["id"] = command.id.uuidString
        post(wv, method: "applyCommand", payload: payload)
    }

    private func insertPlace(_ wv: WKWebView, coordinator: Coordinator, request: PlaceInsertionRequest) {
        guard coordinator.sentPlaceInsertionIDs.insert(request.id).inserted else { return }
        var payload = placeDict(request.place)
        payload["requestId"] = request.id.uuidString
        post(wv, method: "insertPlace", payload: payload)
    }

    private func insertImage(_ wv: WKWebView, coordinator: Coordinator, insertion: EditorImageInsertion) {
        guard coordinator.sentImageInsertionIDs.insert(insertion.id).inserted else { return }
        post(wv, method: "insertImage", payload: ["id": insertion.id.uuidString, "url": insertion.url])
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

    private func canonicalJSONSignature(data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return canonicalJSONSignature(object: object)
    }

    private func canonicalJSONSignature(object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func placeDict(_ p: Place) -> [String: Any] {
        var dict: [String: Any] = [
            "id": p.id,
            "name": p.name,
            "address": p.address,
            "lat": p.lat,
            "lng": p.lng,
            "placeId": p.placeId ?? p.id,
            "category": p.category?.rawValue ?? "other",
        ]
        if let image = p.image { dict["photoUrl"] = image }
        if let images = p.images { dict["photoUrls"] = images }
        if let types = p.types { dict["types"] = types }
        if let rating = p.rating { dict["rating"] = rating }
        if let openingHours = p.openingHours { dict["openingHours"] = openingHours }
        if let description = p.description { dict["editorialSummary"] = description }
        if let openNow = p.openNow { dict["openNow"] = openNow }
        return dict
    }

    private func mapPlaceDict(_ p: MapPlace) -> [String: Any] {
        var dict: [String: Any] = [
            "id": p.id,
            "name": p.name,
            "address": p.address,
            "lat": p.lat,
            "lng": p.lng,
            "category": PlaceCategory.infer(from: p.types).rawValue,
        ]
        if let placeId = p.placeId { dict["placeId"] = placeId }
        if let types = p.types { dict["types"] = types }
        if let photoUrl = p.photoUrl { dict["photoUrl"] = photoUrl }
        if let photoUrls = p.photoUrls { dict["photoUrls"] = photoUrls }
        if let rating = p.rating { dict["rating"] = rating }
        if let openingHours = p.openingHours { dict["openingHours"] = openingHours }
        if let editorialSummary = p.editorialSummary { dict["editorialSummary"] = editorialSummary }
        if let openNow = p.openNow { dict["openNow"] = openNow }
        return dict
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
        var lastSentBlocksSignature: String?
        var lastSentLocked: Bool?
        var lastContentRevision: Int = -1
        var webIsFocused = false
        var sentCommandIDs: Set<UUID> = []
        var sentImageInsertionIDs: Set<UUID> = []
        var sentPlaceInsertionIDs: Set<UUID> = []

        init(parent: WKTextView) {
            self.parent = parent
        }

        @objc
        func handleWebViewTap() {
            // The Tiptap state machine owns tap → edit transitions. A native
            // fallback focus here can reintroduce cursors in display/multi-select.
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

            switch type {
            case "ready":
                ready = true
                lastContentRevision = -1
                print("[WKTextView] ready: blocks=\(parent.blocks?.count ?? -1), md=\(parent.markdown.prefix(30))…")
                if let webView {
                    parent.setContent(webView, coordinator: self)
                }

            case "contentChanged":
                if let revision = body["revision"] as? Int {
                    guard revision > lastContentRevision else {
                        print("[WKTextView] contentChanged: SKIPPED stale revision \(revision) <= \(lastContentRevision)")
                        return
                    }
                    lastContentRevision = revision
                }
                let md = body["markdown"] as? String ?? parent.markdown
                if let blocksArray = body["blocks"] as? [Any],
                   let blocksData = try? JSONSerialization.data(withJSONObject: blocksArray, options: [.sortedKeys]) {
                    print("[WKTextView] contentChanged: \(blocksData.count) bytes, md=\(md.prefix(30))…")
                    // Mark as already in-sync to avoid Swift updateUIView re-sending
                    // the exact same content back into the editor (caret jump).
                    lastSentMarkdown = md
                    lastSentBlocks = blocksData
                    lastSentBlocksSignature = parent.canonicalJSONSignature(object: blocksArray)
                    parent.onMarkdownChanged(md, blocksData)
                } else {
                    // Selection-only events may omit blocks; never overwrite content
                    // with empty data.
                    print("[WKTextView] contentChanged: no blocks in message, md-only")
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
                let focused = body["focused"] as? Bool ?? false
                webIsFocused = focused
                parent.onFocusChange(focused)

            case "placeTap":
                if let id = body["placeId"] as? String {
                    parent.onPlaceTap(id)
                }

            case "error":
                break

            case "requestImagePicker":
                parent.onRequestImagePicker()

            case "requestPlaceSearch":
                if let requestId = body["requestId"] as? String {
                    parent.onPlaceSearchRequest(requestId, body["query"] as? String ?? "")
                }

            case "placeCandidateSelected":
                if let dict = body["place"] as? [String: Any] {
                    parent.onPlaceCandidateSelected(PlaceCandidate(dict: dict), body["inserted"] as? Bool ?? false)
                }

            case "modeChanged":
                if let mode = body["mode"] as? String {
                    parent.onEditorModeChange(mode, body["selectedCount"] as? Int ?? 0)
                }

            case "toolbarState":
                if let dict = body["state"] as? [String: Any] {
                    parent.onToolbarStateChange(EditorToolbarState(dict: dict))
                }

            case "contentFlushed":
                if let raw = body["requestId"] as? String,
                   let id = UUID(uuidString: raw) {
                    parent.onContentFlush(id)
                }

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

struct PlaceSearchResponse: Identifiable, Equatable {
    let id = UUID()
    let requestId: String
    let results: [MapPlace]
}

struct EditorFlushRequest: Identifiable, Equatable {
    let id = UUID()
}

struct EditorToolbarState: Equatable {
    var bold = false
    var headingLevel = 0
    var bulletList = false
    var orderedList = false
    var taskList = false
    var composing = false

    init() {}

    init(dict: [String: Any]) {
        self.bold = dict["bold"] as? Bool ?? false
        self.headingLevel = dict["headingLevel"] as? Int ?? 0
        self.bulletList = dict["bulletList"] as? Bool ?? false
        self.orderedList = dict["orderedList"] as? Bool ?? false
        self.taskList = dict["taskList"] as? Bool ?? false
        self.composing = dict["composing"] as? Bool ?? false
    }
}

struct PlaceCandidate: Equatable {
    var id: String
    var name: String
    var address: String
    var lat: Double
    var lng: Double
    var placeId: String?
    var photoUrl: String?
    var photoUrls: [String]?
    var types: [String]?
    var rating: Double?
    var openingHours: [String]?
    var editorialSummary: String?
    var openNow: Bool?

    init(dict: [String: Any]) {
        let pid = dict["placeId"] as? String
        self.id = (dict["id"] as? String) ?? pid ?? UUID().uuidString
        self.name = (dict["name"] as? String) ?? "地点"
        self.address = (dict["address"] as? String) ?? ""
        self.lat = (dict["lat"] as? Double) ?? 0
        self.lng = (dict["lng"] as? Double) ?? 0
        self.placeId = pid
        self.photoUrl = dict["photoUrl"] as? String
        self.photoUrls = dict["photoUrls"] as? [String]
        self.types = dict["types"] as? [String]
        self.rating = dict["rating"] as? Double
        self.openingHours = dict["openingHours"] as? [String]
        self.editorialSummary = dict["editorialSummary"] as? String
        self.openNow = dict["openNow"] as? Bool
    }
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
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
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
