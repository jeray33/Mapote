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
  BlockGeometry,
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
  const settingContentRef = useRef(false);
  const pendingRef = useRef<PendingState | null>(null);

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
                postToHost({
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
    [editor]
  );

  useEffect(() => {
    window.editorBridge = {
      setContent: (raw) => {
        const payload = raw as SetContentPayload;
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
      requestGeometry: () => {
        emitGeometry(editor);
      },
    };
    reportReady();
    return () => {
      delete window.editorBridge;
    };
  }, [editor, applyPending]);

  // Geometry: re-emit when DOM mutates, scrolls, or window resizes.
  useEffect(() => {
    let pending = false;
    const schedule = () => {
      if (pending) return;
      pending = true;
      requestAnimationFrame(() => {
        pending = false;
        emitGeometry(editor);
      });
    };
    const root = document.getElementById("root");
    const observer = new MutationObserver(schedule);
    if (root) {
      observer.observe(root, {
        childList: true,
        subtree: true,
        characterData: true,
        attributes: true,
        attributeFilter: ["data-id"],
      });
    }
    const ro = new ResizeObserver(schedule);
    if (root) ro.observe(root);
    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    schedule();
    return () => {
      observer.disconnect();
      ro.disconnect();
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
    };
  }, [editor]);

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
        postToHost({
          type: "contentChanged",
          markdown: md,
          blocks: doc,
          mention,
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
      });
    });
    return () => unsubscribe?.();
  }, [editor]);

  // Focus events
  const onFocus = useCallback(() => {
    postToHost({ type: "focusChanged", focused: true });
  }, []);
  const onBlur = useCallback(() => {
    postToHost({ type: "focusChanged", focused: false });
  }, []);

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
    >
      <SuggestionMenuController
        triggerCharacter="/"
        getItems={async (query) =>
          filterSuggestionItems(buildSlashMenuItems(editor), query)
        }
      />
    </BlockNoteView>
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

function emitGeometry(editor: AppEditor) {
  try {
    const doc = editor.document as Array<{
      id: string;
      type: string;
      props?: any;
    }>;
    const items: BlockGeometry[] = [];
    for (const block of doc) {
      const el = document.querySelector<HTMLElement>(
        `[data-id="${cssEscape(block.id)}"]`
      );
      if (!el) continue;
      const rect = el.getBoundingClientRect();
      const top = rect.top + window.scrollY;
      let kind = block.type;
      if (block.type === "paragraph") {
        const inline = (block as any).content as any[] | undefined;
        if (
          Array.isArray(inline) &&
          inline.length === 1 &&
          inline[0]?.type === "placeRef"
        ) {
          kind = "placeRef-only";
        } else if (
          !Array.isArray(inline) ||
          inline.every(
            (n) => n?.type === "text" && (n.text ?? "").trim() === ""
          )
        ) {
          kind = "empty";
        }
      }
      items.push({
        id: block.id,
        top,
        height: rect.height,
        level: block.type === "heading" ? Number(block.props?.level ?? 1) : 0,
        kind,
      });
    }
    // The last block in a BlockNote document is always a mandatory empty
    // paragraph (ProseMirror invariant — cannot be deleted). Mark it so the
    // native overlay can hide its handle without affecting other empty lines.
    if (
      items.length > 0 &&
      items[items.length - 1].kind === "empty"
    ) {
      const last = items[items.length - 1];
      items[items.length - 1] = { ...last, kind: "trailing-empty" };
    }

    postToHost({
      type: "blocksGeometry",
      items,
      scrollY: window.scrollY,
      docHeight: document.documentElement.scrollHeight,
      viewportHeight: window.innerHeight,
    });
  } catch (err) {
    reportError(`emitGeometry failed: ${(err as Error).message}`);
  }
}

function cssEscape(value: string): string {
  if (typeof CSS !== "undefined" && typeof CSS.escape === "function") {
    return CSS.escape(value);
  }
  return value.replace(/(["\\\]\[])/g, "\\$1");
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
