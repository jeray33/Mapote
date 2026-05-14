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
  /** Phase A: native handle drag → move BlockNote block by id. */
  moveBlock?: (payload: unknown) => void;
  /** Phase C: native grouped drag → reorder multiple blocks at once. */
  moveBlocks?: (payload: unknown) => void;
  /** Phase A: ask the editor to re-emit geometry (e.g. after layout change). */
  requestGeometry?: () => void;
  /** Phase C: enter Things-style multi-select mode. {blockId} pre-selects one. */
  enterSelection?: (payload: unknown) => void;
  /** Phase C: native overlay tap on selected block toggles it. */
  toggleSelection?: (payload: unknown) => void;
  /** Phase C: leave selection mode (cancel button or after a successful action). */
  exitSelection?: () => void;
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
