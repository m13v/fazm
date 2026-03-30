/**
 * Fazm Browser Overlay — Init Page Script
 *
 * Used with Playwright MCP --init-page flag.
 * Registers addInitScript on the browser context so the overlay
 * persists across all page navigations, then injects on the current page.
 */
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname2 = typeof __dirname !== 'undefined' ? __dirname : dirname(fileURLToPath(import.meta.url));
const overlayScript = readFileSync(join(__dirname2, 'browser-overlay-init.js'), 'utf-8');

export default async function ({ page }: { page: any }) {
  // Register for all future navigations
  await page.context().addInitScript(overlayScript);
  // Inject on current page immediately
  await page.evaluate(overlayScript).catch(() => {});
}
