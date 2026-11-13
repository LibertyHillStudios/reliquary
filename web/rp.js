/* Other players' writing, as safe HTML. A Total RP 3 profile reaches the page as plain data
   (server/roleplay.py): blocks of runs of text, colours, game icons and links. Here every character
   of text is escaped, a colour must be six hex digits, an icon a whole file id and a link an http(s)
   address; anything else is dropped. app.js draws the rest of a profile around these.
   tests/test_rp.mjs feeds them hostile input. */
(function (root) {
  "use strict";
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const hexColor = (c) => (typeof c === "string" && /^[0-9a-f]{6}$/i.test(c) ? c.toLowerCase() : null);
  const iconId = (i) => { const n = typeof i === "number" ? i : (typeof i === "string" && /^\d+$/.test(i) ? Number(i) : NaN); return Number.isInteger(n) && n > 0 && n < 1e9 ? n : null; };
  const safeUrl = (u) => (typeof u === "string" && /^https?:\/\/[^\s<>"'`]+$/i.test(u) ? u : null);

  function runs(list) {
    return (Array.isArray(list) ? list : []).map((r) => {
      if (!r || typeof r !== "object") return "";
      if (r.br) return "<br>";
      if (r.i !== undefined) {
        const id = iconId(r.i);
        if (!id) return "";
        const px = Math.max(10, Math.min(Number(r.s) || 16, 32));
        return `<img class="rpi" src="/icon/${id}.jpg" alt="" style="width:${px}px;height:${px}px">`;
      }
      const c = hexColor(r.c), style = c ? ` style="color:#${c}"` : "";
      const url = safeUrl(r.u);
      if (url) return `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer nofollow"${style}>${esc(r.t)}</a>`;
      return c ? `<span${style}>${esc(r.t)}</span>` : esc(r.t);
    }).join("");
  }

  // Total RP 3's headings get sizes of their own, apart from a profile's section labels.
  function blocks(list) {
    return (Array.isArray(list) ? list : []).map((b) => {
      if (!b || typeof b !== "object") return "";
      const tag = { h1: "h3", h2: "h4", h3: "h5" }[b.k] || "p";
      const cls = [tag !== "p" ? `rp${b.k}` : "", b.a === "c" ? "ac" : b.a === "r" ? "ar" : ""].filter(Boolean).join(" ");
      return `<${tag}${cls ? ` class="${cls}"` : ""}>${runs(b.r)}</${tag}>`;
    }).join("");
  }

  root.ReliquaryRP = { esc, hexColor, iconId, safeUrl, runs, blocks };
})(typeof window !== "undefined" ? window : globalThis);
