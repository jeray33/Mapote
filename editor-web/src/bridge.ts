import type { OutgoingMessage } from "./types";

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        editor?: { postMessage: (msg: unknown) => void };
      };
    };
    editorBridge?: EditorBridgeAPI;
  }
}

export interface EditorBridgeAPI {
  setContent: (payload: unknown) => void;
  setLocked: (locked: boolean) => void;
  applyCommand: (payload: unknown) => void;
  insertPlace: (place: unknown) => void;
  insertImage?: (payload: unknown) => void;
  focusEditor: () => void;
  placeSearchResults?: (payload: unknown) => void;
  flushContent?: (payload: unknown) => void;
}

export function postToHost(msg: OutgoingMessage): void {
  try {
    window.webkit?.messageHandlers?.editor?.postMessage(msg);
  } catch (err) {
    /* swallow */
  }
}

export function reportReady(): void {
  postToHost({ type: "ready" });
}

export function reportError(message: string): void {
  postToHost({ type: "error", message });
}
