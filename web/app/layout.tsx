import type { Metadata, Viewport } from "next";
import "./globals.css";
import PostHogInit from "@/components/PostHogInit";

export const metadata: Metadata = {
  title: "Fazm",
  description: "Your desktop AI, from your phone",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
  themeColor: "#0a0a0a",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>
        <PostHogInit />
        {children}
      </body>
    </html>
  );
}
