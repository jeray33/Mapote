export interface PlaceData {
  id: string;
  name: string;
  address?: string;
  raw?: string;
  category?: string;
  emoji?: string;
  lat?: number;
  lng?: number;
  placeId?: string;
  photoUrl?: string;
  photoUrls?: string[];
  types?: string[];
  rating?: number;
  openingHours?: string[];
  editorialSummary?: string;
  openNow?: boolean;
}

export interface SetContentPayload {
  markdown: string;
  blocks?: unknown[] | null;
  places: PlaceData[];
  locked: boolean;
  timing?: {
    contentDebounceMs?: number;
  };
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
    | "requestImagePicker"
    | "requestPlaceSearch"
    | "placeCandidateSelected"
    | "contentFlushed"
    | "toolbarState"
    | "modeChanged"
    | "log";
  [key: string]: unknown;
}

export interface ImageInsertPayload {
  id?: string;
  url: string;
  caption?: string;
}

export interface CommandPayload {
  id?: string;
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
