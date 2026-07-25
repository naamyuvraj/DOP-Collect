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
        amber: "#E5A100",
        sidebar: "#14201A",
      },
      fontFamily: {
        sans: ["var(--font-jakarta)", "system-ui", "sans-serif"],
      },
      boxShadow: {
        card: "0 10px 30px rgba(16,27,18,.05)",
      },
      borderRadius: {
        xl2: "20px",
      },
    },
  },
  plugins: [],
};
export default config;
