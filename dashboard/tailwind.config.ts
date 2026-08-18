import type { Config } from "tailwindcss";

/**
 * Three-tone system: stark white ground, charcoal for type and structural
 * blocks, one neon lime for active states and positive movement. Nothing else
 * earns a colour, which is what keeps a dense panel calm.
 *
 * Replaces the Soft-UI mint/glass palette. That one leaned on tint, blur and
 * shadow to separate things; this one separates with whitespace and hard edges.
 */
const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        /** Semantic tokens stay variable-driven so a dark block can restate
         *  what "muted" means for its own inside. */
        canvas: "rgb(var(--c-canvas) / <alpha-value>)",
        card: "rgb(var(--c-card) / <alpha-value>)",
        ink: "rgb(var(--c-ink) / <alpha-value>)",
        muted: "rgb(var(--c-muted) / <alpha-value>)",
        faint: "rgb(var(--c-faint) / <alpha-value>)",
        line: "rgb(var(--c-line) / <alpha-value>)",

        /**
         * Sampled from the reference itself rather than guessed: #EDF751, a
         * yellow-lime, with highlights running to #FAFF59. A FILL colour only —
         * on white it is ~1.2:1. Charcoal on it measures 14.7:1, which is the
         * pairing the reference uses everywhere.
         */
        accent: "#EDF751",
        accentDim: "#E2ED3C",
        /** Positive movement as TEXT, where the neon cannot go. */
        positive: "#5C7A00",

        /** Kept for states the three-tone palette genuinely cannot express. */
        red: "#D64545",
        redSoft: "#FBE9E9",
        amber: "#8A6100",
        amberSoft: "#FBF1D2",
        sidebar: "#FFFFFF",
        /** The reference's secondary dark, for nested blocks on charcoal. */
        inkSoft: "#292C2F",
      },
      fontFamily: {
        /** Geometric for display and figures; Inter for dense table body, which
         *  is where a geometric face gets tiring at 13px. */
        sans: ["var(--font-inter)", "system-ui", "sans-serif"],
        display: ["var(--font-display)", "var(--font-inter)", "sans-serif"],
        mono: ["var(--font-mono)", "ui-monospace", "monospace"],
      },
      fontSize: {
        /* Bumped a step across the board. The panel is read at arm's length on
           a desktop, and 11/12px was pushing legibility for no gain. */
        micro: ["12px", { lineHeight: "1.4" }],
        meta: ["13px", { lineHeight: "1.45" }],
        body: ["14px", { lineHeight: "1.55" }],
        base: ["15px", { lineHeight: "1.5" }],
        lead: ["17px", { lineHeight: "1.45" }],
        h1: ["28px", { lineHeight: "1.1", letterSpacing: "-0.03em" }],
      },
      /** Flat UI: no elevation. Kept only for overlays that must float. */
      boxShadow: {
        pop: "0 8px 28px -10px rgba(16,18,15,.22)",
      },
      borderRadius: {
        /** Hard-edged. The accent block on the active nav item is square. */
        xl2: "4px",
      },
    },
  },
  plugins: [],
};
export default config;
