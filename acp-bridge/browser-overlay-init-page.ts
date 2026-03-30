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
  console.error('[fazm-overlay] init-page script running, page URL:', page.url());
  // Register for all future navigations
  await page.context().addInitScript(overlayScript);
  console.error('[fazm-overlay] addInitScript registered');
  // Inject on current page immediately
  await page.evaluate(overlayScript).catch((e: any) => {
    console.error('[fazm-overlay] evaluate error:', e.message);
  });
  console.error('[fazm-overlay] evaluate completed');
}
