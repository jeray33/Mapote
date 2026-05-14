import SwiftUI
import UIKit
import WebKit
import ObjectiveC.runtime

private final class NoAccessoryView: UIView {
    @objc override var inputAccessoryView: UIView? { nil }
}

private final class EditorWebView: WKWebView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        hideAccessoryView()
    }

    private func hideAccessoryView() {
        scrollView.subviews.forEach { subview in
            let className = NSStringFromClass(type(of: subview))
            guard className.hasPrefix("WKContent") || className.contains("WKApplicationStateTrackingView") else { return }
            guard let targetClass: AnyClass = object_getClass(subview) else { return }

            let subclassName = "\(className)_NoAccessory"
            if let existing = NSClassFromString(subclassName) {
                object_setClass(subview, existing)
                return
            }

            guard let subclass = objc_allocateClassPair(targetClass, subclassName, 0),
                  let method = class_getInstanceMethod(NoAccessoryView.self, #selector(getter: NoAccessoryView.inputAccessoryView))
            else { return }

            class_addMethod(
                subclass,
                #selector(getter: UIResponder.inputAccessoryView),
                method_getImplementation(method),
                method_getTypeEncoding(method)
            )
            objc_registerClassPair(subclass)
            object_setClass(subview, subclass)
        }
    }
}

struct PlaceInsertionRequest: Identifiable, Equatable {
    let id = UUID()
    var place: Place
}

struct TiptapEditorView: UIViewRepresentable {
    struct MentionRect {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct MentionContext {
        var query: String
        var rect: MentionRect?
    }

    @Binding var markdown: String
    @Binding var blocks: Data?
    @Binding var insertCommand: EditorInsertCommand?
    @Binding var placeInsertionRequest: PlaceInsertionRequest?
    @Binding var imageInsertion: EditorImageInsertion?
    @Binding var imagePickerRequest: UUID?
    @Binding var loadErrorMessage: String?
    var places: [Place]
    var isLocked: Bool
    var onFocusChange: (Bool) -> Void
    var onMentionCheck: (String, MentionContext?) -> Void
    var onTapPlace: (String) -> Void
    var onBlocksUpdate: ((Data, String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "editor")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            context.coordinator.imageSchemeHandler,
            forURLScheme: EditorImageStorage.scheme
        )

        let webView = EditorWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        if let fileURL = Bundle.main.url(forResource: "editor", withExtension: "html")
            ?? Bundle.main.url(forResource: "tiptap-editor", withExtension: "html") {
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncIfNeeded()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: TiptapEditorView
        weak var webView: WKWebView?
        let imageSchemeHandler = EditorImageSchemeHandler()
        private var isReady = false
        private var currentMarkdown = ""
        private var currentBlocksData: Data?
        private var lastInsertCommandID: UUID?
        private var lastPlaceInsertID: UUID?
        private var lastImageInsertID: UUID?
        private var lastLockedSent: Bool?
        private var lastReceivedFromJSAt: Date?
        private var latestSeqFromJS: Int = 0
        private var outboundRevision: Int = 0

        init(parent: TiptapEditorView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 等待前端脚本通过 ready/error 主动汇报
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loadErrorMessage = "编辑器加载失败，已切换降级模式"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loadErrorMessage = "编辑器加载失败，已切换降级模式"
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "editor",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            switch type {
            case "ready":
                isReady = true
                parent.loadErrorMessage = nil
                syncIfNeeded(force: true)
            case "error":
                parent.loadErrorMessage = (body["message"] as? String) ?? "编辑器初始化失败"
            case "contentChanged":
                let markdown = body["markdown"] as? String
                if let seqNum = body["seq"] as? NSNumber {
                    latestSeqFromJS = max(latestSeqFromJS, seqNum.intValue)
                } else if let seqInt = body["seq"] as? Int {
                    latestSeqFromJS = max(latestSeqFromJS, seqInt)
                }
                var blocksData: Data?
                if let blocksAny = body["blocks"] {
                    blocksData = try? JSONSerialization.data(withJSONObject: blocksAny, options: [])
                }
                // Mark that JS just sent us an edit. Any SwiftUI re-render in the
                // next ~200ms is the echo of this edit and must NOT push setContent
                // back to JS (which could clobber a newer in-flight edit).
                lastReceivedFromJSAt = Date()
                if let markdown {
                    currentMarkdown = markdown
                }
                if let blocksData {
                    currentBlocksData = blocksData
                }
                if let blocksData, let markdown {
                    if parent.blocks != blocksData || parent.markdown != markdown {
                        parent.onBlocksUpdate?(blocksData, markdown)
                    }
                } else if let markdown, parent.markdown != markdown {
                    parent.markdown = markdown
                }
                if let mention = body["mention"] as? [String: Any],
                   let query = mention["query"] as? String {
                    let rectDict = mention["rect"] as? [String: Any]
                    let rect = rectDict.flatMap { dict -> MentionRect? in
                        guard let x = dict["x"] as? Double,
                              let y = dict["y"] as? Double,
                              let width = dict["width"] as? Double,
                              let height = dict["height"] as? Double
                        else { return nil }
                        return MentionRect(x: x, y: y, width: width, height: height)
                    }
                    parent.onMentionCheck(currentMarkdown, .init(query: query, rect: rect))
                } else {
                    parent.onMentionCheck(currentMarkdown, nil)
                }
            case "focusChanged":
                parent.onFocusChange((body["focused"] as? Bool) ?? false)
            case "placeTap":
                if let placeID = body["placeId"] as? String {
                    parent.onTapPlace(placeID)
                }
            case "requestImagePicker":
                DispatchQueue.main.async {
                    self.parent.imagePickerRequest = UUID()
                }
            case "copyText":
                if let text = body["text"] as? String {
                    UIPasteboard.general.string = text
                }
            default:
                break
            }
        }

        func syncIfNeeded(force: Bool = false) {
            guard isReady, let webView else { return }

            let markdownChanged = currentMarkdown != parent.markdown
            let blocksChanged = currentBlocksData != parent.blocks

            // Debounce: if we just received an edit from JS, the SwiftUI binding
            // may still be catching up (or a newer edit may be in flight).
            // Pushing setContent now risks clobbering JS state with stale data.
            let recentJSEdit: Bool = {
                guard let t = lastReceivedFromJSAt else { return false }
                return Date().timeIntervalSince(t) < 0.2
            }()

            if force || ((markdownChanged || blocksChanged) && !recentJSEdit) {
                currentMarkdown = parent.markdown
                currentBlocksData = parent.blocks
                outboundRevision += 1
                var payload: [String: Any] = [
                    "markdown": parent.markdown,
                    "places": parent.places.map(placeDict),
                    "locked": parent.isLocked,
                    "ackSeq": latestSeqFromJS,
                    "revision": outboundRevision
                ]
                if let blocks = parent.blocks,
                   let parsed = try? JSONSerialization.jsonObject(with: blocks) {
                    payload["blocks"] = parsed
                }
                lastLockedSent = parent.isLocked
                evaluate("window.editorBridge && window.editorBridge.setContent(\(json(payload)))", in: webView)
            } else if lastLockedSent != parent.isLocked {
                lastLockedSent = parent.isLocked
                evaluate("window.editorBridge && window.editorBridge.setLocked(\(parent.isLocked ? "true" : "false"))", in: webView)
            }

            if let insertCommand = parent.insertCommand, lastInsertCommandID != insertCommand.id {
                lastInsertCommandID = insertCommand.id
                let payload: [String: Any] = ["kind": commandDict(insertCommand.kind)]
                evaluate("window.editorBridge && window.editorBridge.applyCommand(\(json(payload)))", in: webView)
                DispatchQueue.main.async {
                    self.parent.insertCommand = nil
                }
            }

            if let request = parent.placeInsertionRequest, lastPlaceInsertID != request.id {
                lastPlaceInsertID = request.id
                evaluate("window.editorBridge && window.editorBridge.insertPlace(\(json(placeDict(request.place))))", in: webView)
                evaluate("window.editorBridge && window.editorBridge.focusEditor && window.editorBridge.focusEditor()", in: webView)
                DispatchQueue.main.async {
                    self.parent.placeInsertionRequest = nil
                }
            }

            if let insertion = parent.imageInsertion, lastImageInsertID != insertion.id {
                lastImageInsertID = insertion.id
                let payload: [String: Any] = ["url": insertion.url]
                evaluate("window.editorBridge && window.editorBridge.insertImage && window.editorBridge.insertImage(\(json(payload)))", in: webView)
                DispatchQueue.main.async {
                    self.parent.imageInsertion = nil
                }
            }
        }

        private func evaluate(_ script: String, in webView: WKWebView) {
            webView.evaluateJavaScript(script)
        }

        private func commandDict(_ kind: EditorCommandKind) -> [String: Any] {
            switch kind {
            case .insertText(let text):
                return ["type": "insertText", "text": text]
            case .toggleBold:
                return ["type": "toggleBold"]
            case .heading(let level):
                return ["type": "heading", "level": level]
            case .bulletList:
                return ["type": "bulletList"]
            case .orderedList:
                return ["type": "orderedList"]
            case .taskList:
                return ["type": "taskList"]
            case .divider:
                return ["type": "divider"]
            case .undo:
                return ["type": "undo"]
            case .redo:
                return ["type": "redo"]
            }
        }

        private func placeDict(_ place: Place) -> [String: Any] {
            [
                "id": place.id,
                "name": place.name,
                "address": place.address,
                "raw": "::place[\(place.name)]{#\(place.id)}",
                "category": (place.category ?? .other).rawValue,
                "emoji": (place.category ?? .other).emoji
            ]
        }

        private func json(_ object: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
                  let string = String(data: data, encoding: .utf8)
            else { return "{}" }
            return string
        }
    }
}

