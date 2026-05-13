import UIKit
import WebKit

// MARK: - Models

struct EditorBlockGeometry: Equatable {
    let id: String
    let top: CGFloat       // CSS pixel offset from top of document
    let height: CGFloat
    let level: Int
    let kind: String
}

// MARK: - Overlay

/// Native ⋮⋮ drag handles drawn over a WKWebView, replacing BlockNote's web side
/// menu with a UIKit experience: instant hit, haptic, smooth springs, no
/// long-press text-selection magnifier interference.
final class EditorHandleOverlay: UIView {
    weak var webView: WKWebView?
    var onMoveBlock: ((_ fromId: String, _ beforeId: String?) -> Void)?

    private struct Constants {
        static let handleWidth: CGFloat = 26
        static let handleInset: CGFloat = 4
        static let activationDelay: TimeInterval = 0.18
        static let dropLineHeight: CGFloat = 2
    }

    private var geometries: [EditorBlockGeometry] = []
    private var handles: [String: HandleView] = [:]
    private var dropIndicator: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.tintColor.withAlphaComponent(0.85)
        v.layer.cornerRadius = 1
        v.alpha = 0
        v.isUserInteractionEnabled = false
        return v
    }()
    private var ghostView: UIView?
    private var draggingHandle: HandleView?
    private var dragStartContainerY: CGFloat = 0
    private var lastDropBeforeId: String?
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let successHaptic = UINotificationFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        addSubview(dropIndicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Touches outside the handles or active ghost should pass through to the
    /// editor below.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for handle in handles.values {
            let p = convert(point, to: handle)
            if handle.bounds.contains(p) { return handle }
        }
        if let ghost = ghostView, ghost.frame.contains(point) {
            return ghost
        }
        return nil
    }

    func setGeometries(_ geometries: [EditorBlockGeometry]) {
        self.geometries = geometries
        layoutHandles()
    }

    private func layoutHandles() {
        var alive: Set<String> = []
        for geo in geometries {
            // The permanent BlockNote trailing paragraph cannot be deleted;
            // hide its handle so it doesn't clutter the gutter.
            if geo.kind == "trailing-empty" { continue }
            alive.insert(geo.id)

            let handle = handles[geo.id] ?? makeHandle(id: geo.id)
            handle.geometry = geo
            handle.frame = CGRect(
                x: Constants.handleInset,
                y: geo.top + max(0, (geo.height - 28) / 2),
                width: Constants.handleWidth,
                height: min(28, geo.height)
            )
            if handle.superview !== self { addSubview(handle) }
        }
        // Remove handles whose blocks vanished
        for (id, handle) in handles where !alive.contains(id) {
            handle.removeFromSuperview()
            handles.removeValue(forKey: id)
        }
        bringSubviewToFront(dropIndicator)
        if let ghost = ghostView { bringSubviewToFront(ghost) }
    }

    private func makeHandle(id: String) -> HandleView {
        let h = HandleView()
        h.onPan = { [weak self] handle, gesture in
            self?.handlePan(handle: handle, gesture: gesture)
        }
        handles[id] = h
        return h
    }

    // MARK: Drag flow

    private func handlePan(handle: HandleView, gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            startDrag(handle: handle)
        case .changed:
            updateDrag(translation: gesture.translation(in: self))
        case .ended:
            commitDrop()
        case .cancelled, .failed:
            cancelDrop()
        default: break
        }
    }

    private func startDrag(handle: HandleView) {
        guard let geo = handle.geometry else { return }
        draggingHandle = handle
        lastDropBeforeId = geo.id
        dragStartContainerY = geo.top
        lightHaptic.impactOccurred(intensity: 0.6)

        let ghost = UIView(frame: CGRect(x: 0, y: geo.top, width: bounds.width, height: geo.height))
        ghost.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.78)
        ghost.layer.cornerRadius = 12
        ghost.layer.shadowColor = UIColor.black.cgColor
        ghost.layer.shadowOpacity = 0.18
        ghost.layer.shadowRadius = 14
        ghost.layer.shadowOffset = CGSize(width: 0, height: 6)
        ghost.layer.borderWidth = 0.5
        ghost.layer.borderColor = UIColor.separator.cgColor
        ghost.isUserInteractionEnabled = false
        addSubview(ghost)
        ghostView = ghost

        UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.6, options: [.allowUserInteraction]) {
            handle.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
            ghost.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
        }
    }

    private func updateDrag(translation: CGPoint) {
        guard let ghost = ghostView else { return }
        let proposedY = dragStartContainerY + translation.y
        ghost.frame.origin.y = proposedY

        // Find drop target: which block boundary is the drag's vertical center closest to?
        let centerY = proposedY + ghost.frame.height / 2
        // Include empty lines as valid drop targets; only skip the permanent
        // trailing-empty paragraph (cannot be moved there meaningfully).
        let candidates = geometries.filter {
            $0.id != draggingHandle?.geometry?.id && $0.kind != "trailing-empty"
        }
        var bestBeforeId: String? = nil
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var indicatorY: CGFloat = 0

        for (idx, geo) in candidates.enumerated() {
            let above = geo.top
            let dAbove = abs(centerY - above)
            if dAbove < bestDistance {
                bestDistance = dAbove
                bestBeforeId = geo.id
                indicatorY = above
            }
            // also consider "after this one" = before next
            if idx == candidates.count - 1 {
                let below = geo.top + geo.height
                let dBelow = abs(centerY - below)
                if dBelow < bestDistance {
                    bestDistance = dBelow
                    bestBeforeId = nil // append at end
                    indicatorY = below
                }
            }
        }

        if bestBeforeId != lastDropBeforeId {
            mediumHaptic.impactOccurred(intensity: 0.4)
            lastDropBeforeId = bestBeforeId
        }
        showDropIndicator(at: indicatorY)
    }

    private func showDropIndicator(at y: CGFloat) {
        dropIndicator.frame = CGRect(
            x: Constants.handleWidth + Constants.handleInset + 8,
            y: y - Constants.dropLineHeight / 2,
            width: bounds.width - (Constants.handleWidth + Constants.handleInset + 16),
            height: Constants.dropLineHeight
        )
        if dropIndicator.alpha < 1 {
            UIView.animate(withDuration: 0.12) { self.dropIndicator.alpha = 1 }
        }
    }

    private func commitDrop() {
        guard let handle = draggingHandle, let from = handle.geometry?.id else { resetDrag(); return }
        let beforeId = lastDropBeforeId
        if beforeId != from {
            successHaptic.notificationOccurred(.success)
            onMoveBlock?(from, beforeId)
        }
        resetDrag()
    }

    private func cancelDrop() {
        resetDrag()
    }

    private func resetDrag() {
        let ghost = ghostView
        let handle = draggingHandle
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4) {
            handle?.transform = .identity
            ghost?.alpha = 0
            self.dropIndicator.alpha = 0
        } completion: { _ in
            ghost?.removeFromSuperview()
        }
        ghostView = nil
        draggingHandle = nil
        lastDropBeforeId = nil
    }
}

// MARK: - HandleView

final class HandleView: UIView {
    var geometry: EditorBlockGeometry?
    var onPan: ((HandleView, UIPanGestureRecognizer) -> Void)?

    private let dotsLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        layer.addSublayer(dotsLayer)
        dotsLayer.fillColor = UIColor.secondaryLabel.withAlphaComponent(0.55).cgColor
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.delegate = self
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        dotsLayer.frame = bounds
        let path = UIBezierPath()
        let dotSize: CGFloat = 3
        let cols: CGFloat = 2
        let rows: CGFloat = 3
        let totalW = cols * dotSize + (cols - 1) * 2
        let totalH = rows * dotSize + (rows - 1) * 2
        let originX = (bounds.width - totalW) / 2
        let originY = (bounds.height - totalH) / 2
        for r in 0..<Int(rows) {
            for c in 0..<Int(cols) {
                let rect = CGRect(
                    x: originX + CGFloat(c) * (dotSize + 2),
                    y: originY + CGFloat(r) * (dotSize + 2),
                    width: dotSize,
                    height: dotSize
                )
                path.append(UIBezierPath(ovalIn: rect))
            }
        }
        dotsLayer.path = path.cgPath
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        onPan?(self, gesture)
    }
}

extension HandleView: UIGestureRecognizerDelegate {
    /// Prevent the WKWebView's scroll pan from stealing our pan once it begins.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Don't run alongside scroll pan — give us priority.
        return false
    }
}
