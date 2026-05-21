import { useCallback, useEffect, useRef, useState, type MutableRefObject } from "react";
import { Node as TiptapNode, mergeAttributes } from "@tiptap/core";
import Image from "@tiptap/extension-image";
import Placeholder from "@tiptap/extension-placeholder";
import TaskItem from "@tiptap/extension-task-item";
import TaskList from "@tiptap/extension-task-list";
import { EditorContent, useEditor, type Editor as TiptapEditor } from "@tiptap/react";
import { TextSelection } from "@tiptap/pm/state";
import StarterKit from "@tiptap/starter-kit";
import type {
  CommandPayload,
  ImageInsertPayload,
  MentionInfo,
  PlaceData,
  SetContentPayload,
} from "./types";
import { CATEGORY_EMOJI } from "./types";
import { postToHost, reportError, reportReady } from "./bridge";
import { normalizeIncomingBlocks, tiptapBlocksToMarkdown } from "./markdown";

type JsonNode = Record<string, any>;
type QueuedCommand = { id?: string; kind: CommandPayload["kind"] };

type EditorMode =
  | { type: "display" }
  | { type: "editing"; blockId: string }
  | { type: "multiSelect"; anchorId: string; selectedIds: string[] }
  | { type: "dragging"; fromMode: "display" | "editing" | "multiSelect"; blockIds: string[] };

interface PointerStart {
  x: number;
  y: number;
  blockId: string | null;
  pointerId: number;
}

interface DragState {
  blockIds: string[];
  beforeId: string | null;
}

const LONG_PRESS_MS = 360;
const POINTER_CANCEL_THRESHOLD = 18;
const AUTO_SCROLL_EDGE_PX = 72;
const AUTO_SCROLL_STEP_PX = 14;

// Stability-first pause: block drag and contiguous multi-select are disabled
// because long-press / horizontal-swipe gestures conflict with WKWebView text
// editing, iOS selection, vertical scrolling, and SwiftUI sheet detents. Keep
// the mode/types/helpers in place so the feature can return later behind an
// explicit handle or organize mode rather than whole-block gestures.
const ENABLE_BLOCK_DRAG = false;
const ENABLE_CONTIGUOUS_MULTI_SELECT = false;

interface MentionMenuState {
  requestId: string;
  query: string;
  rect: MentionInfo["rect"];
  results: PlaceData[];
}

const PlaceRef = TiptapNode.create({
  name: "placeRef",
  group: "inline",
  inline: true,
  atom: true,
  selectable: false,
  addAttributes() {
    return {
      placeId: { default: "" },
      name: { default: "地点" },
      category: { default: "other" },
      emoji: { default: "📍" },
    };
  },
  parseHTML() {
    return [{ tag: "span[data-place-ref]" }];
  },
  renderHTML({ HTMLAttributes }) {
    return [
      "span",
      mergeAttributes(HTMLAttributes, {
        "data-place-ref": "true",
        "data-place-id": HTMLAttributes.placeId,
        class: "place-chip",
        contenteditable: "false",
      }),
      `${HTMLAttributes.emoji ?? "📍"} ${HTMLAttributes.name ?? "地点"}`,
    ];
  },
});

const Divider = TiptapNode.create({
  name: "divider",
  group: "block",
  atom: true,
  selectable: true,
  parseHTML() {
    return [{ tag: "hr[data-mapote-divider]" }];
  },
  renderHTML({ HTMLAttributes }) {
    return ["hr", mergeAttributes(HTMLAttributes, { "data-mapote-divider": "true", class: "mapote-divider" })];
  },
});

interface PendingState {
  markdown: string;
  blocks?: unknown[] | null;
  places: PlaceData[];
  locked: boolean;
}

export function Editor() {
  const [locked, setLocked] = useState(false);
  const [mode, setMode] = useState<EditorMode>({ type: "display" });
  const [dragState, setDragState] = useState<DragState | null>(null);
  const [mentionMenu, setMentionMenu] = useState<MentionMenuState | null>(null);
  const modeRef = useRef<EditorMode>({ type: "display" });
  const editorRef = useRef<TiptapEditor | null>(null);
  const pointerStartRef = useRef<PointerStart | null>(null);
  const longPressTimerRef = useRef<number | null>(null);
  const dragStateRef = useRef<DragState | null>(null);
  const suppressClickUntilRef = useRef<number>(0);
  const placesRef = useRef<PlaceData[]>([]);
  const mentionRequestSeqRef = useRef<number>(0);
  const mentionSearchTimerRef = useRef<number | null>(null);
  const mentionMenuRef = useRef<MentionMenuState | null>(null);
  const commandQueueRef = useRef<QueuedCommand[]>([]);
  const commandDrainingRef = useRef(false);
  const composingRef = useRef(false);
  const appliedCommandIdsRef = useRef<Set<string>>(new Set());
  const appliedInsertionIdsRef = useRef<Set<string>>(new Set());
  const lastEmittedMarkdown = useRef<string>("");
  const lastEmittedBlocksJson = useRef<string>("");
  const lastMentionKey = useRef<string>("");
  const seqRef = useRef<number>(0);
  const contentRevisionRef = useRef<number>(0);
  const settingContentRef = useRef(false);
  const contentEmitTimerRef = useRef<number | null>(null);
  const contentDebounceMsRef = useRef<number>(90);

  const emit = useCallback((msg: Record<string, unknown>) => {
    seqRef.current += 1;
    postToHost({ ...msg, seq: seqRef.current } as any);
  }, []);

  const emitContentChanged = useCallback(
    (markdown: string, blocks: JsonNode[]) => {
      contentRevisionRef.current += 1;
      emit({
        type: "contentChanged",
        revision: contentRevisionRef.current,
        markdown,
        blocks,
        mention: null,
      });
    },
    [emit]
  );

  const setEditorMode = useCallback(
    (next: EditorMode) => {
      modeRef.current = next;
      setMode(next);
      emit({
        type: "modeChanged",
        mode: next.type,
        selectedCount: next.type === "multiSelect" ? next.selectedIds.length : 0,
      });
    },
    [emit]
  );

  const setCurrentDragState = useCallback((next: DragState | null) => {
    dragStateRef.current = next;
    setDragState(next);
  }, []);

  const setCurrentMentionMenu = useCallback((next: MentionMenuState | null) => {
    mentionMenuRef.current = next;
    setMentionMenu(next);
  }, []);

  const drainQueuedCommands = useCallback(() => {
    drainCommandQueue(editorRef.current, commandQueueRef, commandDrainingRef, composingRef, emit);
  }, [emit]);

  const editor = useEditor({
    extensions: [
      StarterKit.configure({ horizontalRule: false }),
      Placeholder.configure({ placeholder: "开始写旅行笔记…" }),
      Image.configure({ inline: false, allowBase64: true }),
      TaskList,
      TaskItem.configure({ nested: false }),
      PlaceRef,
      Divider,
    ] as any,
    content: { type: "doc", content: [{ type: "paragraph" }] },
    editable: false,
    editorProps: {
      attributes: {
        class: "mapote-tiptap-editor",
        autocapitalize: "off",
        autocomplete: "off",
        autocorrect: "on",
      },
      handleDOMEvents: {
        compositionstart() {
          composingRef.current = true;
          return false;
        },
        compositionend() {
          composingRef.current = false;
          window.setTimeout(drainQueuedCommands, 0);
          return false;
        },
      },
      handleClick(view, _pos, event) {
        const target = event.target as HTMLElement | null;
        const chip = target?.closest?.("[data-place-ref]") as HTMLElement | null;
        const placeId = chip?.dataset.placeId;
        if (placeId) {
          postToHost({ type: "placeTap", placeId });
          return true;
        }
        if (Date.now() < suppressClickUntilRef.current) {
          event.preventDefault();
          return true;
        }
        const currentMode = modeRef.current;
        const blockId = blockIDFromEventTarget(view.dom, target);
        if (currentMode.type === "multiSelect") {
          if (blockId) {
            setEditorMode(selectContinuousRange(view.dom, currentMode.anchorId, blockId));
          } else {
            enterDisplay(editorRef.current, setEditorMode);
          }
          event.preventDefault();
          return true;
        }
        if (currentMode.type === "display") {
          enterEditingAtEvent(editorRef.current, event, blockId, setEditorMode);
          event.preventDefault();
          return true;
        }
        return false;
      },
    },
    onUpdate({ editor }) {
      if (settingContentRef.current) return;
      updateMentionMenu(editor, emit, placesRef, mentionRequestSeqRef, mentionSearchTimerRef, mentionMenuRef, setCurrentMentionMenu);
      emitToolbarState(editor, emit, composingRef.current);
      scheduleContentEmit(editor, emitContentChanged, contentEmitTimerRef, contentDebounceMsRef, lastEmittedMarkdown, lastEmittedBlocksJson, lastMentionKey);
    },
    onSelectionUpdate({ editor }) {
      if (settingContentRef.current) return;
      if (modeRef.current.type !== "editing") return;
      updateMentionMenu(editor, emit, placesRef, mentionRequestSeqRef, mentionSearchTimerRef, mentionMenuRef, setCurrentMentionMenu);
      emitToolbarState(editor, emit, composingRef.current);
    },
    onFocus() {
      emit({ type: "focusChanged", focused: true });
    },
    onBlur({ editor }) {
      if (!settingContentRef.current) {
        emitContentNow(editor, emitContentChanged, contentEmitTimerRef, lastEmittedMarkdown, lastEmittedBlocksJson, lastMentionKey);
      }
      emit({ type: "focusChanged", focused: false });
    },
  });

  useEffect(() => {
    if (!editor) return;
    editorRef.current = editor;
    editor.setEditable(!locked && mode.type === "editing");
    syncBlockDom(editor, mode, dragState);
    return () => {
      if (editorRef.current === editor) editorRef.current = null;
    };
  }, [editor, locked, mode, dragState]);

  const applyPending = useCallback(
    (state: PendingState) => {
      if (!editor) return;
      settingContentRef.current = true;
      try {
        placesRef.current = state.places;
        setCurrentMentionMenu(null);
        const blocks = normalizeIncomingBlocks(state.blocks, state.markdown, state.places);
        replaceDocumentWithoutHistory(editor, blocks.length ? blocks : [{ type: "paragraph" }]);
        setLocked(state.locked);
        setEditorMode({ type: "display" });
        editor.setEditable(false);

        const docBlocks = getTopLevelBlocks(editor);
        const markdown = tiptapBlocksToMarkdown(docBlocks);
        const docBlocksJson = JSON.stringify(docBlocks);
        lastEmittedMarkdown.current = markdown;
        lastEmittedBlocksJson.current = docBlocksJson;
        emitToolbarState(editor, emit, false);

        // Legacy markdown / pre-Tiptap payloads are normalized into Tiptap JSON.
        // Emit once so Swift persists the new canonical block format.
        if (!Array.isArray(state.blocks) || JSON.stringify(state.blocks) !== docBlocksJson || state.markdown !== markdown) {
          emitContentChanged(markdown, docBlocks);
        }
      } catch (err) {
        reportError(`setContent failed: ${(err as Error).message}`);
      } finally {
        window.setTimeout(() => {
          settingContentRef.current = false;
        }, 30);
      }
    },
    [editor, emitContentChanged, setEditorMode, setCurrentMentionMenu]
  );

  useEffect(() => {
    if (!editor) return;
    window.editorBridge = {
      setContent: (raw) => {
        const payload = raw as SetContentPayload;
        const maybeDebounce = Number(payload?.timing?.contentDebounceMs);
        contentDebounceMsRef.current = Number.isFinite(maybeDebounce) && maybeDebounce >= 30 ? Math.round(maybeDebounce) : 90;
        applyPending({
          markdown: payload?.markdown ?? "",
          blocks: payload?.blocks ?? null,
          places: payload?.places ?? [],
          locked: !!payload?.locked,
        });
      },
      setLocked: (l) => {
        const nextLocked = !!l;
        setLocked(nextLocked);
        if (nextLocked) setEditorMode({ type: "display" });
      },
      applyCommand: (raw) => {
        try {
          const payload = raw as CommandPayload;
          const { id, kind } = payload;
          if (id && appliedCommandIdsRef.current.has(id)) return;
          if (id) appliedCommandIdsRef.current.add(id);
          if (modeRef.current.type !== "editing" && kind.type !== "undo" && kind.type !== "redo") {
            enterEditingAtCurrentSelection(editor, setEditorMode);
          }
          enqueueCommand({ id, kind }, commandQueueRef, drainQueuedCommands);
        } catch (err) {
          reportError(`applyCommand failed: ${(err as Error).message}`);
        }
      },
      insertPlace: (raw) => {
        try {
          const place = raw as PlaceData & { requestId?: string };
          if (place.requestId && appliedInsertionIdsRef.current.has(place.requestId)) return;
          if (place.requestId) appliedInsertionIdsRef.current.add(place.requestId);
          insertPlace(editor, place);
        } catch (err) {
          reportError(`insertPlace failed: ${(err as Error).message}`);
        }
      },
      insertImage: (raw) => {
        try {
          const payload = raw as ImageInsertPayload;
          if (payload.id && appliedInsertionIdsRef.current.has(payload.id)) return;
          if (payload.id) appliedInsertionIdsRef.current.add(payload.id);
          insertImage(editor, payload);
        } catch (err) {
          reportError(`insertImage failed: ${(err as Error).message}`);
        }
      },
      flushContent: (raw) => {
        const payload = raw as { requestId?: string } | undefined;
        emitContentNow(editor, emitContentChanged, contentEmitTimerRef, lastEmittedMarkdown, lastEmittedBlocksJson, lastMentionKey);
        emit({ type: "contentFlushed", requestId: payload?.requestId ?? "" });
      },
      focusEditor: () => enterEditingAtCurrentSelection(editor, setEditorMode),
      placeSearchResults: (raw) => {
        const payload = raw as { requestId?: string; results?: PlaceData[] };
        const current = mentionMenuRef.current;
        if (!payload?.requestId || !current || current.requestId !== payload.requestId) return;
        setCurrentMentionMenu({ ...current, results: payload.results ?? [] });
      },
    };
    reportReady();
    return () => {
      delete window.editorBridge;
    };
  }, [editor, applyPending, emit, emitContentChanged]);

  useEffect(() => {
    return () => {
      if (contentEmitTimerRef.current != null) {
        window.clearTimeout(contentEmitTimerRef.current);
        contentEmitTimerRef.current = null;
      }
      if (longPressTimerRef.current != null) {
        window.clearTimeout(longPressTimerRef.current);
        longPressTimerRef.current = null;
      }
      if (mentionSearchTimerRef.current != null) {
        window.clearTimeout(mentionSearchTimerRef.current);
        mentionSearchTimerRef.current = null;
      }
      commandQueueRef.current = [];
    };
  }, []);

  useEffect(() => {
    if (!editor) return;
    const flush = () => {
      if (settingContentRef.current) return;
      emitContentNow(editor, emitContentChanged, contentEmitTimerRef, lastEmittedMarkdown, lastEmittedBlocksJson, lastMentionKey);
    };
    const flushWhenHidden = () => {
      if (document.visibilityState === "hidden") flush();
    };
    document.addEventListener("visibilitychange", flushWhenHidden);
    window.addEventListener("pagehide", flush);
    return () => {
      document.removeEventListener("visibilitychange", flushWhenHidden);
      window.removeEventListener("pagehide", flush);
    };
  }, [editor, emitContentChanged]);

  if (!editor) return null;

  const handlePointerDown = (event: React.PointerEvent<HTMLDivElement>) => {
    if (locked) return;
    const shell = event.currentTarget as HTMLElement;
    pointerStartRef.current = {
      x: event.clientX,
      y: event.clientY,
      blockId: blockIDFromEventTarget(editor.view.dom, event.target as HTMLElement | null),
      pointerId: event.pointerId,
    };
    if (ENABLE_BLOCK_DRAG && pointerStartRef.current.blockId) {
      if (longPressTimerRef.current != null) window.clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = window.setTimeout(() => {
        const start = pointerStartRef.current;
        if (!start?.blockId || locked) return;
        beginBlockDrag(editor, start.blockId, modeRef.current, setEditorMode, setCurrentDragState);
        shell.setPointerCapture?.(start.pointerId);
      }, LONG_PRESS_MS);
    }
  };

  const handlePointerMove = (event: React.PointerEvent<HTMLDivElement>) => {
    const start = pointerStartRef.current;
    if (!start) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    const dragging = dragStateRef.current;
    if (!dragging && Math.hypot(dx, dy) > POINTER_CANCEL_THRESHOLD && longPressTimerRef.current != null) {
      window.clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = null;
    }
    if (dragging) {
      event.preventDefault();
      autoScrollDuringDrag(event.clientY);
      setCurrentDragState({
        ...dragging,
        beforeId: computeBeforeBlockId(editor, event.clientY, new Set(dragging.blockIds)),
      });
    }
  };

  const handlePointerUp = (event: React.PointerEvent<HTMLDivElement>) => {
    if (longPressTimerRef.current != null) {
      window.clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = null;
    }
    const start = pointerStartRef.current;
    pointerStartRef.current = null;
    const dragging = dragStateRef.current;
    if (dragging) {
      event.preventDefault();
      commitBlockDrag(editor, dragging);
      emitContentNow(editor, emitContentChanged, contentEmitTimerRef, lastEmittedMarkdown, lastEmittedBlocksJson, lastMentionKey);
      setCurrentDragState(null);
      suppressClickUntilRef.current = Date.now() + 350;
      enterDisplay(editor, setEditorMode);
      (event.currentTarget as HTMLElement).releasePointerCapture?.(event.pointerId);
      return;
    }
    if (!ENABLE_CONTIGUOUS_MULTI_SELECT || locked || !start?.blockId) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (Math.abs(dx) > 36 && Math.abs(dx) > Math.abs(dy) * 1.3) {
      event.preventDefault();
      setCurrentMentionMenu(null);
      enterMultiSelect(editor, start.blockId, setEditorMode);
    }
  };

  const handlePointerCancel = (event: React.PointerEvent<HTMLDivElement>) => {
    if (longPressTimerRef.current != null) {
      window.clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = null;
    }
    pointerStartRef.current = null;
    if (dragStateRef.current) {
      event.preventDefault();
      setCurrentDragState(null);
      enterDisplay(editor, setEditorMode);
    }
  };

  const handleMentionPick = (place: PlaceData) => {
    setCurrentMentionMenu(null);
    insertPlace(editor, place);
    emitContentNow(editor, emitContentChanged, contentEmitTimerRef, lastEmittedMarkdown, lastEmittedBlocksJson, lastMentionKey);
    emit({ type: "placeCandidateSelected", place, inserted: true });
  };

  return (
    <div
      className="mapote-tiptap-shell"
      data-locked={locked ? "true" : "false"}
      data-mode={mode.type}
      data-drop-end={dragState?.beforeId == null && dragState ? "true" : "false"}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerCancel}
    >
      <EditorContent editor={editor} />
      {mentionMenu ? <MentionMenu menu={mentionMenu} onPick={handleMentionPick} /> : null}
    </div>
  );
}

function MentionMenu({ menu, onPick }: { menu: MentionMenuState; onPick: (place: PlaceData) => void }) {
  const rect = menu.rect;
  const estimatedHeight = Math.min(320, 42 + Math.max(1, Math.min(5, menu.results.length)) * 50);
  const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
  const viewportWidth = window.visualViewport?.width ?? window.innerWidth;
  const below = rect ? rect.y + rect.height + 8 : 44;
  const above = rect ? rect.y - estimatedHeight - 8 : 44;
  const top = rect ? Math.max(8, below + estimatedHeight > viewportHeight - 8 ? above : below) : 44;
  const left = rect ? Math.max(8, Math.min(rect.x - 8, viewportWidth - 328)) : 12;
  return (
    <div className="mention-menu" style={{ transform: `translate(${left}px, ${top}px)` }}>
      <div className="mention-menu-title">{menu.query ? "搜索结果" : "笔记中的地点"}</div>
      {menu.results.length === 0 ? (
        <div className="mention-menu-empty">暂无地点</div>
      ) : (
        menu.results.slice(0, 5).map((place) => (
          <button
            key={`${place.id}-${place.placeId ?? ""}`}
            className="mention-menu-item"
            onPointerDown={(event) => {
              event.preventDefault();
              event.stopPropagation();
              onPick(place);
            }}
          >
            <span className="mention-menu-emoji">{place.emoji ?? CATEGORY_EMOJI[place.category ?? "other"] ?? "📍"}</span>
            <span className="mention-menu-copy">
              <strong>{place.name}</strong>
              {place.address ? <small>{place.address}</small> : null}
            </span>
          </button>
        ))
      )}
    </div>
  );
}

function blockIdForIndex(index: number): string {
  return `block-${index}`;
}

function blockIndexFromId(blockId: string): number | null {
  const match = blockId.match(/^block-(\d+)$/);
  return match ? Number(match[1]) : null;
}

function syncBlockDom(editor: TiptapEditor, mode: EditorMode, dragState: DragState | null) {
  const selected = new Set(mode.type === "multiSelect" ? mode.selectedIds : []);
  const dragging = new Set(dragState?.blockIds ?? []);
  Array.from(editor.view.dom.children).forEach((child, index) => {
    const el = child as HTMLElement;
    const blockId = blockIdForIndex(index);
    el.dataset.mapoteBlockId = blockId;
    el.classList.add("mapote-block");
    el.classList.toggle("is-mapote-selected", selected.has(blockId));
    el.classList.toggle("is-mapote-anchor", mode.type === "multiSelect" && mode.anchorId === blockId);
    el.classList.toggle("is-mapote-drag-source", dragging.has(blockId));
    el.classList.toggle("is-mapote-drop-before", dragState?.beforeId === blockId);
  });
}

function blockIDFromEventTarget(root: HTMLElement, target: HTMLElement | null): string | null {
  if (!target) return null;
  const block = target.closest?.("[data-mapote-block-id]") as HTMLElement | null;
  if (!block || !root.contains(block)) return null;
  return block.dataset.mapoteBlockId ?? null;
}

function selectContinuousRange(root: HTMLElement, anchorId: string, targetId: string): EditorMode {
  const ids = Array.from(root.children).map((_child, index) => blockIdForIndex(index));
  const anchorIndex = ids.indexOf(anchorId);
  const targetIndex = ids.indexOf(targetId);
  if (anchorIndex === -1 || targetIndex === -1) {
    return { type: "multiSelect", anchorId: targetId, selectedIds: [targetId] };
  }
  const start = Math.min(anchorIndex, targetIndex);
  const end = Math.max(anchorIndex, targetIndex);
  return { type: "multiSelect", anchorId, selectedIds: ids.slice(start, end + 1) };
}

function enterDisplay(editor: TiptapEditor | null, setEditorMode: (mode: EditorMode) => void) {
  editor?.commands.blur();
  editor?.setEditable(false);
  window.getSelection()?.removeAllRanges();
  setEditorMode({ type: "display" });
}

function enterMultiSelect(editor: TiptapEditor, anchorId: string, setEditorMode: (mode: EditorMode) => void) {
  editor.commands.blur();
  editor.setEditable(false);
  window.getSelection()?.removeAllRanges();
  setEditorMode({ type: "multiSelect", anchorId, selectedIds: [anchorId] });
}

function beginBlockDrag(
  editor: TiptapEditor,
  blockId: string,
  mode: EditorMode,
  setEditorMode: (mode: EditorMode) => void,
  setDragState: (dragState: DragState | null) => void
) {
  const fromMode = mode.type === "editing" || mode.type === "multiSelect" ? mode.type : "display";
  const blockIds = mode.type === "multiSelect" && mode.selectedIds.includes(blockId)
    ? [...mode.selectedIds].sort((a, b) => (blockIndexFromId(a) ?? 0) - (blockIndexFromId(b) ?? 0))
    : [blockId];
  editor.commands.blur();
  editor.setEditable(false);
  window.getSelection()?.removeAllRanges();
  setEditorMode({ type: "dragging", fromMode, blockIds });
  setDragState({ blockIds, beforeId: blockId });
}

function computeBeforeBlockId(editor: TiptapEditor, pointerY: number, excludingBlockIds: Set<string>): string | null {
  for (const child of Array.from(editor.view.dom.children)) {
    const el = child as HTMLElement;
    const blockId = el.dataset.mapoteBlockId;
    if (!blockId || excludingBlockIds.has(blockId)) continue;
    const rect = el.getBoundingClientRect();
    if (pointerY < rect.top + rect.height / 2) return blockId;
  }
  return null;
}

function autoScrollDuringDrag(pointerY: number) {
  const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
  const scroller = document.scrollingElement;
  if (!scroller) return;
  if (pointerY < AUTO_SCROLL_EDGE_PX) {
    scroller.scrollTop = Math.max(0, scroller.scrollTop - AUTO_SCROLL_STEP_PX);
  } else if (pointerY > viewportHeight - AUTO_SCROLL_EDGE_PX) {
    scroller.scrollTop += AUTO_SCROLL_STEP_PX;
  }
}

function commitBlockDrag(editor: TiptapEditor, dragState: DragState) {
  const blocks = getTopLevelBlocks(editor);
  const movingIndices = dragState.blockIds
    .map(blockIndexFromId)
    .filter((idx): idx is number => idx != null && idx >= 0 && idx < blocks.length)
    .sort((a, b) => a - b);
  if (movingIndices.length === 0) return;
  if (dragState.beforeId != null && dragState.blockIds.includes(dragState.beforeId)) return;

  const scrollTop = document.scrollingElement?.scrollTop ?? 0;
  const movingSet = new Set(movingIndices);
  const moving = movingIndices.map((idx) => blocks[idx]).filter(Boolean);
  const remaining = blocks.filter((_block, idx) => !movingSet.has(idx));

  if (dragState.beforeId == null) {
    remaining.push(...moving);
  } else {
    const toIndex = blockIndexFromId(dragState.beforeId);
    if (toIndex == null) return;
    const removedBeforeTarget = movingIndices.filter((idx) => idx < toIndex).length;
    const adjustedIndex = toIndex - removedBeforeTarget;
    remaining.splice(Math.max(0, Math.min(adjustedIndex, remaining.length)), 0, ...moving);
  }

  replaceDocumentWithHistory(editor, remaining);
  window.requestAnimationFrame(() => {
    document.scrollingElement?.scrollTo({ top: scrollTop });
  });
}

function enterEditingAtCurrentSelection(editor: TiptapEditor, setEditorMode: (mode: EditorMode) => void) {
  const blockId = blockIdAtPos(editor, editor.state.selection.from) ?? blockIdForIndex(0);
  editor.setEditable(true);
  setEditorMode({ type: "editing", blockId });
  window.setTimeout(() => editor.commands.focus(), 0);
}

function enterEditingAtEvent(
  editor: TiptapEditor | null,
  event: MouseEvent,
  blockId: string | null,
  setEditorMode: (mode: EditorMode) => void
) {
  if (!editor) return;
  const nextBlockId = blockId ?? blockIdForIndex(0);
  editor.setEditable(true);
  setEditorMode({ type: "editing", blockId: nextBlockId });
  window.setTimeout(() => {
    const found = editor.view.posAtCoords({ left: event.clientX, top: event.clientY });
    const pos = found?.pos ?? 1;
    const selection = TextSelection.near(editor.state.doc.resolve(Math.max(1, Math.min(pos, editor.state.doc.content.size))));
    editor.view.dispatch(editor.state.tr.setSelection(selection));
    editor.view.focus();
  }, 0);
}

function blockIdAtPos(editor: TiptapEditor, pos: number): string | null {
  const dom = editor.view.domAtPos(pos).node;
  const element = dom.nodeType === globalThis.Node.ELEMENT_NODE ? (dom as HTMLElement) : dom.parentElement;
  return blockIDFromEventTarget(editor.view.dom, element);
}

function getTopLevelBlocks(editor: TiptapEditor): JsonNode[] {
  return ((editor.getJSON().content ?? []) as JsonNode[]).map(stripEmptyContent);
}

function stripEmptyContent(node: JsonNode): JsonNode {
  if (!Array.isArray(node.content)) return node;
  const next: JsonNode = { ...node, content: node.content.map(stripEmptyContent) };
  if (next.content.length === 0) next.content = undefined;
  return next;
}

function replaceDocumentWithoutHistory(editor: TiptapEditor, content: JsonNode[]) {
  const nextDoc = editor.schema.nodeFromJSON({ type: "doc", content });
  const tr = editor.state.tr
    .replaceWith(0, editor.state.doc.content.size, nextDoc.content)
    .setMeta("addToHistory", false)
    .setMeta("preventUpdate", true);
  editor.view.dispatch(tr);
}

function replaceDocumentWithHistory(editor: TiptapEditor, content: JsonNode[]) {
  const nextDoc = editor.schema.nodeFromJSON({ type: "doc", content });
  const tr = editor.state.tr
    .replaceWith(0, editor.state.doc.content.size, nextDoc.content)
    .setMeta("addToHistory", true);
  editor.view.dispatch(tr);
}

function scheduleContentEmit(
  editor: TiptapEditor,
  emitContentChanged: (markdown: string, blocks: JsonNode[]) => void,
  timerRef: MutableRefObject<number | null>,
  debounceMsRef: MutableRefObject<number>,
  lastMarkdown: MutableRefObject<string>,
  lastBlocksJson: MutableRefObject<string>,
  lastMentionKey: MutableRefObject<string>
) {
  const blocks = getTopLevelBlocks(editor);
  const blocksJson = JSON.stringify(blocks);
  const markdown = tiptapBlocksToMarkdown(blocks);
  const mentionKey = "";
  if (markdown === lastMarkdown.current && blocksJson === lastBlocksJson.current && mentionKey === lastMentionKey.current) return;
  lastMarkdown.current = markdown;
  lastBlocksJson.current = blocksJson;
  lastMentionKey.current = mentionKey;
  if (timerRef.current != null) window.clearTimeout(timerRef.current);
  // Stability-first persistence: send the canonical JSON snapshot immediately
  // on each Tiptap update. The native layer dedupes identical snapshots and
  // persists received JSON immediately, which removes the "tap back before the
  // debounce fires" data-loss window. Keep debounceMsRef in the signature so
  // the bridge contract can be reintroduced later if saves move off the hot
  // path or gain an explicit flush acknowledgement.
  void debounceMsRef;
  timerRef.current = null;
  emitContentChanged(markdown, blocks);
}

function emitContentNow(
  editor: TiptapEditor,
  emitContentChanged: (markdown: string, blocks: JsonNode[]) => void,
  timerRef: MutableRefObject<number | null>,
  lastMarkdown: MutableRefObject<string>,
  lastBlocksJson: MutableRefObject<string>,
  lastMentionKey: MutableRefObject<string>
) {
  if (timerRef.current != null) {
    window.clearTimeout(timerRef.current);
    timerRef.current = null;
  }
  const blocks = getTopLevelBlocks(editor);
  const markdown = tiptapBlocksToMarkdown(blocks);
  lastMarkdown.current = markdown;
  lastBlocksJson.current = JSON.stringify(blocks);
  lastMentionKey.current = "";
  emitContentChanged(markdown, blocks);
}

function emitToolbarState(editor: TiptapEditor, emit: (msg: Record<string, unknown>) => void, composing: boolean) {
  emit({
    type: "toolbarState",
    state: {
      bold: editor.isActive("bold"),
      headingLevel: editor.isActive("heading", { level: 1 }) ? 1 : editor.isActive("heading", { level: 2 }) ? 2 : editor.isActive("heading", { level: 3 }) ? 3 : 0,
      bulletList: editor.isActive("bulletList"),
      orderedList: editor.isActive("orderedList"),
      taskList: editor.isActive("taskList"),
      composing,
    },
  });
}

function updateMentionMenu(
  editor: TiptapEditor,
  emit: (msg: Record<string, unknown>) => void,
  placesRef: MutableRefObject<PlaceData[]>,
  requestSeqRef: MutableRefObject<number>,
  timerRef: MutableRefObject<number | null>,
  mentionMenuRef: MutableRefObject<MentionMenuState | null>,
  setMentionMenu: (menu: MentionMenuState | null) => void
) {
  const mention = detectMention(editor);
  if (!mention || !mention.rect) {
    if (timerRef.current != null) {
      window.clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    setMentionMenu(null);
    return;
  }

  const query = mention.query.trim();
  const current = mentionMenuRef.current;
  const sameQuery = current?.query === query;
  const requestId = sameQuery ? current.requestId : `mention-${++requestSeqRef.current}`;
  const local = filterLocalPlaces(placesRef.current, query);
  setMentionMenu({ requestId, query, rect: mention.rect, results: sameQuery ? mergePlaces(current?.results ?? [], local) : local });

  if (sameQuery) return;
  if (timerRef.current != null) window.clearTimeout(timerRef.current);
  if (!query) return;
  timerRef.current = window.setTimeout(() => {
    emit({ type: "requestPlaceSearch", requestId, query });
    timerRef.current = null;
  }, 140);
}

function filterLocalPlaces(places: PlaceData[], query: string): PlaceData[] {
  if (!query) return places.slice(0, 5);
  const lower = query.toLowerCase();
  return places.filter((place) => `${place.name} ${place.address ?? ""}`.toLowerCase().includes(lower)).slice(0, 5);
}

function mergePlaces(primary: PlaceData[], secondary: PlaceData[]): PlaceData[] {
  const seen = new Set<string>();
  const merged: PlaceData[] = [];
  for (const place of [...primary, ...secondary]) {
    const key = place.placeId || place.id || place.name;
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(place);
  }
  return merged.slice(0, 5);
}

function enqueueCommand(
  command: QueuedCommand,
  queueRef: MutableRefObject<QueuedCommand[]>,
  drain: () => void
) {
  queueRef.current.push(command);
  drain();
}

function drainCommandQueue(
  editor: TiptapEditor | null,
  queueRef: MutableRefObject<QueuedCommand[]>,
  drainingRef: MutableRefObject<boolean>,
  composingRef: MutableRefObject<boolean>,
  emit: (msg: Record<string, unknown>) => void
) {
  if (!editor || drainingRef.current || composingRef.current) return;
  drainingRef.current = true;
  window.setTimeout(() => {
    try {
      while (queueRef.current.length > 0 && !composingRef.current) {
        const next = queueRef.current.shift();
        if (next) applyCommand(editor, next.kind);
      }
      emitToolbarState(editor, emit, composingRef.current);
    } finally {
      drainingRef.current = false;
      if (queueRef.current.length > 0 && !composingRef.current) {
        drainCommandQueue(editor, queueRef, drainingRef, composingRef, emit);
      }
    }
  }, 0);
}

function applyCommand(editor: TiptapEditor, kind: CommandPayload["kind"]) {
  switch (kind.type) {
    case "insertText":
      editor.chain().focus().insertContent(kind.text || "").run();
      break;
    case "toggleBold":
      editor.chain().focus().toggleBold().run();
      break;
    case "heading":
      (editor.chain().focus() as any).toggleHeading({ level: (kind.level ?? 1) as 1 | 2 | 3 }).run();
      break;
    case "bulletList":
      editor.chain().focus().toggleBulletList().run();
      break;
    case "orderedList":
      editor.chain().focus().toggleOrderedList().run();
      break;
    case "taskList":
      editor.chain().focus().toggleTaskList().run();
      break;
    case "divider":
      editor.chain().focus().insertContent([{ type: "divider" }, { type: "paragraph" }]).run();
      break;
    case "undo":
      editor.chain().focus().undo().run();
      break;
    case "redo":
      editor.chain().focus().redo().run();
      break;
  }
}

function insertPlace(editor: TiptapEditor, place: PlaceData) {
  const category = place.category || "other";
  const placeRefId = place.placeId || place.id;
  const range = mentionPrefixRange(editor);
  let chain = editor.chain().focus();
  if (range) chain = chain.deleteRange(range);
  chain
    .insertContent([
      {
        type: "placeRef",
        attrs: {
          placeId: placeRefId,
          name: place.name,
          category,
          emoji: place.emoji || CATEGORY_EMOJI[category] || "📍",
        },
      },
      { type: "text", text: " " },
    ])
    .run();
}

function insertImage(editor: TiptapEditor, payload: ImageInsertPayload) {
  if (!payload?.url) return;
  editor.chain().focus().setImage({ src: payload.url, alt: payload.caption || "" }).run();
}

function mentionPrefixRange(editor: TiptapEditor): { from: number; to: number } | null {
  const { state } = editor;
  const { from } = state.selection;
  const $pos = state.doc.resolve(from);
  const before = $pos.nodeBefore;
  if (!before || !before.isText) return null;
  const text = before.text || "";
  const m = text.match(/(?:^|[\s\n])@([^\s\n]*)$/);
  if (!m) return null;
  const length = m[0].startsWith("@") ? m[0].length : m[0].length - 1;
  return { from: from - length, to: from };
}

function detectMention(editor: TiptapEditor): MentionInfo | null {
  const { state } = editor;
  const { from, empty } = state.selection;
  if (!empty) return null;
  const $pos = state.doc.resolve(from);
  const before = $pos.nodeBefore;
  if (!before || !before.isText) return null;
  const text = before.text || "";
  const m = text.match(/(?:^|[\s\n])@([^\s\n]*)$/);
  if (!m) return null;
  return { query: m[1] || "", rect: computeMentionRect(editor) };
}

function computeMentionRect(editor: TiptapEditor): MentionInfo["rect"] {
  try {
    const { from } = editor.state.selection;
    const coords = editor.view.coordsAtPos(from);
    const root = editor.view.dom.parentElement?.getBoundingClientRect();
    const baseX = root?.left ?? 0;
    const baseY = root?.top ?? 0;
    return {
      x: coords.left - baseX,
      y: coords.bottom - baseY,
      width: 1,
      height: coords.bottom - coords.top,
    };
  } catch {
    return null;
  }
}
