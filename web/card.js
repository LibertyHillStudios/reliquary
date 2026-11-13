/* The link preview card: the character saved most recently, her portrait and one of her places.
   When everything has loaded the page marks <html data-ready="1">. */
(() => {
  "use strict";
  const CLASS_COLORS = {
    DRUID: "#ff7c0a", WARRIOR: "#c69b6d", PALADIN: "#f48cba", HUNTER: "#aad372", ROGUE: "#fff468",
    PRIEST: "#e8e8e8", SHAMAN: "#2b8cff", MAGE: "#3fc7eb", WARLOCK: "#8788ee",
  };
  const ICONS = {
    pin: '<path d="M8 15s5-4.6 5-8.5A5 5 0 0 0 3 6.5C3 10.4 8 15 8 15z" stroke="currentColor" stroke-width="1.5" fill="none"/><circle cx="8" cy="6.5" r="1.8" fill="currentColor"/>',
    banner: '<path d="M4 2v12M4 3h8l-2 3 2 3H4" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linejoin="round"/>',
  };
  const svg = (name) => `<svg viewBox="0 0 16 16" aria-hidden="true">${ICONS[name]}</svg>`;
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const shot = (file, v) => `/shot/${encodeURIComponent(file)}?v=${v}`;
  const card = document.getElementById("card");

  function draw(c) {
    const p = c.profile || {};
    const name = p.first ? [p.first, p.last].filter(Boolean).join(" ") : c.name || "Unknown";
    const photos = c.photos || [];
    const portrait = c.portrait && c.portrait.file;
    // The backdrop: her newest wide shot of a place, else any photo of hers that is not the portrait.
    const scene = ["place", "levelup", "photo", "portrait"].map((k) => photos.find((x) => x.kind === k && x.file !== portrait)).find(Boolean);
    const where = [c.subzone, c.zone].filter(Boolean).filter((v, i, a) => a.indexOf(v) === i).join(", ");
    const side = [c.faction, c.rulesetLabel].filter(Boolean).join(" · ");
    card.innerHTML = `
      ${scene ? `<div class="scene"><img src="${shot(scene.file, "full")}" alt=""></div>` : ""}
      <div class="veil"></div>
      <div class="rule top"></div>
      <div class="words">
        <div class="eyebrow">Reliquary · WoW: Forever</div>
        <h1 class="${name.length > 14 ? "long" : ""}">${esc(name)}</h1>
        ${p.fullTitle ? `<div class="fulltitle">${esc(p.fullTitle)}</div>` : ""}
        <div class="line">Level <b>${esc(c.level ?? "?")}</b> ${esc(c.race || "")} <b style="color:${CLASS_COLORS[c.classFile] || "#a4977e"}">${esc(c.class || "")}</b></div>
        <div class="tags">
          ${where ? `<span class="tag gold">${svg("pin")}${esc(where)}</span>` : ""}
          ${side ? `<span class="tag sky">${svg("banner")}${esc(side)}</span>` : ""}
        </div>
      </div>
      <div class="studio"><img src="art/lhs-mark.svg" alt=""><span><b>Liberty Hill</b><small>Studios</small></span></div>
      ${portrait
        ? `<figure class="her"><img src="${shot(portrait, "tall")}" alt=""><div class="lv"><b>${esc(c.level ?? "?")}</b><small>Level</small></div></figure>`
        : `<figure class="her none"><span class="initial">${esc(name.slice(0, 1))}</span></figure>`}`;
  }

  async function ready() {
    const imgs = [...card.querySelectorAll("img")];
    await Promise.all(imgs.map((img) => (img.complete ? Promise.resolve() : new Promise((r) => { img.onload = img.onerror = r; }))));
    await Promise.all(imgs.map((img) => img.decode().catch(() => {})));
    await document.fonts.ready;
    document.documentElement.dataset.ready = "1";
  }

  fetch("/api/state", { cache: "no-store" })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`state ${r.status}`))))
    .then((state) => {
      const c = (state.chars || [])[0];
      if (c) draw(c);
      return ready();
    })
    .catch(() => { document.documentElement.dataset.ready = "1"; });
})();
