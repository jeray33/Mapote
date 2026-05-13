import { createReactInlineContentSpec } from "@blocknote/react";
import { CATEGORY_COLORS, CATEGORY_EMOJI } from "./types";
import { postToHost } from "./bridge";

export const PlaceInline = createReactInlineContentSpec(
  {
    type: "placeRef" as const,
    propSchema: {
      placeId: { default: "" },
      name: { default: "" },
      category: { default: "other" },
      emoji: { default: "📍" },
    },
    content: "none",
  },
  {
    render: (props) => {
      const { placeId, name, category, emoji } = props.inlineContent.props;
      const color = CATEGORY_COLORS[category] || CATEGORY_COLORS.other;
      const display = `${emoji || CATEGORY_EMOJI[category] || "📍"} ${name}`;
      return (
        <span
          className="place-chip"
          data-place-chip="true"
          data-place-id={placeId}
          data-category={category}
          contentEditable={false}
          onClick={(e) => {
            e.stopPropagation();
            postToHost({ type: "placeTap", placeId });
          }}
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 6,
            margin: "0 2px",
            padding: "4px 11px",
            borderRadius: 999,
            fontSize: 13,
            fontWeight: 700,
            verticalAlign: "baseline",
            userSelect: "none",
            cursor: "pointer",
            background: color.bg,
            color: color.fg,
            boxShadow: "inset 0 0 0 1px rgba(255, 255, 255, 0.3)",
            transition:
              "transform 160ms ease, box-shadow 160ms ease, outline-color 160ms ease",
          }}
        >
          {display}
        </span>
      );
    },
  }
);
