import type { Metadata } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
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
    <html lang="en" className={`${inter.variable} ${mono.variable}`}>
      <body className="font-sans">{children}</body>
    </html>
  );
}
