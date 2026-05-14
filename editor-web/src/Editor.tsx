import { useCallback, useEffect, useRef, useState } from "react";
import {
  BlockNoteSchema,
  defaultBlockSpecs,
  defaultInlineContentSpecs,
  defaultStyleSpecs,
  filterSuggestionItems,
} from "@blocknote/core";
import { BlockNoteView } from "@blocknote/mantine";
import "@blocknote/core/fonts/inter.css";
import "@blocknote/mantine/style.css";
import {
  getDefaultReactSlashMenuItems,
  SuggestionMenuController,
  useCreateBlockNote,
} from "@blocknote/react";
import type {
  CommandPayload,
  ImageInsertPayload,
  MentionInfo,
  MoveBlockPayload,
  PlaceData,
  SetContentPayload,
} from "./types";
import { CATEGORY_EMOJI } from "./types";
import { postToHost, reportError, reportReady } from "./bridge";
import { PlaceInline } from "./placeInline";
import { DividerBlock } from "./divider";
import { blocksToMarkdown, markdownToBlocks } from "./markdown";

const {
  paragraph,
  heading,
  bulletListItem,
  numberedListItem,
  checkListItem,
  image,
} = defaultBlockSpecs;

const { bold } = defaultStyleSpecs;

const ALLOWED_BLOCK_TYPES = new Set([
  "paragraph",
  "heading",
  "bulletListItem",
  "numberedListItem",
  "checkListItem",
  "image",
  "divider",
]);

function extractBlockText(b: any): string {
  if (!b) return "";
  if (typeof b.content === "string") return b.content;
  if (Array.isArray(b.content)) {
    return b.content
      .map((c: any) => {
        if (typeof c === "string") return c;
        if (typeof c?.text === "string") return c.text;
        return "";
      })
      .join("");
  }
  return "";
}

function sanitizeBlocks(blocks: any[]): any[] {
  if (!Array.isArray(blocks)) return [{ type: "paragraph" }];
  const out: any[] = blocks.map((b: any) => {
    if (!b || typeof b !== "object") return { type: "paragraph" };
    if (ALLOWED_BLOCK_TYPES.has(b.type)) return b;
    const text = extractBlockText(b);
    return text
      ? { type: "paragraph", content: [{ type: "text", text }] }
      : { type: "paragraph" };
  });
  return out.length > 0 ? out : [{ type: "paragraph" }];
}

const schema = BlockNoteSchema.create({
  blockSpecs: {
    paragraph,
    heading,
    bulletListItem,
    numberedListItem,
    checkListItem,
    image,
    divider: DividerBlock(),
  },
  styleSpecs: {
    bold,
  },
  inlineContentSpecs: {
    ...defaultInlineContentSpecs,
    placeRef: PlaceInline,
  },
});

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AppEditor = any;

interface PendingState {
  markdown: string;
  blocks?: unknown[] | null;
  places: PlaceData[];
  locked: boolean;
  ackSeq?: number;
  revision?: number;
  version: number;
}

export function Editor() {
  const editor = useCreateBlockNote({ schema });
  const [locked, setLocked] = useState(false);
  const [editing, setEditing] = useState(false);
  // Phase C: selection mode for batch reorder / delete.
  const [selecting, setSelecting] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(() => new Set());
  const [copyToastVisible, setCopyToastVisible] = useState(false);
  // Refs for gesture state — avoids re-mounting the gesture effect when
  // selecting / selectedIds change, which would kill in-progress pointers.
  const selectingRef = useRef(false);
  const editingRef = useRef(false);
  const selectedIdsRef = useRef<Set<string>>(new Set());
  // Keep refs in sync with state
  editingRef.current = editing;
  selectingRef.current = selecting;
  selectedIdsRef.current = selectedIds;
  const placesRef = useRef<PlaceData[]>([]);
  const lastEmittedMarkdown = useRef<string>("");
  const lastEmittedBlocksJson = useRef<string>("");
  const lastMentionKey = useRef<string>("");
  const localSeqRef = useRef(0);
  const lastAckSeqRef = useRef(0);
  const lastAppliedRevisionRef = useRef(0);
  const inboundVersionRef = useRef(0);
  const settingContentRef = useRef(false);

  // Mode helpers route INPUT only — they never gate ProseMirror's `editable`
  // prop, which would force a view remount and produce spurious onChange
  // events (the root cause of "notes vanish in multi-select" and the input
  // lag on enter/exit edit).
  const blurEditor = useCallback(() => {
    const anyEditor = editor as any;
    try {
      anyEditor._tiptapEditor?.commands?.blur?.();
    } catch {
      // ignore
    }
    if (document.activeElement instanceof HTMLElement) {
      document.activeElement.blur();
    }
  }, [editor]);

  const enterDefaultMode = useCallback(
    (clearSelection = true) => {
      // Update refs synchronously so the next pointerdown — which may fire
      // in the very same tick — sees the new mode without waiting for React
      // to flush the setState batch.
      editingRef.current = false;
      selectingRef.current = false;
      if (clearSelection) selectedIdsRef.current = new Set();
      setEditing(false);
      setSelecting(false);
      if (clearSelection) setSelectedIds(new Set());
      blurEditor();
    },
    [blurEditor]
  );

  const enterMultiSelectMode = useCallback(
    (blockId?: string | null) => {
      const next = new Set(blockId ? [blockId] : []);
      editingRef.current = false;
      selectingRef.current = true;
      selectedIdsRef.current = next;
      setEditing(false);
      setSelecting(true);
      setSelectedIds(next);
      blurEditor();
    },
    [blurEditor]
  );

  const applyPending = useCallback(
    async (state: PendingState) => {
      const isStale = () => state.version !== inboundVersionRef.current;
      settingContentRef.current = true;
      let fromMarkdownMigration = false;
      try {
        if (typeof state.revision === "number") {
          if (state.revision < lastAppliedRevisionRef.current) return;
          lastAppliedRevisionRef.current = state.revision;
        }
        if (typeof state.ackSeq === "number") {
          lastAckSeqRef.current = Math.max(lastAckSeqRef.current, state.ackSeq);
          if (state.ackSeq < localSeqRef.current) {
            placesRef.current = state.places;
            setLocked(state.locked);
            return;
          }
        }
        if (isStale()) return;
        placesRef.current = state.places;
        let blocks: any[];
        if (Array.isArray(state.blocks) && state.blocks.length > 0) {
          blocks = state.blocks as any[];
        } else {
          blocks = await markdownToBlocks(editor, state.markdown, state.places);
          if (isStale()) return;
          if (state.markdown && blocks.length > 0) fromMarkdownMigration = true;
        }
        if (isStale()) return;
        if (blocks.length === 0) {
          editor.replaceBlocks(editor.document, [
            { type: "paragraph" } as any,
          ]);
        } else {
          try {
            editor.replaceBlocks(editor.document, blocks);
          } catch (innerErr) {
            // Schema mismatch — sanitize unknown block types to paragraph
            // while preserving their text content, then retry. Never silently
            // wipe the document to a blank paragraph.
            reportError(
              `replaceBlocks failed, sanitizing: ${(innerErr as Error).message}`
            );
            try {
              const sanitized = sanitizeBlocks(blocks);
              if (isStale()) return;
              editor.replaceBlocks(editor.document, sanitized as any[]);
            } catch (e2) {
              reportError(
                `sanitized replaceBlocks also failed: ${(e2 as Error).message}`
              );
              // Leave the editor document untouched.
              return;
            }
          }
        }
        setLocked(state.locked);
        lastEmittedMarkdown.current = state.markdown;
        lastEmittedBlocksJson.current = JSON.stringify(editor.document);
      } catch (err) {
        reportError(`setContent failed: ${(err as Error).message}`);
      } finally {
        setTimeout(() => {
          settingContentRef.current = false;
          if (fromMarkdownMigration) {
            const doc = editor.document as any;
            const blocksJson = JSON.stringify(doc);
            lastEmittedBlocksJson.current = blocksJson;
            blocksToMarkdown(editor, doc)
              .then((md) => {
                lastEmittedMarkdown.current = md;
                const seq = localSeqRef.current + 1;
                localSeqRef.current = seq;
                postToHost({
                  type: "contentChanged",
                  markdown: md,
                  blocks: doc,
                  mention: null,
                  seq,
                  ackRevision: lastAppliedRevisionRef.current,
                });
              })
              .catch((err) =>
                reportError(`migration emit failed: ${(err as Error).message}`)
              );
          }
        }, 30);
      }
    },
    [editor]
  );

  useEffect(() => {
    window.editorBridge = {
      setContent: (raw) => {
        const payload = raw as SetContentPayload;
        const nextVersion = inboundVersionRef.current + 1;
        inboundVersionRef.current = nextVersion;
        const next: PendingState = {
          markdown: payload?.markdown ?? "",
          blocks: payload?.blocks ?? null,
          places: payload?.places ?? [],
          locked: !!payload?.locked,
          ackSeq:
            typeof payload?.ackSeq === "number" ? payload.ackSeq : undefined,
          revision:
            typeof payload?.revision === "number" ? payload.revision : undefined,
          version: nextVersion,
        };
        void applyPending(next);
      },
      setLocked: (l) => setLocked(!!l),
      applyCommand: (raw) => {
        try {
          applyCommand(editor, (raw as CommandPayload).kind);
        } catch (err) {
          reportError(`applyCommand failed: ${(err as Error).message}`);
        }
      },
      insertPlace: (raw) => {
        try {
          insertPlace(editor, raw as PlaceData);
        } catch (err) {
          reportError(`insertPlace failed: ${(err as Error).message}`);
        }
      },
      insertImage: (raw) => {
        try {
          insertImage(editor, raw as ImageInsertPayload);
        } catch (err) {
          reportError(`insertImage failed: ${(err as Error).message}`);
        }
      },
      focusEditor: () => {
        editor.focus();
      },
      moveBlock: (raw) => {
        try {
          moveBlock(editor, raw as MoveBlockPayload);
        } catch (err) {
          reportError(`moveBlock failed: ${(err as Error).message}`);
        }
      },
      moveBlocks: (raw) => {
        try {
          moveBlocks(editor, raw as { ids?: string[]; beforeId?: string | null });
        } catch (err) {
          reportError(`moveBlocks failed: ${(err as Error).message}`);
        }
      },
      enterSelection: (raw) => {
        const blockId =
          (raw as { blockId?: string } | undefined)?.blockId ?? null;
        enterMultiSelectMode(blockId);
      },
      toggleSelection: (raw) => {
        const blockId =
          (raw as { blockId?: string } | undefined)?.blockId ?? null;
        if (!blockId) return;
        setSelectedIds((prev) => toggleSelectionId(prev, blockId));
      },
      exitSelection: () => {
        enterDefaultMode(true);
      },
    };
    reportReady();
    return () => {
      delete window.editorBridge;
    };
  }, [editor, applyPending, enterDefaultMode, enterMultiSelectMode]);

  // Unified gesture state machine: tap, swipe-to-select, long-press drag, group drag.
  // Uses refs for selecting/selectedIds so the effect is NOT re-mounted when
  // those values change — that would kill in-progress pointers.
  useEffect(() => {
    if (locked) return;

    const tapMaxDuration = 260;
    const tapMoveThreshold = 10;
    const swipeThresholdX = 26;
    const swipeThresholdY = 14;
    const moveCancelThreshold = 8;
    const longPressMs = 380;

    let pointer: null | {
      pointerId: number;
      blockId: string;
      blockEl: HTMLElement;
      startedSelecting: boolean;
      startedEditing: boolean;
      wasSelectedAtStart: boolean;
      startX: number;
      startY: number;
      startT: number;
      moved: boolean;
      dragging: boolean;
      swipeOffset: number;
      movingIds: string[];
      beforeId: string | null;
      ghost: HTMLElement | null;
      dropLine: HTMLElement | null;
      longPressTimer: number | null;
      longPressArmed: boolean;
      blockRects: Array<{ id: string; top: number; height: number }>;
      didSwipeEnterSelection: boolean;
    } = null;

    const clearTimer = () => {
      if (pointer?.longPressTimer != null) {
        window.clearTimeout(pointer.longPressTimer);
        pointer.longPressTimer = null;
      }
    };

    const cleanupDrag = () => {
      const ghost = pointer?.ghost ?? null;
      const dropLine = pointer?.dropLine ?? null;
      if (pointer) {
        pointer.ghost = null;
        pointer.dropLine = null;
      }
      // Defer DOM removals so any pending block move ops settle first;
      // otherwise the element refs the gesture state still holds may be
      // detached mid-cleanup and produce inconsistent state.
      window.setTimeout(() => {
        document.body.classList.remove("editor-dragging");
        if (ghost) ghost.remove();
        if (dropLine) dropLine.remove();
      }, 0);
    };

    const onPointerDown = (e: PointerEvent) => {
      if (e.button !== 0) return;
      const target = e.target as Element | null;
      if (target?.closest?.("[data-selection-chrome]")) return;
      const blockEl = findBlockElementFromTarget(target);
      const blockId = blockEl?.dataset?.id;
      if (selectingRef.current && !blockEl) {
        // Multiselect: tapping blank area exits to default mode.
        e.preventDefault();
        e.stopPropagation();
        enterDefaultMode(true);
        return;
      }
      // Default / editing: blank area (including below the tail) is handled
      // by ProseMirror's native click-routing (caret at end). We deliberately
      // do not preventDefault so caret lands where the user tapped.
      if (!blockEl || !blockId) return;

      // Only multiselect suppresses ProseMirror caret/selection.
      // Default / editing modes let the engine handle the tap naturally so
      // the cursor appears at the tap location without a view remount.
      if (selectingRef.current) {
        e.preventDefault();
        e.stopPropagation();
      }

      pointer = {
        pointerId: e.pointerId,
        blockId,
        blockEl,
        startedSelecting: selectingRef.current,
        startedEditing: editingRef.current,
        wasSelectedAtStart: selectedIdsRef.current.has(blockId),
        startX: e.clientX,
        startY: e.clientY,
        startT: Date.now(),
        moved: false,
        dragging: false,
        swipeOffset: 0,
        movingIds: [],
        beforeId: null,
        ghost: null,
        dropLine: null,
        longPressTimer: null,
        longPressArmed: false,
        blockRects: [],
        didSwipeEnterSelection: false,
      };

      // The long-press timer only ARMS drag intent; the actual drag setup
      // (ghost, blur, dragging=true) is deferred to the first qualifying
      // pointermove. This eliminates the "hold to read = block moves to
      // end of doc + editor blurs" misfire that felt like edit-mode lag.
      pointer.longPressTimer = window.setTimeout(() => {
        if (!pointer || pointer.pointerId !== e.pointerId) return;
        pointer.longPressArmed = true;
      }, longPressMs);
    };

    const beginDrag = () => {
      if (!pointer || pointer.dragging) return;
      const blockId = pointer.blockId;
      const curSelectedIds = selectedIdsRef.current;
      const curSelecting = selectingRef.current;
      const orderedSelected = Array.from(curSelectedIds).filter((id) =>
        (editor.document as any[]).some((b: any) => b.id === id)
      );
      const movingIds =
        curSelecting &&
        orderedSelected.length > 1 &&
        curSelectedIds.has(blockId)
          ? orderedSelected
          : [blockId];
      pointer.movingIds = movingIds;
      pointer.blockRects = measureBlockRects(editor, new Set(movingIds));
      if (pointer.blockRects.length === 0) return;
      blurEditor();
      setEditing(false);
      pointer.dragging = true;
      document.body.classList.add("editor-dragging");

      const ghost = document.createElement("div");
      ghost.className = "editor-block-ghost";
      ghost.textContent =
        movingIds.length > 1 ? `已选 ${movingIds.length}` : "正在移动";
      document.body.appendChild(ghost);
      pointer.ghost = ghost;

      const line = document.createElement("div");
      line.className = "editor-drop-line";
      document.body.appendChild(line);
      pointer.dropLine = line;
    };

    const animateSwipeBack = (el: HTMLElement | null | undefined, blockId?: string) => {
      let target = el ?? null;
      if ((!target || !target.isConnected) && blockId) {
        target = findBlockElementById(blockId);
      }
      if (!target) return;
      const node = target;
      node.style.transition = "transform 0.22s cubic-bezier(0.2, 0.7, 0.2, 1)";
      node.style.transform = "translateX(0)";
      const cleanup = () => {
        node.style.transition = "";
        node.style.transform = "";
        node.removeEventListener("transitionend", cleanup);
      };
      node.addEventListener("transitionend", cleanup);
      // Safety: force-clear after 280ms even if transitionend never fires.
      window.setTimeout(cleanup, 280);
    };

    const onPointerMove = (e: PointerEvent) => {
      if (!pointer || pointer.pointerId !== e.pointerId) return;
      const dx = e.clientX - pointer.startX;
      const dy = e.clientY - pointer.startY;
      const horizontal = Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > 4;
      const activeSelecting = pointer.startedSelecting || selectingRef.current;

      if (!pointer.dragging && horizontal && !pointer.didSwipeEnterSelection) {
        e.preventDefault();
        e.stopPropagation();
        if (!pointer.blockEl.isConnected) {
          const found = findBlockElementById(pointer.blockId);
          if (found) pointer.blockEl = found;
        }
        // Visual swipe feedback: translate the block with the finger (damped).
        const damped = dx * 0.5;
        pointer.swipeOffset = damped;
        if (pointer.blockEl) {
          pointer.blockEl.style.transition = "none";
          pointer.blockEl.style.transform = `translateX(${damped}px)`;
        }
      }

      if (Math.abs(dx) > moveCancelThreshold || Math.abs(dy) > moveCancelThreshold) {
        pointer.moved = true;
      }

      if (!pointer.dragging) {
        if (
          !activeSelecting &&
          !pointer.didSwipeEnterSelection &&
          Math.abs(dx) >= swipeThresholdX &&
          Math.abs(dy) <= swipeThresholdY
        ) {
          clearTimer();
          pointer.didSwipeEnterSelection = true;
          // Animate the row back to 0 immediately after threshold crossed.
          animateSwipeBack(pointer.blockEl, pointer.blockId);
          enterMultiSelectMode(pointer.blockId);
          e.preventDefault();
          e.stopPropagation();
          return;
        }
        // Long-press armed AND user has actually moved → commit to drag now.
        // A static hold never reaches this branch, so reading-style touches
        // no longer trigger the drag pipeline (and no longer blur the editor).
        if (
          pointer.longPressArmed &&
          (Math.abs(dx) > moveCancelThreshold || Math.abs(dy) > moveCancelThreshold)
        ) {
          beginDrag();
          e.preventDefault();
          e.stopPropagation();
          return;
        }
        if (pointer.moved && pointer.startedSelecting) clearTimer();
        return;
      }

      e.preventDefault();
      e.stopPropagation();
      const ghost = pointer.ghost;
      if (!ghost) return;
      ghost.style.left = `${e.clientX + 10}px`;
      ghost.style.top = `${e.clientY + 10}px`;

      const drop = computeDropTarget(e.clientY, pointer.blockRects);
      pointer.beforeId = drop.beforeId;
      if (pointer.dropLine) {
        pointer.dropLine.style.left = `16px`;
        pointer.dropLine.style.right = `16px`;
        pointer.dropLine.style.top = `${drop.y - 1}px`;
        pointer.dropLine.style.opacity = "1";
      }
    };

    const finish = (e: PointerEvent) => {
      if (!pointer || pointer.pointerId !== e.pointerId) return;
      clearTimer();
      if (pointer.dragging && pointer.movingIds.length > 0) {
        if (!(pointer.beforeId && pointer.movingIds.includes(pointer.beforeId))) {
          moveBlocks(editor, { ids: pointer.movingIds, beforeId: pointer.beforeId });
        }
      } else if (
        pointer.startedSelecting &&
        selectingRef.current &&
        !pointer.didSwipeEnterSelection &&
        Date.now() - pointer.startT <= tapMaxDuration &&
        Math.abs(e.clientX - pointer.startX) <= tapMoveThreshold &&
        Math.abs(e.clientY - pointer.startY) <= tapMoveThreshold
      ) {
        setSelectedIds((prev) => {
          const next = toggleSelectionId(prev, pointer!.blockId);
          selectedIdsRef.current = next;
          return next;
        });
      }
      // Default-mode block taps are handled entirely by ProseMirror's native
      // click → caret routing, and onFocus syncs the `editing` UI state. We
      // intentionally do not call enterEditingMode here, which would move the
      // caret to the block end and override the user's tap target.
      if (pointer.dragging && pointer.startedSelecting && !pointer.wasSelectedAtStart) {
        // Multiselect dragging an unselected block should end multiselect.
        enterDefaultMode(true);
      }
      // If we applied a swipe transform but never crossed the threshold,
      // animate back to 0.
      if (pointer.swipeOffset !== 0 && !pointer.didSwipeEnterSelection) {
        animateSwipeBack(pointer.blockEl, pointer.blockId);
      }
      cleanupDrag();
      pointer = null;
    };

    const cancel = (_e: PointerEvent) => {
      if (!pointer) return;
      clearTimer();
      if (pointer.swipeOffset !== 0) {
        animateSwipeBack(pointer.blockEl, pointer.blockId);
      }
      cleanupDrag();
      pointer = null;
    };

    document.addEventListener("pointerdown", onPointerDown, true);
    document.addEventListener("pointermove", onPointerMove, true);
    document.addEventListener("pointerup", finish, true);
    document.addEventListener("pointercancel", cancel, true);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown, true);
      document.removeEventListener("pointermove", onPointerMove, true);
      document.removeEventListener("pointerup", finish, true);
      document.removeEventListener("pointercancel", cancel, true);
      clearTimer();
      cleanupDrag();
      pointer = null;
    };
  }, [editor, blurEditor, enterDefaultMode, enterMultiSelectMode, locked]);

  // Reflect selection state on DOM (CSS targets these classes).
  // NOTE: we do NOT toggle ProseMirror's contentEditable — combining
  // contenteditable=false with user-select:none can cause WKWebView to
  // skip pointer dispatch on the subtree, breaking tap-to-toggle in
  // selection mode. Caret placement is suppressed via preventDefault
  // on pointerdown when selectingRef.current is true (see gesture effect).
  useEffect(() => {
    document.body.classList.toggle("editor-selecting", selecting);
    document.querySelectorAll<HTMLElement>(".bn-block[data-id]").forEach((el) => {
      const id = el.dataset.id || "";
      el.classList.toggle("editor-block-selected", selectedIds.has(id));
    });
  }, [selecting, selectedIds, locked]);

  // Multi-select isolation: directly mutate `contenteditable` on the live
  // .ProseMirror element instead of going through BlockNote's `editable`
  // prop. This is what tells iOS WKWebView to disengage its text-input
  // system (which otherwise eats every tap in select mode), but unlike
  // toggling the prop it never remounts the ProseMirror view — the source
  // of every "notes vanish / multi-select can't toggle" regression so far.
  // A MutationObserver keeps the attribute pinned even if BlockNote rewrites
  // it during its own render cycle.
  useEffect(() => {
    const desired = selecting || locked ? "false" : "true";
    const enforce = () => {
      document.querySelectorAll<HTMLElement>(".ProseMirror").forEach((el) => {
        if (el.getAttribute("contenteditable") !== desired) {
          el.setAttribute("contenteditable", desired);
        }
      });
    };
    enforce();
    const observer = new MutationObserver(enforce);
    document.querySelectorAll<HTMLElement>(".ProseMirror").forEach((el) => {
      observer.observe(el, {
        attributes: true,
        attributeFilter: ["contenteditable"],
      });
    });
    return () => observer.disconnect();
  }, [selecting, locked]);

  // Prevent any horizontal scroll in the web view — stops iOS rubber-band.
  useEffect(() => {
    const clamp = () => {
      if (window.scrollX !== 0) window.scrollTo(0, window.scrollY);
    };
    window.addEventListener("scroll", clamp, { passive: true });
    clamp();
    return () => window.removeEventListener("scroll", clamp);
  }, []);

  // Forward edits to Swift
  useEffect(() => {
    const unsubscribe = editor.onChange(async () => {
      if (settingContentRef.current) return;
      try {
        const doc = editor.document as any;
        const md = await blocksToMarkdown(editor, doc);
        const blocksJson = JSON.stringify(doc);
        const mention = detectMention(editor);
        const mentionKey = mention
          ? `${mention.query}|${mention.rect?.x ?? 0}|${mention.rect?.y ?? 0}`
          : "";
        if (
          md === lastEmittedMarkdown.current &&
          blocksJson === lastEmittedBlocksJson.current &&
          mentionKey === lastMentionKey.current
        ) {
          return;
        }
        lastEmittedMarkdown.current = md;
        lastEmittedBlocksJson.current = blocksJson;
        lastMentionKey.current = mentionKey;
        const seq = localSeqRef.current + 1;
        localSeqRef.current = seq;
        postToHost({
          type: "contentChanged",
          markdown: md,
          blocks: doc,
          mention,
          seq,
          ackRevision: lastAppliedRevisionRef.current,
        });
      } catch (err) {
        reportError(`onChange failed: ${(err as Error).message}`);
      }
    });
    return () => unsubscribe?.();
  }, [editor]);

  // Selection-only mention sweeps (cursor moved without content change)
  useEffect(() => {
    const unsubscribe = editor.onSelectionChange(() => {
      if (settingContentRef.current) return;
      const mention = detectMention(editor);
      const key = mention
        ? `${mention.query}|${mention.rect?.x ?? 0}|${mention.rect?.y ?? 0}`
        : "";
      if (key === lastMentionKey.current) return;
      lastMentionKey.current = key;
      postToHost({
        type: "contentChanged",
        markdown: lastEmittedMarkdown.current,
        mention,
        ackRevision: lastAppliedRevisionRef.current,
      });
    });
    return () => unsubscribe?.();
  }, [editor]);

  // Focus events. `editing` is a UI-only mirror of ProseMirror's focus and
  // never gates the `editable` prop, so re-renders here cannot remount the
  // editor view.
  const onFocus = useCallback(() => {
    if (!selectingRef.current) setEditing(true);
    postToHost({ type: "focusChanged", focused: true });
  }, []);
  const onBlur = useCallback(() => {
    setEditing(false);
    postToHost({ type: "focusChanged", focused: false });
  }, []);

  const exitSelection = useCallback(() => {
    enterDefaultMode(true);
  }, [enterDefaultMode]);

  const handleDelete = useCallback(() => {
    if (selectedIds.size === 0) return;
    editor.removeBlocks(Array.from(selectedIds) as any[]);
    exitSelection();
  }, [editor, selectedIds, exitSelection]);

  const handleCopy = useCallback(async () => {
    if (selectedIds.size === 0) return;
    try {
      const doc = editor.document as any[];
      const selectedBlocks = doc.filter((b: any) => selectedIds.has(b.id));
      if (selectedBlocks.length === 0) return;
      const markdown = await blocksToMarkdown(editor, selectedBlocks);
      if (!markdown.trim()) return;
      try {
        await navigator.clipboard.writeText(markdown);
      } catch {
        // WKWebView often blocks Clipboard API without a secure user-agent
        // context; fall back to native clipboard bridge.
        postToHost({ type: "copyText", text: markdown });
      }
      setCopyToastVisible(true);
      window.setTimeout(() => setCopyToastVisible(false), 1200);
    } catch (err) {
      reportError(`copy failed: ${(err as Error).message}`);
    }
  }, [editor, selectedIds]);

  return (
    <>
      <BlockNoteView
        editor={editor as any}
        editable={!locked}
        onFocus={onFocus}
        onBlur={onBlur}
        slashMenu={false}
        sideMenu={false}
        formattingToolbar={false}
        filePanel={false}
        emojiPicker={false}
        tableHandles={false}
        linkToolbar
      >
        <SuggestionMenuController
          triggerCharacter="/"
          getItems={async (query) =>
            filterSuggestionItems(buildSlashMenuItems(editor), query)
          }
        />
      </BlockNoteView>

      {selecting && (
        <SelectionActionBar
          count={selectedIds.size}
          onCopy={handleCopy}
          onDelete={handleDelete}
          onCancel={exitSelection}
        />
      )}
      {copyToastVisible && (
        <div className="selection-copy-toast">已复制</div>
      )}
    </>
  );
}

// --- Selection action bar ---

interface SelectionActionBarProps {
  count: number;
  onCopy: () => void;
  onDelete: () => void;
  onCancel: () => void;
}

function SelectionActionBar({
  count,
  onCopy,
  onDelete,
  onCancel,
}: SelectionActionBarProps) {
  const onPrimaryPointerDown =
    (handler: () => void, disabled = false) =>
    (e: any) => {
      e.preventDefault();
      e.stopPropagation();
      if (disabled) return;
      handler();
    };

  return (
    <div className="selection-action-bar" data-selection-chrome="true">
      <div className="selection-action-bar__count">已选 {count}</div>
      <div className="selection-action-bar__spacer" />
      <button
        className="selection-action-bar__btn"
        disabled={count === 0}
        onPointerDown={onPrimaryPointerDown(onCopy, count === 0)}
        onClick={onCopy}
      >
        复制
      </button>
      <button
        className="selection-action-bar__btn selection-action-bar__btn--danger"
        disabled={count === 0}
        onPointerDown={onPrimaryPointerDown(onDelete, count === 0)}
        onClick={onDelete}
      >
        删除
      </button>
      <button
        className="selection-action-bar__btn"
        onPointerDown={onPrimaryPointerDown(onCancel)}
        onClick={onCancel}
      >
        取消
      </button>
    </div>
  );
}

// --- Slash menu trimming ---

// Keep this in lower-case for fast prefix/equality compares against item titles.
const REMOVED_SLASH_TITLES = new Set([
  "quote",
  "code block",
  "table",
  "video",
  "audio",
  "file",
  "emoji",
  "toggle list",
]);

function buildSlashMenuItems(editor: AppEditor) {
  const defaults = getDefaultReactSlashMenuItems(editor);
  const out: any[] = [];
  for (const item of defaults) {
    const title = String(item.title ?? "").toLowerCase().trim();
    if (REMOVED_SLASH_TITLES.has(title)) continue;
    if (title.startsWith("toggle heading")) continue;
    if (/^heading\s+[456]$/.test(title)) continue;
    if (title === "image") {
      out.push({
        ...item,
        onItemClick: () => {
          postToHost({ type: "requestImagePicker", source: "slash" });
        },
      });
      continue;
    }
    out.push(item);
  }
  out.push({
    title: "Divider",
    subtext: "Horizontal rule",
    aliases: ["divider", "hr", "rule", "分割", "分割线", "分隔线"],
    group: "Basic blocks",
    onItemClick: () => {
      const cursor = editor.getTextCursorPosition().block;
      editor.insertBlocks([{ type: "divider" } as any], cursor, "after");
    },
  });
  return out;
}

// --- Block manipulation ---

function moveBlock(editor: AppEditor, payload: MoveBlockPayload) {
  if (!payload?.fromId) return;
  moveBlocks(editor, { ids: [payload.fromId], beforeId: payload.beforeId });
}

function moveBlocks(
  editor: AppEditor,
  payload: { ids?: string[]; beforeId?: string | null }
) {
  const ids = Array.isArray(payload?.ids) ? payload.ids : [];
  if (ids.length === 0) return;

  const doc = editor.document as any[];
  const movedSet = new Set(ids);
  // Preserve document order of moved blocks.
  const orderedMoved = doc.filter((b: any) => movedSet.has(b.id));
  if (orderedMoved.length === 0) return;

  const beforeId = payload?.beforeId ?? null;
  if (beforeId && movedSet.has(beforeId)) return;

  // Use incremental removeBlocks + insertBlocks instead of replaceBlocks.
  // Replacing the entire document forces ProseMirror to rebuild the full DOM,
  // which invalidates any element refs the gesture machine still holds and
  // can cause visible flicker / lost interactions just after a drag.
  try {
    if (beforeId) {
      const target = doc.find((b: any) => b.id === beforeId);
      if (!target) return;
      editor.removeBlocks(orderedMoved.map((b: any) => b.id));
      editor.insertBlocks(orderedMoved as any[], beforeId as any, "before");
    } else {
      // Append to end: find last remaining block after removal.
      const remaining = doc.filter((b: any) => !movedSet.has(b.id));
      const lastId = remaining.length > 0 ? remaining[remaining.length - 1].id : null;
      editor.removeBlocks(orderedMoved.map((b: any) => b.id));
      if (lastId) {
        editor.insertBlocks(orderedMoved as any[], lastId as any, "after");
      } else {
        editor.insertBlocks(orderedMoved as any[], (editor.document as any[])[0]?.id, "before");
      }
    }
  } catch (err) {
    // Fall back to replaceBlocks if incremental ops fail for any reason.
    reportError(`incremental moveBlocks failed: ${(err as Error).message}`);
    const remaining = doc.filter((b: any) => !movedSet.has(b.id));
    if (beforeId == null) {
      editor.replaceBlocks(editor.document, [...remaining, ...orderedMoved]);
      return;
    }
    const toIdx = remaining.findIndex((b: any) => b.id === beforeId);
    if (toIdx === -1) return;
    const next = [...remaining];
    next.splice(toIdx, 0, ...orderedMoved);
    editor.replaceBlocks(editor.document, next);
  }
}

function cssEscape(value: string): string {
  if (typeof CSS !== "undefined" && typeof CSS.escape === "function") {
    return CSS.escape(value);
  }
  return value.replace(/(["\\\]\[])/g, "\\$1");
}

function findBlockElementFromTarget(target: Element | null): HTMLElement | null {
  let cur: HTMLElement | null = target as HTMLElement | null;
  while (cur) {
    if (cur.classList?.contains("bn-block") && cur.dataset?.id) return cur;
    cur = cur.parentElement;
  }
  return null;
}

function findBlockElementById(blockId: string): HTMLElement | null {
  return document.querySelector<HTMLElement>(
    `.bn-block[data-id="${cssEscape(blockId)}"]`
  );
}

function toggleSelectionId(prev: Set<string>, blockId: string): Set<string> {
  const next = new Set(prev);
  if (next.has(blockId)) next.delete(blockId);
  else next.add(blockId);
  return next;
}

function measureBlockRects(
  editor: AppEditor,
  movingSet: Set<string>
): Array<{ id: string; top: number; height: number }> {
  const out: Array<{ id: string; top: number; height: number }> = [];
  const doc = editor.document as any[];
  for (const block of doc) {
    if (movingSet.has(block.id)) continue;
    const el = document.querySelector<HTMLElement>(
      `.bn-block[data-id="${cssEscape(block.id)}"]`
    );
    if (!el) continue;
    const rect = el.getBoundingClientRect();
    out.push({ id: block.id, top: rect.top + window.scrollY, height: rect.height });
  }
  return out;
}

function computeDropTarget(
  clientY: number,
  candidates: Array<{ id: string; top: number; height: number }>
): { beforeId: string | null; y: number } {
  const docY = clientY + window.scrollY;
  if (candidates.length === 0) return { beforeId: null, y: docY };
  let best = { beforeId: candidates[0].id as string | null, y: candidates[0].top };
  let bestDistance = Math.abs(docY - candidates[0].top);
  for (let i = 0; i < candidates.length; i += 1) {
    const c = candidates[i];
    const dTop = Math.abs(docY - c.top);
    if (dTop < bestDistance) {
      bestDistance = dTop;
      best = { beforeId: c.id, y: c.top };
    }
    if (i === candidates.length - 1) {
      const bottom = c.top + c.height;
      const dBottom = Math.abs(docY - bottom);
      if (dBottom < bestDistance) {
        bestDistance = dBottom;
        best = { beforeId: null, y: bottom };
      }
    }
  }
  return best;
}

function applyCommand(editor: AppEditor, kind: CommandPayload["kind"]) {
  const cursorBlock = editor.getTextCursorPosition().block;
  switch (kind.type) {
    case "insertText":
      editor.insertInlineContent(kind.text || "");
      break;
    case "toggleBold":
      editor.toggleStyles({ bold: true });
      break;
    case "heading":
      editor.updateBlock(cursorBlock, {
        type: "heading",
        props: { level: (kind.level ?? 1) as 1 | 2 | 3 },
      } as any);
      break;
    case "bulletList":
      editor.updateBlock(cursorBlock, { type: "bulletListItem" } as any);
      break;
    case "orderedList":
      editor.updateBlock(cursorBlock, { type: "numberedListItem" } as any);
      break;
    case "taskList":
      editor.updateBlock(cursorBlock, { type: "checkListItem" } as any);
      break;
    case "divider":
      editor.insertBlocks(
        [{ type: "divider" } as any],
        cursorBlock,
        "after"
      );
      break;
    case "undo":
      editor._tiptapEditor?.commands?.undo?.();
      break;
    case "redo":
      editor._tiptapEditor?.commands?.redo?.();
      break;
  }
  editor.focus();
}

function insertPlace(editor: AppEditor, place: PlaceData) {
  editor.focus();
  consumeMentionPrefix(editor);
  const node: any = {
    type: "placeRef",
    props: {
      placeId: place.id,
      name: place.name,
      category: place.category || "other",
      emoji: place.emoji || CATEGORY_EMOJI[place.category || "other"] || "📍",
    },
  };
  editor.insertInlineContent([node, " "]);
}

function insertImage(editor: AppEditor, payload: ImageInsertPayload) {
  if (!payload?.url) return;
  const cursor = editor.getTextCursorPosition().block;
  editor.insertBlocks(
    [
      {
        type: "image",
        props: { url: payload.url, caption: payload.caption || "" },
      } as any,
    ],
    cursor,
    "after"
  );
  editor.focus();
}

function consumeMentionPrefix(editor: AppEditor) {
  const tt = editor._tiptapEditor;
  if (!tt) return;
  const { state } = tt;
  const { from } = state.selection;
  const $pos = state.doc.resolve(from);
  const before = $pos.nodeBefore;
  if (!before || !before.isText) return;
  const text = before.text || "";
  const m = text.match(/(?:^|[\s\n])@([^\s\n]*)$/);
  if (!m) return;
  const length = m[0].startsWith("@") ? m[0].length : m[0].length - 1;
  const start = from - length;
  tt.commands.deleteRange({ from: start, to: from });
}

function detectMention(editor: AppEditor): MentionInfo | null {
  const tt = editor._tiptapEditor;
  if (!tt) return null;
  const { state } = tt;
  const { from, empty } = state.selection;
  if (!empty) return null;
  const $pos = state.doc.resolve(from);
  const before = $pos.nodeBefore;
  if (!before || !before.isText) return null;
  const text = before.text || "";
  const m = text.match(/(?:^|[\s\n])@([^\s\n]*)$/);
  if (!m) return null;
  const query = m[1] || "";
  const rect = computeMentionRect(tt);
  return { query, rect };
}

function computeMentionRect(tt: any): MentionInfo["rect"] {
  try {
    const { state, view } = tt;
    const { from } = state.selection;
    const coords = view.coordsAtPos(from);
    const root = view.dom.parentElement?.getBoundingClientRect();
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
