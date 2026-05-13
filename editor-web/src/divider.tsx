import { createReactBlockSpec } from "@blocknote/react";

export const DividerBlock = createReactBlockSpec(
  {
    type: "divider" as const,
    propSchema: {},
    content: "none",
  },
  {
    render: () => (
      <div
        contentEditable={false}
        className="mapote-divider"
        style={{
          display: "flex",
          alignItems: "center",
          width: "100%",
          minHeight: 24,
          padding: "10px 0",
          userSelect: "none",
          cursor: "default",
        }}
      >
        <div
          style={{
            flex: 1,
            height: "0.5px",
            background: "rgba(31, 41, 55, 0.35)",
          }}
        />
      </div>
    ),
    toExternalHTML: () => <hr />,
    parse: (el) => (el.tagName === "HR" ? {} : undefined),
  }
);
