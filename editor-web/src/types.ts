export interface PlaceData {
  id: string;
  name: string;
  address?: string;
  raw?: string;
  category?: string;
  emoji?: string;
}

export interface SetContentPayload {
  markdown: string;
  blocks?: unknown[] | null;
  places: PlaceData[];
  locked: boolean;
  ackSeq?: number;
  revision?: number;
}

export interface MentionInfo {
  query: string;
  rect: { x: number; y: number; width: number; height: number } | null;
}

export interface OutgoingMessage {
  type:
    | "ready"
    | "error"
    | "contentChanged"
    | "focusChanged"
    | "placeTap"
    | "blocksGeometry"
    | "requestImagePicker"
    | "selectionChanged"
    | "copyText"
    | "log";
  seq?: number;
  [key: string]: unknown;
  ackRevision?: number;
}

export interface BlockGeometry {
  /** Stable BlockNote block id. */
  id: string;
  /** Top in document (scrollY-included) coordinates, in CSS pixels. */
  top: number;
  /** Height in CSS pixels. */
  height: number;
  /** Heading level if this block is a heading, otherwise 0. */
  level: number;
  /** "paragraph" / "heading" / "bulletListItem" / "placeRef-only" / etc. */
  kind: string;
}

export interface MoveBlockPayload {
  fromId: string;
  /** Drop the moved block immediately before this id. Null = append at end. */
  beforeId: string | null;
}

export interface ImageInsertPayload {
  url: string;
  caption?: string;
}

export interface CommandPayload {
  kind: {
    type:
      | "insertText"
      | "toggleBold"
      | "heading"
      | "bulletList"
      | "orderedList"
      | "taskList"
      | "divider"
      | "undo"
      | "redo";
    text?: string;
    level?: 1 | 2 | 3;
  };
}

export const CATEGORY_EMOJI: Record<string, string> = {
  food: "🍽️",
  lodging: "🏨",
  attraction: "🏛️",
  shopping: "🛍️",
  transit: "🚉",
  nature: "🌲",
  services: "🏢",
  other: "📍",
};

export const CATEGORY_COLORS: Record<string, { bg: string; fg: string }> = {
  food: { bg: "rgba(239, 68, 68, 0.16)", fg: "#dc2626" },
  lodging: { bg: "rgba(139, 92, 246, 0.16)", fg: "#7c3aed" },
  attraction: { bg: "rgba(245, 158, 11, 0.16)", fg: "#d97706" },
  shopping: { bg: "rgba(236, 72, 153, 0.16)", fg: "#db2777" },
  transit: { bg: "rgba(99, 102, 241, 0.16)", fg: "#4f46e5" },
  nature: { bg: "rgba(34, 197, 94, 0.16)", fg: "#16a34a" },
  services: { bg: "rgba(100, 116, 139, 0.16)", fg: "#475569" },
  other: { bg: "rgba(37, 99, 235, 0.16)", fg: "#1d4ed8" },
};
