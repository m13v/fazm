/**
 * Fazm Browser Overlay — Init Page Script (CommonJS).
 *
 * Loaded by Playwright MCP's --init-page flag via requireOrImport() in
 * node_modules/playwright/lib/mcp/browser/tab.js, which destructures
 * `{ default: func }` from the module, so we must expose the handler as
 * `module.exports.default` (not `module.exports =`).
 *
 * File extension MUST be .cjs because acp-bridge/package.json sets
 * "type": "module" — a plain .js file would be treated as ESM and fail
 * to load with "require is not defined in ES module scope".
 *
 * In extension mode (CDP connection) addInitScript is a no-op, so we
 * also inject directly via page.evaluate for the current page.
 */
const { readFileSync } = require('fs');
const { join } = require('path');

const overlayScript = readFileSync(join(__dirname, 'browser-overlay-init.js'), 'utf-8');

module.exports.default = async function ({ page }) {
  try {
    await page.context().addInitScript(overlayScript);
  } catch (e) {}
  try {
    await page.evaluate(overlayScript);
  } catch (e) {}
};
