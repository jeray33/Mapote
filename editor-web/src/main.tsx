import React from "react";
import { createRoot } from "react-dom/client";
// Polyfill HTML5 drag-and-drop for iOS WKWebView touch input.
// Must run before BlockNote so its dragstart handlers see the synthesized events.
import { enableDragDropTouch } from "@dragdroptouch/drag-drop-touch";
import { Editor } from "./Editor";
import "./global.css";
import { reportError } from "./bridge";

enableDragDropTouch(document, document, {
  // Require a short press before drag begins so quick taps still select text.
  isPressHoldMode: true,
  pressHoldDelayMS: 220,
  pressHoldMargin: 6,
  dragThresholdPixels: 4,
  dragImageOpacity: 0.85,
  forceListen: true,
});

window.addEventListener("error", (event) => {
  // Cross-origin scripts surface as bare "Script error." with no filename/line.
  // Those are noise from inlined libs; ignore them.
  if (!event.filename && !event.error) return;
  if (event.message && event.message !== "Script error.") {
    reportError(event.message);
  }
});
window.addEventListener("unhandledrejection", (event) => {
  const reason = event.reason;
  const msg =
    reason instanceof Error ? reason.message : reason ? String(reason) : "";
  if (msg) reportError(`Unhandled: ${msg}`);
});

const container = document.getElementById("root");
if (!container) {
  reportError("Missing #root element");
} else {
  createRoot(container).render(
    <React.StrictMode>
      <Editor />
    </React.StrictMode>
  );
}
