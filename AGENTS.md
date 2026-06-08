# AGENTS.md

Operational guide for AI agents working in this repo. Read `DOCS.md` for the full design.

## What this is

A **single-file** browser tool (`index.html`) that procedurally generates one stepped/terraced
mountain for a top-down tile game, and converts its elevation rings into **Factorio-style cliff
border tiles** (12 directional sprites). No build step, no dependencies, no framework — plain
HTML/CSS/JS in one file. `tiles.png` is the cliff sprite atlas.

## Files

- `index.html` — the entire app (markup, CSS, and JS in one `<script>`).
- `tiles.png` — 80×64 cliff sprite atlas, 16×16 tiles, 12 sprites laid out 5/5/2 (4th row empty).
- `DOCS.md` — architecture, algorithms, data model, the cliff-naming convention.
- `AGENTS.md` — this file.

## Run it

Serve over HTTP (do **not** open via `file://` — the browser taints the canvas when it draws
`tiles.png`, breaking the sprite overlay and Save PNG):

```bash
python3 -m http.server 8765      # then open http://localhost:8765
```

There is no test runner, lint, or CI. Verify changes by loading the page and by the node harness below.

## Testing pure logic with node (no browser)

The generation/cleanup/tracer functions are pure and can be run under node with DOM stubs. Extract
the script, then `eval` everything up to the `Param wiring` marker (which avoids the top-level
`render()` call and event wiring that need a real DOM):

```bash
sed -n '/<script>/,/<\/script>/p' index.html | sed '1d;$d' > /tmp/mg.js
node --check /tmp/mg.js     # syntax check after every edit
```

```js
// /tmp/test.js
const noop=()=>{}; const fakeCtx=new Proxy({},{get:()=>noop});
const fakeEl={getContext:()=>fakeCtx,classList:{add:noop,remove:noop,toggle:noop},addEventListener:noop,querySelectorAll:()=>[],style:{}};
global.document={getElementById:()=>fakeEl,createElement:()=>fakeEl,querySelectorAll:()=>[]};
global.performance={now:()=>0}; global.Image=class{};
const full=require('fs').readFileSync('/tmp/mg.js','utf8');
eval(full.slice(0, full.indexOf('Param wiring')).replace(/\/\* =+\s*$/,''));
// now call computeStepGrid(P), ringCliffs(stepGrid,R), etc.
```

The "chain oracle" used during development checks that every cliff tile's `from`/`to` reciprocates
with its neighbours (a traced cliff loop must connect). Re-derive it from `DOCS.md` if you need it.

## Conventions / invariants — do not break these

- **Grid:** `res × res` tiles; cell `(x,y)` is at array index `y*R + x`. North = `-y`, east = `+x`,
  south = `+y`, west = `-x`.
- **Cliff-on-high-tile model:** a cliff tile sits on the *higher* tile of an elevation boundary.
- **Cliff naming anchor (must hold):** the outer **NW** corner of a high region (low to N & W,
  high to SE) is named **`east-to-south`**. Everything else is derived from this + high-on-left
  loop traversal. If you change winding/labels, re-verify against this anchor.
- **`cleanCliffs` is two-phase and convergent:** an *erode* phase (lowers 1-wide spikes/ridges that
  are local maxima) and a *raise* phase (8-connected staircase + saddle/pinch fill + diagonal-bridge
  fill). The raise phase only ever raises. **Never** reintroduce a rule that raises a cell's *lower
  neighbours up to the cell's own level** — that flooded high ground outward into radial "spokes"
  (the old `widen` bug). To remove a 1-wide feature, lower it, don't grow it.
- **Single source of truth:** `computeStepGrid(P)` (quantize + clean) and `ringCliffs(stepGrid,R)`
  (trace) are shared by render and export. Don't duplicate that logic.
- Match the existing terse, comment-light-but-purposeful style; keep everything in the one file.

## Map of the script (search for the function name)

```
mulberry32 / lerp / fade / clamp01        utilities
makePerlin / makeValue / fbm / ridged     noise
makeDiamondSquare                          midpoint-displacement terrain
buildField(P)                              heightfield: algo + falloff + warp + anisotropy + edge
levelsFor(P)                               step thresholds (linear / ease / easein)
STOPS / paletteColor                       elevation colour ramp
CLIFF_TYPES / NAME_COLOR                   12 cliff names -> id + colour (+ 4 "no tile" placeholders)
TILE_ORDER / TILE_SRC / TILE_ATLAS         tiles.png atlas mapping (16x16, 5 per row)
makeSAt                                     clamped neighbour sampler
cleanCliffs(grid,R)                         erode + raise cleanup
traceRingLoops / nameRingLoop / ringCliffs ring tracer -> per-tile cliff name
computeStepGrid(P)                          quantize heightfield + clean
render()                                    fill / contour / cliff views (+ sprite overlay, legend)
readParams / syncLabels                     UI <-> params
exportSettings / exportMap / downloadJSON  JSON exports
```

## Known rough edges

- ~1% of cliff tiles on a typical map don't form a perfectly connected loop (about half of those at
  the canvas border where the mountain clips the edge). `ringCliffs` uses **skip-on-collision**, not
  active "push the outer ring outward". Closing the last gaps needs that push.
- `tiles.png` order: the user-provided list had `east-to-north` twice; index 10 (a vertical-straight
  slot) is mapped to `north-to-south`. Re-confirm if the atlas changes.
- High `res` (≥128) makes `cleanCliffs` + `ringCliffs` take a few hundred ms; live-update can feel
  laggy. The `clean` checkbox disables the cleanup.
