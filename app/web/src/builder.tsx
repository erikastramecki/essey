import { useEffect, useRef, useState, useMemo, useCallback } from "react";
import type { BuilderData, Resolved } from "./pfp-resolve";
import { resolveSelection, catOptions, blockedCats } from "./pfp-resolve";
import { composite } from "./pfp-compositor";

type G = "male" | "female";
// [categoryId, label, optional] — the panels the user picks from, in order.
const SELECT: Record<G, [string, string, boolean][]> = {
  male: [
    ["4 Body", "Bloodline", false], ["5 Suit", "Suit", false], ["13 Hair", "Hair", false],
    ["17 Face Mod", "Face Mod", true], ["15 Eye Mod", "Eye Mod", true], ["16 Glasses", "Glasses", true],
    ["22 Hat", "Hat", true], ["23 Ceasar", "Crown", true], ["24 Laser Eye", "Laser", true],
    ["19 Hand Grip", "Hand", false], ["18 Canes", "Cane", true], ["25 Snake", "Snake", true],
    ["20 Rings", "Ring", false], ["21 Wrist", "Wrist", false], ["26 AR", "AR Screen", true],
    ["2 The hawk", "Hawk", true], ["1 Background", "Background", false], ["3 Chair", "Chair", false],
  ],
  female: [
    ["3 Body", "Bloodline", false], ["4 Suits", "Suit", false], ["9 Hair", "Hair", false],
    ["8 Necklace", "Necklace", false], ["10 Hat", "Hat", true], ["11 Devilish", "Devilish", true],
    ["16 Neko", "Neko Mask", true], ["15 Earing", "Earring", false], ["13 Hand Grip", "Hand", false],
    ["14 Ring", "Ring", false], ["12 Wrist dec", "Wrist", false], ["17 AR", "AR Screen", true],
    ["18 phoenix eyes", "Phoenix Eyes", true], ["1 Chairs", "Chair", false],
  ],
};
const clean = (v: string) => v.replace(/#\d+/g, "").replace(/^[\d.]+\s*/, "").trim();

export function BuilderPage() {
  const [gender, setGender] = useState<G>("male");
  const [data, setData] = useState<Partial<Record<G, BuilderData>>>({});
  const [picks, setPicks] = useState<Record<string, string>>({});
  const [seed, setSeed] = useState<number>(() => Math.floor(Math.random() * 1e9));
  const [res, setRes] = useState<Resolved | null>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    (["male", "female"] as G[]).forEach((g) => {
      if (!data[g]) fetch(`/builder/data_${g}.json`).then((r) => r.json()).then((d: BuilderData) => setData((p) => ({ ...p, [g]: d }))).catch(() => {});
    });
  }, []); // eslint-disable-line

  const [rsv, setRsv] = useState<{ status: "idle" | "busy" | "reserved" | "taken" | "error"; by?: string }>({ status: "idle" });
  const d = data[gender];
  const opts = useMemo(() => (d ? catOptions(d) : {}), [d]);
  const blocked = useMemo(() => (d ? blockedCats(d, picks) : new Set<string>()), [d, picks]);
  // effective selection = picks minus anything a conflict blocked (preview == what the rules allow)
  const eff = useMemo(() => {
    const e: Record<string, string> = {};
    for (const [k, v] of Object.entries(picks)) if (!blocked.has(k)) e[k] = v;
    return e;
  }, [picks, blocked]);

  const genRef = useRef(0);
  useEffect(() => {
    const cv = canvasRef.current; if (!d || !cv) return;
    const gen = ++genRef.current; // latest-wins: a slower earlier render must not clobber this one
    const r = resolveSelection(d, eff, seed);
    setRes(r); composite(cv, d, r.render, () => genRef.current === gen);
  }, [d, eff, seed]);
  useEffect(() => { setRsv({ status: "idle" }); }, [res?.key]); // token changed -> reset reservation

  const reserve = useCallback(async () => {
    if (!res) return; setRsv({ status: "busy" });
    try {
      const resp = await fetch("/api/reserve", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ gender, forced: eff, seed }) }).then((r) => r.json());
      if (resp.ok) setRsv({ status: "reserved" });
      else if (resp.taken) setRsv({ status: "taken", by: resp.by });
      else setRsv({ status: "error" });
    } catch { setRsv({ status: "error" }); }
  }, [res, gender, eff, seed]);

  const setPick = useCallback((cat: string, val: string) => {
    setPicks((p) => { const n = { ...p }; if (n[cat] === val) delete n[cat]; else n[cat] = val; return n; });
  }, []);
  const randomize = () => setSeed(Math.floor(Math.random() * 1e9));
  const clearAll = () => setPicks({});
  const switchGender = (g: G) => { setGender(g); setPicks({}); };

  return (
    <div style={{ maxWidth: 1180, margin: "0 auto", padding: "20px 16px", color: "#ece9e1" }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 12, flexWrap: "wrap", marginBottom: 14 }}>
        <h1 style={{ margin: 0, letterSpacing: ".18em", fontWeight: 800, background: "linear-gradient(90deg,#e6c877,#c9a24b)", WebkitBackgroundClip: "text", backgroundClip: "text", color: "transparent" }}>PFP BUILDER</h1>
        <span style={{ fontSize: 13, color: "#9a978d" }}>pick traits · rules keep it valid · reserve your 1-of-1</span>
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "minmax(300px,440px) 1fr", gap: 22, alignItems: "start" }}>
        {/* preview + actions (sticky) */}
        <div style={{ position: "sticky", top: 12, display: "flex", flexDirection: "column", gap: 12 }}>
          <div style={{ background: "#0d0e12", border: "1px solid #26283340", borderRadius: 16, padding: 10 }}>
            <canvas ref={canvasRef} style={{ width: "100%", aspectRatio: "1", borderRadius: 10, display: "block", background: "#111218" }} />
          </div>
          <div style={{ display: "flex", gap: 8 }}>
            {(["male", "female"] as G[]).map((g) => <button key={g} onClick={() => switchGender(g)} style={chip(gender === g)}>{g}</button>)}
            <button onClick={randomize} style={{ ...chip(false), marginLeft: "auto" }}>🎲 Shuffle rest</button>
            <button onClick={clearAll} style={chip(false)}>Clear</button>
          </div>
          <div style={{ fontSize: 11, color: "#6f6d66", wordBreak: "break-all", background: "#0d0e12", border: "1px solid #26283340", borderRadius: 10, padding: "8px 10px" }}>
            <span style={{ textTransform: "uppercase", letterSpacing: ".05em" }}>Uniqueness key</span><br />
            <code style={{ color: "#c9a24b" }}>{res?.key.slice(0, 40)}…</code>
          </div>
          <button onClick={reserve} disabled={rsv.status === "busy" || rsv.status === "reserved"}
            style={{ ...chip(rsv.status !== "taken"), padding: "13px", fontSize: 14,
              background: rsv.status === "reserved" ? "linear-gradient(90deg,#5ac47e,#2f9e57)" : rsv.status === "taken" ? "#3a2326" : "linear-gradient(90deg,#e6c877,#c9a24b)",
              color: rsv.status === "taken" ? "#e06a97" : "#0b0c10",
              cursor: rsv.status === "busy" || rsv.status === "reserved" ? "default" : "pointer" }}>
            {rsv.status === "reserved" ? "✓ Reserved — yours to mint"
              : rsv.status === "taken" ? "✗ Taken — tweak a trait"
              : rsv.status === "busy" ? "Reserving…"
              : rsv.status === "error" ? "Error — retry"
              : "Reserve this 1-of-1"}
          </button>
          {rsv.status === "taken" && <div style={{ fontSize: 11, color: "#6f6d66" }}>This exact combination is already reserved. Change any trait for a fresh 1-of-1.</div>}
        </div>
        {/* category pickers */}
        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          {SELECT[gender].map(([cat, label, opt]) => {
            const isBlocked = blocked.has(cat);
            const options = (opts[cat] || []).filter((o) => o && o.toLowerCase() !== "none");
            const cur = picks[cat];
            return (
              <div key={cat} style={{ background: "#12131a", border: "1px solid #26283340", borderRadius: 12, padding: "10px 12px", opacity: isBlocked ? 0.4 : 1, pointerEvents: isBlocked ? "none" : "auto" }}>
                <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 7 }}>
                  <span style={{ fontSize: 11, textTransform: "uppercase", letterSpacing: ".07em", color: "#c9a24b", fontWeight: 700 }}>{label}</span>
                  {isBlocked && <span style={{ fontSize: 10, color: "#6f6d66" }}>blocked by another pick</span>}
                  {!isBlocked && cat === "13 Hair" && res?.drivers.hat && <span style={{ fontSize: 10, color: "#6f6d66" }}>under hat — sets beard/brows</span>}
                </div>
                <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
                  {opt && <button onClick={() => setPick(cat, "none")} style={optChip(cur === "none")}>∅ None</button>}
                  {options.map((o) => <button key={o} onClick={() => setPick(cat, o)} style={optChip(cur ? cur === o : false)}>{clean(o)}</button>)}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

function chip(active: boolean): React.CSSProperties {
  return { border: "1px solid " + (active ? "transparent" : "#26283340"), background: active ? "linear-gradient(90deg,#e6c877,#c9a24b)" : "#16171f", color: active ? "#0b0c10" : "#c9c6bd", padding: "8px 14px", borderRadius: 999, fontSize: 13, fontWeight: 700, cursor: "pointer", letterSpacing: ".02em" };
}
function optChip(active: boolean): React.CSSProperties {
  return { border: "1px solid " + (active ? "#c9a24b" : "#26283340"), background: active ? "#c9a24b22" : "#16171f", color: active ? "#e6c877" : "#9a978d", padding: "5px 10px", borderRadius: 8, fontSize: 12, fontWeight: 600, cursor: "pointer" };
}
