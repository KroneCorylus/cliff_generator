# Stepped Mountain + Cliff Generator — Documentation

A browser tool that generates **one** terraced mountain inside a configurable square grid and turns
its elevation steps into **Factorio-style cliff border tiles** for a top-down tile game. Everything
lives in `index.html` (no build, no dependencies); `tiles.png` holds the cliff sprites.

Open it by serving the folder over HTTP and visiting it:

```bash
python3 -m http.server 8765   # http://localhost:8765
```

Use HTTP, not `file://` — drawing `tiles.png` onto the canvas under `file://` taints it and breaks the
sprite overlay and "Save PNG".

---

## 1. Pipeline overview

```
parameters (UI)
      │  buildField(P)
      ▼
heightfield  H[y*R+x] ∈ [0,1]          one central mountain
      │  levelsFor(P) thresholds  +  quantize
      ▼
stepGrid     integer elevation level per tile (0 = base)
      │  cleanCliffs(grid,R)           make it "cliff-legal"
      ▼
clean stepGrid                          terraces ≥1 wide, no saddles/pinches
      │  ringCliffs(stepGrid,R)        trace each level's boundary
      ▼
cliff map    tile → Factorio cliff name (+ level)
      │  render() / exportMap()
      ▼
canvas views & JSON
```

`computeStepGrid(P)` does the first three boxes; `ringCliffs` the next. Both render and export use
them, so the on-screen image and the exported data always match.

---

## 2. Heightfield — `buildField(P)`

Produces a normalized `[0,1]` height per grid point. Steps:

1. **Base generator** — one of:
   - `perlin` — classic gradient noise, fractal (fBm).
   - `value` — value noise, fBm (smoother/blobbier).
   - `ridged` — ridged multifractal (sharp ridgelines).
   - `diamond` — diamond-square midpoint displacement.
   - `cone` / `gaussian` — analytic shapes (baselines).
2. **Domain warp** (`warp`, `warpScale`) — perturb sample coordinates with extra noise so detail isn't
   radially symmetric.
3. **Radial falloff** to isolate a *single* mountain (`fall`, `rad`), with **anisotropy**
   (`stretch`, `rot` — elongate/rotate into a ridge) and **edge irregularity** (`edge`, `edgeScale` —
   a lumpy, lobed outline instead of a clean circle).
4. **Normalize** to `[0,1]`, then **peak sharpness** (`sharp`, a power curve).

All randomness comes from a seeded `mulberry32` PRNG, so a given `seed` + params is reproducible. The
auxiliary warp/edge noises are seed-derived, so each seed gives a genuinely different overall shape.

`levelsFor(P)` returns `steps` thresholds strictly inside `(0,1)`, spaced `linear`, `ease`-out, or
`ease`-in. Quantizing assigns each tile the count of thresholds its height exceeds → integer
elevation level `0..steps`.

---

## 3. Cleanup — `cleanCliffs(grid, R)`

The raw quantized grid has features that **cannot be represented by the 12 cliff tiles**: 2-level
jumps, diagonal "saddle" pinches, 1-wide spikes/ridges, 1-wide diagonal "bridges". Cleanup removes
them so the ring tracer produces clean L-staircases. It runs two phases to a fixpoint:

- **Erode** (lowers): a tile that is a 1-wide spike/ridge (lower neighbours on opposite or 3+ sides)
  **and** has no strictly-higher neighbour is dropped to its tallest neighbour. Safe — a tile with no
  higher neighbour is never raised back, so it can't oscillate.
- **Raise** (only raises → monotonic, always converges):
  - **8-connected staircase** — every tile ≥ its highest neighbour (incl. diagonals) − 1. This makes
    terraces ≥1 tile wide *even at corners*, which is what gives the inner-corner L its room.
  - **Saddle / pinch fill** — raise one cell of a 2×2 where the high tiles touch only diagonally
    (`H L / L H`, or one diagonal pair equal) so the cliff turns through an L, not a `/`.
  - **Diagonal-bridge fill** — a tile high on all 4 sides but with two *opposite* diagonal neighbours
    low is a 1-wide diagonal strip; raise one diagonal notch.

> ⚠️ History/gotcha: an earlier "widen" rule removed 1-wide tiles by raising their *lower neighbours
> up to the tile's level*. Because raising grows the high region, it chain-reacted outward and
> produced long radial **spokes to the border**. Don't do that. Remove 1-wide features by lowering.

The `clean` checkbox toggles this. With it off you see the raw noise (useful to see what cleanup fixed).

---

## 4. Cliff tiles & the Factorio naming convention

Cliffs sit on the **higher** tile of an elevation boundary. Each cliff tile is a **directed segment**
of the boundary loop, named `<entering edge>-to-<leaving edge>`. There are 12:

| Group | Tiles |
|---|---|
| Straight walls | `east-to-west`, `west-to-east`, `north-to-south`, `south-to-north` |
| Outer (convex) corners | `east-to-south`, `south-to-west`, `west-to-north`, `north-to-east` |
| Inner (concave) corners | `east-to-north`, `south-to-east`, `west-to-south`, `north-to-west` |

Coordinates: north = up (`-y`), east = `+x`, south = `+y`, west = `-x`.

**Anchor** (pins the whole scheme): the outer **NW** corner of a high region — low to the N and W,
high to the SE — is `east-to-south`. The loop is traversed with the **high region on the left**, and
each tile's name is `<dir to previous tile in the loop>-to-<dir to next tile>`. From the anchor:

- The four outer corners chain: `east-to-south → south-to-west → west-to-north → north-to-east`.
- Inner corners are the reverses (`east-to-north`, `south-to-east`, `west-to-south`, `north-to-west`).

`CLIFF_TYPES` maps each name to an `id` + legend colour. It also holds 4 placeholders
(`ridge*`, `tip`, `pillar`) with `id: null` for 1-wide features that have **no** legal tile — cleanup
plus tracing are designed so these never reach the output.

---

## 5. Ring tracer — `traceRingLoops` / `nameRingLoop` / `ringCliffs`

Instead of classifying tiles independently (which loses how rings relate and mis-labels ambiguous
spots), `ringCliffs` traces each elevation **ring** as an ordered loop and reads directions off the
traversal:

1. For each level `L` from the **innermost (highest)** outward, take the region `{level ≥ L}` and
   **trace its boundary** with `traceRingLoops` — a wall-follower that keeps the high region on the
   left and walks tile-to-tile (priority: turn left, straight, right, back).
2. `nameRingLoop` dedups the owner-cell sequence and assigns each tile
   `name = dir(prev)-to-dir(next)`. Where the loop steps **diagonally** (a concave/inner corner) it
   **inserts the inside cell** so the corner uses a real inner-corner sprite instead of leaving a
   diagonal gap.
3. Rings are placed innermost-first into a `Map` (`tile index → {name, level}`). An outer ring
   **yields** (skips) a tile already taken by an inner ring.

Because tracing knows the real connectivity, the from/to directions form consistent connected loops —
the local-classification ambiguities (double inner corners, diagonal bridges) disappear once cleanup
has guaranteed the topology is clean.

**Quality:** on typical maps ~99% of cliff tiles form perfectly connected loops; ~1% (about half at
the canvas border) don't, because `ringCliffs` skips on collision rather than actively pushing the
outer ring outward. Implementing that push is the path to 100%.

---

## 6. Views — `render()`

- **Terraced fill** — every tile filled by elevation via `paletteColor` (water → grass → sand → rock →
  snow). `outline`/`gridlines` overlays optional.
- **Contour tiles only** — only the outermost ring of each step, using an **8-connected** test (a tile
  is drawn if any of its 8 neighbours is lower) so diagonals read as solid L-staircases, not dotted
  `/`.
- **Cliff borders (autotile)** — the `ringCliffs` result: each tile filled with its class colour, then
  the matching `tiles.png` sprite drawn on top (16×16, scaled to the zoom, no smoothing). A legend of
  the 12 names is shown. Zoom up to see sprites.

`tiles.png` layout: 16×16 tiles, **5 per row**, in `TILE_ORDER`
(`east-to-south, north-to-east, west-to-south, north-to-west, east-to-north, south-to-east,
west-to-north, south-to-west, east-to-west, west-to-east, north-to-south, south-to-north`). `TILE_SRC`
maps each name → `(sx,sy)` in the atlas.

---

## 7. Parameters (`readParams`)

| Group | Params |
|---|---|
| Tile grid | `res` (8–256), `zoom` px/tile, `view`, `gridlines`, `outline`, `clean` |
| Steps | `steps` (2–40), `spacing` (linear/ease/easein) |
| Algorithm | `algo`, `freq`, `oct`, `pers`, `lac`, `rough` |
| Single-mountain shaping | `fall`, `rad`, `sharp` |
| Shape variety | `stretch`, `rot`, `edge`, `edgeScale`, `warp`, `warpScale` |
| Seed | `seed` |

UI extras: **Random** (reseed), **Randomize shape** (reseed + reroll variety params), live-update
toggle, **Save PNG**.

---

## 8. Export

- **Export settings** → `mountain-settings-<seed>.json` — the flat `readParams()` object (every
  generator parameter, no tile data). The full recipe to reproduce a map.
- **Export map** → `mountain-map-<seed>-<R>x<R>.json` — only the tile matrices, no settings:

```json
{
  "steps":  [[0,0,1, ...], ...],                  // [y][x] ground elevation level, 0 = base
  "cliffs": [["east-to-south", null, ...], ...]   // [y][x] cliff tile name, or null
}
```

`steps` is the ground layer (place a ground tile per level); `cliffs` is the cliff sprite per tile.

---

## 9. Coordinate & data quick-reference

- Grid is `res × res`; tile `(x,y)` → array index `y*R + x`.
- `stepGrid` / `steps`: `Int16` elevation level, `0` = base, up to `steps`.
- `ringCliffs` returns `Map<index, {name, level}>`; non-cliff tiles are absent (exported as `null`).
- Directions: N `[0,-1]`, E `[1,0]`, S `[0,1]`, W `[-1,0]`.

See `AGENTS.md` for the node test harness and the do-not-break invariants.
