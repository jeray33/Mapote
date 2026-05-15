import type { BlockNoteEditor } from "@blocknote/core";
import { CATEGORY_EMOJI, type PlaceData } from "./types";

const PLACE_DIRECTIVE = /::place\[([^\]]*)\]\{#([^}]+)\}/g;
// Unicode private-use sentinels keep us out of the way of normal markdown.
const SENTINEL_OPEN = "\uE000PLACE\uE001";
const SENTINEL_CLOSE = "\uE002";

interface PlaceLookup {
  byId: Record<string, PlaceData>;
}

function buildLookup(places: PlaceData[]): PlaceLookup {
  return {
    byId: Object.fromEntries(places.map((p) => [p.id, p])),
  };
}

function encodeMarkdown(markdown: string): string {
  return markdown.replace(PLACE_DIRECTIVE, (_match, name: string, id: string) => {
    const safeName = name.replace(/\|/g, "\\|");
    const safeId = id.replace(/\|/g, "\\|");
    return `${SENTINEL_OPEN}${safeId}|${safeName}${SENTINEL_CLOSE}`;
  });
}

const SENTINEL_PATTERN = new RegExp(
  `${SENTINEL_OPEN}([^|]+)\\|([^${SENTINEL_CLOSE}]*)${SENTINEL_CLOSE}`,
  "g"
);

function placeInlineFor(
  id: string,
  fallbackName: string,
  lookup: PlaceLookup
) {
  const match = lookup.byId[id];
  const name = match?.name ?? fallbackName;
  const category = match?.category ?? "other";
  const emoji = match?.emoji ?? CATEGORY_EMOJI[category] ?? "📍";
  return {
    type: "placeRef" as const,
    props: { placeId: id, name, category, emoji },
  };
}

// Walk BlockNote blocks and replace any text spans containing sentinel markers
// with proper placeRef inline content nodes.
function expandSentinels(blocks: any[], lookup: PlaceLookup): any[] {
  for (const block of blocks) {
    if (Array.isArray(block.content)) {
      block.content = expandInline(block.content, lookup);
    }
    if (Array.isArray(block.children) && block.children.length > 0) {
      expandSentinels(block.children, lookup);
    }
  }
  return blocks;
}

function expandInline(content: any[], lookup: PlaceLookup): any[] {
  const out: any[] = [];
  for (const node of content) {
    if (node.type === "text" && typeof node.text === "string") {
      const split = splitTextWithPlaceTokens(node.text, node.styles ?? {}, lookup);
      out.push(...split);
    } else {
      out.push(node);
    }
  }
  return out;
}

function splitTextWithPlaceTokens(
  text: string,
  styles: Record<string, unknown>,
  lookup: PlaceLookup
): any[] {
  const out: any[] = [];
  let lastIndex = 0;
  SENTINEL_PATTERN.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = SENTINEL_PATTERN.exec(text)) !== null) {
    if (match.index > lastIndex) {
      out.push({
        type: "text",
        text: text.slice(lastIndex, match.index),
        styles,
      });
    }
    const id = match[1];
    const name = match[2];
    out.push(placeInlineFor(id, name, lookup));
    lastIndex = match.index + match[0].length;
  }
  if (lastIndex < text.length) {
    out.push({
      type: "text",
      text: text.slice(lastIndex),
      styles,
    });
  }
  if (out.length === 0) {
    out.push({ type: "text", text: "", styles });
  }
  return out;
}

export async function markdownToBlocks(
  editor: BlockNoteEditor<any, any, any>,
  markdown: string,
  places: PlaceData[]
) {
  const lookup = buildLookup(places);
  const encoded = encodeMarkdown(markdown ?? "");
  const blocks = await editor.tryParseMarkdownToBlocks(encoded);
  return expandSentinels(blocks, lookup);
}

// Reverse: replace placeRef inline content with sentinel text, run lossy
// markdown export, then unwrap sentinels back to ::place[name]{#id}.
function collapsePlaceRefs(blocks: any[]): any[] {
  return blocks.map((block) => {
    const next = { ...block };
    if (Array.isArray(block.content)) {
      next.content = block.content.map((node: any) => {
        if (node.type === "placeRef") {
          const { placeId, name } = node.props;
          return {
            type: "text",
            text: `${SENTINEL_OPEN}${placeId}|${name}${SENTINEL_CLOSE}`,
            styles: {},
          };
        }
        return node;
      });
    }
    if (Array.isArray(block.children) && block.children.length > 0) {
      next.children = collapsePlaceRefs(block.children);
    }
    return next;
  });
}

const DECODE_PATTERN = new RegExp(
  `${SENTINEL_OPEN}([^|]+)\\|([^${SENTINEL_CLOSE}]*)${SENTINEL_CLOSE}`,
  "g"
);

export async function blocksToMarkdown(
  editor: BlockNoteEditor<any, any, any>,
  blocks: any[]
): Promise<string> {
  const collapsed = collapsePlaceRefs(blocks);
  const md = await editor.blocksToMarkdownLossy(collapsed as any);
  return md.replace(DECODE_PATTERN, (_m, id, name) => {
    return `::place[${name}]{#${id}}`;
  });
}
