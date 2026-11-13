// Screenshots of the dashboard at desktop and phone size, plus a hovered tooltip, and of the
// Guild, Friends and Public views (use the sample data, ?demo=1, to see them filled in).
// node tools/shoot.mjs <url> <outdir>
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_PATH || "playwright");
const [url, out] = process.argv.slice(2);
const browser = await chromium.launch({ args: ["--mute-audio"], executablePath: process.env.CHROME_PATH || undefined });
const errors = [];
const at = (view) => { const u = new URL(url); u.hash = view; return u.toString(); };
async function shot(name, viewport, opts = {}) {
  const page = await browser.newPage({ viewport, deviceScaleFactor: opts.dpr || 1, isMobile: !!opts.mobile, hasTouch: !!opts.mobile });
  page.on("console", (m) => { if (m.type() === "error") errors.push(`${name}: ${m.text()}`); });
  page.on("pageerror", (e) => errors.push(`${name}: ${e.message}`));
  await page.goto(opts.view ? at(opts.view) : url, { waitUntil: "load" });
  await page.waitForTimeout(1600);
  if (opts.before) await opts.before(page);
  await page.screenshot({ path: `${out}/${name}.png`, fullPage: true });
  if (opts.hover) {
    for (const [sel, label] of opts.hover) {
      const el = page.locator(sel).first();
      await el.scrollIntoViewIfNeeded();
      await el.hover();
      await page.waitForTimeout(400);
      await page.screenshot({ path: `${out}/${name}-${label}.png` });
    }
  }
  if (opts.tap) {
    const el = page.locator(opts.tap).first();
    await el.scrollIntoViewIfNeeded();
    await el.tap();
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${out}/${name}-tap.png` });
  }
  await page.close();
}
const desktop = { width: 1440, height: 900 };
const phone = { width: 390, height: 844 };
await shot("desktop", desktop, { hover: [['[data-tip="gear:11"]', "ring"], ['[data-tip^="talent:"]', "talent"]] });
await shot("phone", phone, { dpr: 2, mobile: true, tap: '[data-tip="gear:16"]' });
await shot("guild", desktop, { view: "guild", hover: [['[data-stip^="pgear|"]', "gear"], ['[data-stip^="gb|"]', "bank"]] });
await shot("guild-search", desktop, { view: "guild", before: async (page) => {
  await page.fill("#bankSearch", "silverleaf");
  await page.waitForTimeout(300);
  await page.locator("#bankCard").scrollIntoViewIfNeeded();
} });
await shot("guild-phone", phone, { view: "guild", dpr: 2, mobile: true, tap: '[data-stip^="gb|"]' });
await shot("friends", desktop, { view: "friends" });
await shot("public", desktop, { view: "public" });
await shot("public-phone", phone, { view: "public", dpr: 2, mobile: true });
await browser.close();
console.log(errors.length ? errors.join("\n") : "no console errors");
