import SwiftUI
import WebKit

struct CobeMarker: Equatable {
    var id: String
    var lat: Double
    var lng: Double
    var country: String
    var image: String?
    var caption: String
    var rotate: Double
}

struct CobeGlobeView: UIViewRepresentable {
    var markers: [CobeMarker]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "cobeReady")
        config.userContentController = controller

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.isUserInteractionEnabled = true

        context.coordinator.attach(webView: webView)
        webView.loadHTMLString(Self.html, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.setMarkers(markers)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "cobeReady")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private weak var webView: WKWebView?
        private var ready = false
        private var pendingMarkers: [CobeMarker] = []

        func attach(webView: WKWebView) {
            self.webView = webView
        }

        func setMarkers(_ markers: [CobeMarker]) {
            pendingMarkers = markers
            applyMarkersIfNeeded()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "cobeReady" else { return }
            ready = true
            applyMarkersIfNeeded()
        }

        private func applyMarkersIfNeeded() {
            guard ready, let webView else { return }
            let payload = pendingMarkers.map { marker in
                [
                    "id": marker.id,
                    "lat": marker.lat,
                    "lng": marker.lng,
                    "country": marker.country,
                    "image": marker.image ?? "",
                    "caption": marker.caption,
                    "rotate": marker.rotate,
                ]
            }
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.setCobeMarkers(\(json));")
        }
    }
}

private extension CobeGlobeView {
    static let html = """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no" />
  <style>
    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: visible;
      background: transparent;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
    }
    #wrap {
      position: relative;
      width: 100%;
      height: 100%;
      overflow: visible;
      --globe-scale: 90%;
      --polaroid-headroom: 56px;
      --polaroid-side-room: 12px;
      --polaroid-bottom-room: 8px;
    }
    #globe-area {
      position: absolute;
      left: 50%;
      transform: translateX(-50%);
      width: var(--globe-scale);
      max-width: 100%;
      bottom: 0;
      aspect-ratio: 1 / 1;
    }
    #globe {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      display: block;
      cursor: grab;
      touch-action: none;
      opacity: 0;
      transition: opacity 0.8s ease;
      border-radius: 50%;
    }
    #polaroids {
      position: absolute;
      inset:
        calc(-1 * var(--polaroid-headroom))
        calc(-1 * var(--polaroid-side-room))
        calc(-1 * var(--polaroid-bottom-room))
        calc(-1 * var(--polaroid-side-room));
      overflow: visible;
      pointer-events: none;
      z-index: 2;
    }
    .showcase-polaroid {
      position: absolute;
      left: anchor(center);
      bottom: anchor(top);
      margin-bottom: 8px;
      background: #fff;
      padding: 6px 6px 24px;
      box-shadow:
        0 2px 8px rgba(0, 0, 0, 0.15),
        0 1px 2px rgba(0, 0, 0, 0.1);
      transform: translate(calc(-50% + var(--polaroid-offset-x, 0px)), var(--polaroid-offset-y, 0px)) rotate(var(--polaroid-rotate, 0deg));
      transform-origin: bottom center;
      transition: opacity 0.3s, filter 0.3s;
      pointer-events: none;
      user-select: none;
      will-change: transform, opacity, filter;
    }
    .showcase-polaroid img {
      display: block;
      width: 60px;
      height: 60px;
      object-fit: cover;
      background: #f3f4f6;
    }
    .showcase-polaroid-caption {
      position: absolute;
      bottom: 5px;
      left: 0;
      right: 0;
      text-align: center;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
      font-size: 0.5rem;
      color: #333;
      letter-spacing: 0.02em;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      padding: 0 4px;
    }
    @media (max-width: 460px) {
      .showcase-polaroid {
        padding: 4px 4px 18px;
      }
      .showcase-polaroid img {
        width: 45px;
        height: 45px;
      }
      .showcase-polaroid-caption {
        font-size: 0.4rem;
        bottom: 4px;
      }
    }
  </style>
</head>
<body>
  <div id="wrap">
    <div id="globe-area">
      <canvas id="globe"></canvas>
      <div id="polaroids"></div>
    </div>
  </div>
  <script type="module">
    import createGlobe from "https://cdn.skypack.dev/cobe";

    const canvas = document.getElementById("globe");
    const polaroidsLayer = document.getElementById("polaroids");
    const MAX_DPR = 2;
    const BASE_THETA = 0.2;
    const GLOBE_RADIUS = 0.8;
    const MARKER_ELEVATION = 0.01;
    const ROTATION_SPEED = 0.003;
    const THETA_MIN = -0.4;
    const THETA_MAX = 0.4;
    const supportsAnchorPositioning =
      Boolean(window.CSS?.supports?.("position-anchor: --cobe-test")) &&
      Boolean(window.CSS?.supports?.("anchor-name: --cobe-test"));
    const isLikelyIOSWebKit =
      /AppleWebKit/i.test(navigator.userAgent) &&
      /Mobile|iPhone|iPad|iPod/i.test(navigator.userAgent);
    const useAnchorPositioning = supportsAnchorPositioning && !isLikelyIOSWebKit;

    let globe = null;
    let markers = [];
    let markerCache = [];
    let animationId = 0;
    let phi = 0;
    let phiOffset = 0;
    let thetaOffset = 0;
    let dragOffset = { phi: 0, theta: 0 };
    let velocity = { phi: 0, theta: 0 };
    let pointerInteracting = null;
    let lastPointer = null;
    let isPaused = false;
    let currentPhi = 0;
    let currentTheta = BASE_THETA;
    let activeMarkers = [];
    let lastTurnBucket = Number.NaN;
    const TWO_PI = Math.PI * 2;
    const MAX_MARKERS_PER_COUNTRY = 3;
    const PROXIMITY_BUCKET_DEGREES = 0.35;
    const polaroidOffsets = new Map();
    const cardNodes = new Map();

    const toNumber = (value) => {
      const parsed = Number(value);
      return Number.isFinite(parsed) ? parsed : null;
    };

    const normalizeMarkers = (incoming) => {
      if (!Array.isArray(incoming)) return [];
      const normalized = [];
      const seen = new Set();
      for (const item of incoming) {
        const lat = toNumber(item?.lat);
        const lng = toNumber(item?.lng);
        if (lat == null || lng == null) continue;
        const id = String(item?.id || `${lat.toFixed(4)}:${lng.toFixed(4)}`);
        if (seen.has(id)) continue;
        seen.add(id);
        const country = String(item?.country || "unknown").trim() || "unknown";
        normalized.push({
          id,
          lat,
          lng,
          country,
          image: String(item?.image || ""),
          caption: String(item?.caption || "地点"),
          rotate: Number.isFinite(Number(item?.rotate)) ? Number(item.rotate) : 0,
        });
      }
      return normalized;
    };

    const placeholderImage = (() => {
      const svg = `
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="120">
          <rect width="120" height="120" fill="#eef2f7"/>
          <text x="60" y="66" text-anchor="middle" font-size="30" fill="#5f6b7b">📍</text>
        </svg>
      `;
      return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;
    })();

    const currentDpr = () => Math.min(window.devicePixelRatio || 1, MAX_DPR);

    const rebuildMarkerCache = () => {
      markerCache.length = 0;
      markerCache.push(
        ...activeMarkers.map((item) => ({
          id: item.id,
          location: [item.lat, item.lng],
          size: 0.03,
        }))
      );
    };

    const normalizedCountryKey = (marker) => {
      const raw = String(marker?.country || "").trim();
      return raw.length === 0 ? "unknown" : raw;
    };

    const turnBucketForPhi = (value) => {
      if (!Number.isFinite(value)) return 0;
      return Math.floor(value / TWO_PI);
    };

    const buildActiveMarkersForTurn = (turnBucket) => {
      const groups = new Map();
      for (const marker of markers) {
        const countryKey = normalizedCountryKey(marker);
        if (!groups.has(countryKey)) {
          groups.set(countryKey, []);
        }
        groups.get(countryKey).push(marker);
      }

      const selected = [];
      for (const group of groups.values()) {
        if (group.length <= MAX_MARKERS_PER_COUNTRY) {
          selected.push(...group);
          continue;
        }
        const step = MAX_MARKERS_PER_COUNTRY;
        const start = ((turnBucket * step) % group.length + group.length) % group.length;
        for (let i = 0; i < MAX_MARKERS_PER_COUNTRY; i += 1) {
          selected.push(group[(start + i) % group.length]);
        }
      }
      return selected;
    };

    const proximityBucketKey = (marker) => {
      const latBucket = Math.round(marker.lat / PROXIMITY_BUCKET_DEGREES);
      const lngBucket = Math.round(marker.lng / PROXIMITY_BUCKET_DEGREES);
      return `${latBucket}:${lngBucket}`;
    };

    const rebuildPolaroidOffsets = () => {
      polaroidOffsets.clear();
      const groups = new Map();
      for (const marker of activeMarkers) {
        const key = proximityBucketKey(marker);
        if (!groups.has(key)) {
          groups.set(key, []);
        }
        groups.get(key).push(marker);
      }
      const pattern = [
        { x: 0, y: 0 },
        { x: 20, y: 4 },
        { x: -20, y: 4 },
        { x: 30, y: 10 },
        { x: -30, y: 10 },
      ];
      for (const group of groups.values()) {
        group.forEach((marker, index) => {
          const offset = pattern[index % pattern.length];
          polaroidOffsets.set(marker.id, offset);
        });
      }
    };

    const refreshActiveMarkers = (turnBucket, force = false) => {
      if (!force && turnBucket === lastTurnBucket) return false;
      lastTurnBucket = turnBucket;
      activeMarkers = buildActiveMarkersForTurn(turnBucket);
      rebuildPolaroidOffsets();
      rebuildMarkerCache();
      ensureCards();
      applyFallbackCardPositions();
      return true;
    };

    const latLngToXYZ = (lat, lng) => {
      const latRad = (lat * Math.PI) / 180;
      const lngRad = (lng * Math.PI) / 180 - Math.PI;
      const cosLat = Math.cos(latRad);
      return [
        -cosLat * Math.cos(lngRad),
        Math.sin(latRad),
        cosLat * Math.sin(lngRad),
      ];
    };

    const projectPoint = (point) => {
      const canvasRect = canvas.getBoundingClientRect();
      const width = canvasRect.width || 1;
      const height = canvasRect.height || 1;
      const aspect = width / height;
      const cosTheta = Math.cos(currentTheta);
      const sinTheta = Math.sin(currentTheta);
      const cosPhi = Math.cos(currentPhi);
      const sinPhi = Math.sin(currentPhi);
      const c = cosPhi * point[0] + sinPhi * point[2];
      const s = sinPhi * sinTheta * point[0] + cosTheta * point[1] - cosPhi * sinTheta * point[2];
      return {
        x: (c / aspect + 1) / 2,
        y: (-s + 1) / 2,
        visible: (-sinPhi * cosTheta * point[0] + sinTheta * point[1] + cosPhi * cosTheta * point[2] >= 0) || (c * c + s * s >= 0.64),
      };
    };

    const projectMarker = (marker) => {
      const base = latLngToXYZ(marker.lat, marker.lng);
      const radius = GLOBE_RADIUS + MARKER_ELEVATION;
      return projectPoint([base[0] * radius, base[1] * radius, base[2] * radius]);
    };

    const applyCardStyle = (card, marker) => {
      card.style.setProperty("--polaroid-rotate", `${marker.rotate}deg`);
      const offset = polaroidOffsets.get(marker.id) || { x: 0, y: 0 };
      card.style.setProperty("--polaroid-offset-x", `${offset.x}px`);
      card.style.setProperty("--polaroid-offset-y", `${offset.y}px`);
      if (useAnchorPositioning) {
        card.style.setProperty("position-anchor", `--cobe-${marker.id}`);
        card.style.left = "anchor(center)";
        card.style.bottom = "anchor(top)";
        card.style.top = "auto";
        card.style.opacity = `var(--cobe-visible-${marker.id}, 0)`;
        card.style.filter = `blur(calc((1 - var(--cobe-visible-${marker.id}, 0)) * 8px))`;
        card.style.transform = `translate(calc(-50% + var(--polaroid-offset-x, 0px)), var(--polaroid-offset-y, 0px)) rotate(var(--polaroid-rotate))`;
      } else {
        card.style.removeProperty("position-anchor");
        card.style.left = "0px";
        card.style.top = "0px";
        card.style.bottom = "auto";
        card.style.opacity = "0";
        card.style.filter = "blur(8px)";
        card.style.transform = `translate(calc(-50% + var(--polaroid-offset-x, 0px)), calc(-100% - 8px + var(--polaroid-offset-y, 0px))) rotate(var(--polaroid-rotate))`;
      }
    };

    const applyFallbackCardPositions = () => {
      if (useAnchorPositioning) return;
      const canvasRect = canvas.getBoundingClientRect();
      const layerRect = polaroidsLayer.getBoundingClientRect();
      const width = canvasRect.width;
      const height = canvasRect.height;
      if (!width || !height) return;
      for (const marker of activeMarkers) {
        const card = cardNodes.get(marker.id);
        if (!card) continue;
        const projection = projectMarker(marker);
        const left = projection.x * width + (canvasRect.left - layerRect.left);
        const top = projection.y * height + (canvasRect.top - layerRect.top);
        card.style.left = `${left}px`;
        card.style.top = `${top}px`;
        card.style.opacity = projection.visible ? "1" : "0";
        card.style.filter = projection.visible ? "none" : "blur(8px)";
      }
    };

    const ensureCards = () => {
      const activeIDs = new Set(activeMarkers.map((m) => m.id));
      for (const [id, node] of cardNodes.entries()) {
        if (!activeIDs.has(id)) {
          node.remove();
          cardNodes.delete(id);
        }
      }
      for (const marker of activeMarkers) {
        if (cardNodes.has(marker.id)) {
          const existing = cardNodes.get(marker.id);
          applyCardStyle(existing, marker);
          continue;
        }

        const card = document.createElement("div");
        card.className = "showcase-polaroid";
        applyCardStyle(card, marker);

        const image = document.createElement("img");
        image.src = marker.image || placeholderImage;
        image.alt = marker.caption;
        image.loading = "lazy";
        image.referrerPolicy = "no-referrer";
        image.onerror = () => {
          image.src = placeholderImage;
        };

        const caption = document.createElement("span");
        caption.className = "showcase-polaroid-caption";
        caption.textContent = marker.caption;

        card.appendChild(image);
        card.appendChild(caption);
        polaroidsLayer.appendChild(card);
        cardNodes.set(marker.id, card);
      }
      applyFallbackCardPositions();
    };

    const rebuildGlobe = () => {
      const rect = canvas.getBoundingClientRect();
      const width = Math.max(1, Math.floor(rect.width));
      const height = Math.max(1, Math.floor(rect.height));
      const dpr = currentDpr();
      if (globe) globe.destroy();
      globe = createGlobe(canvas, {
        devicePixelRatio: dpr,
        width,
        height,
        phi: currentPhi,
        theta: currentTheta,
        dark: 0,
        diffuse: 1.5,
        mapSamples: 16000,
        mapBrightness: 10,
        baseColor: [1, 1, 1],
        markerColor: [0.3, 0.45, 0.85],
        glowColor: [0.94, 0.93, 0.91],
        markerElevation: MARKER_ELEVATION,
        markers: markerCache,
        opacity: 0.7,
      });
      canvas.style.opacity = "1";
    };

    const clamp = (value, min, max) => Math.max(min, Math.min(max, value));

    const handlePointerDown = (event) => {
      pointerInteracting = { x: event.clientX, y: event.clientY };
      lastPointer = { x: event.clientX, y: event.clientY, t: Date.now() };
      isPaused = true;
      canvas.style.cursor = "grabbing";
    };

    const handlePointerMove = (event) => {
      if (!pointerInteracting) return;
      const deltaX = event.clientX - pointerInteracting.x;
      const deltaY = event.clientY - pointerInteracting.y;
      dragOffset = { phi: deltaX / 300, theta: deltaY / 1000 };

      const now = Date.now();
      if (lastPointer) {
        const dt = Math.max(now - lastPointer.t, 1);
        const maxVelocity = 0.15;
        velocity = {
          phi: clamp(((event.clientX - lastPointer.x) / dt) * 0.3, -maxVelocity, maxVelocity),
          theta: clamp(((event.clientY - lastPointer.y) / dt) * 0.08, -maxVelocity, maxVelocity),
        };
      }
      lastPointer = { x: event.clientX, y: event.clientY, t: now };
    };

    const handlePointerUp = () => {
      if (pointerInteracting) {
        phiOffset += dragOffset.phi;
        thetaOffset += dragOffset.theta;
        dragOffset = { phi: 0, theta: 0 };
        lastPointer = null;
      }
      pointerInteracting = null;
      isPaused = false;
      canvas.style.cursor = "grab";
    };

    const animate = () => {
      if (!globe) return;
      if (!isPaused) {
        phi += ROTATION_SPEED;
        if (Math.abs(velocity.phi) > 0.0001 || Math.abs(velocity.theta) > 0.0001) {
          phiOffset += velocity.phi;
          thetaOffset += velocity.theta;
          velocity.phi *= 0.95;
          velocity.theta *= 0.95;
        }
        if (thetaOffset < THETA_MIN) {
          thetaOffset += (THETA_MIN - thetaOffset) * 0.1;
        } else if (thetaOffset > THETA_MAX) {
          thetaOffset += (THETA_MAX - thetaOffset) * 0.1;
        }
      }

      currentPhi = phi + phiOffset + dragOffset.phi;
      currentTheta = BASE_THETA + thetaOffset + dragOffset.theta;
      const turnBucket = turnBucketForPhi(currentPhi);
      refreshActiveMarkers(turnBucket);
      globe.update({
        phi: currentPhi,
        theta: currentTheta,
        markers: markerCache,
      });
      applyFallbackCardPositions();
      animationId = requestAnimationFrame(animate);
    };

    window.setCobeMarkers = (incoming) => {
      markers = normalizeMarkers(incoming);
      const turnBucket = turnBucketForPhi(currentPhi);
      refreshActiveMarkers(turnBucket, true);
      if (globe) {
        globe.update({ markers: markerCache });
      }
      applyFallbackCardPositions();
    };

    const handleResize = () => {
      rebuildGlobe();
      const turnBucket = turnBucketForPhi(currentPhi);
      refreshActiveMarkers(turnBucket, true);
      if (globe) {
        globe.update({ phi: currentPhi, theta: currentTheta, markers: markerCache });
      }
      applyFallbackCardPositions();
    };

    let resizeScheduled = false;
    const scheduleResize = () => {
      if (resizeScheduled) return;
      resizeScheduled = true;
      requestAnimationFrame(() => {
        resizeScheduled = false;
        handleResize();
      });
    };

    window.addEventListener("resize", scheduleResize);
    const resizeObserver = new ResizeObserver(scheduleResize);
    resizeObserver.observe(document.getElementById("wrap"));
    canvas.addEventListener("pointerdown", handlePointerDown, { passive: true });
    window.addEventListener("pointermove", handlePointerMove, { passive: true });
    window.addEventListener("pointerup", handlePointerUp, { passive: true });
    window.addEventListener("pointercancel", handlePointerUp, { passive: true });
    canvas.style.cursor = "grab";

    rebuildGlobe();
    refreshActiveMarkers(turnBucketForPhi(currentPhi), true);
    if (globe) {
      globe.update({ phi: currentPhi, theta: currentTheta, markers: markerCache });
    }
    if (animationId) cancelAnimationFrame(animationId);
    animationId = requestAnimationFrame(animate);
    window.webkit?.messageHandlers?.cobeReady?.postMessage("ready");
  </script>
</body>
</html>
"""
}