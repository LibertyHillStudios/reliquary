/* Reliquary dashboard: draws one character from /api/state and redraws whenever the
   game saves (the server's /api/events stream). Plain script, no build step. */
(() => {
  "use strict";

  const params = new URLSearchParams(location.search);
  const DEMO = params.get("demo") === "1";
  const app = document.getElementById("app");
  const tipEl = document.getElementById("tip");
  const backdrop = document.getElementById("sheetBackdrop");
  const pageEl = document.getElementById("itemPage");
  const viewer = document.getElementById("viewer");
  const detail = document.getElementById("detail");

  let state = null;
  let current = null;       // selected character key
  let bagView = "bags";
  let bagQuery = "";
  let firstPaint = true;
  let albumAll = false;
  let questsAll = false;
  let viewFile = null;      // the photo open in the viewer
  let viewReturn = null;    // where focus goes when the viewer closes

  // ── Formatting ────────────────────────────────────────────────────────────
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  // The public copy (reliquary.libertyhillstudio.com) is read-only, for friends to look at.
  const isPublic = () => Boolean(state && state.public);
  // A part a character keeps off the public copy: the server has already left its data out.
  const hides = (c, part) => Boolean(c && c.hidden && c.hidden.includes(part));
  const n = (v) => (typeof v === "number" ? v.toLocaleString("en-US") : "-");
  const pct = (a, b) => (b > 0 ? Math.max(0, Math.min(1, a / b)) : 0);

  function money(copper, compact) {
    if (typeof copper !== "number") return "-";
    const g = Math.floor(copper / 10000), s = Math.floor((copper % 10000) / 100), c = copper % 100;
    const parts = [];
    if (g) parts.push(`<span class="coin coin-g">${n(g)}</span>`);
    if (s || (g && !compact)) parts.push(`<span class="coin coin-s">${s}</span>`);
    if (!compact || !g) parts.push(`<span class="coin coin-c">${c}</span>`);
    return parts.join("");
  }

  function played(sec) {
    if (typeof sec !== "number") return "-";
    const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    return `${m}m`;
  }

  function ago(ts) {
    if (!ts) return "never";
    const s = Math.max(0, Date.now() / 1000 - ts);
    if (s < 45) return "just now";
    if (s < 3600) return `${Math.round(s / 60)} min ago`;
    if (s < 86400) return `${Math.round(s / 3600)} h ago`;
    const d = Math.round(s / 86400);
    return d === 1 ? "yesterday" : `${d} days ago`;
  }

  function day(ts) {
    return ts ? new Date(ts * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric" }) : "";
  }

  function when(ts) {
    if (!ts) return "";
    const d = new Date(ts * 1000);
    const sameYear = d.getFullYear() === new Date().getFullYear();
    return `${d.toLocaleDateString("en-US", { month: "short", day: "numeric", ...(sameYear ? {} : { year: "numeric" }) })}, ${d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })}`;
  }

  // ── Game knowledge ────────────────────────────────────────────────────────
  const CLASS = {
    DRUID: { c: "#ff7c0a", tabs: ["Balance", "Feral Combat", "Restoration"] },
    WARRIOR: { c: "#c69b6d", tabs: ["Arms", "Fury", "Protection"] },
    PALADIN: { c: "#f48cba", tabs: ["Holy", "Protection", "Retribution"] },
    HUNTER: { c: "#aad372", tabs: ["Beast Mastery", "Marksmanship", "Survival"] },
    ROGUE: { c: "#fff468", tabs: ["Assassination", "Combat", "Subtlety"] },
    PRIEST: { c: "#e8e8e8", tabs: ["Discipline", "Holy", "Shadow"] },
    SHAMAN: { c: "#2b8cff", tabs: ["Elemental", "Enhancement", "Restoration"] },
    MAGE: { c: "#3fc7eb", tabs: ["Arcane", "Fire", "Frost"] },
    WARLOCK: { c: "#8788ee", tabs: ["Affliction", "Demonology", "Destruction"] },
  };
  const TAB_TINTS = ["rgba(186,204,236,.09)", "rgba(212,84,43,.09)", "rgba(95,184,122,.09)"];
  const classColor = (c) => (CLASS[c.classFile] || {}).c || "rgb(164,151,126)";

  const SLOT = {
    1: "Head", 2: "Neck", 3: "Shoulder", 4: "Shirt", 5: "Chest", 6: "Waist", 7: "Legs", 8: "Feet", 9: "Wrist", 10: "Hands",
    11: "Finger", 12: "Finger", 13: "Trinket", 14: "Trinket", 15: "Back", 16: "Main Hand", 17: "Off Hand", 18: "Ranged", 19: "Tabard",
  };
  const LEFT = [1, 2, 3, 15, 5, 4, 19, 9];
  const RIGHT = [10, 6, 7, 8, 11, 12, 13, 14];
  const WEAPONS = [16, 17, 18];

  const STANDING = [
    null,
    ["Hated", "#c2402f"], ["Hostile", "#e0604f"], ["Unfriendly", "#e8b04a"], ["Neutral", "#e8d27a"],
    ["Friendly", "#5fb87a"], ["Honored", "#49c39a"], ["Revered", "#6fc7c2"], ["Exalted", "#9fd0ff"],
  ];

  const isJoan = (c) => /^Joan\b/.test(c.name || "") && c.classFile === "DRUID" &&
    (/(Of[aâ]rc)/i.test(c.name) || (c.profile && /Of[aâ]rc/i.test(c.profile.last || "")) || c.name === "Joan");

  function fullName(c) {
    const p = Object.assign({}, c.profileDraft || {}, c.profile || {});
    if (p.first) return [p.first, p.last].filter(Boolean).join(" ");
    return c.name || "Unknown";
  }

  // ── Icons ─────────────────────────────────────────────────────────────────
  function icon(id, q, size, extra = "") {
    const s = size ? ` style="--s:${size}px"` : "";
    if (!id) return `<span class="ico q${q ?? 1} hollow"${s}><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5 13.5 8 8 13.5 2.5 8z" fill="none" stroke="currentColor" stroke-width="1"/></svg>${extra}</span>`;
    return `<span class="ico q${q ?? 1}"${s}><span class="fallback">?</span><img src="/icon/${id}.jpg" alt="" decoding="async">${extra}</span>`;
  }

  // ── Data lookups for tooltips ─────────────────────────────────────────────
  const char = () => (state && state.chars.find((c) => c.key === current)) || null;

  // Everyone in the guild who can equip an item, best help first, from the guild that lists it
  // (your character's own guild first).
  function fitsFor(id) {
    const c = char();
    const guilds = (state && state.guilds) || [];
    const has = (g) => g.fits && g.fits[String(id)];
    const g = guilds.find((x) => c && x.name === c.guild && has(x)) || guilds.find(has);
    return g ? g.fits[String(id)] : [];
  }
  // An item's auction price for the character on screen: their realm's house on their own side
  // first, then the newest word anywhere. { p, q, at, live, more, house, h } or null.
  // The newest price of an item for the game's tooltips, from the houses this character can use: its
  // realm's own faction's and its neutral one, its own faction's first.
  function priceFor(id) {
    const list = (state && state.prices && state.prices.items && state.prices.items[String(id)]) || [];
    if (!list.length) return null;
    const c = char();
    const houses = state.prices.houses || {};
    const ranked = list.filter((w) => {
      const h = houses[w.house] || {};
      return !c || (h.realm === c.realm && (h.side === c.faction || h.side === "Neutral"));
    }).map((w) => {
      const h = houses[w.house] || {};
      return Object.assign({}, w, { h, rank: (c && h.realm === c.realm ? 2 : 0) + (c && h.side === c.faction ? 1 : 0) });
    });
    if (!ranked.length) return null;
    ranked.sort((a, b) => (b.rank - a.rank) || (b.at - a.at));
    return ranked[0];
  }
  const stacks = (id) => ((state && state.itemInfo && state.itemInfo[String(id)]) || {}).stack > 1;

  // Who a guild bank item is set aside for and who asked for it (the addon's board), from the tab
  // that holds it, or null.
  function boardFor(id) {
    for (const g of (state && state.guilds) || []) {
      for (const t of g.bank.tabs || []) {
        const b = t.board && t.board[String(id)];
        if (b) return { aside: b.aside || [], asks: b.asks || [], g };
      }
    }
    return null;
  }
  // "you", or a guildmate's name as the guild list gives it.
  const wordName = (g, w) => (g.members.some((m) => m.key === w.who && m.me) ? "you" : w.name);
  const joinNames = (names) => (names.length < 2 ? names[0] || "" : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`);

  // "Upgrade for Thalia and you", or "" when it helps nobody now (but those in `skip`).
  function upgradeWords(id, skip) {
    const names = fitsFor(id).filter((x) => x.v === "up" && !(skip && skip.has(x.who))).map((x) => (x.me ? "you" : x.name));
    if (!names.length) return "";
    if (names.length > 3) return `Upgrade for ${names[0]}, ${names[1]} and ${names.length - 2} more`;
    return `Upgrade for ${names.length === 1 ? names[0] : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`}`;
  }

  function itemTip(it) {
    if (!it) return "";
    const lines = (it.tip && it.tip.length ? it.tip : (state.items[it.id] || [])).slice();
    let html = "";
    if (lines.length) {
      html = lines.map((l, i) => {
        const lc = i === 0 ? "" : colorOf(l.lc);
        const rc = colorOf(l.rc);
        return `<div class="l${i === 0 ? ` qt${it.q ?? 1}` : ""}"><span${lc}>${esc(l.l || "")}</span>${l.r ? `<span${rc}>${esc(l.r)}</span>` : ""}</div>`;
      }).join("");
    } else {
      html = `<div class="l qt${it.q ?? 1}"><span>${esc(it.name)}</span></div>`;
      const kind = [it.sub, it.kind].filter(Boolean)[0];
      if (kind) html += `<div class="l"><span class="dim">${esc(kind)}</span></div>`;
    }
    const notes = [];
    if (it.ilvl && !lines.some((l) => /^item level/i.test(l.l || ""))) notes.push(`Item level ${it.ilvl}`);
    if (it.n > 1) notes.push(`${it.n} in this stack`);
    if (it.dur && !lines.some((l) => /durability/i.test(l.l || ""))) notes.push(`Durability ${it.dur[0]} / ${it.dur[1]}`);
    if (notes.length) html += `<div class="note">${notes.join(" · ")}</div>`;
    const pw = it.id ? priceFor(it.id) : null;
    if (pw && pw.p) html += `<div class="note priceline">Auction ${money(pw.p)}${stacks(it.id) ? " each" : ""} <span class="faint">· ${ago(pw.at)}</span></div>`;
    const bd = it.id && !isPublic() ? boardFor(it.id) : null;
    if (bd && bd.aside.length) html += `<div class="note asideline">Set aside for ${esc(joinNames(bd.aside.map((w) => wordName(bd.g, w))))}</div>`;
    const up = it.id && !isPublic() ? upgradeWords(it.id, new Set((bd ? bd.aside : []).map((w) => w.who))) : "";
    if (up) html += `<div class="note upline">${esc(up)}</div>`;
    for (const [label, words] of it.id && !isPublic() ? craftNotes(it.id) : []) html += `<div class="note craftline"><b>${esc(label)}</b> ${esc(words)}</div>`;
    return { html, qc: `var(--q${it.q ?? 1})` };
  }

  function colorOf(hex) {
    if (!hex || hex === "ffffff") return "";
    return ` style="color:#${esc(hex)}"`;
  }

  function talentTip(node, tab) {
    const st = node.rank >= node.max && node.max > 0 ? "Learned" : node.rank > 0 ? "Learning" : "Not learned";
    return {
      html: `<div class="l"><span>${esc(node.name || "Talent")}</span></div>` +
        `<div class="l"><span class="dim">Rank ${node.rank}/${node.max}</span><span class="dim">${esc(tab || "")}</span></div>` +
        (node.desc ? `<div style="margin-top:6px;color:rgb(var(--gold-200))">${esc(node.desc)}</div>` : "") +
        `<div class="note">${st}</div>`,
      qc: node.rank > 0 ? "rgb(var(--verdant))" : "transparent",
    };
  }

  function tipFor(el) {
    const c = char();
    if (!c) return null;
    const [kind, a, b] = el.dataset.tip.split(":");
    if (kind === "gear") return itemTip(c.gear[a]);
    if (kind === "bag") {
      const list = a === "bank" ? c.bank : c.bags;
      const bag = list[Number(b)];
      return bag ? itemTip(bag.slots[el.dataset.slot]) : null;
    }
    if (kind === "bagitem") {
      const list = a === "bank" ? c.bank : c.bags;
      const bag = list[Number(b)];
      return bag ? itemTip(bag.item) : null;
    }
    if (kind === "talent" || kind === "legacy") {
      const nodes = kind === "talent" ? (c.talents ? c.talents.nodes : []) : (c.legacy ? c.legacy.trees.flatMap((t) => t.nodes) : []);
      const node = nodes.find((x) => String(x.id) === a);
      return node ? talentTip(node, el.dataset.tab) : null;
    }
    return null;
  }

  // The item an element shows, for its page: your gear and bags, what others share, the guild bank
  // and its logs. Talents have no page.
  function itemFor(el) {
    if (el.dataset.tip) {
      const c = char();
      if (!c) return null;
      const [kind, a, b] = el.dataset.tip.split(":");
      if (kind === "gear") return c.gear[a] || null;
      if (kind === "bag" || kind === "bagitem") {
        const bag = (a === "bank" ? c.bank : c.bags)[Number(b)];
        return bag ? (kind === "bag" ? bag.slots[el.dataset.slot] : bag.item) || null : null;
      }
      return null;
    }
    if (!el.dataset.stip) return null;
    const [kind, a, b, d] = el.dataset.stip.split("|");
    if (kind === "pgear") { const p = peerByKey(a); return (p && p.gear && p.gear[b]) || null; }
    if (kind === "pbag" || kind === "pbagitem") {
      const p = peerByKey(a);
      const bag = p && ((b === "bank" ? p.bank : p.bags) || [])[Number(d)];
      return bag ? (kind === "pbag" ? bag.slots[el.dataset.slot] : bag.item) || null : null;
    }
    if (kind === "gb" || kind === "gl") {
      const g = (state.guilds || [])[Number(a)];
      const tab = g && g.bank.tabs.find((t) => t.index === Number(b));
      if (kind === "gb") return (tab && tab.slots[el.dataset.slot]) || null;
      const e = tab && tab.log && tab.log.entries[Number(d)];
      return e && e.id ? { id: e.id, name: e.name, q: e.q, icon: e.icon } : null;
    }
    if (kind === "ip") return { id: Number(a) };
    return null;
  }

  // Tooltips for what others share: their gear, talents, bags and bank, and the guild bank's slots.
  function sharedTipFor(el) {
    const [kind, a, b, d] = el.dataset.stip.split("|");
    if (kind === "pgear") { const p = peerByKey(a); return p && p.gear ? itemTip(p.gear[b]) : null; }
    if (kind === "ptal") {
      const p = peerByKey(a);
      const node = p && p.talents && p.talents.nodes[Number(b)];
      return node ? talentTip(Object.assign({ desc: null }, node), treeNames(p)[(node.tree || 1) - 1]) : null;
    }
    if (kind === "pbag" || kind === "pbagitem") {
      const p = peerByKey(a);
      const bag = p && ((b === "bank" ? p.bank : p.bags) || [])[Number(d)];
      return bag ? itemTip(kind === "pbag" ? bag.slots[el.dataset.slot] : bag.item) : null;
    }
    if (kind === "gb") {
      const g = (state.guilds || [])[Number(a)];
      const tab = g && g.bank.tabs.find((t) => t.index === Number(b));
      return tab ? itemTip(tab.slots[el.dataset.slot]) : null;
    }
    if (kind === "gl") {
      const g = (state.guilds || [])[Number(a)];
      const tab = g && g.bank.tabs.find((t) => t.index === Number(b));
      const e = tab && tab.log && tab.log.entries[Number(d)];
      return e ? itemTip({ id: e.id, name: e.name, q: e.q }) : null;
    }
    if (kind === "ip") return itemTip(itemRec(Number(a)));
    return null;
  }

  // ── Sections ──────────────────────────────────────────────────────────────
  function strip(chars) {
    const chips = chars.map((c) => `
      <button class="who-chip" aria-pressed="${view === "chars" && c.key === current}" data-pick="${esc(c.key)}" style="--cc:${classColor(c)}">
        ${avatar(c)}${esc(fullName(c))}
      </button>`).join("");
    const c = char();
    const live = !DEMO && state.live;
    return `<nav class="strip" aria-label="Characters">
      <div class="roster">${chips}</div>
      ${viewsNav()}
      ${DEMO ? `<a class="sample-tag" href="./" title="Show your real characters">Sample data</a>` : ""}
      <span class="saved ${live ? "live" : ""}" id="saved"><i></i><span id="savedText">${savedText(c)}</span></span>
    </nav>`;
  }

  // Her face in the roster: the same head-and-shoulders crop as the big portrait, ringed in her
  // class colour, with her level on its edge. Her initial sits underneath for when there is no
  // picture yet or the picture is gone.
  function avatar(c) {
    const pic = portraitPic(c);
    return `<span class="av"><span class="ini" aria-hidden="true">${esc((c.name || "?").slice(0, 1))}</span>${pic ? `<span class="face"><img class="ph" src="${shotUrl(pic.file, "face")}" alt="" decoding="async"></span>` : ""}<span class="lv"><span class="sr">Level </span>${c.level ?? "?"}<span class="sr">, </span></span></span>`;
  }

  function portraitPic(c) {
    return c.portrait && (c.photos || []).find((p) => p.file === c.portrait.file);
  }

  function savedText(c) {
    if (DEMO) return "Sample, not live";
    if (!c) return isPublic() ? "Nothing saved yet" : "Watching for your first save";
    return `Saved ${ago(c.updated)}`;
  }

  function ring(c) {
    const xpF = c.xpMax ? pct(c.xp, c.xpMax) : 1;
    const restF = c.xpMax ? Math.min(1, (c.rested || 0) / (c.xpMax * 1.5)) : 0;
    const R1 = 128, R2 = 117;
    const L1 = 2 * Math.PI * R1, L2 = 2 * Math.PI * R2;
    const skyborne = /skyborne/i.test(c.race || "");
    const word = skyborne ? "With love always · KG · " : `${c.class || ""} · level ${c.level ?? ""} · `;
    const engraving = word.repeat(3);
    // Her real face from the game: the head and shoulders of her portrait picture. Until one
    // exists, her initial (never painted or generated art).
    const pic = portraitPic(c);
    const portrait = pic
      ? `<button class="face" data-photo="${esc(pic.file)}" aria-label="Open her portrait"><img class="ph" src="${shotUrl(pic.file, "face")}" alt="${esc(fullName(c))} in the game"></button>`
      : `<span class="initial">${esc((c.name || "?").slice(0, 1))}</span>`;
    const atMax = c.level && c.maxLevel && c.level >= c.maxLevel;
    return `<div class="ring" aria-label="Level ${c.level}, ${Math.round(xpF * 100)}% of the way to the next level">
      <svg viewBox="0 0 300 300" width="300" height="300" aria-hidden="true">
        <defs>
          <linearGradient id="gXP" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f6dda0"/><stop offset=".5" stop-color="#e8a13a"/><stop offset="1" stop-color="#b3661f"/></linearGradient>
          <linearGradient id="gRest" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e3ecff"/><stop offset="1" stop-color="#7d93c4"/></linearGradient>
          <path id="engr" d="M150,150 m-141,0 a141,141 0 1,1 282,0 a141,141 0 1,1 -282,0"/>
        </defs>
        <g class="spin"><text class="engrave"><textPath href="#engr" startOffset="0" textLength="${(2 * Math.PI * 141 - 6).toFixed(1)}" lengthAdjust="spacing">${esc(engraving)}</textPath></text></g>
        <circle class="track" cx="150" cy="150" r="${R1}" stroke-width="7"/>
        <circle class="track" cx="150" cy="150" r="${R2}" stroke-width="3"/>
        <circle class="arc xp" cx="150" cy="150" r="${R1}" stroke-width="7" stroke-dasharray="${L1}" style="stroke-dashoffset:${atMax ? 0 : L1 * (1 - xpF)}"/>
        <circle class="arc rest" cx="150" cy="150" r="${R2}" stroke-width="3" stroke-dasharray="${L2}" style="stroke-dashoffset:${L2 * (1 - restF)}"/>
      </svg>
      <div class="halo"></div>
      <div class="portrait">${portrait}</div>
      <div class="medal"><b>${c.level ?? "?"}</b><span>Level</span></div>
    </div>`;
  }

  function specOf(c) {
    const t = c.talents;
    if (!t || !(t.nodes || []).length) return null;
    const tabs = splitTabs(t.nodes);
    const names = (CLASS[c.classFile] || {}).tabs || ["Tree 1", "Tree 2", "Tree 3"];
    const points = tabs.map((tab) => tab.nodes.reduce((s, x) => s + (x.rank || 0), 0));
    const total = points.reduce((a, b) => a + b, 0);
    if (!total) return null;
    const best = points.indexOf(Math.max(...points));
    return { name: names[best], points };
  }

  function hero(c) {
    const p = Object.assign({}, c.profileDraft || {}, c.profile || {});
    const eyebrow = p.title || c.title || (c.guild ? `<${c.guild}>` : "");
    const spec = specOf(c);
    const where = [c.subzone, c.zone].filter(Boolean).filter((v, i, a) => a.indexOf(v) === i).join(", ");
    const coords = typeof c.x === "number" ? ` <span class="mono faint">${c.x.toFixed(1)}, ${c.y.toFixed(1)}</span>` : "";
    const xpF = c.xpMax ? pct(c.xp, c.xpMax) : 0;
    const restEnd = c.xpMax ? pct((c.xp || 0) + (c.rested || 0), c.xpMax) : 0;
    const atMax = c.level && c.maxLevel && c.level >= c.maxLevel;
    const mana = c.manaMax ? { v: c.mana, m: c.manaMax, k: "Mana" } : c.powerMax ? { v: c.power, m: c.powerMax, k: (c.powerToken || "Power").toLowerCase().replace(/^\w/, (x) => x.toUpperCase()) } : null;
    const vitals = [
      hides(c, "stats") ? "" : `<div class="vital hp"><div class="k">Health</div><div class="v">${n(c.healthMax)}</div><div class="s">at last save</div></div>`,
      mana ? `<div class="vital mp"><div class="k">${esc(mana.k)}</div><div class="v">${n(mana.m)}</div><div class="s">${c.manaMax && c.powerToken && c.powerToken !== "MANA" ? "while not shifted" : "at last save"}</div></div>` : "",
      hides(c, "gold") ? "" : `<div class="vital"><div class="k">Gold</div><div class="v">${money(c.money)}</div><div class="s">on this character</div></div>`,
      hides(c, "played") ? "" : `<div class="vital"><div class="k">Played</div><div class="v">${played(c.played)}</div><div class="s">${c.playedLevel != null ? `${played(c.playedLevel)} this level` : "time in game"}</div></div>`,
    ].join("");
    return `<section class="hero rise" style="--i:0">
      ${ring(c)}
      <div class="ident">
        ${eyebrow ? `<div class="eyebrow">${esc(eyebrow)}</div>` : ""}
        <h1>${esc(fullName(c))}</h1>
        ${p.fullTitle ? `<div class="fulltitle">${esc(p.fullTitle)}</div>` : ""}
        <div class="line">Level <b>${c.level ?? "?"}</b> ${esc(c.race || "")} <b style="color:${classColor(c)}">${esc(c.class || "")}</b>${spec ? ` <span class="dim">· ${esc(spec.name)} ${spec.points.join("/")}</span>` : ""}</div>
        <div class="tags">
          ${c.rulesetLabel ? `<span class="tag crimson">${svg("swords")}${esc(c.rulesetLabel)}</span>` : ""}
          ${c.faction ? `<span class="tag sky">${svg("banner")}${esc(c.faction)}</span>` : ""}
          ${where ? `<span class="tag gold">${svg("pin")}${esc(where)}${coords}</span>` : ""}
          ${c.hearth ? `<span class="tag">${svg("hearth")}Hearth: ${esc(c.hearth)}</span>` : ""}
          ${c.guild ? `<span class="tag">${svg("banner")}&lt;${esc(c.guild)}&gt;${c.guildRank ? ` ${esc(c.guildRank)}` : ""}</span>` : ""}
          ${c.resting ? `<span class="tag sky">${svg("moon")}Resting</span>` : ""}
        </div>
        ${atMax ? "" : `<div class="xpbar">
          <div class="row"><span><b>${n(c.xp)}</b> / ${n(c.xpMax)} XP · ${Math.round(xpF * 100)}%</span><span>${c.rested ? `<b style="color:rgb(var(--moon))">${n(c.rested)}</b> rested` : "No rested XP"}</span></div>
          <div class="bar"><i class="rest" style="width:${restEnd * 100}%"></i><i class="xp" style="width:${xpF * 100}%"></i><span class="ticks"></span></div>
        </div>`}
        ${vitals ? `<div class="vitals">${vitals}</div>` : ""}
      </div>
    </section>`;
  }

  function svg(name) {
    const P = {
      swords: '<path d="M4 4l9 9M13 4l-9 9M2 14l2-2M14 14l-2-2" stroke="currentColor" stroke-width="1.6" fill="none" stroke-linecap="round"/>',
      banner: '<path d="M4 2v12M4 3h8l-2 3 2 3H4" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linejoin="round"/>',
      pin: '<path d="M8 15s5-4.6 5-8.5A5 5 0 0 0 3 6.5C3 10.4 8 15 8 15z" stroke="currentColor" stroke-width="1.5" fill="none"/><circle cx="8" cy="6.5" r="1.8" fill="currentColor"/>',
      hearth: '<path d="M3 14V7l5-4 5 4v7M6.5 14v-3h3v3" stroke="currentColor" stroke-width="1.5" fill="none" stroke-linejoin="round"/>',
      moon: '<path d="M11.5 10.5A5.5 5.5 0 0 1 6 2.6 5.5 5.5 0 1 0 13.4 10a5.5 5.5 0 0 1-1.9.5z" stroke="currentColor" stroke-width="1.4" fill="none"/>',
      search: '<circle cx="7" cy="7" r="4.5" stroke="currentColor" stroke-width="1.5" fill="none"/><path d="M10.5 10.5L14 14" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>',
      camera: '<path d="M2 5.5h3l1.2-2h3.6l1.2 2h3v7.5H2z" stroke="currentColor" stroke-width="1.4" fill="none" stroke-linejoin="round"/><circle cx="8" cy="9" r="2.3" stroke="currentColor" stroke-width="1.4" fill="none"/>',
      star: '<path d="M8 1.8l1.9 3.9 4.3.6-3.1 3 .7 4.3L8 11.6l-3.8 2 .7-4.3-3.1-3 4.3-.6z" fill="currentColor"/>',
      close: '<path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>',
      left: '<path d="M10 3L5 8l5 5" stroke="currentColor" stroke-width="1.7" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
      right: '<path d="M6 3l5 5-5 5" stroke="currentColor" stroke-width="1.7" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
      gem: '<path d="M4.5 2.5h7L14 6l-6 7.5L2 6z" stroke="currentColor" stroke-width="1.3" fill="none" stroke-linejoin="round"/><path d="M2 6h12M6.2 2.5 8 13.5l1.8-11" stroke="currentColor" stroke-width="1" fill="none" opacity=".7"/>',
      check: '<path d="M3.5 8.4l2.9 2.9 6.1-6.6" stroke="currentColor" stroke-width="1.9" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
      mask: '<path d="M2.5 3.5c3.2 1.2 7.8 1.2 11 0v4.2c0 3-2.5 5.3-5.5 5.3S2.5 10.7 2.5 7.7z" stroke="currentColor" stroke-width="1.3" fill="none" stroke-linejoin="round"/><path d="M5 7.2c.6-.5 1.4-.5 2 0M9 7.2c.6-.5 1.4-.5 2 0M6.2 10c1 .7 2.6.7 3.6 0" stroke="currentColor" stroke-width="1.2" fill="none" stroke-linecap="round"/>',
      link: '<path d="M6.5 9.5l3-3M7 4.5l1.2-1.2a2.6 2.6 0 0 1 3.7 3.7L10.7 8.2M9 11.5l-1.2 1.2a2.6 2.6 0 0 1-3.7-3.7L5.3 7.8" stroke="currentColor" stroke-width="1.4" fill="none" stroke-linecap="round"/>',
      dash: '<path d="M5.5 8h5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>',
    };
    return `<svg viewBox="0 0 16 16" aria-hidden="true">${P[name] || ""}</svg>`;
  }

  // Druids, paladins and shamans carry an idol, libram or totem in slot 18, which the game calls Relic.
  const RELIC_CLASSES = new Set(["DRUID", "PALADIN", "SHAMAN"]);
  const slotLabel = (c, slot) => (slot === "18" && RELIC_CLASSES.has(c.classFile) ? "Relic" : SLOT[slot]);

  function slotRow(c, slot) {
    slot = String(slot);
    const it = c.gear[slot];
    const main = c.gear["16"];
    if (!it && slot === "17" && main && main.loc === "INVTYPE_2HWEAPON") {
      // Like the game's paper doll: a two-handed weapon fills the off hand too, shown greyed.
      return `<div class="slot twohand" tabindex="0" data-tip="gear:16">${icon(main.icon, main.q, 44)}<div class="meta"><div class="nm">${SLOT[slot]}</div><div class="sb">Two-hand weapon</div></div></div>`;
    }
    if (!it) return `<div class="slot empty">${icon(null, null, 44)}<div class="meta"><div class="nm">${slotLabel(c, slot)}</div><div class="sb">Empty</div></div></div>`;
    let wear = "";
    if (it.dur) {
      const f = pct(it.dur[0], it.dur[1]);
      wear = `<span class="wear ${f < 0.25 ? "bad" : f < 0.5 ? "low" : ""}" title="Durability ${it.dur[0]} / ${it.dur[1]}"><i style="width:${f * 100}%"></i></span>`;
    }
    return `<div class="slot" tabindex="0" data-tip="gear:${slot}">
      ${icon(it.icon, it.q, 44)}
      <div class="meta"><div class="nm qt${it.q ?? 1}">${esc(it.name)}</div><div class="sb">${slotLabel(c, slot)}${it.ilvl ? ` · ilvl ${it.ilvl}` : ""}${wear}</div></div>
    </div>`;
  }

  function doll(c) {
    // Her equipment kept from the public copy: her face and the album still show her.
    if (hides(c, "gear")) return "";
    const il = c.stats && c.stats.ilvl;
    const pic = c.portrait && (c.photos || []).find((p) => p.file === c.portrait.file);
    const figure = pic
      ? `<button class="figure real" data-photo="${esc(pic.file)}" aria-label="Open her portrait"><img class="ph" src="${shotUrl(pic.file, "tall")}" alt="${esc(c.name)} in game${placeOf(pic) ? `, ${esc(placeOf(pic))}` : ""}"><span class="chip">${svg("camera")}${esc(pic.kind === "select" ? "Character screen" : placeOf(pic) || "In game")}</span><div class="il">${il ? `<b>${il.toFixed(1)}</b><span>Average item level</span>` : ""}</div></button>`
      : `<div class="figure blank"><div class="wait">${svg("camera")}<span>${esc(c.name || "She")} appears here once the game has shown her: from the character screen, or her first photo.</span></div><div class="il">${il ? `<b>${il.toFixed(1)}</b><span>Average item level</span>` : ""}</div></div>`;
    return `<section class="card equip rise" style="--i:1">
      <header><h2>Equipment</h2><small>${c.durability != null ? `Lowest durability ${c.durability}%` : ""}</small></header>
      <div class="doll">
        <div class="slots left">${LEFT.map((s) => slotRow(c, s)).join("")}</div>
        ${figure}
        <div class="slots right">${RIGHT.map((s) => slotRow(c, s)).join("")}</div>
        <div class="weapons">${WEAPONS.map((s) => slotRow(c, s)).join("")}</div>
      </div>
    </section>`;
  }

  function stats(c) {
    if (hides(c, "stats")) return "";
    const s = c.stats || {};
    const prime = [["str", "STR"], ["agi", "AGI"], ["sta", "STA"], ["int", "INT"], ["spi", "SPI"]]
      .filter(([k]) => s[k])
      .map(([k, label]) => `<div title="Base ${s[k].base}${s[k].plus ? `, +${s[k].plus} from gear and buffs` : ""}"><b class="${s[k].plus > 0 ? "up" : ""}">${s[k].total}</b><span>${label}</span></div>`).join("");
    const row = (k, v, up) => (v == null ? "" : `<div class="stat"><span class="k">${k}</span><span class="v ${up ? "up" : ""}">${v}</span></div>`);
    const p2 = (v) => (v == null ? null : `${Number(v).toFixed(2)}%`);
    const res = s.resist || {};
    const RES = [["arcane", "#c9a7ff"], ["fire", "#ff7a5a"], ["nature", "#7fd66b"], ["frost", "#7fc8ff"], ["shadow", "#a77ad6"]];
    return `<section class="card rise" style="--i:2">
      <header><h2>Attributes</h2><small>${s.armor != null ? `${n(s.armor)} armor` : ""}</small></header>
      <div class="statgroup"><div class="prime">${prime || '<div class="faint">-</div>'}</div></div>
      <div class="statgroup"><h3>Melee</h3><div class="stats">
        ${row("Attack power", s.ap != null ? n(s.ap) : null)}
        ${row("Damage", s.dmg ? `${s.dmg[0]}-${s.dmg[1]}` : null)}
        ${row("Speed", s.speed != null ? s.speed.toFixed(2) : null)}
        ${row("Crit", p2(s.crit))}
        ${row("Hit", s.hit ? p2(s.hit) : null)}
      </div></div>
      <div class="statgroup"><h3>Spell</h3><div class="stats">
        ${row("Spell power", s.spellPower != null ? n(s.spellPower) : null)}
        ${row("Healing", s.healing != null ? n(s.healing) : null)}
        ${row("Spell crit", p2(s.spellCrit))}
        ${row("Mana regen", s.mp5 != null ? `${s.mp5} / 5s` : null)}
      </div></div>
      <div class="statgroup"><h3>Defense</h3><div class="stats">
        ${row("Armor", s.armor != null ? n(s.armor) : null)}
        ${row("Dodge", p2(s.dodge))}
        ${s.parry ? row("Parry", p2(s.parry)) : ""}
        ${s.block ? row("Block", p2(s.block)) : ""}
      </div></div>
      <div class="statgroup"><h3>Resistances</h3><div class="resists">
        ${RES.map(([k, col]) => `<div title="${k[0].toUpperCase() + k.slice(1)} resistance"><i style="background:${col};box-shadow:0 0 8px ${col}"></i>${res[k] ?? 0}</div>`).join("")}
      </div></div>
    </section>`;
  }

  // Forever runs all three tabs on one trait tree, side by side: a tab is a group of
  // columns, with a big jump in x between tabs.
  function splitTabs(nodes) {
    const visible = nodes.filter((x) => !x.hidden && typeof x.x === "number" && typeof x.y === "number");
    const xs = [...new Set(visible.map((x) => x.x))].sort((a, b) => a - b);
    const tabOf = new Map();
    let tab = 0;
    xs.forEach((x, i) => { if (i > 0 && x - xs[i - 1] > 1500) tab++; tabOf.set(x, Math.min(tab, 2)); });
    const tabs = [0, 1, 2].map(() => ({ nodes: [] }));
    visible.forEach((x) => tabs[tabOf.get(x.x)].nodes.push(x));
    const ys = [...new Set(visible.map((x) => x.y))].sort((a, b) => a - b);
    tabs.forEach((t) => {
      const cols = [...new Set(t.nodes.map((x) => x.x))].sort((a, b) => a - b);
      t.cols = Math.max(4, cols.length);
      t.nodes.forEach((x) => { x._c = cols.indexOf(x.x); x._r = ys.indexOf(x.y); });
      t.rows = Math.max(1, ...t.nodes.map((x) => x._r + 1));
    });
    return tabs;
  }

  function talents(c) {
    if (hides(c, "talents")) return "";
    const t = c.talents;
    if (!t || !(t.nodes || []).length) {
      return `<section class="card c-12 rise" style="--i:3"><header><h2>Talents</h2></header><div class="empty-note">No talents recorded yet. They appear after the next save.</div></section>`;
    }
    const names = (CLASS[c.classFile] || {}).tabs || ["Tree 1", "Tree 2", "Tree 3"];
    const tabs = splitTabs(t.nodes);
    const CELL = 46, GX = 16, GY = 14;
    const byId = new Map(t.nodes.map((x) => [x.id, x]));
    const trees = tabs.map((tab, i) => {
      const pts = tab.nodes.reduce((s, x) => s + (x.rank || 0), 0);
      const w = tab.cols * CELL + (tab.cols - 1) * GX, h = tab.rows * CELL + (tab.rows - 1) * GY;
      const cx = (x) => x._c * (CELL + GX) + CELL / 2, cy = (x) => x._r * (CELL + GY) + CELL / 2;
      const lines = tab.nodes.flatMap((a) => (a.to || []).map((id) => byId.get(id)).filter((b) => b && b._c != null && tab.nodes.includes(b))
        .map((b) => `<line class="${a.rank > 0 ? "on" : ""}" x1="${cx(a)}" y1="${cy(a)}" x2="${cx(b)}" y2="${cy(b)}"/>`)).join("");
      const cells = tab.nodes.map((x) => {
        const cls = x.rank > 0 ? (x.rank >= x.max ? "on max" : "on") : "";
        return `<div class="tnode ${cls}" tabindex="0" data-tip="talent:${x.id}" data-tab="${esc(names[i])}" style="grid-column:${x._c + 1};grid-row:${x._r + 1}">
          ${icon(x.icon, 1, 46)}<span class="rk">${x.rank}/${x.max}</span></div>`;
      }).join("");
      return `<div class="tree" style="--tint:${TAB_TINTS[i]}">
        <header><h3>${esc(names[i])}</h3><b>${pts}</b></header>
        <div class="tgrid" style="grid-template-columns:repeat(${tab.cols},${CELL}px);width:${w}px;margin:0 auto">
          <svg class="tlinks" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${lines}</svg>${cells}
        </div>
      </div>`;
    }).join("");
    const lg = c.legacy;
    const legacy = lg && (lg.trees || []).length ? `<div class="legacy">
      <span class="tag gold">Legacy: <b>${lg.spent ?? 0}</b> spent${lg.left != null ? `, <b>${lg.left}</b> to spend` : ""}</span>
      ${lg.trees.flatMap((tr) => tr.nodes).filter((x) => x.rank > 0).map((x) => `<span class="tnode on" tabindex="0" data-tip="legacy:${x.id}" data-tab="Legacy" style="display:inline-block">${icon(x.icon, 1, 34)}<span class="rk">${x.rank}/${x.max}</span></span>`).join("")}
    </div>` : "";
    return `<section class="card c-12 rise" style="--i:3">
      <header><h2>Talents</h2><small>${t.spent ?? tabs.reduce((s, tb) => s + tb.nodes.reduce((a, x) => a + x.rank, 0), 0)} spent${t.unspent ? ` · <b style="color:rgb(var(--gold-200))">${t.unspent} to spend</b>` : ""}</small></header>
      <div class="trees">${trees}</div>${legacy}
    </section>`;
  }

  // Bags or the bank as the game lays them out, one container after another. `cellTip` and `bagTip`
  // give the tooltip attributes of a slot and of the container itself; `size` is a slot's in pixels.
  function bagCells(list, which, q, cellTip, bagTip, size = 44) {
    // The keyring is a built-in container at a negative index. The game does not count it as bag space.
    const isKeyring = (b) => which === "bags" && b.bag < 0;
    return list.map((b, bi) => {
      if (isKeyring(b) && b.free >= b.size) return "";
      const name = b.item ? b.item.name : which === "bank" ? `Bank tab ${bi + 1}` : isKeyring(b) ? "Keyring" : bi === 0 ? "Backpack" : `Bag ${bi + 1}`;
      const cells = [];
      for (let s = 1; s <= b.size; s++) {
        const it = b.slots[String(s)];
        if (!it) { cells.push(`<span class="cell empty${q ? " dimmed" : ""}"></span>`); continue; }
        const hit = q && (it.name || "").toLowerCase().includes(q);
        cells.push(`<span class="cell ${q ? (hit ? "hit" : "dimmed") : ""}" tabindex="0" ${cellTip(bi, s)}>${icon(it.icon, it.q, size, it.n > 1 ? `<span class="count">${it.n}</span>` : "")}</span>`);
      }
      return `<div class="bag"><h4>${b.item ? `<span ${bagTip(bi)}>${icon(b.item.icon, b.item.q, 22)}</span>` : ""}${esc(name)}<small>${b.size - b.free}/${b.size}</small></h4><div class="cells">${cells.join("")}</div></div>`;
    }).join("");
  }

  function bags(c) {
    const showBags = !hides(c, "bags"), showBank = !hides(c, "bank");
    if (!showBags && !showBank) return "";
    const which = !showBags ? "bank" : !showBank ? "bags" : bagView;
    const list = which === "bank" ? c.bank : c.bags;
    const q = bagQuery.trim().toLowerCase();
    const space = c.bags.filter((b) => b.bag >= 0);
    const carried = space.reduce((s, b) => s + b.size, 0), free = space.reduce((s, b) => s + b.free, 0);
    const body = !list.length
      ? `<div class="empty-note">${which === "bank" ? "Visit a banker once on this character and the bank shows up here." : "No bags recorded yet."}</div>`
      : bagCells(list, which, q, (bi, s) => `data-tip="bag:${which}:${bi}" data-slot="${s}"`, (bi) => `data-tip="bagitem:${which}:${bi}"`);
    return `<section class="card rise" style="--i:4" id="bagsCard">
      <header><h2>${showBags ? "Bags" : "Bank"}</h2><small>${showBags ? `${free} of ${carried} slots free` : c.bankAt ? `Visited ${ago(c.bankAt)}` : ""}</small></header>
      <div class="bagtools">
        ${showBags && showBank ? `<div class="seg" role="group" aria-label="Bags or bank">
          <button data-bags="bags" aria-pressed="${which === "bags"}">Bags</button>
          <button data-bags="bank" aria-pressed="${which === "bank"}">Bank${c.bankAt ? ` · ${ago(c.bankAt)}` : ""}</button>
        </div>` : ""}
        <label class="search">${svg("search")}<span class="sr">Find an item</span><input id="bagSearch" type="search" placeholder="Find an item" value="${esc(bagQuery)}" autocomplete="off"></label>
      </div>
      <div id="bagBody">${body}</div>
    </section>`;
  }

  // One profession's bar; with its recipes known, a button that opens them.
  function profRow(owner, books, p, size) {
    const book = (books || []).find((b) => b.name === p.name);
    const n = book ? book.recipes.length : 0;
    const inner = `${icon(p.icon, 1, size)}<div>
      <div class="top"><b>${esc(p.name)}${n ? '<i class="chev" aria-hidden="true"></i>' : ""}</b><span>${p.skill ?? "-"} / ${p.max ?? "-"}</span></div>
      <div class="meter"><i style="width:${pct(p.skill, p.max) * 100}%"></i></div></div>`;
    if (!n) return `<div class="brow">${inner}</div>`;
    return `<button class="brow prow" data-craft="${esc(owner)}~${esc(p.name)}" title="${esc(`${n} ${n === 1 ? "recipe" : "recipes"}`)}">${inner}</button>`;
  }

  function crafts(c) {
    if (hides(c, "profs")) return "";
    const profs = c.profs.map((p) => profRow(`c:${c.key}`, c.recipes, p, 34)).join("");
    const groups = {};
    c.skills.filter((s) => s.max && !/language/i.test(s.group || "") && !c.profs.some((p) => p.name === s.name)).forEach((s) => { (groups[s.group || "Skills"] ||= []).push(s); });
    const skills = Object.entries(groups).map(([g, list]) => `<div class="subhead">${esc(g)}</div><div class="bars">${list.map((s) => `<div class="brow" style="grid-template-columns:1fr"><div>
      <div class="top"><b>${esc(s.name)}</b><span>${s.rank} / ${s.max}</span></div><div class="meter"><i style="width:${pct(s.rank, s.max) * 100}%;--fill:linear-gradient(90deg,rgb(var(--moon)/.5),rgb(var(--moon)))"></i></div></div></div>`).join("")}</div>`).join("");
    return `<section class="card rise" style="--i:3">
      <header><h2>Professions</h2></header>
      ${profs ? `<div class="bars">${profs}</div>` : '<div class="empty-note">No professions learned yet.</div>'}
      ${skills}
    </section>`;
  }

  function repRows(reps) {
    return reps.map((r) => {
      if (r.header && r.value == null) return `<div class="subhead">${esc(r.name)}</div>`;
      const st = STANDING[r.reaction] || ["Unknown", "#999"];
      const span = (r.hi ?? 0) - (r.lo ?? 0);
      const into = (r.value ?? 0) - (r.lo ?? 0);
      const f = r.reaction >= 8 ? 1 : pct(into, span);
      return `<div class="brow rep"><div>
        <div class="top"><b>${esc(r.name)}${r.war ? '<span class="war">At war</span>' : ""}</b><span style="color:${st[1]}">${st[0]}${r.reaction < 8 && span > 0 ? ` <span class="faint">${n(into)} / ${n(span)}</span>` : ""}</span></div>
        <div class="meter"><i style="width:${f * 100}%;--fill:linear-gradient(90deg,${st[1]}aa,${st[1]})"></i></div></div></div>`;
    }).join("");
  }

  function reputation(c) {
    if (hides(c, "reps")) return "";
    const html = repRows(c.reps);
    return `<section class="card rise" style="--i:5" id="repCard">
      <header><h2>Reputation</h2><small>${c.reps.filter((r) => r.value != null).length} factions</small></header>
      ${html || '<div class="empty-note">No reputations recorded yet.</div>'}
    </section>`;
  }

  // ── Timeline: the road of where she spent her time (addon/Reliquary/Timeline.lua,
  // server/timeline.py). Each stop is a stretch of play in one zone, oldest first; a stop opens
  // its details. Only the game's own names and numbers: nothing here is written about her.
  const ROAD_SHOWN = 12;
  let roadAll = false;
  let detailKey = null;     // the stop open in the details panel
  let detailReturn = null;  // where focus goes when it closes
  const plural = (k, one, many) => `${n(k)} ${k === 1 ? one : many}`;
  const questCount = (x) => (Array.isArray(x.quests) ? x.quests.length : x.quests || 0);
  const questXP = (x) => (Array.isArray(x.quests) ? x.quests.reduce((t, q) => t + (q.xp || 0), 0) : x.xp || 0);

  function activeTime(sec) {
    const h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
    if (h) return m ? `${h}h ${m}m` : `${h}h`;
    return `${Math.max(1, m)}m`;
  }

  function hours(from, to) {
    const t = (ts) => new Date(ts * 1000).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
    const a = t(from), b = t(to);
    if (a === b) return a;
    const sameDay = new Date(from * 1000).toDateString() === new Date(to * 1000).toDateString();
    return sameDay && a.slice(-2) === b.slice(-2) ? `${a.slice(0, -3)}-${b}` : `${a}-${b}`;
  }

  function dayHeading(ts) {
    const d = new Date(ts * 1000);
    const sameYear = d.getFullYear() === new Date().getFullYear();
    return d.toLocaleDateString("en-US", { weekday: "long", month: "short", day: "numeric", ...(sameYear ? {} : { year: "numeric" }) });
  }

  // Every stop, oldest first: what came before Reliquary, the days folded after 30 days, then
  // the entries.
  function stops(c) {
    const tl = c && c.journey; // {} on the public copy when where it has been is kept off it
    if (!tl || (!Array.isArray(tl.entries) && !tl.before)) return [];
    const list = [...(tl.days || [])].reverse().map((x) => ({ x, folded: true }))
      .concat([...(tl.entries || [])].reverse().map((x) => ({ x, folded: false })))
      .map((st, i) => ({ ...st, num: i + 1, key: `${st.folded ? "d" : "e"}${st.x.from}-${st.x.zone}` }));
    return tl.before ? [{ x: tl.before, before: true, num: 0, key: "before" }, ...list] : list;
  }

  const PARTS = { challenges: "Legacy challenges", quests: "completed quests", explored: "the explored map",
    stats: "statistics", pvp: "PvP", titles: "titles" };

  function dateOf(iso) {
    const [y, m, d] = iso.split("-").map(Number);
    const dt = new Date(y, m - 1, d);
    return dt.toLocaleDateString("en-US", { month: "short", day: "numeric", ...(y === new Date().getFullYear() ? {} : { year: "numeric" }) });
  }

  function beforeLine(b) {
    const facts = [];
    if (b.quests) facts.push(plural(b.quests.count, "quest", "quests"));
    if (b.explored) facts.push(plural(b.explored.length, "zone explored", "zones explored"));
    if (b.challenges) facts.push(plural(b.challenges.length, "challenge", "challenges"));
    return facts.join(" · ");
  }

  function stopWhen(st) {
    return st.folded ? day(st.x.from) : `${day(st.x.from)} · ${hours(st.x.from, st.x.to)}`;
  }

  function stopLine(x) {
    const facts = [activeTime(x.active)];
    if (questCount(x)) facts.push(plural(questCount(x), "quest", "quests"));
    const ch = Array.isArray(x.challenges) ? x.challenges.length : x.challenges || 0;
    if (ch) facts.push(plural(ch, "challenge", "challenges"));
    if (x.kills) facts.push(plural(x.kills, "killing blow", "killing blows"));
    return facts.join(" · ");
  }

  function levelLine(x) {
    if (!x.level) return "";
    return x.levelTo && x.levelTo > x.level ? `Level ${x.level} to ${x.levelTo}` : `Level ${x.level}`;
  }

  function stop(st) {
    const x = st.x, photos = x.photos || [];
    const pic = photos.length
      ? `<span class="snap"><img class="ph" src="${shotUrl(photos[0], "thumb")}" alt="" loading="lazy">${photos.length > 1 ? `<span class="more">+${photos.length - 1}</span>` : ""}</span>`
      : "";
    if (st.before) {
      const lv = [x.level ? `Level ${x.level}` : "", x.played ? `${played(x.played)} played` : ""].filter(Boolean).join(" · ");
      return `<button class="stop before" data-stop="before" aria-label="Before Reliquary, up to ${esc(day(x.at))}: open what the game remembered">
      <span class="pin star">${svg("star")}</span>
      <span class="sd"><span class="nm">Before Reliquary</span><span class="rg">Up to ${esc(day(x.at))}</span>${beforeLine(x) ? `<span class="ln">${beforeLine(x)}</span>` : ""}${lv ? `<span class="when">${lv}</span>` : ""}${pic}</span>
    </button>`;
    }
    return `<button class="stop${st.folded ? " folded" : ""}" data-stop="${esc(st.key)}" aria-label="Stop ${st.num}, ${esc(x.zone)}, ${esc(stopWhen(st))}: open its details">
      <span class="pin">${st.num}</span>
      <span class="sd"><span class="nm">${esc(x.zone)}</span><span class="rg">${esc(stopWhen(st))}</span>${x.first ? `<span class="first-tag">First visit</span>` : ""}<span class="ln">${stopLine(x)}</span>${levelLine(x) ? `<span class="when">${levelLine(x)}</span>` : ""}${pic}</span>
    </button>`;
  }

  function timeline(c) {
    const all = stops(c);
    if (!all.length) return "";
    const shown = roadAll ? all : all.slice(-ROAD_SHOWN);
    const earlier = all.length - shown.length;
    const count = all.filter((st) => !st.before).length; // "Before Reliquary" is not a stop
    return `<section class="card rise" style="--i:6" id="timelineCard">
      <header><h2>Timeline</h2>${count ? `<small>${plural(count, "stop", "stops")}</small>` : ""}</header>
      ${earlier ? `<button class="btn outline road-more" data-road-all>Show ${plural(earlier, "earlier stop", "earlier stops")}</button>` : ""}
      <div class="roadwrap"><div class="road">${shown.map(stop).join("")}</div></div>
      <p class="faint road-note">A stop is 10 active minutes in one zone, or a quest handed in there; time marked AFK is left out. Open a stop for its details.</p>
    </section>`;
  }

  function renderTimeline() {
    const card = document.getElementById("timelineCard");
    const c = char();
    if (card && c) card.outerHTML = timeline(c);
    catchUpPhotos(app);
  }

  // ── A stop's details ──────────────────────────────────────────────────────
  function photoGrid(files) {
    return files && files.length
      ? `<h5>Photos</h5><div class="dph">${files.map((f) => `<button class="snap" data-photo="${esc(f)}" aria-label="Open this photo"><img class="ph" src="${shotUrl(f, "thumb")}" alt="" loading="lazy"></button>`).join("")}</div>`
      : "";
  }

  function stopNav(all, i) {
    const st = all[i], prev = all[i - 1], next = all[i + 1];
    const name = (s) => esc(s.before ? "Before Reliquary" : s.x.zone);
    return `<nav class="dnav" aria-label="Other stops">
        ${prev ? `<button data-stop-step="-1">${svg("left")}<span>${name(prev)}</span></button>` : "<span></span>"}
        <span class="faint">${st.before ? "Before Reliquary" : `Stop ${st.num} of ${all.length - (all[0].before ? 1 : 0)}`}</span>
        ${next ? `<button data-stop-step="1"><span>${name(next)}</span>${svg("right")}</button>` : "<span></span>"}
      </nav>`;
  }

  // What the game remembered before Reliquary: only its challenges are dated.
  function beforeHtml(all, i) {
    const b = all[i].x;
    const facts = [];
    if (b.level) facts.push(["Level", n(b.level)]);
    if (b.played) facts.push(["Played", played(b.played)]);
    if (b.quests) facts.push(["Quests", n(b.quests.count)]);
    if (b.explored) facts.push(["Zones explored", n(b.explored.length)]);
    if (b.challenges) facts.push(["Challenges", n(b.challenges.length)]);
    if (b.honorKills) facts.push(["Honorable kills", n(b.honorKills)]);
    const SHOWN = 24;
    const sections = [];
    if (b.challenges) {
      sections.push(`<h5>Legacy challenges</h5><ul class="dq">${b.challenges.map((ch) => `<li><span>${esc(ch.name)}${ch.description ? `<small>${esc(ch.description)}</small>` : ""}</span><b>${[ch.date ? esc(dateOf(ch.date)) : "", ch.points ? `${n(ch.points)} pts` : ""].filter(Boolean).join(" · ")}</b></li>`).join("")}</ul>`);
    }
    if (b.explored) {
      sections.push(`<h5>Zones explored</h5><ul class="dq">${b.explored.map((z) => `<li><span>${esc(z.zone)}<small>${esc(z.areas.join(", "))}</small></span><b>${plural(z.areas.length, "area", "areas")}</b></li>`).join("")}</ul>`);
    }
    if (b.stats) {
      const groups = new Map();
      b.stats.forEach((st) => groups.set(st.group, [...(groups.get(st.group) || []), st]));
      sections.push(`<h5>Lifetime statistics</h5>${[...groups].map(([group, list]) => `<h6>${esc(group)}</h6><ul class="dq">${list.map((st) => `<li><span>${st.sub ? `${esc(st.sub)}: ` : ""}${esc(st.name)}</span><b>${n(st.value)}</b></li>`).join("")}</ul>`).join("")}`);
    }
    if (b.quests && b.quests.titles.length) {
      const unnamed = b.quests.count - b.quests.titles.length;
      sections.push(`<h5>Quests completed</h5><ul class="dcols">${b.quests.titles.map((t) => `<li>${esc(t)}</li>`).join("")}</ul>${b.quests.titles.length > SHOWN ? `<button class="btn outline dmore" data-detail-more>Show all ${n(b.quests.titles.length)}</button>` : ""}${unnamed > 0 ? `<p class="faint dnote">${plural(unnamed, "more quest", "more quests")} the game hasn't given a title for yet.</p>` : ""}`);
    }
    if (b.titles) sections.push(`<h5>Titles</h5><p class="dp">${esc(b.titles.join(", "))}</p>`);
    const missing = (b.missing || []).map((m) => PARTS[m]).filter(Boolean);
    return `<div class="detail-card" role="dialog" aria-modal="true" aria-labelledby="detailTitle">
      <button class="vbtn close" data-detail-close aria-label="Close">${svg("close")}</button>
      <div class="dhead"><span class="pin star">${svg("star")}</span><div>
        <h3 id="detailTitle">Before Reliquary</h3>
        <small>What the game remembered on ${esc(dayHeading(b.at))}</small>
      </div></div>
      <p class="faint dfold">Read from the game the first time Reliquary ran. The game keeps dates only for challenges.</p>
      ${facts.length ? `<dl class="dfacts">${facts.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join("")}</dl>` : ""}
      ${sections.join("")}${photoGrid(b.photos)}
      ${missing.length ? `<p class="faint dnote">The game gave nothing for ${esc(missing.join(", "))}.</p>` : ""}
      ${stopNav(all, i)}
    </div>`;
  }

  function detailHtml(all, i) {
    if (all[i].before) return beforeHtml(all, i);
    const st = all[i], x = st.x;
    const facts = [["Active time", activeTime(x.active)]];
    if (x.level) facts.push(["Level", x.levelTo && x.levelTo > x.level ? `${x.level} to ${x.levelTo}` : `${x.level}`]);
    if (questCount(x)) facts.push(["Quests", `${n(questCount(x))}${questXP(x) ? `<small>+${n(questXP(x))} XP</small>` : ""}`]);
    if (x.challenges) facts.push(["Challenges", n(Array.isArray(x.challenges) ? x.challenges.length : x.challenges)]);
    if (x.kills) facts.push(["Killing blows", n(x.kills)]);
    const quests = Array.isArray(x.quests) && x.quests.length
      ? `<h5>Quests handed in</h5><ul class="dq">${x.quests.map((q) => `<li><span>${q.title ? esc(q.title) : `Quest ${esc(q.id || "")}`}</span>${q.xp ? `<b>+${n(q.xp)} XP</b>` : ""}</li>`).join("")}</ul>`
      : "";
    const challenges = Array.isArray(x.challenges) && x.challenges.length
      ? `<h5>Legacy challenges</h5><ul class="dq">${x.challenges.map((ch) => `<li><span>${esc(ch.name)}</span></li>`).join("")}</ul>`
      : "";
    const passed = x.passed && x.passed.length ? `<h5>Passed through</h5><p class="dp">${esc(x.passed.join(", "))}</p>` : "";
    const photos = photoGrid(x.photos);
    return `<div class="detail-card" role="dialog" aria-modal="true" aria-labelledby="detailTitle">
      <button class="vbtn close" data-detail-close aria-label="Close">${svg("close")}</button>
      <div class="dhead"><span class="pin${st.folded ? " hollow" : ""}">${st.num}</span><div>
        <h3 id="detailTitle">${esc(x.zone)}</h3>
        <small>${esc(dayHeading(x.from))}${st.folded ? "" : ` · ${esc(hours(x.from, x.to))}`}</small>
      </div>${x.first ? `<span class="first-tag">First visit</span>` : ""}</div>
      ${st.folded ? `<p class="faint dfold">Every stretch in ${esc(x.zone)} that day, kept as one line after 30 days.</p>` : ""}
      <dl class="dfacts">${facts.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join("")}</dl>
      ${quests}${challenges}${passed}${photos}
      ${stopNav(all, i)}
    </div>`;
  }

  function openDetail(key) {
    const all = stops(char());
    const i = all.findIndex((st) => st.key === key);
    if (i < 0) { closeDetail(); return; }
    if (!detailKey) detailReturn = document.activeElement;
    detailKey = key;
    hideTip();
    detail.innerHTML = detailHtml(all, i);
    detail.hidden = false;
    document.body.classList.add("detailing");
    requestAnimationFrame(() => detail.classList.add("show"));
    catchUpPhotos(detail);
    const close = detail.querySelector("[data-detail-close]");
    if (close && !detail.contains(document.activeElement)) close.focus({ preventScroll: true });
  }

  function stepDetail(d) {
    const all = stops(char());
    const i = all.findIndex((st) => st.key === detailKey);
    if (i >= 0 && all[i + d]) openDetail(all[i + d].key);
  }

  function closeDetail() {
    if (!detailKey && detail.hidden) return;
    const key = detailKey;
    detailKey = null;
    detail.classList.remove("show");
    document.body.classList.remove("detailing");
    setTimeout(() => { if (!detailKey) { detail.hidden = true; detail.innerHTML = ""; } }, 220);
    // Back to the stop that opened it, or its fresh copy after a save redrew the page.
    const back = detailReturn && document.contains(detailReturn) ? detailReturn : app.querySelector(`[data-stop="${CSS.escape(key || "")}"]`);
    if (back) back.focus({ preventScroll: true });
    detailReturn = null;
  }

  detail.addEventListener("click", (e) => {
    if (e.target === detail || e.target.closest("[data-detail-close]")) { closeDetail(); return; }
    const step = e.target.closest("[data-stop-step]");
    if (step) { stepDetail(Number(step.dataset.stopStep)); return; }
    const more = e.target.closest("[data-detail-more]");
    if (more) { more.previousElementSibling.classList.add("all"); more.remove(); return; }
    const photo = e.target.closest("[data-photo]");
    if (photo) openViewer(photo.dataset.photo);
  });

  // ── Photos ────────────────────────────────────────────────────────────────
  // Bump a size's version whenever its crop changes: the copies are cached for a month.
  const SHOT_VERSIONS = { face: 2 };
  const shotUrl = (file, v) => `/shot/${encodeURIComponent(file)}?v=${v}${SHOT_VERSIONS[v] ? `&r=${SHOT_VERSIONS[v]}` : ""}`;

  function placeOf(p) {
    const here = p.spot || p.sub || p.zone;
    if (!here) return "";
    return p.zone && p.zone !== here ? `${here}, ${p.zone}` : here;
  }

  function titleOf(p) {
    return placeOf(p) || (p.kind === "select" ? "Character screen" : p.guess ? "Just taken" : "Somewhere in Azeroth");
  }

  function photoLine(p) {
    return [p.level ? `Level ${p.level}` : "", p.form || "", when(p.t)].filter(Boolean).join(" · ");
  }

  function photoBadge(c, p) {
    if (c.portrait && c.portrait.file === p.file) return `<span class="badge gold">${svg("star")}Portrait</span>`;
    if (p.kind === "levelup") return `<span class="badge">Level ${p.level || "up"}</span>`;
    if (p.kind === "place") return `<span class="badge">New place</span>`;
    if (p.kind === "portrait") return `<span class="badge">Close-up</span>`;
    if (p.kind === "select") return `<span class="badge">Character screen</span>`;
    if (p.kind === "screenshot") return `<span class="badge dim">Screenshot</span>`;
    return "";
  }

  // The album is a mosaic: the newest photo large (two by two), the rest small. These widen the
  // last tiles so every row is full, four columns on desktop and two on a phone.
  function tileSpan(total, i) {
    const k = total - 1;
    const cls = [];
    if (i === 0 && k === 0) cls.push("d-w4");
    if (i > 0) {
      if (k === 1) cls.push("d-w2", "d-h2");
      else if (k === 2) cls.push("d-w2");
      else if (k === 3 && i === 3) cls.push("d-w2");
      else if (k > 4 && i === k) { const r = (k - 4) % 4; if (r) cls.push(`d-w${5 - r}`); }
      if (k % 2 === 1 && i === k) cls.push("p-w2");
    }
    return cls.length ? " " + cls.join(" ") : "";
  }

  function album(c) {
    const ph = c.photos || [];
    if (!ph.length && isPublic()) {
      return `<section class="card c-12 rise" style="--i:3" id="album">
        <header><h2>Album</h2><small>Her photos take themselves</small></header>
        <div class="album-empty"><p>No photos of ${esc(c.name)} yet. Reliquary takes them by itself as she travels: the first time she stands somewhere new, each new level, and a close-up now and then while she rests.</p></div>
      </section>`;
    }
    if (!ph.length) {
      return `<section class="card c-12 rise" style="--i:3" id="album">
        <header><h2>Album</h2><small>Her photos take themselves</small></header>
        <div class="album-empty"><p>No photos of ${esc(c.name)} yet. Reliquary takes them by itself as you play, and her newest close-up appears beside her equipment.</p>
        <div class="steps album-steps">
          <div><b>${svg("pin")}</b><span><i>New places.</i> The first time she stands somewhere new, a wide shot of her there.</span></div>
          <div><b>${svg("star")}</b><span><i>Level-ups.</i> Each new level, once the fight is over.</span></div>
          <div><b>${svg("camera")}</b><span><i>Close-ups.</i> Once a session, while she rests at an inn or in a city.</span></div>
        </div>
        <p class="faint">Each waits until she is standing still in her own shape, out of combat and not talking to anyone, then turns the camera to face her and hides your interface for about a second. <span class="mono">/rq portrait</span> takes one now, <span class="mono">/rq auto</span> turns them off, and Print Screen shots show up here too.</p></div>
      </section>`;
    }
    const LIMIT = 9;
    const shown = albumAll ? ph : ph.slice(0, LIMIT);
    const tiles = shown.map((p, i) => `<button class="shot${i === 0 ? " lead" : ""}${tileSpan(shown.length, i)}" data-photo="${esc(p.file)}">
        <img class="ph" src="${shotUrl(p.file, "thumb")}" alt="${esc(placeOf(p) || "A photo")}"${i >= LIMIT ? ' loading="lazy"' : ""} decoding="async">
        ${photoBadge(c, p)}
        <span class="cap"><b>${esc(titleOf(p))}</b><small>${esc(photoLine(p) || (p.guess ? "Where she was shows after the next save" : ""))}</small></span>
      </button>`).join("");
    const more = ph.length > LIMIT ? `<button class="btn outline album-more" data-album-all>${albumAll ? "Show fewer" : `Show all ${ph.length}`}</button>` : "";
    return `<section class="card c-12 rise" style="--i:3" id="album">
      <header><h2>Album</h2><small>${ph.length} ${ph.length === 1 ? "photo" : "photos"} · they take themselves as she travels</small></header>
      <div class="album">${tiles}</div>${more}
    </section>`;
  }

  function viewerHtml(c, i) {
    const ph = c.photos;
    const p = ph[i];
    const isPortrait = c.portrait && c.portrait.file === p.file;
    const choose = isPublic()
      ? (isPortrait ? `<span class="badge gold big">${svg("star")}Her portrait</span>` : "")
      : isPortrait
      ? `<span class="badge gold big">${svg("star")}Her portrait</span>${c.portrait.chosen ? `<button class="linkish" data-portrait="">Let Reliquary choose</button>` : ""}`
      : `<button class="btn" data-portrait="${esc(p.file)}">${svg("star")}Use as her portrait</button>`;
    const note = p.guess
      ? "Taken after her last save. Where she was is added the next time you log out or /reload."
      : p.kind === "levelup" ? "Taken by Reliquary when she reached this level."
      : p.kind === "place" ? "Taken by Reliquary the first time she stood here."
      : p.kind === "portrait" ? "A close portrait, framed by Reliquary."
      : p.kind === "select" ? "Captured from the character screen, as the game shows her there."
      : p.kind === "screenshot" ? "Your own screenshot, with the interface showing." : "";
    return `<div class="viewer-frame" role="dialog" aria-modal="true" aria-label="Photo ${i + 1} of ${ph.length}">
      <button class="vbtn close" data-view-close aria-label="Close">${svg("close")}</button>
      <figure>
        <div class="vimg"><img src="${shotUrl(p.file, "full")}" alt="${esc(placeOf(p) || "A photo")}" style="aspect-ratio:${p.w}/${p.h}"></div>
        <figcaption>
          <div><b>${esc(titleOf(p))}</b><small>${esc(photoLine(p))}</small>${note ? `<p>${esc(note)}</p>` : ""}</div>
          <div class="vact">${choose}<span class="count mono">${i + 1} / ${ph.length}</span></div>
        </figcaption>
      </figure>
      ${ph.length > 1 ? `<button class="vbtn prev" data-view-step="-1" aria-label="Newer photo">${svg("left")}</button><button class="vbtn next" data-view-step="1" aria-label="Older photo">${svg("right")}</button>` : ""}
    </div>`;
  }

  function openViewer(file) {
    const c = char();
    const i = c ? (c.photos || []).findIndex((p) => p.file === file) : -1;
    if (i < 0) { closeViewer(); return; }
    if (!viewFile) viewReturn = document.activeElement;
    viewFile = file;
    hideTip();
    viewer.innerHTML = viewerHtml(c, i);
    viewer.hidden = false;
    document.body.classList.add("viewing");
    requestAnimationFrame(() => viewer.classList.add("show"));
    const close = viewer.querySelector("[data-view-close]");
    if (close && !viewer.contains(document.activeElement)) close.focus({ preventScroll: true });
    // Fetch the neighbours so stepping through feels instant.
    [i - 1, i + 1].forEach((j) => { const q = c.photos[j]; if (q) new Image().src = shotUrl(q.file, "full"); });
  }

  function stepViewer(d) {
    const c = char();
    const ph = (c && c.photos) || [];
    const i = ph.findIndex((p) => p.file === viewFile);
    if (i < 0 || !ph.length) return;
    openViewer(ph[(i + d + ph.length) % ph.length].file);
  }

  function closeViewer() {
    if (!viewFile && viewer.hidden) return;
    viewFile = null;
    viewer.classList.remove("show");
    document.body.classList.remove("viewing");
    setTimeout(() => { if (!viewFile) { viewer.hidden = true; viewer.innerHTML = ""; } }, 220);
    if (viewReturn && document.contains(viewReturn)) viewReturn.focus({ preventScroll: true });
    viewReturn = null;
  }

  async function choosePortrait(file) {
    const c = char();
    if (!c || DEMO) return;
    const res = await fetch("/api/portrait", {
      method: "POST", headers: { "Content-Type": "application/json", "X-Reliquary": "1" },
      body: JSON.stringify({ key: c.key, file: file || null }),
    });
    if (res.ok) await load();
  }

  // A quest's colour is its level against the character's, as the game's quest log shows it.
  function questRows(list, level) {
    const lvl = level || 1;
    const diff = (q) => { const d = (q.level || lvl) - lvl; return d >= 5 ? "red" : d >= 3 ? "orange" : d >= -2 ? "yellow" : d >= -6 ? "green" : "grey"; };
    return list.map((q) => `<div class="quest ${q.done ? "done" : ""}">
      <div class="t"><span class="lvl diff-${diff(q)}">${q.level ?? "?"}</span>${esc(q.title)}${q.done ? '<span class="ready">Ready to turn in</span>' : ""}</div>
      ${q.obj && q.obj.length ? `<ul>${q.obj.map((o) => `<li class="${o.done ? "ok" : ""}">${esc(o.text)}</li>`).join("")}</ul>` : ""}
    </div>`).join("");
  }

  // The quest log in the game's order, as many quests as the cards beside it reach (fitQuests), the
  // rest on asking: a long log would otherwise run far below them and leave a hole beside it.
  const QUESTS_MIN = 5, QUESTS_STACKED = 12;
  function quests(c) {
    if (hides(c, "quests")) return "";
    const list = questRows(c.quests, c.level);
    const more = c.quests.length > QUESTS_MIN ? `<button class="btn outline quests-more" data-quests-all>${questsAll ? "Show fewer" : `Show all ${c.quests.length}`}</button>` : "";
    return `<section class="card rise" style="--i:7" id="questsCard">
      <header><h2>Quest log</h2><small>${c.quests.length} quests${c.quests.some((q) => q.done) ? ` · ${c.quests.filter((q) => q.done).length} ready` : ""}</small></header>
      ${list ? `<div class="quests">${list}</div>${more}` : '<div class="empty-note">The quest log is empty.</div>'}
    </section>`;
  }

  // Beside other cards, the quests that end above the bottom of those cards (with the button below
  // them), five at least; on a phone, where the columns stack, the first twelve. Measured in layout
  // terms (offsets), so the cards' rising-in doesn't move the numbers.
  const layoutTop = (el) => { let y = 0; for (let e = el; e; e = e.offsetParent) y += e.offsetTop; return y; };
  const layoutBottom = (el) => layoutTop(el) + el.offsetHeight;
  // Rows of two columns are kept even where they sit side by side. Reputation, and "Who sees" on your
  // copy, read well in more than one place: each goes where it leaves the columns closest in height
  // (reputation also beside or under the equipment), counting the quest log as fitQuests will fit it.
  // A card leaves its usual place only when that closes the gaps by more than MOVE_COST px. Every
  // place is weighed from one measuring, without moving a card to try it. Then each row ends level.
  const MOVE_COST = 40;
  function balance() {
    const $ = (id) => document.getElementById(id);
    unlevel();
    const topL = $("topL"), topR = $("topR"), L = $("lowerL"), R = $("lowerR");
    // The column each place puts a card in: under the equipment, under the character sheet, under
    // the timeline, or above the quest log.
    const into = { U: topR && topL, T: topL && topR, L: R && L, R: L && R };
    const where = (el) => ["U", "T", "L", "R"].find((k) => into[k] && el.parentElement === into[k]);
    const cards = [[$("repCard"), "UTLR"], [$("whoCard"), "LR"]].flatMap(([el, may]) => {
      if (!el) return [];
      if (!el.dataset.home) el.dataset.home = where(el) || "-";
      const home = el.dataset.home;
      return into[home] ? [{ el, home, may: [...may].filter((k) => into[k]) }] : [];
    });
    const beside = (a, b) => a && b && layoutTop(a) === layoutTop(b);
    const end = (col) => (col.lastElementChild ? layoutBottom(col.lastElementChild) : layoutTop(col));
    const q = $("questsCard"), fits = q && q.parentElement === R;
    let best = cards.map((x) => x.home);
    if (cards.length && (beside(topL, topR) || beside(L, R))) {
      // Everything shown, once: where each column's own cards end, and the quest log's rows.
      const rows = fits ? [...q.querySelectorAll(".quest")] : [], more = fits && q.querySelector("[data-quests-all]");
      rows.forEach((r) => r.classList.remove("off"));
      if (more) more.classList.remove("off");
      const gap = parseFloat(getComputedStyle(into[cards[0].home]).rowGap) || 0;
      const loose = new Set(cards.map((x) => x.el));
      const own = (col) => { const k = [...col.children].filter((el) => !loose.has(el) && el !== q); return k.length ? layoutBottom(k[k.length - 1]) : layoutTop(col) - gap; };
      const start = {};
      for (const k of ["U", "T", "L"]) if (into[k]) start[k] = own(into[k]);
      if (into.R) start.R = layoutTop(R) - gap;
      // Where the quest log ends, from its top, beside a column ending at `reach`: fitted, even when
      // it's shown in full, so asking for all of it doesn't move the cards.
      let fit = (top) => top;
      if (fits) {
        const qt = layoutTop(q), h = q.offsetHeight;
        if (!more) fit = (top) => top + h;
        else {
          const rel = rows.map((r) => layoutBottom(r) - qt), reserve = h - rel[rel.length - 1];
          const bare = h - (layoutBottom(more) - layoutBottom(q.querySelector(".quests")));  // all of them, so no button
          fit = (top, reach) => {
            const over = rel.findIndex((b, i) => i >= QUESTS_MIN && top + b > reach - reserve);
            return over < 0 ? top + bare : top + rel[over - 1] + reserve;
          };
        }
      }
      // Each card's height in each column it may go to, at that column's width, without moving it.
      const tall = cards.map((x) => ({ [where(x.el)]: x.el.offsetHeight }));
      for (;;) {
        const next = cards.map((x, i) => x.may.find((k) => !(k in tall[i])));
        if (!next.some(Boolean)) break;
        next.forEach((k, i) => { if (k) cards[i].el.style.width = `${into[k].clientWidth}px`; });
        next.forEach((k, i) => { if (k) tall[i][k] = cards[i].el.offsetHeight; });
      }
      cards.forEach((x) => { x.el.style.width = ""; });
      const moves = (w) => w.filter((k, i) => k !== cards[i].home).length;
      const tries = cards.reduce((acc, x) => acc.flatMap((t) => x.may.map((k) => [...t, k])), [[]]).sort((a, b) => moves(a) - moves(b));
      const pairs = [beside(topL, topR) && ["U", "T"], beside(L, R) && ["L", "R"]].filter(Boolean);
      let low = Infinity;
      for (const w of tries) {
        const e = { ...start };
        w.forEach((k, i) => { e[k] += gap + tall[i][k]; });
        if (fits) e.R = fit(e.R + gap, e.L);
        const cost = pairs.reduce((sum, [a, b]) => sum + Math.abs(e[a] - e[b]), 0) + MOVE_COST * moves(w);
        if (cost < low) { low = cost; best = w; }
      }
    }
    // Moving a card would start its rising-in again and drop the focus: carry both across.
    if (best.some((k, i) => k !== where(cards[i].el))) {
      const was = cards.map(({ el }) => el.getAnimations().map((a) => a.currentTime));
      const focus = document.activeElement;
      cards.forEach((x, i) => {
        if (best[i] === "R" && fits) R.insertBefore(x.el, q);
        else into[best[i]].appendChild(x.el);
      });
      cards.forEach(({ el }, i) => el.getAnimations().forEach((a, j) => { if (was[i][j] != null) a.currentTime = was[i][j]; }));
      if (focus && focus !== document.activeElement && document.contains(focus)) focus.focus({ preventScroll: true });
    }
    fitQuests();
    level();
  }

  // Each row of columns ends level: the shorter column's last card runs on to where the longest ends,
  // the equipment card by its portrait. What's left to even out once the cards are placed and the
  // quest log fitted is usually a few pixels; it's more only for a character with little in a column.
  function unlevel() {
    document.querySelectorAll("#charGrid .grow").forEach((el) => { el.classList.remove("grow"); el.style.minHeight = ""; });
  }
  function level() {
    unlevel();
    const grid = document.getElementById("charGrid");
    if (!grid) return;
    const rows = new Map();
    for (const s of grid.children) {
      if (!s.classList.contains("stack") || !s.lastElementChild) continue;
      const t = layoutTop(s);
      rows.set(t, [...(rows.get(t) || []), s]);
    }
    const grow = [];
    for (const row of rows.values()) {
      if (row.length < 2) continue;
      const ends = row.map((s) => layoutBottom(s.lastElementChild)), last = Math.max(...ends);
      // The quest log shown in full, as asked, runs on below the cards beside it.
      if (questsAll && row[ends.indexOf(last)].querySelector("#questsCard")) continue;
      row.forEach((s, i) => {
        const card = s.querySelector(":scope > .card.equip") || s.lastElementChild;
        if (last - ends[i] >= 1) grow.push([card, card.offsetHeight + last - ends[i]]);
      });
    }
    grow.forEach(([card, h]) => { card.style.minHeight = `${h}px`; card.classList.add("grow"); });
  }

  function fitQuests() {
    const card = document.getElementById("questsCard");
    const more = card && card.querySelector("[data-quests-all]");
    if (!more) return;
    const rows = [...card.querySelectorAll(".quest")];
    rows.forEach((r) => r.classList.remove("off"));
    more.classList.remove("off");
    if (questsAll) return;
    const right = card.closest(".stack"), left = right && right.previousElementSibling;
    let shown = Math.min(rows.length, QUESTS_STACKED);
    if (left && left.classList.contains("stack") && left.lastElementChild && layoutTop(left) === layoutTop(right)) {
      const reach = layoutBottom(left.lastElementChild);
      const reserve = layoutBottom(card) - layoutBottom(rows[rows.length - 1]);
      const over = rows.findIndex((r, i) => i >= QUESTS_MIN && layoutBottom(r) > reach - reserve);
      shown = over < 0 ? rows.length : over;
    }
    rows.forEach((r, i) => r.classList.toggle("off", i >= shown));
    more.classList.toggle("off", shown >= rows.length);
  }

  function profile(c) {
    const p = c.profile || {}, d = c.profileDraft || {};
    const get = (k) => (p[k] != null ? [p[k], false] : d[k] != null ? [d[k], true] : [null, false]);
    const misc = Object.assign({}, d.misc || {}, p.misc || {});
    const miscDraft = (k) => !(p.misc && p.misc[k]);
    const about = Object.assign({}, d.about || {}, p.about || {});
    const aboutDraft = (k) => !(p.about && p.about[k]);
    let drafts = 0;
    const mark = (isDraft) => { if (!isDraft) return ""; drafts++; return '<i class="dmark" title="From your prepared profile text, not in Total RP 3 yet"></i>'; };
    const facts = [["Race", "race"], ["Class", "class"], ["Age", "age"], ["Eyes", "eyes"], ["Birthplace", "birthplace"], ["Residence", "residence"], ["Height", "height"], ["Build", "build"]]
      .map(([label, k]) => { const [v, dr] = get(k); return v ? `<dt>${label}</dt><dd>${esc(v)}${mark(dr)}</dd>` : ""; }).join("") +
      Object.entries(misc).filter(([k]) => k !== "Motto").map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}${mark(miscDraft(k))}</dd>`).join("");
    const sections = [["physical", "Appearance"], ["personality", "Personality"], ["history", "What people say"], ["text", "About"]]
      .filter(([k]) => about[k]).map(([k, label]) => `<h4>${label}${mark(aboutDraft(k))}</h4><p>${esc(about[k])}</p>`).join("");
    const [cur, curDraft] = get("currently");
    const [ooc, oocDraft] = get("ooc");
    const motto = misc.Motto ? `<div class="motto">${esc(misc.Motto)}${mark(miscDraft("Motto"))}</div>` : "";
    const curHtml = cur ? `<div class="currently"><b>Currently${mark(curDraft)}</b>${esc(cur)}</div>` : "";
    const oocHtml = ooc ? `<div class="currently ooc"><b>Out of character${mark(oocDraft)}</b>${esc(ooc)}</div>` : "";
    // The rest of her Total RP 3 profile: status, glances, personality and roleplay style, and her
    // about text as Total RP 3 lays it out when it has one (else the prepared text above).
    const rp = c.rp || {};
    const aboutHtml = rpAbout(rp) || sections;
    const chips = rpChips(rp), glances = rpGlances(rp), traits = rpTraits(rp), style = rpStyle(rp);
    const extra = [
      glances ? `<div class="rpsub"><h4>At first glance</h4><div class="glances">${glances}</div></div>` : "",
      traits ? `<div class="rpsub"><h4>Personality</h4><div class="traits">${traits}</div></div>` : "",
      style ? `<div class="rpsub"><h4>Roleplay style</h4><div class="stats">${style}</div></div>` : "",
    ].join("");
    if (!facts && !aboutHtml && !motto && !cur && !chips && !extra) {
      return `<section class="card c-12 rise" style="--i:9"><header><h2>Roleplay profile</h2></header><div class="empty-note">No Total RP 3 profile for this character yet.</div></section>`;
    }
    return `<section class="card c-12 rise" style="--i:9">
      <header><h2>Roleplay profile</h2><small>${drafts ? '<i class="dmark"></i> from your prepared text, not in Total RP 3 yet' : "From Total RP 3"}</small></header>
      ${chips ? `<div class="tags rpchips">${chips}</div>` : ""}
      <div class="profile">
        <div>${motto}<dl class="facts">${facts}</dl>${curHtml}${oocHtml}</div>
        <div class="prose rptext">${aboutHtml}</div>
      </div>
      ${extra ? `<div class="rpextra">${extra}</div>` : ""}
    </section>`;
  }

  function account(chars) {
    const some = (part) => chars.some((c) => !hides(c, part)), all = (part) => chars.every((c) => !hides(c, part));
    const show = { place: some("place"), gold: some("gold"), played: some("played") };
    const kept = '<span class="faint">Private</span>';
    const rows = chars.map((c) => `<tr class="pick ${c.key === current ? "me" : ""}" data-pick="${esc(c.key)}">
      <td><span class="nm" style="--cc:${classColor(c)}"><i></i>${esc(fullName(c))}</span></td>
      <td class="num">${c.level ?? "-"}</td>
      <td class="hide-s">${esc([c.race, c.class].filter(Boolean).join(" "))}</td>
      ${show.place ? `<td class="hide-s">${hides(c, "place") ? kept : esc(c.zone || "-")}</td>` : ""}
      ${show.gold ? `<td>${hides(c, "gold") ? kept : money(c.money, true)}</td>` : ""}
      ${show.played ? `<td class="num">${hides(c, "played") ? kept : played(c.played)}</td>` : ""}
      <td class="faint hide-s">${ago(c.updated)}</td>
    </tr>`).join("");
    const gold = chars.reduce((s, c) => s + (c.money || 0), 0), time = chars.reduce((s, c) => s + (c.played || 0), 0);
    return `<section class="card c-12 rise" style="--i:10">
      <header><h2>All characters</h2><small>${chars.length} recorded</small></header>
      <div class="tablewrap"><table class="roll">
        <thead><tr><th>Name</th><th>Level</th><th class="hide-s">Race and class</th>${show.place ? '<th class="hide-s">Last seen in</th>' : ""}${show.gold ? "<th>Gold</th>" : ""}${show.played ? "<th>Played</th>" : ""}<th class="hide-s">Saved</th></tr></thead>
        <tbody>${rows}</tbody>
        <tfoot><tr><td>Account</td><td></td><td class="hide-s"></td>${show.place ? '<td class="hide-s"></td>' : ""}${show.gold ? `<td>${all("gold") ? money(gold, true) : ""}</td>` : ""}${show.played ? `<td class="num">${all("played") ? played(time) : ""}</td>` : ""}<td class="hide-s"></td></tr></tfoot>
      </table></div>
      ${hood()}
    </section>`;
  }

  function hood() {
    const c = char();
    const m = state.meta || {};
    const src = state.sources.map((s) => `<div>${esc(s.path || "Saved file")}${s.mtime ? ` · written ${ago(s.mtime)}` : ""}${s.error ? ` <span class="err">${esc(s.error)}</span>` : ""}</div>`).join("");
    const errs = c && c.errors ? Object.entries(c.errors).map(([k, v]) => `<div class="err">Couldn't read ${esc(k)}: ${esc(v)}</div>`).join("") : "<div>Every part read cleanly at the last save.</div>";
    return `<details class="hood"><summary>Under the hood</summary><div class="hoodbody">
      ${src || "<div>No saved file yet.</div>"}
      <div>Addon ${esc(m.addon || "?")} · client ${esc(m.client || "?")} build ${esc(m.build || "?")} · interface ${esc(m.interface || "?")}</div>
      ${errs}
      ${c && c.journey && c.journey.hiddenKills ? `<div>Kills whose killer the game kept hidden from the addon: ${n(c.journey.hiddenKills)} (not counted as killing blows)</div>` : ""}
      <div>Icons from Blizzard's icon server${isPublic() ? "" : ", cached on this PC"}.</div>
    </div></details>`;
  }

  function welcome() {
    if (isPublic()) {
      return `${strip([])}<section class="welcome rise"><h1>Nothing recorded yet</h1><p>This reliquary fills itself in the first time its owner logs out of the game.</p></section>`;
    }
    return `${strip([])}<section class="welcome rise">
      <h1>Nothing recorded yet</h1>
      <p>Reliquary is installed and watching for your first save.</p>
      <div class="steps">
        <div><b>1</b><span>Start WoW: Forever. On the character screen, open <i>AddOns</i> and make sure <i>Reliquary</i> is ticked.</span></div>
        <div><b>2</b><span>Log in on Joan and play as you normally would.</span></div>
        <div><b>3</b><span>Log out, or type <span class="mono">/reload</span>. This page fills itself in within a few seconds.</span></div>
      </div>
      <a class="btn" href="?demo=1">Preview with sample data</a>
    </section>`;
  }

  // ── Sharing: who sees this character, and which parts of it ─────────────
  // The parts a player chooses to show, in the order of the game's own grid (Share.lua).
  const PART_ROWS = [
    ["gear", "Gear"], ["talents", "Talents"], ["profs", "Professions"], ["stats", "Character sheet"], ["gold", "Gold"],
    ["place", "Where you are"], ["played", "Time played"], ["reps", "Reputation"], ["quests", "Quest log"], ["bags", "Bags"], ["bank", "Bank"],
  ];
  const AUDIENCES = [["guild", "g", "Guild"], ["friends", "f", "Friends"], ["public", "p", "Public"]];

  function sharing(c) {
    if (isPublic()) return "";
    const s = c.share;
    const head = `<header><h2>Who sees ${esc(c.name || "this character")}</h2></header>`;
    if (!s) {
      return `<section class="card rise" style="--i:4" id="whoCard">${head}
        <p class="faint" style="margin:0">Saved before sharing existed, so all of it stays on your public copy. The next time you log in, Reliquary keeps it public with every part shown, and turns guild and friends off until you choose.</p>
      </section>`;
    }
    const parts = s.parts || {};
    const cols = AUDIENCES.map(([k, , label]) => `<th scope="col" class="${s[k] ? "on" : "off"}"><b>${label}</b><i>${s[k] ? "On" : "Off"}</i></th>`).join("");
    const rows = PART_ROWS.map(([part, label]) => `<tr><th scope="row">${label}</th>${AUDIENCES.map(([k, letter, aud]) => {
      const shown = (parts[part] || "").includes(letter);
      const say = !shown ? "Hidden" : s[k] ? "Shown" : `Shown once ${aud.toLowerCase()} sharing is on`;
      return `<td class="${shown ? "yes" : "no"}${s[k] ? "" : " off"}" title="${label}: ${say.toLowerCase()}">${svg(shown ? "check" : "dash")}<span class="sr">${say}</span></td>`;
    }).join("")}</tr>`).join("");
    return `<section class="card rise" style="--i:4" id="whoCard">${head}
      <table class="seegrid"><thead><tr><th scope="col"><span class="sr">Part</span></th>${cols}</tr></thead><tbody>${rows}</tbody></table>
      <p class="faint share-how">Name, race, class, level and guild go with any of them. Choose in game for each character: the Sharing tab of <span class="mono">/rq</span>, or for example <span class="mono">/rq share gold public off</span>. Your public page follows the Public column, and there <i>Where you are</i> also covers the timeline and where photos were taken.</p>
    </section>`;
  }

  // ── Total RP 3: roleplay profiles, as server/roleplay.py makes them plain data ──
  // Every word in a profile is someone's writing: rp.js turns their text into safe HTML (escaped,
  // six-digit colours, whole icon ids, http(s) links only), and everything else here is escaped too.
  const { runs: rpRuns, blocks: rpBlocks, hexColor, iconId } = window.ReliquaryRP;
  const rpByUnit = (unit) => (unit && state && (state.roleplay || []).find((c) => c.unit === unit)) || null;

  function rpChips(c) {
    return [
      c.status === "ic" ? `<span class="tag verdant">${svg("mask")}In character</span>` : c.status === "ooc" ? `<span class="tag crimson">Out of character</span>` : "",
      c.experience ? `<span class="tag">${esc(c.experience)}</span>` : "",
      c.walkup ? '<span class="tag gold">Walkup friendly</span>' : "",
      c.relationship ? `<span class="tag">${esc(c.relationship)}</span>` : "",
    ].join("");
  }

  function rpGlances(c) {
    return (c.glances || []).map((g) => `<div class="glance">${iconId(g.icon) ? icon(iconId(g.icon), 1, 34) : ""}<div><b>${esc(g.title || "")}</b>${g.text ? `<div class="rptext">${rpBlocks(g.text)}</div>` : ""}</div></div>`).join("");
  }

  // A personality trait as Total RP 3 shows it: the left trait's share of twenty, the right's the rest.
  function rpTraits(c) {
    return (c.traits || []).map((t) => {
      const v = Math.max(0, Math.min(20, Number(t.value) || 0));
      const lc = hexColor(t.leftColor) || "ffc26b", rc = hexColor(t.rightColor) || "6ba6ff";
      return `<div class="trait">
        <span class="tl">${iconId(t.leftIcon) ? icon(iconId(t.leftIcon), 1, 26) : ""}<b>${esc(t.left)}</b><i>${v}</i></span>
        <span class="tbar"><i style="width:${(v / 20) * 100}%;background:#${lc}"></i><i style="width:${((20 - v) / 20) * 100}%;background:#${rc}"></i></span>
        <span class="tr"><i>${20 - v}</i><b>${esc(t.right)}</b>${iconId(t.rightIcon) ? icon(iconId(t.rightIcon), 1, 26) : ""}</span>
      </div>`;
    }).join("");
  }

  function rpStyle(c) {
    return (c.style || []).map((x) => `<div class="stat"><span class="k">${esc(x.name)}</span><span class="v">${esc(x.value)}</span></div>`).join("");
  }

  function rpAbout(c) {
    const a = c.about;
    if (!a) return "";
    if (a.text) return rpBlocks(a.text);
    if (a.sections) return a.sections.map((x) => `<h4>${iconId(x.icon) ? icon(iconId(x.icon), 1, 22) : ""}${esc(x.name)}</h4>${rpBlocks(x.text)}`).join("");
    if (a.frames) return a.frames.map((f) => `<div class="rpframe">${iconId(f.icon) ? icon(iconId(f.icon), 1, 40) : ""}<div>${rpBlocks(f.text)}</div></div>`).join("");
    return "";
  }

  // Everything in one Total RP 3 profile.
  function rpCard(c) {
    if (!c) return "";
    const color = hexColor(c.color);
    const facts = [["Race", c.race], ["Class", c.class], ["Age", c.age], ["Height", c.height], ["Build", c.build],
      ["Eyes", c.eyes, c.eyeColor], ["Birthplace", c.birthplace], ["Residence", c.residence], ["Guild", c.guild && `<${c.guild}>`]]
      .filter(([, v]) => v)
      .map(([k, v, sw]) => `<dt>${k}</dt><dd>${hexColor(sw) ? `<i class="swatch" style="background:#${hexColor(sw)}"></i>` : ""}${esc(v)}</dd>`).join("") +
      (c.misc || []).map((m) => `<dt>${esc(m.name)}</dt><dd>${iconId(m.icon) ? `<img class="rpi" src="/icon/${iconId(m.icon)}.jpg" alt="">` : ""}${esc(m.value)}</dd>`).join("");
    const now = [c.currently ? `<div class="currently"><b>Currently</b>${rpRuns(c.currently)}</div>` : "",
      c.ooc ? `<div class="currently ooc"><b>Out of character</b>${rpRuns(c.ooc)}</div>` : ""].join("");
    const chips = rpChips(c), glances = rpGlances(c), traits = rpTraits(c), style = rpStyle(c), about = rpAbout(c);
    const foot = [c.client && `Profile from ${c.client}${c.msp ? " (another roleplay addon's profile)" : ""}`,
      c.seen && `last seen${c.seenIn ? ` in ${c.seenIn}` : ""} ${ago(c.seen)}`].filter(Boolean).join(" · ");
    return `<div class="rpcard">
      <header class="rphead">${iconId(c.icon) ? icon(iconId(c.icon), 1, 54) : `<span class="rpnoicon">${svg("mask")}</span>`}
        <div><h3 class="rpname"${color ? ` style="color:#${color}"` : ""}>${esc(c.name || "Unnamed")}</h3>
          ${c.title ? `<div class="rptitle">${esc(c.title)}</div>` : ""}${c.fullTitle ? `<div class="rpfull">${esc(c.fullTitle)}</div>` : ""}</div>
      </header>
      ${chips ? `<div class="tags">${chips}</div>` : ""}
      ${facts || now || glances ? `<div class="rpgrid"><div>${facts ? `<dl class="facts">${facts}</dl>` : ""}${now}</div>
        <div>${glances ? `<div class="rpsub"><h4>At first glance</h4><div class="glances">${glances}</div></div>` : ""}</div></div>` : ""}
      ${traits ? `<div class="rpsub"><h4>Personality</h4><div class="traits">${traits}</div></div>` : ""}
      ${style ? `<div class="rpsub"><h4>Roleplay style</h4><div class="stats">${style}</div></div>` : ""}
      ${about ? `<div class="rpsub"><h4>About</h4><div class="prose rptext">${about}</div></div>` : ""}
      ${foot ? `<p class="rpfoot faint">${esc(foot)}</p>` : ""}
    </div>`;
  }

  // ── Views: your characters, your guild, friends, everyone ───────────────
  const VIEWS = [["chars", "Characters"], ["guild", "Guild"], ["friends", "Friends"], ["public", "Public"], ["roleplay", "Roleplay"]];
  let view = "chars";
  let guildPick = null;    // which guild, when your characters are in several
  let memberPick = null;   // the guildmate shown beside the roster
  const peerPick = { friends: null, public: null };
  let peerBags = "bags";     // their bags or their bank, on a shared reliquary
  let rosterFilter = "all";
  let rosterQuery = "";
  let rpQuery = "";
  let rpFilter = "all";
  let rpPick = null;        // the profile shown in the Roleplay view
  let bankTab = null;
  let bankQuery = "";
  let bankHelps = false;    // the guild bank shows only what would be an upgrade for someone
  let bankView = "items";   // the guild bank tab's items, its log, or the gold log

  const peerByKey = (key) => (state.peers || []).find((p) => p.key === key) || null;
  const peersOf = (scope) => (state.peers || []).filter((p) => (p.scopes || []).includes(scope));
  const treeNames = (p) => (CLASS[p.classFile] || {}).tabs || ["Tree 1", "Tree 2", "Tree 3"];
  const colorOfClass = (file) => (CLASS[file] || {}).c || "rgb(164,151,126)";

  function readHash() {
    const parts = decodeURIComponent(location.hash.slice(1)).split("/");
    view = !isPublic() && VIEWS.some(([k]) => k === parts[0]) ? parts[0] : "chars";
    const m = /^item-(\d+)$/.exec(parts[1] || "") || /^item-(\d+)$/.exec(parts[0] || "");
    // A recipe book: whose (c: one of your characters, p: someone who shares with you) and which profession.
    const k = /^craft-([cp]:[^~]+)~(.+)$/.exec(parts[1] || "") || /^craft-([cp]:[^~]+)~(.+)$/.exec(parts[0] || "");
    if (k) craftOpen = { owner: k[1], prof: k[2] };
    else if (!m) craftOpen = null;
    if (!m) itemOpen = null;
    else if (!itemOpen || itemOpen.id !== Number(m[1])) itemOpen = { id: Number(m[1]) };
  }

  function viewsNav() {
    if (isPublic()) return "";
    const n = { friends: peersOf("friends").length, public: peersOf("public").length,
      guild: (state.guilds || []).reduce((s, g) => s + g.members.filter((m) => m.shares).length, 0), roleplay: (state.roleplay || []).length };
    return `<div class="views seg" role="tablist" aria-label="What to show">${VIEWS.map(([k, label]) => `<button role="tab" data-view="${k}" aria-selected="${view === k}" aria-pressed="${view === k}">${label}${n[k] ? `<i>${n[k]}</i>` : ""}</button>`).join("")}</div>`;
  }

  function lastSeen(m) {
    if (m.online) return m.zone ? esc(m.zone) : "Online";
    return m.seen ? `Seen ${ago(m.seen)}` : "Offline";
  }

  // Another player's reliquary, as they shared it with you.
  function peerSlot(p, slot) {
    slot = String(slot);
    const it = p.gear && p.gear[slot];
    const label = slot === "18" && RELIC_CLASSES.has(p.classFile) ? "Relic" : SLOT[slot];
    if (!it) return `<div class="slot empty">${icon(null, null, 40)}<div class="meta"><div class="nm">${label}</div><div class="sb">Empty</div></div></div>`;
    return `<div class="slot" tabindex="0" data-stip="pgear|${esc(p.key)}|${slot}">${icon(it.icon, it.q, 40)}<div class="meta"><div class="nm qt${it.q ?? 1}">${esc(it.name)}</div><div class="sb">${label}${it.ilvl ? ` · ilvl ${it.ilvl}` : ""}</div></div></div>`;
  }

  function scopeTags(p) {
    const words = { guild: "your guild", friends: "friends", public: "everyone" };
    const marks = { guild: "banner", friends: "star", public: "pin" };
    return (p.scopes || []).filter((s) => words[s]).map((s) => `<span class="tag ${s === "public" ? "sky" : "gold"}">${svg(marks[s])}Shared with ${words[s]}</span>`).join("");
  }

  function peerSheet(p) {
    const color = colorOfClass(p.classFile);
    const t = p.talents;
    const trees = t && t.pts ? treeNames(p).map((name, i) => {
      const pts = t.pts[i] || 0;
      const total = t.pts.reduce((a, b) => a + (b || 0), 0) || 1;
      return `<div class="tbar"><div class="top"><b>${esc(name)}</b><span>${pts}</span></div><div class="meter"><i style="width:${(pts / total) * 100}%"></i></div></div>`;
    }).join("") : "";
    const learned = t && t.nodes ? t.nodes.map((n, i) => `<span class="tnode on${n.rank >= n.max ? " max" : ""}" tabindex="0" data-stip="ptal|${esc(p.key)}|${i}">${icon(n.icon, 1, 34)}<span class="rk">${n.rank}/${n.max ?? n.rank}</span></span>`).join("") : "";
    const profs = (p.profs || []).map((x) => profRow(`p:${p.key}`, p.recipes, x, 30)).join("");
    const st = p.stats || {};
    const STATN = [["str", "Strength"], ["agi", "Agility"], ["sta", "Stamina"], ["int", "Intellect"], ["spi", "Spirit"], ["armor", "Armor"], ["ap", "Attack power"], ["sp", "Spell power"], ["heal", "Healing"], ["crit", "Crit", "%"]];
    const stats = STATN.filter(([k]) => typeof st[k] === "number" && st[k]).map(([k, label, unit]) => `<div><b>${unit ? Number(st[k]).toFixed(2) + "%" : n(st[k])}</b><span>${label}</span></div>`).join("");
    // Their card holds who they are and the parts they show; the rest arrive in sections of their own.
    const got = Array.isArray(p.shows);
    const lv = p.live || {};
    const where = [lv.subzone, lv.zone].filter(Boolean).filter((v, i, a) => a.indexOf(v) === i).join(", ");
    const coords = typeof lv.x === "number" && typeof lv.y === "number" ? ` <span class="mono faint">${lv.x.toFixed(1)}, ${lv.y.toFixed(1)}</span>` : "";
    const facts = [
      typeof lv.gold === "number" ? `<div><b>${money(lv.gold, true)}</b><span>Gold</span></div>` : "",
      typeof lv.played === "number" ? `<div><b>${played(lv.played)}</b><span>Played</span></div>` : "",
      typeof lv.playedLevel === "number" ? `<div><b>${played(lv.playedLevel)}</b><span>This level</span></div>` : "",
    ].join("");
    const which = !p.bags ? "bank" : !p.bank ? "bags" : peerBags;
    const held = which === "bank" ? p.bank : p.bags;
    const pbags = held ? `<div class="psub">
        <div class="psubhead"><h3>${which === "bank" ? `Bank${p.bankAt ? ` <small>visited ${ago(p.bankAt)}</small>` : ""}` : "Bags"}</h3>
          ${p.bags && p.bank ? `<div class="seg" role="group" aria-label="Their bags or bank"><button data-pbags="bags" aria-pressed="${which === "bags"}">Bags</button><button data-pbags="bank" aria-pressed="${which === "bank"}">Bank</button></div>` : ""}</div>
        <div class="pbags">${bagCells(held, which, "", (bi, sl) => `data-stip="pbag|${esc(p.key)}|${which}|${bi}" data-slot="${sl}"`, (bi) => `data-stip="pbagitem|${esc(p.key)}|${which}|${bi}"`, 38) || '<div class="empty-note">Nothing in them.</div>'}</div>
      </div>` : "";
    return `<div class="psheet">
      <header class="phead">
        <div class="pmedal" style="--cc:${color}"><span>${esc((p.name || "?").slice(0, 1))}</span><b>${p.level ?? "?"}</b></div>
        <div class="pident">
          ${p.guild ? `<div class="eyebrow">&lt;${esc(p.guild)}&gt;${p.guildRank ? ` ${esc(p.guildRank)}` : ""}</div>` : p.title ? `<div class="eyebrow">${esc(p.title)}</div>` : ""}
          <h2 class="pname">${esc(p.name)}</h2>
          <div class="line">Level <b>${p.level ?? "?"}</b> ${esc(p.race || "")} <b style="color:${color}">${esc(p.class || "")}</b>${p.ilvl ? ` <span class="dim">· item level ${Number(p.ilvl).toFixed(1)}</span>` : ""}</div>
          <div class="tags">${scopeTags(p)}${where ? `<span class="tag gold">${svg("pin")}${esc(where)}${coords}</span>` : ""}${lv.hearth ? `<span class="tag">${svg("hearth")}Hearth: ${esc(lv.hearth)}</span>` : ""}<span class="tag">${svg("moon")}Shared ${ago(p.got || p.seen)}</span></div>
        </div>
      </header>
      ${facts ? `<div class="plive">${facts}</div>` : ""}
      ${(p.scopes || []).includes("guild") ? bankForBlock(p.key, "them") : ""}
      ${!got ? `<div class="empty-note">Their reliquary is on its way: it arrives the next time you are both online.</div>`
        : p.shows.includes("gear") ? `<div class="pdoll"><div class="slots left">${LEFT.map((x) => peerSlot(p, x)).join("")}</div><div class="slots right">${RIGHT.map((x) => peerSlot(p, x)).join("")}</div><div class="weapons">${WEAPONS.map((x) => peerSlot(p, x)).join("")}</div></div>` : ""}
      ${trees ? `<div class="psub"><h3>Talents</h3><div class="tbars">${trees}</div>${learned ? `<div class="learned">${learned}</div>` : ""}</div>` : ""}
      ${profs ? `<div class="psub"><h3>Professions</h3><div class="bars">${profs}</div></div>` : ""}
      ${stats ? `<div class="psub"><h3>Character sheet</h3><div class="pstats">${stats}</div></div>` : ""}
      ${pbags}
      ${p.reps && p.reps.length ? `<div class="psub"><h3>Reputation</h3><div class="preps">${repRows(p.reps)}</div></div>` : ""}
      ${p.quests && p.quests.length ? `<div class="psub"><h3>Quest log</h3><div class="quests">${questRows(p.quests, p.level)}</div></div>` : ""}
      ${rpByUnit(p.rp) ? `<div class="psub"><h3>Roleplay profile <small>from Total RP 3</small></h3>${rpCard(rpByUnit(p.rp))}</div>` : ""}
    </div>`;
  }

  function rosterSheet(m) {
    const color = colorOfClass(m.classFile);
    const cls = m.classFile ? m.classFile[0] + m.classFile.slice(1).toLowerCase() : "";
    return `<div class="psheet">
      <header class="phead">
        <div class="pmedal plain" style="--cc:${color}"><span>${esc((m.name || "?").slice(0, 1))}</span><b>${m.level ?? "?"}</b></div>
        <div class="pident">
          ${m.rank ? `<div class="eyebrow">${esc(m.rank)}</div>` : ""}
          <h2 class="pname">${esc(m.name)}</h2>
          <div class="line">Level <b>${m.level ?? "?"}</b> <b style="color:${color}">${esc(cls)}</b></div>
          <div class="tags"><span class="tag ${m.online ? "gold" : ""}">${svg("pin")}${lastSeen(m)}</span>${(m.profs || []).map((x) => `<span class="tag">${esc(x.name)}${x.skill ? ` ${x.skill}` : ""}</span>`).join("")}</div>
        </div>
      </header>
      ${m.note ? `<p class="mnote">${esc(m.note)}</p>` : ""}
      ${bankForBlock(m.key, m.me ? "you" : "them")}
      <div class="empty-note">${m.me ? "This is you. Your own reliquary is under Characters." : `${esc(m.name)} doesn't share a reliquary with the guild. Guildmates who use Reliquary and turn on guild sharing show what they choose here: gear, talents and professions, and if they like their gold, bags, reputations and quests.`}</div>
      ${!m.me && rpByUnit(m.rp) ? `<div class="psub"><h3>Roleplay profile <small>from Total RP 3</small></h3>${rpCard(rpByUnit(m.rp))}</div>` : ""}
    </div>`;
  }

  function guildView() {
    const guilds = state.guilds || [];
    if (!guilds.length) {
      return `<section class="welcome rise"><h1>No guild yet</h1><p>When one of your characters is in a guild, everyone in it is listed here, guildmates who share their reliquary show what they choose to, and the guild bank is here as you last saw it.</p></section>`;
    }
    const c = char();
    const gi = Math.max(0, guilds.findIndex((x) => x.key === guildPick) >= 0 ? guilds.findIndex((x) => x.key === guildPick) : guilds.findIndex((x) => c && x.name === c.guild));
    const g = guilds[gi];
    guildPick = g.key;
    const online = g.members.filter((m) => m.online).length;
    const sharers = g.members.filter((m) => m.shares).length;
    const q = rosterQuery.trim().toLowerCase();
    const members = g.members
      .filter((m) => rosterFilter === "all" || (rosterFilter === "online" ? m.online : m.shares))
      .filter((m) => !q || [m.name, m.rank, m.zone, m.note, ...(m.profs || []).map((x) => x.name)].some((v) => (v || "").toLowerCase().includes(q)))
      .sort((a, b) => (b.online - a.online) || (b.shares - a.shares) || ((a.rankOrder ?? 99) - (b.rankOrder ?? 99)) || a.name.localeCompare(b.name));
    if (!g.members.some((m) => m.key === memberPick)) memberPick = (g.members.find((m) => m.shares && !m.me) || g.members[0] || {}).key;
    const picked = g.members.find((m) => m.key === memberPick);
    const sheet = picked ? (picked.shares && peerByKey(picked.key) ? peerSheet(peerByKey(picked.key)) : rosterSheet(picked)) : "";
    const rows = members.map((m) => `<button class="mrow${m.key === memberPick ? " sel" : ""}${m.online ? "" : " off"}" data-member="${esc(m.key)}" style="--cc:${colorOfClass(m.classFile)}">
        <i class="dot"></i><span class="nm">${esc(m.name)}${m.me ? ' <span class="you">you</span>' : ""}${!m.me && rpByUnit(m.rp) ? `<span class="rpmark" title="Has a Total RP 3 profile">${svg("mask")}</span>` : ""}</span>
        ${m.shares ? `<span class="relic" title="Shares a reliquary with the guild">${svg("gem")}</span>` : "<span></span>"}
        <span class="rk">${esc(m.rank || "")}</span><span class="lv">${m.level ?? ""}</span>
      </button>`).join("");
    const pickGuild = guilds.length > 1 ? `<div class="seg gpick">${guilds.map((x, i) => `<button data-guild="${esc(x.key)}" aria-pressed="${i === gi}">${esc(x.name)}</button>`).join("")}</div>` : "";
    return `<div class="grid">
      <section class="card c-12 ghead rise" style="--i:0">
        <div class="crest" aria-hidden="true">${svg("banner")}</div>
        <div class="gident">
          <div class="eyebrow">${esc(g.realm || "")}${g.faction ? ` · ${esc(g.faction)}` : ""}</div>
          <h1>&lt;${esc(g.name)}&gt;</h1>
          ${g.motd ? `<p class="motd">${esc(g.motd)}</p>` : ""}
        </div>
        <div class="gstats">
          <div><b>${g.members.length}</b><span>Members</span></div>
          <div><b>${online}</b><span>Online</span></div>
          <div><b>${sharers}</b><span>Share a reliquary</span></div>
          ${g.bank.money != null ? `<div><b>${money(g.bank.money, true)}</b><span>Guild bank</span></div>` : ""}
        </div>
        ${pickGuild}
      </section>
      <div class="duo c-12">
      <section class="card c-5 listcard rise" style="--i:1">
        <header><h2>Roster</h2><small>${g.at ? `As of ${ago(g.at)}` : ""}</small></header>
        <div class="rtools">
          <div class="seg" role="group" aria-label="Who to list">
            <button data-filter="all" aria-pressed="${rosterFilter === "all"}">All</button>
            <button data-filter="online" aria-pressed="${rosterFilter === "online"}">Online</button>
            <button data-filter="shares" aria-pressed="${rosterFilter === "shares"}">Reliquary</button>
          </div>
          <label class="search">${svg("search")}<span class="sr">Find a guildmate</span><input id="rosterSearch" type="search" placeholder="Name, rank, zone, profession" value="${esc(rosterQuery)}" autocomplete="off"></label>
        </div>
        <div class="mlist">${rows || '<div class="empty-note">Nobody matches.</div>'}</div>
      </section>
      <section class="card c-7 rise" style="--i:2" id="memberCard">${sheet}</section>
      </div>
      ${bankCard(g, gi)}
    </div>`;
  }

  // A tab's log, or the gold log, newest first, in the bank's own words.
  const LOG_WORDS = { deposit: "put in", withdraw: "took", move: "moved", repair: "repaired with", withdrawForTab: "bought a tab with", buyTab: "bought a tab for", depositSummary: "put in" };
  function logRows(entries, gi, tabIndex, gold) {
    const rows = entries.map((e, k) => {
      const verb = `<span class="lverb ${esc(e.kind)}">${esc(LOG_WORDS[e.kind] || e.kind)}</span>`;
      const what = gold
        ? `<span class="lmoney">${money(e.money || 0)}</span>`
        : `${e.n > 1 ? `${e.n} ` : ""}<span class="qt${e.q ?? 1}">${esc(e.name || "an item")}</span>${e.to ? ` to ${esc(e.to)}` : ""}`;
      const pic = gold ? '<span class="lcoin" aria-hidden="true"></span>'
        : `<span class="lpic" tabindex="0" data-stip="gl|${gi}|${tabIndex}|${k}">${icon(e.icon, e.q, 32)}</span>`;
      return `<div class="lrow">${pic}<span class="ltext"><b>${esc(e.who || "Someone")}</b> ${verb} ${what}</span><span class="lwhen">${ago(e.at)}</span></div>`;
    }).join("");
    return rows || '<div class="empty-note">Nothing in this log yet.</div>';
  }

  // What your rank may take, in one line.
  function limitsLine(lim, tabIndex) {
    if (!lim) return "";
    const perDay = lim.tabs ? lim.tabs[String(tabIndex)] : null;
    const bits = [];
    if (perDay === -1) bits.push("as many stacks as you like from this tab");
    else if (perDay > 0) bits.push(`${perDay} ${perDay === 1 ? "stack" : "stacks"} a day from this tab`);
    if (lim.gold === -1) bits.push("any gold from the bank");
    else if (lim.gold > 0) bits.push(`${lim.gold}g a day from the bank`);
    if (!bits.length) return "";
    return `Your rank${lim.rank ? ` (${esc(lim.rank)})` : ""} may take ${bits.join(", and ")}.`;
  }

  // The guild bank as the game lays it out: seven groups of fourteen slots, two wide. Like the
  // bank's own frame it shows a tab's items, its log or the gold log.
  function bankCard(g, gi) {
    const b = g.bank || { tabs: [] };
    const head = `<header><h2>Guild bank</h2><small>${b.money != null ? `${money(b.money)}${b.moneyAt ? ` <span class="faint">· ${ago(b.moneyAt)}</span>` : ""}` : ""}</small></header>`;
    if (!b.tabs.length) {
      return `<section class="card c-12 rise" style="--i:3" id="bankCard">${head}<div class="empty-note">Open the guild bank once on a character in &lt;${esc(g.name)}&gt;. Reliquary then knows which tabs that rank may see, and keeps them here as you and your guildmates last saw them.</div></section>`;
    }
    const tab = b.tabs.find((t) => t.index === bankTab) || b.tabs[0];
    bankTab = tab.index;
    let mode = bankView;
    if (mode === "log" && !tab.log) mode = "items";
    if (mode === "gold" && !b.goldLog) mode = "items";
    const q = bankQuery.trim().toLowerCase();
    const helpsSomeone = (it) => ((g.fits || {})[String(it.id)] || []).some((x) => x.v === "up");
    // The filter shows only while something in the bank would help someone.
    const canHelp = b.tabs.some((t) => Object.values(t.slots).some((it) => it && helpsSomeone(it)));
    const onlyHelps = bankHelps && canHelp;
    const filtering = !!q || onlyHelps;
    const matches = (it) => it && (!q || (it.name || "").toLowerCase().includes(q)) && (!onlyHelps || helpsSomeone(it));
    const tabs = b.tabs.map((t) => {
      const hits = filtering ? Object.values(t.slots).filter(matches).length : 0;
      // The number is how many items in the tab the search or the filter finds; hovering says so.
      const verb = hits === 1 ? "matches" : "match";
      const found = !hits ? "" : `${hits} ${hits === 1 ? "item" : "items"} here ${q && onlyHelps ? `${verb} your search and would help someone in the guild`
        : q ? `${verb} your search` : "would help someone in the guild"}`;
      const title = [t.shared ? `The guild master shares this tab: ${t.shared}` : "", found].filter(Boolean).join(". ");
      return `<button class="btab" data-gtab="${t.index}" aria-pressed="${t.index === tab.index && mode !== "gold"}"${title ? ` title="${esc(title)}"` : ""}>${icon(t.icon, 1, 34)}<span>${esc(t.name)}</span>${filtering && hits ? `<i aria-label="${esc(found)}">${hits}</i>` : ""}</button>`;
    }).join("");
    const views = (tab.log || b.goldLog) ? `<div class="seg bviews" role="group" aria-label="Show">
        <button data-bview="items" aria-pressed="${mode === "items"}">Items</button>
        ${tab.log ? `<button data-bview="log" aria-pressed="${mode === "log"}">Log</button>` : ""}
        ${b.goldLog ? `<button data-bview="gold" aria-pressed="${mode === "gold"}">Gold log</button>` : ""}
      </div>` : "";
    let seen;
    if (mode === "log") seen = `<b>${esc(tab.name)}</b>, read at the bank by ${esc(tab.log.by || "a guildmate")} ${ago(tab.log.at)}`;
    else if (mode === "gold") seen = `<b>Gold log</b>, read at the bank by ${esc(b.goldLog.by || "a guildmate")} ${ago(b.goldLog.at)}`;
    else seen = tab.at ? `<b>${esc(tab.name)}</b> as ${esc(tab.by || "a guildmate")} saw it, ${ago(tab.at)}` : `<b>${esc(tab.name)}</b>`;
    const note = mode !== "gold" && tab.note ? `<p class="bnote"><b>Note</b>${esc(tab.note)}</p>` : "";
    let body;
    if (mode === "items") {
      let groups = "";
      for (let grp = 0; grp < 7; grp++) {
        let cells = "";
        for (let row = 0; row < 7; row++) {
          for (let col = 0; col < 2; col++) {
            const slot = grp * 14 + col * 7 + row + 1;
            const it = tab.slots[String(slot)];
            if (!it) { cells += `<span class="cell empty${filtering ? " dimmed" : ""}"></span>`; continue; }
            const fit = (g.fits || {})[String(it.id)] || [];
            const up = fit.some((x) => x.v === "up") ? `<span class="up${fit.some((x) => x.v === "up" && x.me) ? " mine" : ""}" aria-hidden="true"></span>` : "";
            cells += `<span class="cell ${filtering ? (matches(it) ? "hit" : "dimmed") : ""}" tabindex="0" data-stip="gb|${gi}|${tab.index}" data-slot="${slot}">${icon(it.icon, it.q, null, it.n > 1 ? `<span class="count">${it.n}</span>` : "")}${up}</span>`;
          }
        }
        groups += `<div class="bgroup">${cells}</div>`;
      }
      body = `<div class="bgrid">${groups}</div>`;
    } else {
      body = `<div class="blog">${mode === "gold" ? logRows(b.goldLog.entries, gi, 0, true) : logRows(tab.log.entries, gi, tab.index, false)}</div>`;
    }
    const lim = mode === "gold" ? "" : limitsLine(b.limits, tab.index);
    const pol = b.policy;
    const shared = mode !== "gold" && tab.shared ? `The guild master shares this tab: ${esc(tab.shared.toLowerCase())}.` : "";
    const foot = [lim, shared, pol ? `<span class="faint">Bank sharing set by ${esc(pol.by)}, guild master, ${ago(pol.at)}.</span>` : ""].filter(Boolean).join(" ");
    return `<section class="card c-12 rise" style="--i:3" id="bankCard">${head}
      <div class="btabs">${tabs}</div>
      <div class="btools"><div class="bseen">${seen}</div>${views}
        ${mode === "items" && canHelp ? `<button class="bhelps" data-bhelps aria-pressed="${onlyHelps}" title="Only what would be an upgrade for someone in the guild">Helps someone</button>` : ""}
        ${mode === "items" ? `<label class="search">${svg("search")}<span class="sr">Find an item in the guild bank</span><input id="bankSearch" type="search" placeholder="Find an item in every tab" value="${esc(bankQuery)}" autocomplete="off"></label>` : ""}</div>
      ${note}
      ${body}
      ${foot ? `<p class="bfoot">${foot}</p>` : ""}
    </section>`;
  }

  // ── An item's page: the game's tooltip, who in the guild can use it, where you have it, links ──
  let itemOpen = null; // { id, it }: the item whose page is open, and the copy that was clicked
  const QUALITY = ["Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom"];
  const LOC_WORDS = { INVTYPE_HEAD: "Head", INVTYPE_NECK: "Neck", INVTYPE_SHOULDER: "Shoulder", INVTYPE_CHEST: "Chest", INVTYPE_ROBE: "Chest",
    INVTYPE_WAIST: "Waist", INVTYPE_LEGS: "Legs", INVTYPE_FEET: "Feet", INVTYPE_WRIST: "Wrist", INVTYPE_HAND: "Hands", INVTYPE_FINGER: "Finger",
    INVTYPE_TRINKET: "Trinket", INVTYPE_CLOAK: "Back", INVTYPE_WEAPON: "One-Hand", INVTYPE_2HWEAPON: "Two-Hand", INVTYPE_WEAPONMAINHAND: "Main Hand",
    INVTYPE_WEAPONOFFHAND: "Off Hand", INVTYPE_SHIELD: "Off Hand", INVTYPE_HOLDABLE: "Held In Off-hand", INVTYPE_RANGED: "Ranged",
    INVTYPE_RANGEDRIGHT: "Ranged", INVTYPE_THROWN: "Thrown", INVTYPE_RELIC: "Relic", INVTYPE_BAG: "Bag", INVTYPE_BODY: "Shirt",
    INVTYPE_TABARD: "Tabard", INVTYPE_QUIVER: "Quiver", INVTYPE_AMMO: "Ammo" };
  const VERDICT_WORDS = { up: "Upgrade", trade: "Trade-off", no: "No gain" };

  // What changes for one person: what it replaces, item levels, the stats that move.
  function fitDetail(x) {
    const bits = [x.curName ? `Replaces ${x.curName}${x.cur != null ? ` (item level ${x.cur})` : ""}` : x.slot ? "An empty slot" : ""].filter(Boolean);
    if (x.ilvl != null && x.cur != null && x.ilvl !== x.cur) bits.push(`${x.ilvl > x.cur ? "+" : ""}${x.ilvl - x.cur} item levels`);
    for (const c of x.changes || []) bits.push(`${c.n > 0 ? "+" : ""}${c.n} ${c.stat}`);
    return bits.join(" · ");
  }

  function whoBlock(id) {
    const list = fitsFor(id);
    const bd = boardFor(id);
    const aside = new Map((bd ? bd.aside : []).map((w) => [w.who, w]));
    const asks = new Map((bd ? bd.asks : []).map((w) => [w.who, w]));
    if (!list.length && !aside.size && !asks.size) return "";
    // Anyone who asked for it or has it set aside is never folded away, verdict or not.
    const marked = (x) => aside.has(x.who) || asks.has(x.who);
    const helps = list.filter((x) => x.v !== "no" || marked(x));
    const none = list.filter((x) => x.v === "no" && !marked(x));
    const listed = new Set(list.map((x) => x.who));
    const others = [...new Set([...aside.keys(), ...asks.keys()])].filter((who) => !listed.has(who)).map((who) => {
      const m = bd.g.members.find((x) => x.key === who) || {};
      return { who, name: m.name || (aside.get(who) || asks.get(who)).name, classFile: m.classFile, level: m.level, me: m.me, own: true };
    });
    const marks = (x) => `${aside.has(x.who) ? '<span class="mk aside">Set aside</span>' : ""}${asks.has(x.who) ? '<span class="mk asked">Asked</span>' : ""}`;
    const rows = [...helps, ...others].map((x) => `<div class="urow">
        <div class="uinfo"><p class="un"><i class="dot" style="--cc:${colorOfClass(x.classFile)}"></i>${esc(x.me ? `${x.name} (you)` : x.name)}<small>${x.level ? `level ${x.level}` : ""}${x.v && !x.own ? " · from what they share" : ""}${x.asked ? " · from their ask" : ""}</small>${marks(x)}</p>
        <p class="ud">${esc((x.v && fitDetail(x)) || (asks.has(x.who) ? `Asked for it ${ago(asks.get(x.who).at)}` : "Set aside for them"))}</p></div>
        ${x.v ? `<span class="chip ${x.v}">${x.v === "lvl" ? `At level ${x.at}` : VERDICT_WORDS[x.v]}</span>` : ""}
      </div>`).join("");
    const fold = none.length ? `<p class="fold"><b>${none.length} more can equip it, with no gain:</b> ${esc(none.map((x) => (x.me ? "you" : x.name)).join(", "))}.</p>` : "";
    const last = bd && bd.aside.length ? bd.aside[bd.aside.length - 1] : null;
    const line = last ? `<p class="asidebar"><b>Set aside for ${esc(joinNames(bd.aside.map((w) => wordName(bd.g, w))))}</b> by ${esc(last.by || "an officer")}, ${ago(last.at)}.</p>` : "";
    // The count is of those whose game weighed it; with others listed it would read as theirs too.
    return `<div class="ip-blk"><h3>Who can use it${list.length && !others.length ? ` <small>${list.length} in the guild can equip it</small>` : ""}</h3>${line}${rows}${fold}</div>`;
  }

  // ── Prices and where an item comes from: the item page asks the server for its details ──
  const itemDetails = new Map(); // id -> /api/item's answer (null while it's on its way)
  async function loadItemDetails(id) {
    if (itemDetails.has(id)) return;
    itemDetails.set(id, null);
    try {
      const res = await fetch(`/api/item?id=${id}${DEMO ? "&demo=1" : ""}`, { cache: "no-store" });
      if (!res.ok) throw new Error(`item ${res.status}`);
      itemDetails.set(id, await res.json());
    } catch {
      itemDetails.delete(id);
      return;
    }
    if (itemOpen && itemOpen.id === id) showItemPage();
  }

  const SIDE_WORDS = { Alliance: "Alliance house", Horde: "Horde house", Neutral: "Neutral house" };
  const dayLabel = (d) => new Date(`${d}T12:00:00`).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  function whoseWord(w, h) {
    if (w.live) return `checked at the house ${ago(w.at)}`;
    if (h.api) return `Blizzard's hourly prices, ${ago(w.at)}`;
    return `${h.own ? "your scan" : `${esc(h.by || "a guildmate")}'s scan`}, ${ago(w.at)}`;
  }

  // Thirty days of the day's lowest price: a line with a crosshair that snaps to the nearest day,
  // and the same numbers as a table for screen readers.
  function sparkline(points, each) {
    if (points.length < 2) return "";
    const W = 360, H = 56, PX = 6, PY = 8;
    const prices = points.map((p) => p[1]);
    const lo = Math.min(...prices), hi = Math.max(...prices);
    const t0 = Date.parse(points[0][0]), t1 = Date.parse(points[points.length - 1][0]);
    const xs = points.map((p) => PX + ((Date.parse(p[0]) - t0) / Math.max(1, t1 - t0)) * (W - 2 * PX));
    const ys = points.map((p) => (hi === lo ? H / 2 : PY + (1 - (p[1] - lo) / (hi - lo)) * (H - 2 * PY)));
    const path = xs.map((x, i) => `${i ? "L" : "M"}${x.toFixed(1)},${ys[i].toFixed(1)}`).join("");
    const last = points.length - 1;
    const rows = points.map((p) => `<tr><td>${dayLabel(p[0])}</td><td>${money(p[1])}</td><td>${p[2]}</td></tr>`).join("");
    return `<div class="spark" tabindex="0" aria-label="Lowest price each day, ${dayLabel(points[0][0])} to ${dayLabel(points[last][0])}" data-each="${each ? 1 : 0}"
        data-points="${esc(JSON.stringify(points.map((p, i) => [p[0], p[1], p[2], +(xs[i] / W).toFixed(4), +(ys[i] / H).toFixed(4)])))}">
      <svg viewBox="0 0 ${W} ${H}" aria-hidden="true"><path class="sline" d="${path}"/>
        <line class="scross" x1="0" x2="0" y1="0" y2="${H}" visibility="hidden"/>
        <circle class="sdot" cx="${xs[last].toFixed(1)}" cy="${ys[last].toFixed(1)}" r="4"/></svg>
      <div class="stip" hidden></div>
      <div class="sdays" aria-hidden="true"><span>${dayLabel(points[0][0])}</span><span>${dayLabel(points[last][0])}</span></div>
      <table class="sr"><caption>Lowest price each day</caption><tr><th>Day</th><th>Price</th><th>Listed</th></tr>${rows}</table>
    </div>`;
  }

  // Each word on an item for its page from the houses this character can use, its realm's own
  // faction's and its neutral one: the house's own, or, where its newest full scan didn't list the
  // item, that none was listed then (a house only checked item by item has no scan time, and says
  // nothing of the rest). Its own faction's house first, then the newest.
  function pageWords(words) {
    const houses = (state.prices && state.prices.houses) || {};
    const c = char();
    const usable = (h) => !c || (h.realm === c.realm && (h.side === c.faction || h.side === "Neutral"));
    const all = words.filter((w) => usable(houses[w.house] || {}));
    const have = new Set(all.map((w) => w.house));
    for (const [key, h] of Object.entries(houses)) {
      if (!have.has(key) && c && usable(h) && h.at) all.push({ house: key, p: null, q: 0, at: h.at });
    }
    const rank = (w) => { const h = houses[w.house] || {}; return (c && h.realm === c.realm ? 2 : 0) + (c && h.side === c.faction ? 1 : 0); };
    return all.sort((a, b) => (rank(b) - rank(a)) || (b.at - a.at));
  }

  function priceBlock(id) {
    const info = (state.itemInfo || {})[String(id)] || {};
    const cant = info.bind === 1 ? "It binds when picked up, so it can't be sold at the auction house."
      : info.bind === 4 ? "A quest item: it can't be sold at the auction house." : "";
    if (cant) return `<div class="ip-blk pblock"><h3>Auction price</h3><p class="pmeta">${cant}</p></div>`;
    const known = itemDetails.get(id);
    const words = pageWords(known ? known.prices : ((state.prices && state.prices.items && state.prices.items[String(id)]) || []));
    if (!words.length) {
      return `<div class="ip-blk pblock"><h3>Auction price</h3><p class="pmeta">${isPublic() ? "Not read yet."
        : "Not read yet. Reliquary reads the auction house's prices when one of your characters opens it in game."}</p></div>`;
    }
    const houses = (state.prices && state.prices.houses) || {};
    const top = words[0];
    const h = houses[top.house] || {};
    const each = stacks(id);
    const now = top.p ? `<div class="pnow">${money(top.p)}${each ? '<span class="peach">each</span>' : ""}</div>` : `<div class="pnow none">None listed</div>`;
    const meta = [top.p ? `${n(top.q || 0)}${top.more ? "+" : ""} listed` : "", whoseWord(top, h)].filter(Boolean).join(" · ");
    const series = known && known.history ? (known.history[top.house] || []) : [];
    const lows = series.map((p) => p[1]);
    const range = lows.length > 1 ? `<p class="prange">${series.length}-day low ${money(Math.min(...lows))} · high ${money(Math.max(...lows))}</p>` : "";
    const others = words.filter((w) => w.house !== top.house).map((w) => {
      const oh = houses[w.house] || {};
      return `<p class="pother"><b>${esc(SIDE_WORDS[oh.side] || oh.side || "Another house")}</b> ${w.p ? money(w.p) : "none listed"} <span class="faint">· ${whoseWord(w, oh)}</span></p>`;
    }).join("");
    return `<div class="ip-blk pblock"><h3>Auction price <small>${esc(SIDE_WORDS[h.side] || "")}${h.realm ? ` · ${esc(h.realm)}` : ""}</small></h3>
      ${now}<p class="pmeta">${meta}</p>${sparkline(series, each)}${range}${others}</div>`;
  }

  // Where it comes from, as Reliquary noted it while you (and guildmates who share) played. Outside
  // pages are linked, never copied.
  const WOWHEAD = "https://www.wowhead.com/forever";
  // Warcraft Wiki's page for a name: the article when it has one by that name, else its search.
  const wikiUrl = (name) => `https://warcraft.wiki.gg/wiki/Special:Search?search=${encodeURIComponent(name)}&go=Go`;
  function sourcesBlock(id) {
    if (isPublic()) return "";
    const known = itemDetails.get(id);
    if (known === null) return `<div class="ip-blk"><h3>Where it comes from</h3><p class="faint">Looking at Reliquary's notes...</p></div>`;
    const s = known && known.sources;
    if (!s || !Object.keys(s).length) return "";
    const whose = (x) => (x.from ? ` <span class="faint">· ${esc(x.from)}'s note</span>` : "");
    const where = (x) => esc([x.sub, x.zone].filter(Boolean).join(", "));
    const link = (kind, num, text) => (num ? `<a href="${WOWHEAD}/${kind}=${num}" target="_blank" rel="noopener noreferrer">${text}</a>` : text);
    const rows = [];
    for (const v of s.vendors || []) {
      const price = v.currency ? "for tokens" : v.price ? `${money(v.price)}${v.stack > 1 ? ` <span class="faint">for ${v.stack}</span>` : ""}` : "";
      const spot = v.x != null && v.y != null ? ` <span class="faint mono">${v.x.toFixed(1)}, ${v.y.toFixed(1)}</span>` : "";
      rows.push(["Sold by", `${link("npc", v.npc, `<b>${esc(v.name)}</b>`)}, ${where(v)}${spot}${price ? ` · ${price}` : ""}${v.limited ? ' <span class="faint">· limited</span>' : ""}${whose(v)}`]);
    }
    for (const q of s.quests || []) rows.push(["Quest", `${link("quest", q.id, `<b>${esc(q.title)}</b>`)}${q.choice ? ' <span class="faint">· a reward choice</span>' : ""}${whose(q)}`]);
    // The journal names a boss, not its creature: its Warcraft Wiki article.
    for (const j of s.journal || []) rows.push(["Boss", `<a href="${esc(wikiUrl(j.encounter))}" target="_blank" rel="noopener noreferrer"><b>${esc(j.encounter)}</b></a>, ${esc(j.instance)}${j.modes ? ` <span class="faint">· ${esc(j.modes)}</span>` : ""}${whose(j)}`]);
    for (const d of s.drops || []) {
      const what = d.kind === "fishing" ? `Fished up in ${where(d)}`
        : d.kind === "gathered" ? `Gathered in ${where(d)}`
        : d.kind === "container" ? `Found in ${link("item", d.id, `<b>${esc(d.container || `item ${d.id}`)}</b>`)}`
        : `${link("npc", d.id, `<b>${esc(d.name || "A creature")}</b>`)}, ${where(d)}`;
      rows.push([d.kind === "creature" ? "Drop" : "Found", `${what}${d.count > 1 ? ` <span class="faint">· seen ${d.count} times</span>` : ""}${whose(d)}`]);
    }
    for (const m of s.made || []) {
      const uses = (m.uses || []).map((u) => `${u.n} × ${link("item", u.id, esc(u.name || `item ${u.id}`))}`).join(", ");
      rows.push(["Crafted", `<b>${esc(m.profession)}</b>${uses ? `: ${uses}` : ""}${whose(m)}`]);
    }
    const goes = s.uses || [];
    if (goes.length) {
      const names = goes.slice(0, 6).map((g) => link("item", g.makes, esc(g.name || `item ${g.makes}`))).join(", ");
      rows.push(["Used in", `${names}${goes.length > 6 ? ` <span class="faint">and ${goes.length - 6} more</span>` : ""}`]);
    }
    const list = rows.map(([k, v]) => `<li><span class="sk">${k}</span><span class="sv">${v}</span></li>`).join("");
    return `<div class="ip-blk"><h3>Where it comes from</h3><ul class="srcs">${list}</ul></div>`;
  }

  // What in the guild bank is set aside for a guildmate, then what would be an upgrade for them
  // now, the biggest first: one line of items on their page.
  function bankForBlock(key, whom) {
    const out = [], seen = new Set();
    (state.guilds || []).forEach((g, gi) => {
      for (const t of g.bank.tabs || []) {
        for (const [slot, it] of Object.entries(t.slots || {})) {
          if (!it || seen.has(it.id)) continue;
          const b = t.board && t.board[String(it.id)];
          const fit = ((g.fits || {})[String(it.id)] || []).find((x) => x.who === key && x.v === "up");
          const set = !!(b && (b.aside || []).some((w) => w.who === key));
          if (!set && !fit) continue;
          seen.add(it.id);
          out.push({ it, gi, tab: t.index, slot, set, gain: set ? 1e6 : (fit.ilvl || 0) - (fit.cur || 0) });
        }
      }
    });
    if (!out.length) return "";
    out.sort((a, b) => (b.gain - a.gain) || (a.it.id - b.it.id));
    const items = out.map((x) => `<span class="bfi" tabindex="0" data-stip="gb|${x.gi}|${x.tab}" data-slot="${esc(x.slot)}">${icon(x.it.icon, x.it.q, 26)}<span class="qt${x.it.q ?? 1}">${esc(x.it.name)}</span>${x.set ? '<span class="mk aside">Set aside</span>' : ""}</span>`).join("");
    return `<div class="bankfor"><h3>In the guild bank for ${whom}</h3><div class="bfitems">${items}</div></div>`;
  }

  // Where you have it: your characters, the guild bank, and what others share with you.
  function haveBlock(id) {
    const lines = [];
    const count = (slots) => Object.values(slots || {}).reduce((n, it) => n + (it && it.id === id ? (it.n || 1) : 0), 0);
    for (const c of state.chars || []) {
      let n = count(c.gear);
      for (const bag of [...(c.bags || []), ...(c.bank || [])]) n += count(bag.slots);
      if (n) lines.push(`${esc(c.name)}${n > 1 ? `, ${n}` : ""}`);
    }
    for (const g of state.guilds || []) {
      for (const t of g.bank.tabs || []) { const n = count(t.slots); if (n) lines.push(`The guild bank's ${esc(t.name)} tab${n > 1 ? `, ${n}` : ""}`); }
    }
    for (const p of state.peers || []) {
      let n = 0;
      for (const bag of [...(p.bags || []), ...(p.bank || [])]) n += count(bag.slots);
      n += count(p.gear);
      if (n) lines.push(`${esc(p.name)}${n > 1 ? `, ${n}` : ""}`);
    }
    return lines.length ? `<div class="ip-blk"><h3>Who has it</h3><p>${lines.join(" · ")}</p></div>` : "";
  }

  // What the dashboard knows of an item from wherever it appears: your characters, the guild bank and
  // its logs, and what others share. For a page opened from its link.
  function knownItem(id) {
    const seen = [];
    const look = (slots) => { for (const it of Object.values(slots || {})) if (it && it.id === id) seen.push(it); };
    for (const c of state.chars || []) { look(c.gear); for (const bag of [...(c.bags || []), ...(c.bank || [])]) { look(bag.slots); if (bag.item) look({ x: bag.item }); } }
    for (const g of state.guilds || []) {
      for (const t of g.bank.tabs || []) { look(t.slots); for (const e of (t.log && t.log.entries) || []) if (e.id === id) seen.push(e); }
    }
    for (const p of state.peers || []) { look(p.gear); for (const bag of [...(p.bags || []), ...(p.bank || [])]) look(bag.slots); }
    const out = {};
    for (const it of seen) for (const k of ["name", "q", "icon", "ilvl"]) if (out[k] == null && it[k] != null) out[k] = it[k];
    return out;
  }

  function itemPageHtml(id, it) {
    const info = (state.itemInfo || {})[String(id)] || {};
    const rec = Object.assign({ id }, knownItem(id), info, it || {});
    const name = rec.name || `Item ${id}`;
    const q = rec.q ?? 1;
    const tip = itemTip(Object.assign({}, rec, { name, tip: rec.tip }));
    const level = info.ilvl || rec.ilvl;
    const meta = [level ? `Item level ${level}` : "", LOC_WORDS[info.loc] || "", info.sub && !/^Misc/.test(info.sub) ? info.sub : "", QUALITY[q] || "",
      info.req > 1 ? `Requires level ${info.req}` : ""].filter(Boolean).join(" · ");
    // The public copy shows an item's auction price (Blizzard's own) and nothing else of the dashboard's.
    const blocks = isPublic() ? priceBlock(id) : [priceBlock(id), whoBlock(id), craftBlock(id), haveBlock(id), sourcesBlock(id),
      typeof window.reliquaryItemBlocks === "function" ? window.reliquaryItemBlocks(id) : ""].join("");
    const sell = info.sell > 0 ? `<div class="ip-blk"><h3>Sell price</h3><p>A vendor pays ${money(info.sell)}${info.stack > 1 ? " each" : ""}</p></div>` : "";
    return `<div class="ip-panel" role="dialog" aria-modal="true" aria-labelledby="ipName">
      <header class="ip-head">${icon(rec.icon, q, 56)}<div class="ip-title"><h2 id="ipName" class="qt${q}">${esc(name)}</h2><p>${esc(meta)}</p></div>
        <button class="ip-close" data-ip-close aria-label="Close">${svg("close")}</button></header>
      <div class="ip-body">
        <div class="tipbox" style="--qc:${tip.qc}">${tip.html}</div>
        <div class="ip-side">${blocks}${sell}
          <div class="ip-blk ip-links"><a class="lbtn" href="https://www.wowhead.com/forever/item=${id}" target="_blank" rel="noopener noreferrer">Wowhead</a>
            <a class="lbtn" href="https://foreverdb.net/item/${id}" target="_blank" rel="noopener noreferrer">ForeverDB</a>${rec.name ? `
            <a class="lbtn" href="${esc(wikiUrl(rec.name))}" target="_blank" rel="noopener noreferrer">Warcraft Wiki</a>` : ""}</div>
        </div>
      </div>
    </div>`;
  }

  function showItemPage() {
    if (!itemOpen && craftOpen) { showCraftPage(); return; }
    if (!itemOpen) { pageEl.hidden = true; document.body.classList.remove("paged"); return; }
    loadItemDetails(itemOpen.id); // however the page was opened: a click, a link, the back button
    pageEl.innerHTML = itemPageHtml(itemOpen.id, itemOpen.it);
    pageEl.hidden = false;
    document.body.classList.add("paged");
  }
  function openItem(id, it) {
    itemOpen = { id: Number(id), it };
    const hash = `#${view}/item-${id}`;
    if (location.hash !== hash) history.pushState(null, "", location.pathname + location.search + hash);
    hideTip();
    showItemPage();
    const close = pageEl.querySelector("[data-ip-close]");
    if (close) close.focus();
  }
  function closeItem() {
    if (!itemOpen) return;
    itemOpen = null;
    history.pushState(null, "", location.pathname + location.search + (craftOpen ? craftHash() : view === "chars" ? "" : `#${view}`));
    showItemPage();
  }

  // ── Crafting: each character's recipes (the addon's Crafting.lua), and who in your guild and among
  // your friends can make an item, whose recipes use it, and who could learn a recipe ──
  let craftOpen = null;  // { owner: "c:<key>" | "p:<key>", prof }: the recipe book open over the page
  let craftQuery = "";
  const craftHash = () => `#${view}/craft-${encodeURIComponent(`${craftOpen.owner}~${craftOpen.prof}`)}`;
  // How a recipe would skill up, as the game colours it in its own window.
  const SKILL_UP = { optimal: ["#ff8040", "A skill-up every time"], medium: ["#ffff00", "Usually a skill-up"], easy: ["#40bf40", "Rarely a skill-up"],
    trivial: ["#9d9d9d", "No more skill-ups"] };
  const WHERE_WORDS = { yours: "yours", guild: "guild", friend: "friend" };

  // An item as the page knows it from wherever it shows: its name, quality, icon and tooltip.
  function itemRec(id) {
    return Object.assign({ id }, knownItem(id), (state.itemInfo || {})[String(id)] || {}, { tip: (state.items || {})[String(id)] });
  }
  const itemName = (id) => itemRec(id).name || `Item ${id}`;

  // Whose recipes the page has: your characters (but what the public copy keeps off), and those who
  // share with you as guildmates or friends. Yours first, the one on screen first of all.
  function craftPeople() {
    const out = [];
    for (const c of state.chars || []) {
      if ((c.recipes || []).length && !hides(c, "profs")) out.push({ owner: `c:${c.key}`, name: c.name, cls: c.classFile, where: "yours", me: c.key === current, books: c.recipes });
    }
    for (const p of state.peers || []) {
      const sc = p.scopes || [];
      const where = sc.includes("guild") ? "guild" : sc.includes("friends") ? "friend" : null;
      if (where && (p.recipes || []).length) out.push({ owner: `p:${p.key}`, name: p.name, cls: p.classFile, where, books: p.recipes });
    }
    const rank = (x) => (x.me ? 0 : x.where === "yours" ? 1 : x.where === "guild" ? 2 : 3);
    return out.sort((a, b) => (rank(a) - rank(b)) || (a.name || "").localeCompare(b.name || ""));
  }

  // For each item: who can make it, and whose recipes use it (with those recipes). Built once a state.
  let craftCache = null;
  function craftIndex() {
    if (craftCache && craftCache.state === state && craftCache.current === current) return craftCache;
    const makes = new Map(), uses = new Map(), people = craftPeople();
    for (const person of people) {
      for (const book of person.books) {
        for (const r of book.recipes) {
          if (r.makes) {
            const list = makes.get(r.makes.id) || [];
            if (!list.some((x) => x.person === person && x.book === book)) list.push({ person, book, recipe: r });
            makes.set(r.makes.id, list);
          }
          for (const u of r.uses || []) {
            const list = uses.get(u.id) || [];
            let e = list.find((x) => x.person === person && x.book === book);
            if (!e) { e = { person, book, recipes: [] }; list.push(e); }
            e.recipes.push({ recipe: r, n: u.n });
            uses.set(u.id, list);
          }
        }
      }
    }
    craftCache = { state, current, makes, uses, people };
    return craftCache;
  }

  // Who could learn the recipe a recipe item teaches: someone with its profession (the game's class
  // for recipe items, and its kinds by profession) and the skill it needs ("Requires Leatherworking
  // (40)" on its tooltip), whose recipes show they don't know it yet.
  const RECIPE_LINES = { 1: 165, 2: 197, 3: 202, 4: 164, 5: 185, 6: 171, 7: 129, 8: 333, 9: 356, 10: 755, 11: 773 };
  function learnersOf(id) {
    const info = (state.itemInfo || {})[String(id)] || {};
    const taught = (info.cls === 9 || (info.cls == null && info.kind === "Recipe")) && info.name && /^[^:]+:\s*(.+)$/.exec(info.name);
    if (!taught) return [];
    const line = RECIPE_LINES[info.scls];
    let need = 0;
    for (const l of (state.items || {})[String(id)] || []) {
      const m = info.sub && (l.l || "").includes(info.sub) && /\((\d+)\)\s*$/.exec(l.l || "");
      if (m) need = Number(m[1]);
    }
    const out = [];
    for (const person of craftIndex().people) {
      const book = person.books.find((b) => (line && b.line === line) || b.name === info.sub);
      if (!book || (book.skill || 0) < need) continue;
      if (book.recipes.some((r) => (r.name || "").toLowerCase() === taught[1].toLowerCase())) continue;
      out.push({ person, book });
    }
    return out;
  }

  // An ingredient the game files under one profession (trade goods of that kind, marked a crafting
  // reagent), as the addon reads it: that profession, or null. A save from before the mark was kept
  // has the tooltip's own "Crafting Reagent" line.
  const REAGENT_PROFS = { 8: "Cooking", 12: "Enchanting", 1: "Engineering", 2: "Engineering", 3: "Engineering", 17: "Engineering", 4: "Jewelcrafting", 16: "Inscription" };
  const REAGENT_SUBS = { Cooking: "Cooking", Enchanting: "Enchanting", Parts: "Engineering", Explosives: "Engineering", Devices: "Engineering",
    "Explosives and Devices": "Engineering", Jewelcrafting: "Jewelcrafting", Inscription: "Inscription" };
  function reagentProf(id) {
    const info = (state.itemInfo || {})[String(id)] || {};
    const prof = info.cls != null ? (info.cls === 7 ? REAGENT_PROFS[info.scls] : null) : (info.kind === "Trade Goods" ? REAGENT_SUBS[info.sub] : null);
    if (!prof) return null;
    const marked = info.reagent === true || ((state.items || {})[String(id)] || []).some((l) => l.l === "Crafting Reagent");
    return marked ? prof : null;
  }
  // Everyone with a profession: your characters, and guildmates and friends who show you theirs.
  function profHolders(prof) {
    const out = [];
    const holds = (list) => (list || []).find((p) => p.name === prof);
    for (const c of state.chars || []) {
      const p = !hides(c, "profs") && holds(c.profs);
      if (p) out.push({ person: { owner: `c:${c.key}`, name: c.name, cls: c.classFile, where: "yours", me: c.key === current, books: c.recipes || [] }, skill: p.skill });
    }
    for (const p of state.peers || []) {
      const sc = p.scopes || [];
      const where = sc.includes("guild") ? "guild" : sc.includes("friends") ? "friend" : null;
      const x = where && holds(p.profs);
      if (x) out.push({ person: { owner: `p:${p.key}`, name: p.name, cls: p.classFile, where, books: p.recipes || [] }, skill: x.skill });
    }
    return out;
  }
  // Whose recipes use an item, with those recipes; and for an ingredient the game files under one
  // profession, everyone else with that profession (byType), as the game's tooltips say it.
  function usersOf(id) {
    const exact = craftIndex().uses.get(id) || [];
    const prof = reagentProf(id);
    if (!prof) return exact;
    const extra = profHolders(prof)
      .filter((h) => !exact.some((x) => x.person.owner === h.person.owner && x.book.name === prof))
      .map((h) => ({ person: h.person, book: h.person.books.find((b) => b.name === prof) || { name: prof, none: true }, recipes: [], byType: true, skill: h.skill }));
    const rank = (x) => (x.person.me ? 0 : x.person.where === "yours" ? 1 : x.person.where === "guild" ? 2 : 3);
    return [...exact, ...extra].sort((a, b) => (rank(a) - rank(b)) || (a.person.name || "").localeCompare(b.person.name || ""));
  }

  const whoName = (x) => (x.person.me ? `${x.person.name} (you)` : x.person.name);
  // A person on an item's page: opens their recipe book for it, when there is one.
  function craftRow(x, detail) {
    const inner = `<i class="dot" style="--cc:${colorOfClass(x.person.cls)}"></i>
      <span class="cinfo"><b>${esc(whoName(x))}</b><small>${esc(detail)}</small></span>`;
    if (x.book.none) return `<div class="crow plain">${inner}</div>`;
    return `<button class="crow" data-craft="${esc(x.person.owner)}~${esc(x.book.name)}">${inner}<i class="chev" aria-hidden="true"></i></button>`;
  }
  const whereText = (x) => (x.person.me ? "" : ` · ${WHERE_WORDS[x.person.where]}`);

  function craftBlock(id) {
    const idx = craftIndex();
    const makers = idx.makes.get(id) || [], users = usersOf(id), learners = learnersOf(id);
    const out = [];
    if (makers.length) out.push(`<div class="ip-blk"><h3>Who can make it</h3>${makers.map((x) => craftRow(x, `${x.book.name}${whereText(x)}`)).join("")}</div>`);
    if (users.length) {
      out.push(`<div class="ip-blk"><h3>Who uses it</h3>${users.map((x) => craftRow(x, x.byType ? `${x.book.name}${x.skill != null ? ` ${x.skill}` : ""}${whereText(x)}` : `${x.book.name}: ${
        x.recipes.map((r) => `${r.recipe.name || (r.recipe.makes ? itemName(r.recipe.makes.id) : `Recipe ${r.recipe.rid}`)} (${r.n})`).join(", ")}${whereText(x)}`)).join("")}</div>`);
    }
    if (learners.length) out.push(`<div class="ip-blk"><h3>Who can learn it</h3>${learners.map((x) => craftRow(x, `${x.book.name} ${x.book.skill ?? ""}${whereText(x)}`)).join("")}</div>`);
    return out.join("");
  }

  // The lines Reliquary puts under an item on the game's tooltips, as the character on screen sees
  // them: who else can make it, whose recipes use it, who could learn it, and who else has it.
  // "Faelwen and Eluned (Leatherworking)", or each with their own profession when they differ.
  function withProfs(list) {
    const profs = [...new Set(list.map((x) => x.book.name))];
    const names = list.map((x) => (profs.length > 1 ? `${x.person.name} (${x.book.name})` : x.person.name));
    const shown = names.length > 3 ? [...names.slice(0, 2), `${names.length - 2} more`] : names;
    return `${joinNames(shown)}${profs.length === 1 ? ` (${profs[0]})` : ""}`;
  }
  function heldBy(id) {
    const c = char();
    if (!c) return "";
    const counts = new Map();
    const add = (name, n, rank) => { const x = counts.get(name) || { name, n: 0, rank }; x.n += n || 1; counts.set(name, x); };
    const look = (bags, name, rank) => { for (const b of bags || []) for (const it of Object.values(b.slots || {})) if (it && it.id === id) add(name, it.n, rank); };
    for (const o of state.chars || []) {
      if (o.key !== c.key && o.realm === c.realm && o.faction === c.faction) { look(o.bags, o.name, 1); look(o.bank, o.name, 1); }
    }
    const g = (state.guilds || []).find((x) => x.name === c.guild);
    for (const t of (g && g.bank.tabs) || []) for (const it of Object.values(t.slots || {})) if (it && it.id === id) add("the guild bank", it.n, 2);
    for (const p of state.peers || []) {
      if ((p.scopes || []).includes("guild") && p.guild === c.guild) { look(p.bags, p.name, 3); look(p.bank, p.name, 3); }
    }
    const list = [...counts.values()].sort((a, b) => (b.n - a.n) || (a.rank - b.rank) || a.name.localeCompare(b.name));
    if (!list.length) return "";
    const shown = list.length > 3 ? [...list.slice(0, 2).map((x) => `${x.name} (${x.n})`), `${list.length - 2} more`] : list.map((x) => `${x.name} (${x.n})`);
    return joinNames(shown);
  }
  function craftNotes(id) {
    const idx = craftIndex();
    const others = (list) => list.filter((x) => !x.person.me);
    const out = [];
    const makers = others(idx.makes.get(id) || []), users = others(usersOf(id)), learners = others(learnersOf(id));
    if (makers.length) out.push(["Made by", withProfs(makers)]);
    if (users.length) out.push(["Used by", withProfs(users)]);
    if (learners.length) out.push(["Can be learned by", withProfs(learners)]);
    const held = heldBy(id);
    if (held) out.push(["Held by", held]);
    return out;
  }

  // One recipe: what it makes (its page on a click, its tooltip on hover) and what goes into it.
  function recipeRow(r, mine) {
    const made = r.makes ? itemRec(r.makes.id) : null;
    const q = made ? made.q ?? 1 : 1;
    const name = r.name || (made && made.name) || `Recipe ${r.rid}`;
    const diff = mine && SKILL_UP[r.diff];
    const pic = icon(made ? made.icon : r.icon, made ? q : 1, 38, r.makes && r.makes.n > 1 ? `<span class="count">${r.makes.n}</span>` : "");
    const main = r.makes
      ? `<span class="rmain" tabindex="0" data-stip="ip|${r.makes.id}">${pic}<span class="rname qt${q}">${esc(name)}</span></span>`
      : `<span class="rmain plain">${pic}<span class="rname">${esc(name)}</span></span>`;
    const uses = (r.uses || []).map((u) => {
      const it = itemRec(u.id);
      return `<span class="ruse" tabindex="0" data-stip="ip|${u.id}" aria-label="${esc(`${u.n} ${it.name || `item ${u.id}`}`)}">${icon(it.icon, it.q ?? 1, 30, u.n > 1 ? `<span class="count">${u.n}</span>` : "")}</span>`;
    }).join("");
    return `<div class="rrow">${main}${diff ? `<i class="rdiff" style="--dc:${diff[0]}" title="${esc(diff[1])}"></i>` : ""}<span class="ruses">${uses}</span></div>`;
  }

  function recipeListHtml(book, mine) {
    const q = craftQuery.trim().toLowerCase();
    const hit = (r) => !q || (r.name || "").toLowerCase().includes(q) || (r.makes && itemName(r.makes.id).toLowerCase().includes(q))
      || (r.uses || []).some((u) => itemName(u.id).toLowerCase().includes(q));
    const shown = book.recipes.filter(hit);
    if (!shown.length) return `<p class="faint rb-none">No recipe matches.</p>`;
    // The window's own groups, when the game gave them; else one list by name.
    const groups = new Map();
    for (const r of shown) {
      const g = r.cat || "";
      if (!groups.has(g)) groups.set(g, []);
      groups.get(g).push(r);
    }
    const named = [...groups.keys()].filter(Boolean).sort((a, b) => a.localeCompare(b));
    if (!named.length) return shown.map((r) => recipeRow(r, mine)).join("");
    return [...named, ...(groups.has("") ? [""] : [])].map((g) => `<h4 class="rb-group">${esc(g || "Other")}<small>${groups.get(g).length}</small></h4>${groups.get(g).map((r) => recipeRow(r, mine)).join("")}`).join("");
  }

  function craftOwner(owner) {
    const key = owner.slice(2);
    if (owner.startsWith("c:")) {
      const c = (state.chars || []).find((x) => x.key === key);
      return c && !hides(c, "profs") ? { name: c.name, profs: c.profs || [], books: c.recipes || [], mine: true } : null;
    }
    const p = peerByKey(key);
    return p ? { name: p.name, profs: p.profs || [], books: p.recipes || [], mine: false } : null;
  }

  function craftPageHtml() {
    const who = craftOwner(craftOpen.owner);
    const book = who && who.books.find((b) => b.name === craftOpen.prof);
    if (!book) return "";
    const prof = who.profs.find((p) => p.name === book.name) || {};
    const skill = prof.skill ?? book.skill, max = prof.max ?? book.max;
    const meta = [who.name, skill != null ? `${skill} / ${max ?? "-"}` : "", `${book.recipes.length} ${book.recipes.length === 1 ? "recipe" : "recipes"}`,
      book.at ? `as of ${ago(book.at)}` : ""].filter(Boolean).join(" · ");
    return `<div class="ip-panel rb-panel" role="dialog" aria-modal="true" aria-labelledby="rbName">
      <header class="ip-head">${icon(prof.icon, 1, 56)}<div class="ip-title"><h2 id="rbName">${esc(book.name)}</h2><p>${esc(meta)}</p></div>
        <button class="ip-close" data-ip-close aria-label="Close">${svg("close")}</button></header>
      ${book.recipes.length > 8 ? `<div class="rb-tools"><label class="search">${svg("search")}<span class="sr">Find a recipe</span><input id="recipeSearch" type="search" placeholder="Find a recipe, or what goes into one" value="${esc(craftQuery)}" autocomplete="off"></label></div>` : ""}
      <div class="rb-list" id="rbList">${recipeListHtml(book, who.mine)}</div>
    </div>`;
  }

  function showCraftPage() {
    const html = craftPageHtml();
    if (!html) { craftOpen = null; pageEl.hidden = true; document.body.classList.remove("paged"); return; }
    pageEl.innerHTML = html;
    pageEl.hidden = false;
    document.body.classList.add("paged");
  }
  function openCraft(owner, prof) {
    craftOpen = { owner, prof };
    itemOpen = null;
    craftQuery = "";
    const hash = craftHash();
    if (location.hash !== hash) history.pushState(null, "", location.pathname + location.search + hash);
    hideTip();
    showItemPage();
    const close = pageEl.querySelector("[data-ip-close]");
    if (close) close.focus();
  }
  function closeCraft() {
    if (!craftOpen) return;
    craftOpen = null;
    history.pushState(null, "", location.pathname + location.search + (view === "chars" ? "" : `#${view}`));
    showItemPage();
  }

  function peersView(scope) {
    const list = peersOf(scope);
    const intro = scope === "friends"
      ? "Friends who share their reliquary with you, from your friends list and Battle.net friends."
      : "Players who share their reliquary with anyone. Reliquary asks the players you target in game, and /rq look <name> asks by name.";
    if (!list.length) {
      return `<section class="welcome rise"><h1>${scope === "friends" ? "No friends' reliquaries yet" : "Nobody met yet"}</h1><p>${esc(intro)}</p><p class="faint">${scope === "friends" ? "They appear here once a friend who uses Reliquary turns on friends sharing and you have both been online." : "They appear here once you target a player who uses Reliquary and shares publicly."}</p></section>`;
    }
    if (!list.some((p) => p.key === peerPick[scope])) peerPick[scope] = list[0].key;
    const tiles = list.map((p) => `<button class="ptile${p.key === peerPick[scope] ? " sel" : ""}" data-peer="${esc(p.key)}" style="--cc:${colorOfClass(p.classFile)}">
        <span class="pmedal sm"><span>${esc((p.name || "?").slice(0, 1))}</span><b>${p.level ?? "?"}</b></span>
        <span class="pt"><b>${esc(p.name)}</b><small>${esc([p.race, p.class].filter(Boolean).join(" "))}</small>${p.guild ? `<small class="faint">&lt;${esc(p.guild)}&gt;</small>` : ""}</span>
        ${p.ilvl ? `<span class="pil"><b>${Number(p.ilvl).toFixed(1)}</b><small>ilvl</small></span>` : ""}
      </button>`).join("");
    return `<div class="grid">
      <section class="card c-5 listcard rise" style="--i:0"><header><h2>${scope === "friends" ? "Friends" : "Public"}</h2><small>${list.length} ${list.length === 1 ? "reliquary" : "reliquaries"}</small></header>
        <p class="faint vintro">${esc(intro)}</p><div class="ptiles">${tiles}</div></section>
      <section class="card c-7 rise" style="--i:1" id="peerCard">${peerSheet(peerByKey(peerPick[scope]))}</section>
    </div>`;
  }

  // Every Total RP 3 profile your Total RP 3 holds: everyone you have met who writes one, and
  // everyone who shares a reliquary with you (Reliquary asks Total RP 3 for theirs).
  function roleplayView() {
    const all = state.roleplay || [];
    if (!all.length) {
      return `<section class="welcome rise"><h1>No roleplay profiles yet</h1><p>Total RP 3 keeps the profile of every player it meets who writes one, and Reliquary asks it for everyone who shares a reliquary with you. They appear here after your next save: log out or type <span class="mono">/reload</span>.</p><p class="faint">Without Total RP 3 installed there are none to show.</p></section>`;
    }
    const sharer = new Map((state.peers || []).filter((p) => p.rp).map((p) => [p.rp, p]));
    const guildmate = new Set((state.guilds || []).flatMap((g) => g.members.filter((m) => m.rp && !m.me).map((m) => m.rp)));
    const q = rpQuery.trim().toLowerCase();
    const words = (c) => [c.name, c.title, c.fullTitle, c.race, c.class, c.guild, c.residence, c.birthplace,
      ...(c.misc || []).map((m) => m.value), ...(c.currently || []).map((r) => r.t)].filter(Boolean).join(" ").toLowerCase();
    const list = all
      .filter((c) => rpFilter === "all" || (rpFilter === "reliquary" ? sharer.has(c.unit) : guildmate.has(c.unit)))
      .filter((c) => !q || words(c).includes(q));
    if (!all.some((c) => c.unit === rpPick)) rpPick = (all.find((c) => sharer.has(c.unit)) || all[0]).unit;
    const picked = rpByUnit(rpPick);
    const p = sharer.get(rpPick);
    const where = p ? ((p.scopes || []).includes("guild") ? "guild" : (p.scopes || []).includes("friends") ? "friends" : "public") : null;
    const tiles = list.map((c) => `<button class="ptile rptile${c.unit === rpPick ? " sel" : ""}" data-rp="${esc(c.unit)}"${hexColor(c.color) ? ` style="--cc:#${hexColor(c.color)}"` : ""}>
        ${iconId(c.icon) ? icon(iconId(c.icon), 1, 42) : `<span class="rpnoicon sm">${svg("mask")}</span>`}
        <span class="pt"><b>${esc(c.name || c.unit)}</b><small>${esc(c.title || [c.race, c.class].filter(Boolean).join(" ") || "")}</small></span>
        <span class="rpbadges">${sharer.has(c.unit) ? `<span class="relic" title="Shares a reliquary with you">${svg("gem")}</span>` : ""}${guildmate.has(c.unit) ? `<span title="In your guild">${svg("banner")}</span>` : ""}${c.status === "ic" ? '<i class="ic" title="In character"></i>' : ""}</span>
      </button>`).join("");
    return `<div class="grid">
      <section class="card c-5 listcard rise" style="--i:0"><header><h2>Roleplay</h2><small>${all.length} ${all.length === 1 ? "profile" : "profiles"}</small></header>
        <p class="faint vintro">Every Total RP 3 profile your Total RP 3 holds: the players you have met who write one, and everyone who shares a reliquary with you.</p>
        <div class="rtools">
          <div class="seg" role="group" aria-label="Whose profiles">
            <button data-rpfilter="all" aria-pressed="${rpFilter === "all"}">All</button>
            <button data-rpfilter="guild" aria-pressed="${rpFilter === "guild"}">Guild</button>
            <button data-rpfilter="reliquary" aria-pressed="${rpFilter === "reliquary"}">Reliquary</button>
          </div>
          <label class="search">${svg("search")}<span class="sr">Find a profile</span><input id="rpSearch" type="search" placeholder="Name, title, race, words" value="${esc(rpQuery)}" autocomplete="off"></label>
        </div>
        <div class="ptiles rplist">${tiles || '<div class="empty-note">Nobody matches.</div>'}</div></section>
      <section class="card c-7 rise" style="--i:1" id="rpCard">
        ${p ? `<div class="rpgoto"><button class="btn outline" data-goto="${where}" data-key="${esc(p.key)}">${svg("gem")}${p.name ? `See the reliquary ${esc(p.name)} shares` : "See their reliquary"}</button></div>` : ""}
        ${rpCard(picked)}
      </section>
    </div>`;
  }

  function viewHtml() {
    if (view === "guild") return guildView();
    if (view === "friends" || view === "public") return peersView(view);
    if (view === "roleplay") return roleplayView();
    return "";
  }

  // ── Render ────────────────────────────────────────────────────────────────
  // Two columns of cards. When one side has nothing to show (its parts kept off the public copy),
  // the other side's cards share the row between them instead of leaving a hole.
  function columns(left, lspan, right, rspan, id) {
    left = left.filter(Boolean);
    right = right.filter(Boolean);
    const ids = (side) => (id ? ` id="${id}${side}"` : "");
    if (left.length && right.length) return `<div class="stack c-${lspan}"${ids("L")}>${left.join("")}</div><div class="stack c-${rspan}"${ids("R")}>${right.join("")}</div>`;
    const only = left.length ? left : right;
    const span = 12 / Math.min(only.length, 3);
    return only.map((card) => `<div class="stack c-${span}">${card}</div>`).join("");
  }

  // On a phone the view tabs scroll sideways: bring the one shown into view.
  function showViewTab() {
    const nav = app.querySelector(".views"), sel = nav && nav.querySelector('[aria-selected="true"]');
    if (!nav || !sel || nav.scrollWidth <= nav.clientWidth) return;
    nav.scrollLeft += sel.getBoundingClientRect().left - nav.getBoundingClientRect().left - (nav.clientWidth - sel.offsetWidth) / 2;
  }

  function render() {
    hideTip();
    const chars = state.chars;
    readHash();
    if (view !== "chars") {
      if (!chars.some((x) => x.key === current) && chars.length) current = (chars.find((x) => x.key === localStorage.getItem("reliquary.pick")) || chars.find(isJoan) || chars[0]).key;
      document.title = `${VIEWS.find(([k]) => k === view)[1]} · Reliquary`;
      app.innerHTML = `${strip(chars)}${viewHtml()}`;
      if (!firstPaint) app.querySelectorAll(".rise").forEach((el) => el.classList.remove("rise"));
      firstPaint = false;
      showViewTab();
      showItemPage();
      return;
    }
    if (!chars.length) { app.innerHTML = welcome(); return; }
    if (!chars.some((c) => c.key === current)) {
      const saved = localStorage.getItem("reliquary.pick");
      current = (chars.find((c) => c.key === saved) || chars.find(isJoan) || chars[0]).key;
    }
    const c = char();
    document.title = `${fullName(c)} · Reliquary`;
    app.innerHTML = `${strip(chars)}${hero(c)}<div class="grid" id="charGrid">
      ${columns([doll(c)], 8, [stats(c), crafts(c)], 4, "top")}
      ${album(c)}
      ${talents(c)}
      ${isPublic() ? columns([bags(c), timeline(c), reputation(c)], 7, [quests(c)], 5, "lower") : columns([bags(c), timeline(c), sharing(c)], 7, [reputation(c), quests(c)], 5, "lower")}
      ${profile(c)}${account(chars)}
    </div>`;
    if (!firstPaint) app.querySelectorAll(".rise").forEach((el) => el.classList.remove("rise"));
    firstPaint = false;
    balance();
    catchUpPhotos(app);
    if (detailKey) openDetail(detailKey); // a save while a stop is open: show its fresh numbers
    if (viewFile) openViewer(viewFile); // a save while the viewer is open: show the fresh caption
    showItemPage();
  }

  function renderBags() {
    const c = char();
    const card = document.getElementById("bagsCard");
    if (!c || !card) return;
    const tmp = document.createElement("div");
    tmp.innerHTML = bags(c);
    document.getElementById("bagBody").replaceWith(tmp.querySelector("#bagBody"));
    card.querySelectorAll("[data-bags]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.bags === bagView)));
  }

  // ── Events ────────────────────────────────────────────────────────────────
  app.addEventListener("click", (e) => {
    const pick = e.target.closest("[data-pick]");
    if (pick) {
      current = pick.dataset.pick;
      localStorage.setItem("reliquary.pick", current);
      firstPaint = true;
      if (view !== "chars") { history.pushState(null, "", location.pathname + location.search); }
      render();
      window.scrollTo({ top: 0, behavior: "smooth" });
      return;
    }
    const v = e.target.closest("[data-view]");
    if (v) {
      if (v.dataset.view === view) return;
      history.pushState(null, "", v.dataset.view === "chars" ? location.pathname + location.search : `#${v.dataset.view}`);
      firstPaint = true;
      render();
      window.scrollTo({ top: 0, behavior: "smooth" });
      return;
    }
    const member = e.target.closest("[data-member]");
    if (member) {
      memberPick = member.dataset.member;
      render();
      if (matchMedia("(max-width: 1180px)").matches) document.getElementById("memberCard").scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }
    const peerTile = e.target.closest("[data-peer]");
    if (peerTile) {
      peerPick[view] = peerTile.dataset.peer;
      render();
      if (matchMedia("(max-width: 1180px)").matches) document.getElementById("peerCard").scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }
    const filter = e.target.closest("[data-filter]");
    if (filter) { rosterFilter = filter.dataset.filter; render(); return; }
    const gtab = e.target.closest("[data-gtab]");
    if (gtab) { bankTab = Number(gtab.dataset.gtab); if (bankView === "gold") bankView = "items"; render(); return; }
    const bview = e.target.closest("[data-bview]");
    if (bview) { bankView = bview.dataset.bview; render(); return; }
    if (e.target.closest("[data-bhelps]")) { bankHelps = !bankHelps; render(); return; }
    const guildBtn = e.target.closest("[data-guild]");
    if (guildBtn) { guildPick = guildBtn.dataset.guild; memberPick = null; bankTab = null; render(); return; }
    const photo = e.target.closest("[data-photo]");
    if (photo) { openViewer(photo.dataset.photo); return; }
    if (e.target.closest("[data-quests-all]")) {
      questsAll = !questsAll;
      const tmp = document.createElement("div");
      tmp.innerHTML = quests(char());
      tmp.firstElementChild.classList.remove("rise");
      unlevel();
      document.getElementById("questsCard").replaceWith(tmp.firstElementChild);
      fitQuests();
      level();
      return;
    }
    if (e.target.closest("[data-album-all]")) {
      albumAll = !albumAll;
      const tmp = document.createElement("div");
      tmp.innerHTML = album(char());
      tmp.firstElementChild.classList.remove("rise");
      document.getElementById("album").replaceWith(tmp.firstElementChild);
      catchUpPhotos(app);
      return;
    }
    const bagBtn = e.target.closest("[data-bags]");
    if (bagBtn) { bagView = bagBtn.dataset.bags; renderBags(); return; }
    const stopBtn = e.target.closest("[data-stop]");
    if (stopBtn) { openDetail(stopBtn.dataset.stop); return; }
    if (e.target.closest("[data-road-all]")) { roadAll = true; renderTimeline(); return; }
    const peerBagBtn = e.target.closest("[data-pbags]");
    if (peerBagBtn) { peerBags = peerBagBtn.dataset.pbags; render(); return; }
    const rpTile = e.target.closest("[data-rp]");
    if (rpTile) {
      rpPick = rpTile.dataset.rp;
      render();
      if (matchMedia("(max-width: 1180px)").matches) document.getElementById("rpCard").scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }
    const rpFilterBtn = e.target.closest("[data-rpfilter]");
    if (rpFilterBtn) { rpFilter = rpFilterBtn.dataset.rpfilter; render(); return; }
    const gotoBtn = e.target.closest("[data-goto]");
    if (gotoBtn) {
      // From a profile to the reliquary its player shares, in the view it is shared in.
      const to = gotoBtn.dataset.goto, key = gotoBtn.dataset.key;
      if (to === "guild") memberPick = key; else peerPick[to] = key;
      history.pushState(null, "", `#${to}`);
      firstPaint = true;
      render();
      window.scrollTo({ top: 0, behavior: "smooth" });
      return;
    }
    const craftBtn = e.target.closest("[data-craft]");
    if (craftBtn) { const [owner, prof] = craftBtn.dataset.craft.split("~"); openCraft(owner, prof); return; }
    const tipTarget = e.target.closest("[data-tip], [data-stip]");
    const clicked = tipTarget && itemFor(tipTarget);
    if (clicked && clicked.id) { e.preventDefault(); openItem(clicked.id, clicked); return; }
    if (tipTarget && matchMedia("(hover: none)").matches) { e.preventDefault(); showTip(tipTarget, null); }
  });
  function sparkAt(spark, i) {
    const pts = JSON.parse(spark.dataset.points);
    i = Math.max(0, Math.min(pts.length - 1, i));
    spark.dataset.at = i;
    const [d, p, q, fx, fy] = pts[i];
    const svg = spark.querySelector("svg"), cross = spark.querySelector(".scross"), tip = spark.querySelector(".stip");
    const W = svg.viewBox.baseVal.width;
    cross.setAttribute("x1", fx * W);
    cross.setAttribute("x2", fx * W);
    cross.setAttribute("visibility", "visible");
    tip.innerHTML = `<b>${dayLabel(d)}</b> ${money(p)}${spark.dataset.each === "1" ? " each" : ""} <span class="faint">· ${n(q)} listed</span>`;
    tip.hidden = false;
    tip.style.left = `${Math.min(Math.max(fx * 100, 12), 88)}%`;
    tip.style.top = `${fy * 100}%`;
  }
  function sparkOff(spark) {
    spark.querySelector(".scross").setAttribute("visibility", "hidden");
    spark.querySelector(".stip").hidden = true;
  }
  pageEl.addEventListener("pointermove", (e) => {
    const spark = e.target.closest(".spark");
    if (!spark) return;
    const pts = JSON.parse(spark.dataset.points);
    const r = spark.querySelector("svg").getBoundingClientRect();
    const fx = (e.clientX - r.left) / r.width;
    let best = 0;
    pts.forEach((p, i) => { if (Math.abs(p[3] - fx) < Math.abs(pts[best][3] - fx)) best = i; });
    sparkAt(spark, best);
  });
  pageEl.addEventListener("pointerout", (e) => { const s = e.target.closest(".spark"); if (s && !s.contains(e.relatedTarget)) sparkOff(s); });
  pageEl.addEventListener("focusin", (e) => { if (e.target.classList && e.target.classList.contains("spark")) sparkAt(e.target, JSON.parse(e.target.dataset.points).length - 1); });
  pageEl.addEventListener("focusout", (e) => { if (e.target.classList && e.target.classList.contains("spark")) sparkOff(e.target); });
  pageEl.addEventListener("keydown", (e) => {
    const spark = e.target.closest && e.target.closest(".spark");
    if (!spark || (e.key !== "ArrowLeft" && e.key !== "ArrowRight")) return;
    e.preventDefault();
    sparkAt(spark, Number(spark.dataset.at || 0) + (e.key === "ArrowRight" ? 1 : -1));
  });
  pageEl.addEventListener("click", (e) => {
    if (e.target === pageEl || e.target.closest("[data-ip-close]")) { if (itemOpen) closeItem(); else closeCraft(); return; }
    const craftBtn = e.target.closest("[data-craft]");
    if (craftBtn) { const [owner, prof] = craftBtn.dataset.craft.split("~"); openCraft(owner, prof); return; }
    const inner = e.target.closest("[data-stip]");
    const it = inner && itemFor(inner);
    if (it && it.id) openItem(it.id, it);
  });
  // The recipe book's search redraws the list only, keeping the box's focus.
  pageEl.addEventListener("input", (e) => {
    if (e.target.id !== "recipeSearch" || !craftOpen) return;
    craftQuery = e.target.value;
    const who = craftOwner(craftOpen.owner);
    const book = who && who.books.find((b) => b.name === craftOpen.prof);
    if (book) document.getElementById("rbList").innerHTML = recipeListHtml(book, who.mine);
  });
  app.addEventListener("input", (e) => {
    if (e.target.id === "bagSearch") {
      bagQuery = e.target.value;
      renderBags();
    } else if (e.target.id === "rosterSearch" || e.target.id === "bankSearch" || e.target.id === "rpSearch") {
      // Redraw, keeping the box's focus and caret.
      const id = e.target.id;
      if (id === "rosterSearch") rosterQuery = e.target.value; else if (id === "rpSearch") rpQuery = e.target.value; else bankQuery = e.target.value;
      render();
      const box = document.getElementById(id);
      if (box) { box.focus(); box.setSelectionRange(box.value.length, box.value.length); }
    }
  });
  addEventListener("popstate", () => { firstPaint = true; render(); });

  // ── Tooltips: hover on desktop, a bottom sheet on touch ───────────────────
  let tipOwner = null;
  function showTip(el, ev) {
    const t = el.dataset.stip ? sharedTipFor(el) : tipFor(el);
    if (!t || !t.html) return;
    tipOwner = el;
    tipEl.innerHTML = t.html;
    tipEl.style.setProperty("--qc", t.qc || "transparent");
    tipEl.classList.add("show");
    if (matchMedia("(hover: none)").matches) backdrop.classList.add("show");
    placeTip(ev, el);
  }
  // The screen's safe area (an iPhone's notch and home bar; none on a computer), for what's placed by
  // script: read off an empty box padded by it.
  let safeBox = null;
  function safeArea() {
    if (!safeBox) {
      safeBox = document.createElement("div");
      safeBox.style.cssText = "position:fixed;left:0;top:0;visibility:hidden;pointer-events:none;padding:var(--safe-t) var(--safe-r) var(--safe-b) var(--safe-l)";
      document.body.appendChild(safeBox);
    }
    const st = getComputedStyle(safeBox);
    return { t: parseFloat(st.paddingTop) || 0, r: parseFloat(st.paddingRight) || 0, b: parseFloat(st.paddingBottom) || 0, l: parseFloat(st.paddingLeft) || 0 };
  }
  function placeTip(ev, el) {
    if (matchMedia("(max-width: 560px)").matches) return;
    const r = tipEl.getBoundingClientRect(), sa = safeArea();
    const minX = 10 + sa.l, maxX = innerWidth - 10 - sa.r, minY = 10 + sa.t, maxY = innerHeight - 10 - sa.b;
    let x, y;
    if (ev && ev.clientX != null) { x = ev.clientX + 18; y = ev.clientY + 16; }
    else { const b = el.getBoundingClientRect(); x = b.right + 10; y = b.top; }
    if (x + r.width > maxX) x = (ev && ev.clientX != null ? ev.clientX - 18 : el.getBoundingClientRect().left - 10) - r.width;
    if (y + r.height > maxY) y = maxY - r.height;
    tipEl.style.left = `${Math.max(minX, x)}px`;
    tipEl.style.top = `${Math.max(minY, y)}px`;
  }
  function hideTip() { tipOwner = null; tipEl.classList.remove("show"); backdrop.classList.remove("show"); }
  document.addEventListener("mouseover", (e) => {
    if (matchMedia("(hover: none)").matches) return;
    const el = e.target.closest("[data-tip], [data-stip]");
    if (el && el !== tipOwner) showTip(el, e);
    else if (!el && tipOwner) hideTip();
  });
  document.addEventListener("mousemove", (e) => { if (tipOwner && !matchMedia("(hover: none)").matches) placeTip(e, tipOwner); });
  document.addEventListener("focusin", (e) => { const el = e.target.closest && e.target.closest("[data-tip], [data-stip]"); if (el) showTip(el, null); });
  document.addEventListener("focusout", hideTip);
  backdrop.addEventListener("click", hideTip);
  document.addEventListener("keydown", (e) => {
    if (itemOpen && e.key === "Escape") { e.preventDefault(); closeItem(); return; }
    if (craftOpen && e.key === "Escape") { e.preventDefault(); closeCraft(); return; }
    // Enter on a focused item opens its page, as a click does.
    if (e.key === "Enter" && e.target.closest && e.target.closest("[data-tip], [data-stip]")) {
      const it = itemFor(e.target.closest("[data-tip], [data-stip]"));
      if (it && it.id) { e.preventDefault(); openItem(it.id, it); return; }
    }
    if (viewFile) {
      if (e.key === "Escape") { e.preventDefault(); closeViewer(); }
      else if (e.key === "ArrowLeft") { e.preventDefault(); stepViewer(-1); }
      else if (e.key === "ArrowRight") { e.preventDefault(); stepViewer(1); }
      else if (e.key === "Tab") {
        // Keep focus inside the viewer while it is open.
        const f = [...viewer.querySelectorAll("button")];
        if (!f.length) return;
        const i = f.indexOf(document.activeElement);
        const next = e.shiftKey ? (i <= 0 ? f.length - 1 : i - 1) : (i === f.length - 1 ? 0 : i + 1);
        e.preventDefault();
        f[next].focus();
      }
      return;
    }
    if (detailKey) {
      if (e.key === "Escape") { e.preventDefault(); closeDetail(); }
      else if (e.key === "ArrowLeft") { e.preventDefault(); stepDetail(-1); }
      else if (e.key === "ArrowRight") { e.preventDefault(); stepDetail(1); }
      else if (e.key === "Tab") {
        // Keep focus inside the details while they are open.
        const f = [...detail.querySelectorAll("button")];
        if (!f.length) return;
        const i = f.indexOf(document.activeElement);
        const next = e.shiftKey ? (i <= 0 ? f.length - 1 : i - 1) : (i === f.length - 1 ? 0 : i + 1);
        e.preventDefault();
        f[next].focus();
      }
      return;
    }
    if (e.key === "Escape") hideTip();
  });

  // ── Photos fade in over a shimmer; one deleted from disk says so quietly ──
  function photoLoaded(img) { img.classList.add("in"); img.parentElement.classList.add("loaded"); }
  document.addEventListener("load", (e) => { if (e.target.classList && e.target.classList.contains("ph")) photoLoaded(e.target); }, true);
  // An icon the server can't find leaves its "?" showing. (One listener, not an attribute on each
  // icon: the public copy's Content-Security-Policy refuses inline handlers.)
  document.addEventListener("error", (e) => {
    const img = e.target;
    if (!img.classList) return;
    if (img.parentElement && img.parentElement.classList.contains("ico")) { img.remove(); return; }
    if (!img.classList.contains("ph")) return;
    img.parentElement.classList.add("loaded", "missing");
    img.remove();
  }, true);
  function catchUpPhotos(root) { root.querySelectorAll("img.ph:not(.in)").forEach((img) => { if (img.complete && img.naturalWidth) photoLoaded(img); }); }

  // ── Photo viewer ──────────────────────────────────────────────────────────
  viewer.addEventListener("click", (e) => {
    if (e.target.closest("[data-view-close]") || e.target === viewer || e.target.classList.contains("viewer-frame")) { closeViewer(); return; }
    const step = e.target.closest("[data-view-step]");
    if (step) { stepViewer(Number(step.dataset.viewStep)); return; }
    const pick = e.target.closest("[data-portrait]");
    if (pick) { pick.disabled = true; choosePortrait(pick.dataset.portrait).catch(() => { pick.disabled = false; }); }
  });
  let touchX = null, touchY = null;
  viewer.addEventListener("touchstart", (e) => { if (e.touches.length === 1) { touchX = e.touches[0].clientX; touchY = e.touches[0].clientY; } }, { passive: true });
  viewer.addEventListener("touchend", (e) => {
    if (touchX === null) return;
    const dx = e.changedTouches[0].clientX - touchX, dy = e.changedTouches[0].clientY - touchY;
    touchX = null;
    if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.5) stepViewer(dx < 0 ? 1 : -1);
    else if (dy > 90 && Math.abs(dy) > Math.abs(dx) * 1.5) closeViewer();
  }, { passive: true });
  addEventListener("scroll", () => { if (tipOwner && !matchMedia("(hover: none)").matches) hideTip(); }, { passive: true });

  // ── Data ──────────────────────────────────────────────────────────────────
  async function load() {
    const res = await fetch(`/api/state${DEMO ? "?demo=1" : ""}`, { cache: "no-store" });
    if (!res.ok) throw new Error(`state ${res.status}`);
    const next = await res.json();
    next.live = state ? state.live : false;
    state = next;
    // New saved data: an open item's details are asked for again.
    itemDetails.clear();
    if (itemOpen) loadItemDetails(itemOpen.id);
    // Keep the bag search box's focus and caret across a redraw.
    const focused = document.activeElement && document.activeElement.id === "bagSearch";
    render();
    if (focused) { const s = document.getElementById("bagSearch"); if (s) { s.focus(); s.setSelectionRange(s.value.length, s.value.length); } }
  }

  function setLive(on) {
    if (!state) return;
    state.live = on;
    const el = document.getElementById("saved");
    if (el) el.classList.toggle("live", on && !DEMO);
  }

  function flashSaved() {
    const el = document.getElementById("saved");
    if (!el) return;
    el.classList.remove("flash");
    void el.offsetWidth;
    el.classList.add("flash");
  }

  function listen() {
    if (DEMO || !window.EventSource) return;
    const es = new EventSource("/api/events");
    es.addEventListener("hello", () => setLive(true));
    es.addEventListener("update", async () => { await load().catch(() => {}); setLive(true); flashSaved(); });
    es.onerror = () => setLive(false);
  }

  setInterval(() => {
    const t = document.getElementById("savedText");
    if (t && state) t.textContent = savedText(char());
  }, 30000);

  // The columns change height with the window, and once the fonts have come: place and fit again.
  let fitting = 0;
  addEventListener("resize", () => { cancelAnimationFrame(fitting); fitting = requestAnimationFrame(balance); });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(balance);

  load().then(listen).catch((err) => {
    const own = /\.ts\.net$|^localhost$|^127\./.test(location.hostname);  // the owner's own copy, on the tailnet
    app.innerHTML = own
      ? `<section class="welcome"><h1>Can't reach the reliquary</h1><p>The dashboard's server on this PC didn't answer (${esc(err.message)}). It runs as the <span class="mono">reliquary</span> service.</p></section>`
      : `<section class="welcome"><h1>Can't reach the reliquary</h1><p>Its server didn't answer (${esc(err.message)}). Try again in a minute.</p></section>`;
  });
})();
