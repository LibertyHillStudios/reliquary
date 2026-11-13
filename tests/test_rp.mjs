// The page's renderer for other players' writing (web/rp.js), fed hostile input: tags in text, script
// addresses, quotes in links, styles posing as colours, attributes posing as icon ids, headings that
// aren't. Nothing may come out as markup but what rp.js writes itself.
//     node tests/test_rp.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const ctx = { window: {} };
vm.runInNewContext(readFileSync(join(here, "..", "web", "rp.js"), "utf8"), ctx);
const { runs, blocks } = ctx.window.ReliquaryRP;
let failed = 0;
function check(ok, what) {
  if (!ok) { failed++; console.error("FAIL " + what); }
}

const evil = runs([{ t: '<img src=x onerror=alert(1)>"\'&' }]);
check(evil === "&lt;img src=x onerror=alert(1)&gt;&quot;&#39;&amp;", "text is escaped: " + evil);
check(runs([{ t: "a", c: "red;background:url(javascript:x)" }]) === "a", "a style posing as a colour is dropped");
check(runs([{ t: "a", c: "FF00aa" }]) === '<span style="color:#ff00aa">a</span>', "a real colour stays");
check(runs([{ t: "click", u: "javascript:alert(1)" }]) === "click", "a script address is never a link");
check(runs([{ t: "x", u: 'https://example.com/"onmouseover=alert(1)' }]) === "x", "an address with a quote is never a link");
check(runs([{ t: "<b>site</b>", u: "https://example.com/a?b=1&c=2" }]) ===
  '<a href="https://example.com/a?b=1&amp;c=2" target="_blank" rel="noopener noreferrer nofollow">&lt;b&gt;site&lt;/b&gt;</a>', "a real link, its text escaped");
check(runs([{ i: '1" onerror="alert(1)' }]) === "", "an attribute posing as an icon id is dropped");
check(runs([{ i: 134141, s: 999 }]) === '<img class="rpi" src="/icon/134141.jpg" alt="" style="width:32px;height:32px">', "an icon, its size capped");
check(runs([{ br: 1 }, null, "<script>", { t: "ok" }]) === "<br>ok", "line breaks; junk entries dropped");
check(blocks([{ k: 'h1" onclick="x', r: [{ t: "h" }] }]) === "<p>h</p>", "a heading that isn't one is a paragraph");
check(blocks([{ k: "h2", a: "c", r: [{ t: "T" }] }]) === '<h4 class="rph2 ac">T</h4>', "a centred heading");
check(blocks([{ k: "p", a: 'r" onclick="x', r: [{ t: "p" }] }]) === "<p>p</p>", "an alignment that isn't one is dropped");
check(blocks("<script>") === "" && runs({ t: "x" }) === "", "something that isn't a list draws nothing");
if (failed) process.exit(1);
console.log("page renderer ok: other players' text, colours, icons and links come out escaped or not at all");
