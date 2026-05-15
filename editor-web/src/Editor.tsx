import { useCallback, useEffect, useRef, useState } from "react";
import {
  BlockNoteSchema,
  defaultBlockSpecs,
  defaultInlineContentSpecs,
  defaultStyleSpecs,
} from "@blocknote/core";
import { BlockNoteView } from "@blocknote/mantine";
import "@blocknote/core/fonts/inter.css";
import "@blocknote/mantine/style.css";
import {
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
}

export function Editor() {
  const editor = useCreateBlockNote({ schema });
  const [locked, setLocked] = useState(false);
  const placesRef = useRef<PlaceData[]>([]);
  const lastEmittedMarkdown = useRef<string>("");
  const lastEmittedBlocksJson = useRef<string>("");
  const lastMentionKey = useRef<string>("");
  const seqRef = useRef<number>(0);
  const settingContentRef = useRef(false);
  const pendingRef = useRef<PendingState | null>(null);
  const contentEmitTimerRef = useRef<number | null>(null);
  const contentDebounceMsRef = useRef<number>(90);

  const emit = useCallback((msg: Record<string, unknown>) => {
    seqRef.current += 1;
    postToHost({ ...msg, seq: seqRef.current });
  }, []);

  const applyPending = useCallback(
    async (state: PendingState) => {
      settingContentRef.current = true;
      let fromMarkdownMigration = false;
      try {
        placesRef.current = state.places;
        let blocks: any[];
        if (Array.isArray(state.blocks) && state.blocks.length > 0) {
          blocks = state.blocks as any[];
        } else {
          blocks = await markdownToBlocks(editor, state.markdown, state.places);
          if (state.markdown && blocks.length > 0) fromMarkdownMigration = true;
        }
        if (blocks.length === 0) {
          editor.replaceBlocks(editor.document, [
            { type: "paragraph" } as any,
          ]);
        } else {
          try {
            editor.replaceBlocks(editor.document, blocks);
          } catch (innerErr) {
            // Schema mismatch (legacy block types removed in current build).
            // Fall back to a blank paragraph rather than wedging the editor.
            reportError(
              `replaceBlocks failed, resetting: ${(innerErr as Error).message}`
            );
            editor.replaceBlocks(editor.document, [
              { type: "paragraph" } as any,
            ]);
            // Sync tracking refs to the now-empty editor so that the next
            // onChange does NOT misread the mismatch as a user edit and
            // overwrite stored content with blank data.
            lastEmittedMarkdown.current = "";
            lastEmittedBlocksJson.current = JSON.stringify(editor.document);
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
                emit({
                  type: "contentChanged",
                  markdown: md,
                  blocks: doc,
                  mention: null,
                });
              })
              .catch((err) =>
                reportError(`migration emit failed: ${(err as Error).message}`)
              );
          }
        }, 30);
      }
    },
    [editor, emit]
  );

  useEffect(() => {
    window.editorBridge = {
      setContent: (raw) => {
        const payload = raw as SetContentPayload;
        const maybeDebounce = Number(payload?.timing?.contentDebounceMs);
        contentDebounceMsRef.current =
          Number.isFinite(maybeDebounce) && maybeDebounce >= 30
            ? Math.round(maybeDebounce)
            : 90;
        const next: PendingState = {
          markdown: payload?.markdown ?? "",
          blocks: payload?.blocks ?? null,
          places: payload?.places ?? [],
          locked: !!payload?.locked,
        };
        pendingRef.current = next;
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
    };
    reportReady();
    return () => {
      delete window.editorBridge;
    };
  }, [editor, applyPending]);

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
        if (contentEmitTimerRef.current != null) {
          window.clearTimeout(contentEmitTimerRef.current);
        }
        contentEmitTimerRef.current = window.setTimeout(() => {
          emit({
            type: "contentChanged",
            markdown: md,
            blocks: doc,
            mention,
          });
          contentEmitTimerRef.current = null;
        }, contentDebounceMsRef.current);
      } catch (err) {
        reportError(`onChange failed: ${(err as Error).message}`);
      }
    });
    return () => {
      if (contentEmitTimerRef.current != null) {
        window.clearTimeout(contentEmitTimerRef.current);
        contentEmitTimerRef.current = null;
      }
      unsubscribe?.();
    };
  }, [editor, emit]);

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
      emit({
        type: "contentChanged",
        markdown: lastEmittedMarkdown.current,
        mention,
      });
    });
    return () => unsubscribe?.();
  }, [editor, emit]);

  // Focus events
  const onFocus = useCallback(() => {
    emit({ type: "focusChanged", focused: true });
  }, [emit]);
  const onBlur = useCallback(() => {
    emit({ type: "focusChanged", focused: false });
  }, [emit]);

  return (
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
    />
  );
}

// --- Block manipulation ---

function moveBlock(editor: AppEditor, payload: MoveBlockPayload) {
  if (!payload?.fromId) return;
  const doc = editor.document as any[];
  const fromIdx = doc.findIndex((b: any) => b.id === payload.fromId);
  if (fromIdx === -1) return;
  if (payload.beforeId === payload.fromId) return;

  // Reorder in one replaceBlocks call so BlockNote sees it as a single
  // transaction — avoids the spurious empty paragraph that appears when
  // using separate removeBlocks + insertBlocks calls.
  const reordered = [...doc];
  const [moved] = reordered.splice(fromIdx, 1);

  if (payload.beforeId == null) {
    reordered.push(moved);
  } else {
    const toIdx = reordered.findIndex((b: any) => b.id === payload.beforeId);
    if (toIdx === -1) return;
    reordered.splice(toIdx, 0, moved);
  }

  editor.replaceBlocks(editor.document, reordered);
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
