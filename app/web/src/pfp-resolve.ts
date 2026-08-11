// Essey PFP resolver — faithful TS port of pfp/engine.py (generate + apply_conflicts).
// One source of truth for the live builder preview and (server-side) the mint reservation key.
import { sha256 } from "@noble/hashes/sha256";
import { bytesToHex } from "@noble/hashes/utils";

export type Leaf = { z: number; category: string; path: string; file: string; bbox: number[]; blend: string };
export type TreeNode = {
  name: string; group: boolean; z?: number; rarity?: number | null; vis?: boolean;
  blend?: string; file?: string; children?: TreeNode[];
};
export type Rules = {
  DIMS: Record<string, string[]>; DIM_PRIORITY: string[];
  FAMILY_TO_FACEID: Record<string, string>; FACEMOD_COVER: Record<string, string>;
  SUPPRESS: string[]; OPTIONAL: Record<string, number>;
  POS_OFFSET: Record<string, number>; Z_UNDER: Record<string, string>;
  SUPPRESS_IN?: Record<string, string[]>;
  HIDE_LEAF?: string[]; CROP_TOP?: Record<string, number>; CROP_BOTTOM?: Record<string, number>;
  FEMALE_HAT_BLOCK?: string[]; FEMALE_HAT_HAIR_CROP?: Record<string, number>; FEMALE_HAT_HAIR_CROP_STYLES?: string[];
};
export type BuilderData = {
  gender: string; leaves: Leaf[]; tree: TreeNode[];
  cats: Record<string, { group: boolean; role: string | null }>;
  rules: Rules; hand_conflicts: { cane_grip?: [string, string][]; snake_grip?: string[]; cane_snake?: [string, string][] };
};
export type RenderLeaf = { file: string; bbox: number[]; blend: string; category: string; zEff: number; cropTop?: number; cropBottom?: number };
export type Resolved = { render: RenderLeaf[]; picks: Record<string, string>; drivers: Record<string, string | null>; key: string };

// ---- seeded RNG (choices/choice/random) ----
function mulberry32(seed: number) {
  return () => { let t = (seed += 0x6d2b79f5); t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
class RNG {
  r: () => number;
  constructor(seed: number) { this.r = mulberry32(seed >>> 0); }
  random() { return this.r(); }
  choice<T>(a: T[]): T { return a[Math.floor(this.r() * a.length)]; }
  choices<T>(a: T[], w: number[]): T { const s = w.reduce((x, y) => x + y, 0); let t = this.r() * s; for (let i = 0; i < a.length; i++) { t -= w[i]; if (t <= 0) return a[i]; } return a[a.length - 1]; }
}

const fw = (n: string) => (n ? n.split(/\s+/)[0] : "");
const isPart = (c: TreeNode) => { const nl = (c.name || "").toLowerCase(); return nl.includes("shadow") || ["mouth", "eyes", "8 mouth", "9 eyes"].includes(nl); };

function coupleDim(children: TreeNode[], R: Rules): [string | null, Record<string, TreeNode[]> | null] {
  for (const dim of R.DIM_PRIORITY) {
    const hit: Record<string, TreeNode[]> = {};
    for (const c of children) {
      const nl = (c.name || "").toLowerCase();
      for (const v of R.DIMS[dim]) { if (nl.includes(v.toLowerCase())) { (hit[v] ||= []).push(c); break; } }
    }
    if (Object.keys(hit).length >= 2) return [dim, hit];
  }
  return [null, null];
}

class Sel {
  rng: RNG; R: Rules; forced: Record<string, string>;
  leaves: TreeNode[] = []; picks: Record<string, string> = {}; drivers: Record<string, string | null> = {};
  constructor(rng: RNG, R: Rules, forced: Record<string, string> = {}) { this.rng = rng; this.R = R; this.forced = forced; }
  emit(node: TreeNode, path: string) { if (node.group) this.select(node.children || [], path); else this.leaves.push(node); }
  couplePick(children: TreeNode[]): TreeNode | null {
    const [dim, hit] = coupleDim(children, this.R);
    if (!dim || !hit) return null;
    const v = (this.drivers[dim] || "").toLowerCase();
    if (!v) return null;
    for (const val of Object.keys(hit)) { const vl = val.toLowerCase(); if (v.includes(vl) || vl.includes(v)) return hit[val][0]; }
    return null;
  }
  select(children: TreeNode[], path: string) {
    const parts = children.filter(isPart);
    let rest = children.filter((c) => !isPart(c));
    const kept = rest.filter((c) => !this.R.SUPPRESS.some((x) => (c.name || "").toLowerCase().includes(x)));
    if (kept.length) rest = kept;
    const si = this.R.SUPPRESS_IN?.[path.split("/")[0]];
    if (si) { const k2 = rest.filter((c) => !si.includes((c.name || "").toLowerCase())); if (k2.length) rest = k2; }
    for (const c of parts) this.emit(c, path);
    if (!rest.length) return;
    // USER-FORCED pick at a category top-level (builder): override random selection.
    if (this.forced[path] !== undefined) {
      const want = this.forced[path].toLowerCase();
      if (want === "none" || want === "__none__") { this.picks[path] = "None"; return; } // explicit absent
      // EXACT-first: a forced value is a bare option name, so an exact leaf-name match must win over
      // any substring sibling ("MVHQ Martini" must beat "Martini"; "Knowledge Throne" beat "Throne";
      // female ring "Bar" beat a longer "Bar…"). Only fall back to a one-directional substring match
      // (option name contains the forced value) — never `want.includes(name)`, which is what let a
      // longer forced name collapse onto a shorter sibling.
      const c = rest.find((x) => (x.name || "").toLowerCase() === want)
        ?? rest.find((x) => (x.name || "").toLowerCase().includes(want));
      if (c) { this.picks[path] = c.name; this.emit(c, path + "/" + c.name); return; }
    }
    const [dim, hit] = coupleDim(rest, this.R);
    if (dim && this.drivers[dim]) {
      const pick = this.couplePick(rest);
      if (pick) { this.picks[path] = pick.name; this.emit(pick, path + "/" + pick.name); return; }
      const nm = rest.map((c) => c.name || "").join(" ").toLowerCase();
      if (nm.includes("tattoo") || nm.includes("beard")) return; // optional coupled: no match -> absent
    }
    const weighted = rest.filter((c) => c.rarity != null);
    if (weighted.length) {
      const pick = this.rng.choices(weighted, weighted.map((c) => c.rarity as number));
      this.picks[path] = pick.name; this.emit(pick, path + "/" + pick.name); return;
    }
    if (dim && hit) {
      const cands = Object.values(hit).flat();
      const pick = cands.length ? this.rng.choice(cands) : this.rng.choice(rest);
      this.picks[path] = pick.name; this.emit(pick, path + "/" + pick.name); return;
    }
    const vis = rest.filter((c) => c.vis);
    if (vis.length === rest.length) { for (const c of rest) this.emit(c, path); }
    else {
      const pick = vis.length ? vis[0] : this.rng.choice(rest);
      // Category-wrapper node (a vis=false top-level category whose sole `rest` member is itself):
      // when the user has FORCED this category, descend at the SAME path so the forced key (the bare
      // category name) still matches the real options one level down. Gated on forced -> random untouched.
      if (pick.name === path && this.forced[path] !== undefined) { this.emit(pick, path); }
      else { this.picks[path] = pick.name; this.emit(pick, path + "/" + pick.name); }
    }
  }
  selectCategory(cat: TreeNode): string | null { this.select([cat], cat.name); return this.picks[cat.name] ?? null; }
}

const roleOf = (name: string): string | null => {
  const n = name.toLowerCase();
  if (n.endsWith("body")) return "body";
  if (n.endsWith("suit") || n.endsWith("suits")) return "suit";
  if (n.endsWith("hair") && !n.includes("hat") && !n.includes("rear")) return "hair";
  if (n.includes("eye mod")) return "eyemod";
  if (n.endsWith("hat") && !n.includes("hair")) return "hat";
  return null;
};
const PRI: Record<string, number> = { body: 0, suit: 1, hair: 2, eyemod: 3, hat: 4 };

function generate(data: BuilderData, rng: RNG, forced: Record<string, string> = {}): Sel {
  const R = data.rules; const s = new Sel(rng, R, forced);
  const cats: Record<string, TreeNode> = {};
  for (const c of data.tree) if (c.group) cats[c.name] = c;
  const roles: Record<string, string | null> = {};
  for (const name of Object.keys(cats)) roles[name] = roleOf(name);
  const drivers = Object.keys(cats).filter((n) => roles[n]).sort((a, b) => PRI[roles[a]!] - PRI[roles[b]!]);
  const order = [...drivers, ...Object.keys(cats).filter((c) => !roles[c])];
  for (const name of order) {
    if (name in R.OPTIONAL && forced[name] === undefined) {   // random rarity gate (unless user forced it)
      if (rng.random() >= R.OPTIONAL[name]) continue;
      if (s.couplePick(cats[name].children || []) === null) continue;
    }
    // FEMALE_HAT_BLOCK (engine.py): Medusa's snake-crown pierces every female hat -> skip the hat
    // category entirely for a blocked hair style, so preview + uniqueness key match the engine.
    if (name === "10 Hat" && R.FEMALE_HAT_BLOCK && typeof s.drivers.hair_style === "string"
      && R.FEMALE_HAT_BLOCK.includes(s.drivers.hair_style)) continue;
    const top = s.selectCategory(cats[name]); const r = roles[name];
    if (r === "body" && top) {
      const fam = fw(top); s.drivers.family = fam;
      if (R.FAMILY_TO_FACEID[fam]) s.drivers.faceid = R.FAMILY_TO_FACEID[fam];
      if (fam === "Zombie" || fam === "Golden") s.drivers.build = fam;
      else { const sub = s.picks[name + "/" + top] || top; s.drivers.build = R.DIMS.build.find((b) => sub.split(/\s+/).includes(b)) || null; }
    } else if (r === "suit" && top) { s.drivers.suit = top; }
    else if (r === "hair" && top) {
      const cw = s.picks[name + "/" + top] || ""; const full = (top + " " + cw).toLowerCase();
      s.drivers.hair_color = R.DIMS.hair_color.find((c) => full.includes(c.toLowerCase())) || null;
      s.drivers.hair_style = R.DIMS.hair_style.find((st) => full.includes(st.toLowerCase())) || fw(top);
      if (!s.drivers.hair_color) s.drivers.hair_color = rng.choice(["Black", "Red", "White"]);
    } else if (r === "eyemod") {
      const vals = Object.entries(s.picks).filter(([k]) => k.startsWith(name)).map(([, v]) => v).join(" ").toLowerCase();
      s.drivers.eyemod = R.DIMS.eyemod.find((m) => vals.includes(m.toLowerCase())) || null;
    } else if (r === "hat" && top && top.toLowerCase() !== "none") { s.drivers.hat = fw(top); }
    if (name.toLowerCase().endsWith("face") && top) s.drivers.faceid = fw(top);
  }
  return s;
}

function applyConflicts(data: BuilderData, s: Sel) {
  const R = data.rules; const meta: Record<number, Leaf> = {}; for (const e of data.leaves) meta[e.z] = e;
  const HC = data.hand_conflicts || {};
  const CG = new Set((HC.cane_grip || []).map((p) => p.join("")));
  const SG = new Set(HC.snake_grip || []);
  const CS = new Set((HC.cane_snake || []).map((p) => p.join("")));
  const picks = s.picks, dr = s.drivers;
  const fm = picks["17 Face Mod"] || "None";
  const cover = fm.toLowerCase() !== "none" ? R.FACEMOD_COVER[fm.split(/\s+/)[0]] : undefined;
  const laser = (picks["24 Laser Eye"] || "None").toLowerCase() !== "none";
  let hat = !!dr.hat;
  const hideCats = new Set<string>(); const hidePaths: string[] = [];
  const fam = dr.family;
  if (fam === "Zombie" || fam === "Golden" || fam === "Glitch") {
    ["10 Nose", "11 Tattoos", "12 Beard", "13 Hair", "13.5 Hat Hair", "14 Eyebrow", "15 Eye Mod", "16 Glasses", "17 Face Mod", "22 Hat", "23 Ceasar", "24 Laser Eye"].forEach((c) => hideCats.add(c));
    if (fam === "Glitch") hideCats.add("7 Face");
  }
  if (cover === "full") { ["16 Glasses", "15 Eye Mod", "14 Eyebrow", "10 Nose", "12 Beard"].forEach((c) => hideCats.add(c)); hidePaths.push("8 Mouth", "9 Eyes"); }
  else if (cover === "eyes") { hideCats.add("16 Glasses"); hideCats.add("15 Eye Mod"); }
  else if (cover === "lower") { hideCats.add("12 Beard"); hidePaths.push("8 Mouth"); }
  if (laser) { hideCats.add("16 Glasses"); hideCats.add("15 Eye Mod"); }
  if (hat) hideCats.add("23 Ceasar");
  if (fm.split(/\s+/)[0] === "Doom") { ["22 Hat", "13.5 Hat Hair", "13 Hair", "23 Ceasar"].forEach((c) => hideCats.add(c)); hat = false; }

  const variant = (cat: string): string | null => {
    for (const lf of s.leaves) { const m = meta[lf.z!]; if (m && m.category === cat) { const p = m.path.split("/"); return p.length > 1 ? p[1] : p[0]; } }
    return null;
  };
  let grip = variant("19 Hand Grip"), cane = variant("18 Canes"), snake = variant("25 Snake");
  if (grip && cane) { hideCats.add("18 Canes"); cane = null; }
  if (grip && snake && SG.has(grip)) { hideCats.add("25 Snake"); snake = null; }
  if (cane && snake && CS.has(cane + "" + snake)) { hideCats.add("25 Snake"); snake = null; }
  const addLeaves: TreeNode[] = [];
  hideCats.add("6 Snake Tail");
  if (snake) {
    const col = snake.toLowerCase().includes("red") ? "red" : "green";
    const tail = data.leaves.find((e) => e.category === "6 Snake Tail" && e.path.toLowerCase().includes(col));
    if (tail) addLeaves.push({ name: "tail", group: false, z: tail.z });
  }
  if (fam !== "Zombie" && fam !== "Golden" && fam !== "Glitch") hideCats.add(hat ? "13 Hair" : "13.5 Hat Hair");

  const HL = R.HIDE_LEAF || [];
  const keep = (lf: TreeNode) => { const m = meta[lf.z!]; if (!m) return true; if (hideCats.has(m.category)) return false; if (hidePaths.some((hp) => m.path.includes(hp))) return false; if (HL.some((h) => m.path.includes(h))) return false; return true; };
  const kept = [...s.leaves.filter(keep), ...addLeaves];

  // effective z: earrings under hair (Z_UNDER); order + attach render info
  const tz: Record<string, number> = {};
  for (const [cat, under] of Object.entries(R.Z_UNDER)) {
    const zs = kept.map((lf) => meta[lf.z!]).filter((m) => m && m.category === under).map((m) => m.z);
    if (zs.length) tz[cat] = Math.min(...zs) - 0.5;
  }
  // FEMALE_HAT_HAIR_CROP (engine.py): female hats keep the full '9 Hair'; Gem/Updo/Lush poke above
  // the crown -> crop those styles' hair at the chosen hat's crown line (same cut the PSD's per-hat
  // 'Hat Hair' variants use), so the preview + uniqueness key match the engine.
  const FHC = R.FEMALE_HAT_HAIR_CROP, FHCS = R.FEMALE_HAT_HAIR_CROP_STYLES;
  const femHairCrop = (FHC && FHCS && typeof dr.hat === "string" && FHC[dr.hat] !== undefined
    && typeof dr.hair_style === "string" && FHCS.includes(dr.hair_style)) ? FHC[dr.hat] : undefined;

  const render: RenderLeaf[] = [];
  for (const lf of kept) {
    const m = meta[lf.z!];
    if (!m || !m.file) continue;
    const rl: RenderLeaf = { file: m.file, bbox: m.bbox.slice(), blend: m.blend, category: m.category, zEff: tz[m.category] ?? (lf.z as number) };
    const ct = R.CROP_TOP ? Object.entries(R.CROP_TOP).find(([k]) => m.path.includes(k))?.[1] : undefined;
    if (ct !== undefined) rl.cropTop = ct;
    if (femHairCrop !== undefined && m.category === "9 Hair") rl.cropTop = femHairCrop;
    const cb = R.CROP_BOTTOM ? Object.entries(R.CROP_BOTTOM).find(([k]) => m.path.includes(k))?.[1] : undefined;
    if (cb !== undefined) rl.cropBottom = cb;
    render.push(rl);
  }
  render.sort((a, b) => a.zEff - b.zEff);

  const visiblePaths = kept.map((lf) => meta[lf.z!]?.path).filter(Boolean).sort();
  const key = bytesToHex(sha256(data.gender + "\n" + visiblePaths.join("\n")));
  return { render, picks: s.picks, drivers: s.drivers, key } as Resolved;
}

export function resolveRandom(data: BuilderData, seed: number): Resolved {
  const s = generate(data, new RNG(seed));
  return applyConflicts(data, s);
}
export function resolveSelection(data: BuilderData, forced: Record<string, string>, seed: number): Resolved {
  const s = generate(data, new RNG(seed), forced);
  return applyConflicts(data, s);
}
export function posOffset(data: BuilderData, category: string): number { return data.rules.POS_OFFSET[category] || 0; }

// top-level variant options per category (for the picker panels). Mirror the resolver's own pool
// filtering so the picker never offers a trait the engine suppresses (else a forced click on it
// silently falls back to a random sibling): SUPPRESS (substring, everywhere) + SUPPRESS_IN
// (exact option names per category, e.g. female "14 Ring" -> "Bar", a broken art variant).
export function catOptions(data: BuilderData): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  const S = data.rules.SUPPRESS || [];
  for (const cat of data.tree) if (cat.group) {
    const si = data.rules.SUPPRESS_IN?.[cat.name] || [];
    out[cat.name] = (cat.children || []).map((c) => c.name).filter((n) => {
      const nl = n.toLowerCase();
      if (S.some((x) => nl.includes(x))) return false;
      if (si.includes(nl)) return false;
      return true;
    });
  }
  return out;
}

// which category panels to gray-out given the current selection (a pick there won't render)
export function blockedCats(data: BuilderData, forced: Record<string, string>): Set<string> {
  const b = new Set<string>();
  const male = data.gender === "male";
  const HAT = male ? "22 Hat" : "10 Hat", EYEMOD = "15 Eye Mod", GLASSES = "16 Glasses",
    CEASAR = "23 Ceasar", LASER = "24 Laser Eye", FACEMOD = "17 Face Mod";
  const fm = forced[FACEMOD] || "None";
  const cover = data.rules.FACEMOD_COVER[fm.split(/\s+/)[0]];
  if (fm.split(/\s+/)[0] === "Doom") { b.add(HAT); b.add(CEASAR); }
  if (cover === "full" || cover === "eyes") { b.add(GLASSES); b.add(EYEMOD); }
  const laser = forced[LASER]; if (laser && laser.toLowerCase() !== "none") { b.add(GLASSES); b.add(EYEMOD); }
  const hat = forced[HAT]; if (hat && hat.toLowerCase() !== "none") b.add(CEASAR);
  const fam = (forced[male ? "4 Body" : "3 Body"] || "").split(/\s+/)[0];
  if (["Zombie", "Golden", "Glitch"].includes(fam)) [FACEMOD, HAT, CEASAR, GLASSES, EYEMOD, LASER].forEach((x) => b.add(x));
  // FEMALE_HAT_BLOCK: a blocked hair style (Medusa) pierces every female hat -> the hat won't render.
  if (!male) {
    const hairStyle = (forced["9 Hair"] || "").split(/\s+/)[0];
    if (hairStyle && (data.rules.FEMALE_HAT_BLOCK || []).includes(hairStyle)) b.add(HAT);
  }
  return b;
}
