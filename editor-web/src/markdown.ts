import { CATEGORY_EMOJI, type PlaceData } from "./types";

const PLACE_DIRECTIVE = /::place\[([^\]]*)\]\{#([^}]+)\}/g;

type JsonNode = Record<string, any>;

function placeFor(id: string, fallbackName: string, places: PlaceData[]): JsonNode {
  const match = places.find((p) => p.id === id || p.raw === id);
  const category = match?.category ?? "other";
  return {
    type: "placeRef",
    attrs: {
      placeId: id,
      name: match?.name ?? fallbackName,
      category,
      emoji: match?.emoji ?? CATEGORY_EMOJI[category] ?? "📍",
    },
  };
}

export function markdownToTiptapBlocks(markdown: string, places: PlaceData[]): JsonNode[] {
  const lines = (markdown ?? "").split(/\r?\n/);
  const blocks: JsonNode[] = [];
  let paragraph: string[] = [];

  const flushParagraph = () => {
    const text = paragraph.join("\n").trimEnd();
    paragraph = [];
    if (!text.trim()) return;
    blocks.push({ type: "paragraph", content: parseInline(text, places) });
  };

  for (const raw of lines) {
    const line = raw.trimEnd();
    if (!line.trim()) {
      flushParagraph();
      continue;
    }
    const heading = line.match(/^(#{1,3})\s+(.*)$/);
    if (heading) {
      flushParagraph();
      blocks.push({
        type: "heading",
        attrs: { level: heading[1].length },
        content: parseInline(heading[2], places),
      });
      continue;
    }
    if (/^---+$/.test(line.trim())) {
      flushParagraph();
      blocks.push({ type: "divider" });
      continue;
    }
    const image = line.match(/^!\[[^\]]*\]\(([^)]+)\)$/);
    if (image) {
      flushParagraph();
      blocks.push({ type: "image", attrs: { src: image[1] } });
      continue;
    }
    const task = line.match(/^- \[([ xX])\]\s+(.*)$/);
    if (task) {
      flushParagraph();
      blocks.push({
        type: "taskList",
        content: [
          {
            type: "taskItem",
            attrs: { checked: task[1].toLowerCase() === "x" },
            content: [{ type: "paragraph", content: parseInline(task[2], places) }],
          },
        ],
      });
      continue;
    }
    const bullet = line.match(/^[-*+]\s+(.*)$/);
    if (bullet) {
      flushParagraph();
      blocks.push({
        type: "bulletList",
        content: [
          { type: "listItem", content: [{ type: "paragraph", content: parseInline(bullet[1], places) }] },
        ],
      });
      continue;
    }
    const ordered = line.match(/^\d+\.\s+(.*)$/);
    if (ordered) {
      flushParagraph();
      blocks.push({
        type: "orderedList",
        content: [
          { type: "listItem", content: [{ type: "paragraph", content: parseInline(ordered[1], places) }] },
        ],
      });
      continue;
    }
    paragraph.push(line);
  }
  flushParagraph();
  return blocks.length > 0 ? blocks : [{ type: "paragraph" }];
}

function parseInline(text: string, places: PlaceData[]): JsonNode[] {
  const out: JsonNode[] = [];
  let last = 0;
  PLACE_DIRECTIVE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = PLACE_DIRECTIVE.exec(text)) !== null) {
    if (match.index > last) out.push(textNode(text.slice(last, match.index)));
    out.push(placeFor(match[2], match[1], places));
    last = match.index + match[0].length;
  }
  if (last < text.length) out.push(textNode(text.slice(last)));
  return out.length > 0 ? out : undefined as unknown as JsonNode[];
}

function textNode(text: string): JsonNode {
  return { type: "text", text };
}

export function tiptapBlocksToMarkdown(blocks: JsonNode[]): string {
  return blocks.map(blockToMarkdown).filter(Boolean).join("\n\n");
}

function blockToMarkdown(node: JsonNode): string {
  switch (node.type) {
    case "heading":
      return `${"#".repeat(node.attrs?.level ?? 1)} ${inlineToMarkdown(node.content ?? [])}`;
    case "paragraph":
      return inlineToMarkdown(node.content ?? []);
    case "divider":
      return "---";
    case "image":
      return node.attrs?.src ? `![](${node.attrs.src})` : "";
    case "bulletList":
      return (node.content ?? []).map((item: JsonNode) => `- ${listItemText(item)}`).join("\n");
    case "orderedList":
      return (node.content ?? [])
        .map((item: JsonNode, idx: number) => `${idx + 1}. ${listItemText(item)}`)
        .join("\n");
    case "taskList":
      return (node.content ?? [])
        .map((item: JsonNode) => `- [${item.attrs?.checked ? "x" : " "}] ${listItemText(item)}`)
        .join("\n");
    default:
      return inlineToMarkdown(node.content ?? []);
  }
}

function listItemText(item: JsonNode): string {
  const paragraph = (item.content ?? []).find((node: JsonNode) => node.type === "paragraph");
  return paragraph ? inlineToMarkdown(paragraph.content ?? []) : inlineToMarkdown(item.content ?? []);
}

function inlineToMarkdown(content: JsonNode[]): string {
  return content.map(inlineNodeToMarkdown).join("");
}

function inlineNodeToMarkdown(node: JsonNode): string {
  if (node.type === "placeRef") {
    const attrs = node.attrs ?? node.props ?? {};
    return `::place[${attrs.name ?? "地点"}]{#${attrs.placeId ?? attrs.id ?? ""}}`;
  }
  if (node.type !== "text") return inlineToMarkdown(node.content ?? []);
  let text = node.text ?? "";
  for (const mark of node.marks ?? []) {
    if (mark.type === "bold") text = `**${text}**`;
    if (mark.type === "italic") text = `*${text}*`;
    if (mark.type === "code") text = `\`${text}\``;
  }
  return text;
}

export function normalizeIncomingBlocks(blocks: unknown[] | null | undefined, markdown: string, places: PlaceData[]): JsonNode[] {
  if (!Array.isArray(blocks) || blocks.length === 0) {
    return markdownToTiptapBlocks(markdown, places);
  }
  return blocks.map((block) => normalizeNode(block as JsonNode, places)).filter(Boolean);
}

function normalizeNode(node: JsonNode, places: PlaceData[]): JsonNode {
  if (!node || typeof node !== "object") return { type: "paragraph" };
  if (node.attrs || node.marks || isTiptapType(node.type)) {
    return normalizeTiptapNode(node, places);
  }
  return normalizeLegacyBlockNode(node, places);
}

function isTiptapType(type: string): boolean {
  return [
    "paragraph",
    "heading",
    "text",
    "bulletList",
    "orderedList",
    "listItem",
    "taskList",
    "taskItem",
    "image",
    "divider",
    "placeRef",
  ].includes(type);
}

function normalizeTiptapNode(node: JsonNode, places: PlaceData[]): JsonNode {
  if (node.type === "placeRef" && node.props && !node.attrs) {
    return { type: "placeRef", attrs: node.props };
  }
  const next = { ...node };
  if (Array.isArray(node.content)) next.content = node.content.map((child) => normalizeNode(child, places));
  return next;
}

function normalizeLegacyBlockNode(node: JsonNode, places: PlaceData[]): JsonNode {
  const content = normalizeInline(node.content ?? [], places);
  switch (node.type) {
    case "heading":
      return { type: "heading", attrs: { level: node.props?.level ?? 1 }, content };
    case "bulletListItem":
      return { type: "bulletList", content: [{ type: "listItem", content: [{ type: "paragraph", content }] }] };
    case "numberedListItem":
      return { type: "orderedList", content: [{ type: "listItem", content: [{ type: "paragraph", content }] }] };
    case "checkListItem":
      return { type: "taskList", content: [{ type: "taskItem", attrs: { checked: !!node.props?.checked }, content: [{ type: "paragraph", content }] }] };
    case "image":
      return { type: "image", attrs: { src: node.props?.url ?? node.props?.src ?? "" } };
    case "divider":
      return { type: "divider" };
    default:
      return { type: "paragraph", content };
  }
}

function normalizeInline(content: JsonNode[], places: PlaceData[]): JsonNode[] | undefined {
  if (!Array.isArray(content) || content.length === 0) return undefined;
  const out = content.map((node) => {
    if (node.type === "placeRef") return { type: "placeRef", attrs: node.attrs ?? node.props ?? {} };
    if (node.type === "text") {
      const marks = [];
      if (node.styles?.bold) marks.push({ type: "bold" });
      if (node.styles?.italic) marks.push({ type: "italic" });
      if (node.styles?.code) marks.push({ type: "code" });
      return { type: "text", text: node.text ?? "", ...(marks.length ? { marks } : {}) };
    }
    return normalizeNode(node, places);
  });
  return out.length > 0 ? out : undefined;
}
