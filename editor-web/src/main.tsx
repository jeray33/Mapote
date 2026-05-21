import React from "react";
import { createRoot } from "react-dom/client";
import { Editor } from "./Editor";
import "./global.css";
import { reportError } from "./bridge";

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
