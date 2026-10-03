import type { Metadata } from "next";
import { Inter, Space_Grotesk, JetBrains_Mono } from "next/font/google";
import "./globals.css";

/**
 * Inter over Plus Jakarta Sans: this is a dense numeric panel, and it wants a
 * neutral face that disappears, not a geometric one with personality. `cv11`
 * gives the single-storey `l`/`1` that keeps agent ids and versions readable.
 */
const inter = Inter({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-inter",
});

/**
 * The geometric face, for display: headings, KPI figures, nav, card titles.
 * Inter stays for table and body text, where a geometric face gets tiring at
 * 13px across a dense grid — the reference's own body copy is far sparser than
 * this panel's.
 */
const display = Space_Grotesk({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-display",
});

/** Agent ids, phone hashes, versions, provider references. */
const mono = JetBrains_Mono({
  subsets: ["latin"],
  weight: ["400", "500"],
  variable: "--font-mono",
});

export const metadata: Metadata = {
  title: "DOP Collect · Admin",
  description: "Analytics & management for DOP Collect",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={`${inter.variable} ${display.variable} ${mono.variable}`}>
      <body className="font-sans">{children}</body>
    </html>
  );
}
