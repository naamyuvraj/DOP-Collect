import type { Config } from "tailwindcss";

// Mirrors the DOP Collect app's Soft-UI FinTech palette.
const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        canvas: "#E7F0E9",
        card: "#FFFFFF",
        ink: "#14201A",
        muted: "#5B6B62",
        faint: "#95A69C",
        line: "#E3ECE5",
        green: "#21A06A",
        greenSoft: "#DCF0E5",
        yellow: "#EFE94C",
        focal: "#F0EE8F",
        red: "#E15B5B",
        redSoft: "#FBE3E3",
        blue: "#2E3A8C",
        blueSoft: "#E1E6FA",
        amber: "#9A6E00",
        // The soft partner the other tones already had. `focal` (#F0EE8F) is a
        // saturated highlighter — fine as a 4px accent, wrong as a fill behind text.
        amberSoft: "#FBF1D2",
        sidebar: "#14201A",
      },
      fontFamily: {
        sans: ["var(--font-inter)", "system-ui", "sans-serif"],
        mono: ["var(--font-mono)", "ui-monospace", "monospace"],
      },
      /**
       * One scale, named by role. Sizes were nine unrelated arbitrary values
       * before, so nothing lined up and every new element invented its own.
       * Line heights ride along, because a size without one is half a decision.
       */
      fontSize: {
        micro: ["11px", { lineHeight: "1.4" }],
        meta: ["12px", { lineHeight: "1.45" }],
        body: ["13px", { lineHeight: "1.5" }],
        base: ["14px", { lineHeight: "1.5" }],
        lead: ["15px", { lineHeight: "1.45" }],
        h1: ["20px", { lineHeight: "1.2", letterSpacing: "-0.02em" }],
      },
      /**
       * NOT named `card`. `colors.card` is #FFFFFF, and `shadow-card` matches a
       * shadow *colour* too — Tailwind emitted both and the colour won, so every
       * card has been drawing a white shadow (i.e. none) since the palette was
       * written. Any key here must stay clear of the colour names above.
       *
       * Tight and close rather than a wide soft bloom: a crisp surface, not a
       * floating pillow.
       */
      boxShadow: {
        elev: "0 1px 2px rgba(16,27,18,.04), 0 6px 16px -6px rgba(16,27,18,.08)",
        elevHover: "0 1px 2px rgba(16,27,18,.05), 0 10px 24px -8px rgba(16,27,18,.13)",
      },
      borderRadius: {
        xl2: "14px",
      },
    },
  },
  plugins: [],
};
export default config;
