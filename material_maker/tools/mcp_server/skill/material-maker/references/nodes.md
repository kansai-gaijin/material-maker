# Material Maker node catalog (2D PBR authoring)

Type names, ports and parameters below were checked against the live MCP server
(`list_node_types`, `describe_node_type`, `search_library`) and the `.mmg` node
files of Material Maker 1.8. Descriptions are condensed from the official manual.

## Contents

0. [How to read this catalog](#0-how-to-read-this-catalog)
1. [Material (output) nodes](#1-material-output-nodes)
2. [Simple: uniforms, shapes, gradients, 2D SDF](#2-simple-uniforms-shapes-gradients-2d-sdf)
3. [Pattern](#3-pattern)
4. [Noise](#4-noise)
5. [Filter](#5-filter)
   - 5.1 Tones and color · 5.2 Channels and math · 5.3 Blending
   - 5.4 Height to PBR (normal, AO, curvature, edges) · 5.5 Blur and smoothing
   - 5.6 Shape and mask filters · 5.7 Fill (per-cell) nodes · 5.8 Tiling and resampling
6. [Transform](#6-transform)
7. [Workflow](#7-workflow)
8. [Miscellaneous](#8-miscellaneous)
9. [3D nodes (skip for 2D work)](#9-3d-nodes-skip-for-2d-work)
10. [Superseded types](#10-superseded-types)
11. [Picking nodes by goal](#11-picking-nodes-by-goal)

## 0. How to read this catalog

- **Ports** are written `index:name:type`. Outputs are `index:label:type`. Indices
  are 0-based and are what `connect_nodes` / `add_nodes` connections use.
- **Data types**: `f` greyscale, `rgb`, `rgba` (these three convert into each other
  automatically: colour to grey is the channel average), `fill` (per-cell data
  from patterns/Fill, only accepted by Fill companion nodes), `sdf2d` (2D signed
  distance, only for SDF nodes), `any` (reroute, switch, portal).
- **Parameters** are written `name` range (start value). The start value is what
  a freshly added node gets (taken from the node file). In `describe_node_type`
  output, trust the **`value`** field (what a new node actually starts with);
  the `default` field is not always the same (e.g. `bricks3.pattern` lists
  default Flemish Bond but starts at Running Bond). Always set the parameters
  you care about explicitly.
- **`size` parameters** are powers of two: value v = 2^v px (9 = 512, 10 = 1024,
  11 = 2048). Many filters are fixed-resolution because they buffer their input;
  match the resolution you intend to export, and keep it at 9-10 while iterating.
- **Enums** are set by label (`"Herringbone"`) or index. Labels are listed `A|B|C`.
- **`paramN` names**: group-based nodes (Normal Map, Occlusion, blurs, ...)
  expose generic names like `param0`; `describe_node_type` resolves their real
  type, range, enum labels and label (e.g. Normal Map `param2` = Algorithm,
  Sobel|Scharr|Simple|Cheap), so check it rather than guessing.
- **Library items vs types**: `search_library` paths (e.g. `Pattern/Bricks/Tiles`)
  are presets of a type with tuned parameters. Pass them as `library_item` to
  `add_nodes`. Items of type `graph` (prebuilt groups) can only be added by
  `library_item`. The newest version of a node is the one in the library
  (`bricks3`, `fbm4`, `voronoi2`, `blend2`, `normal_map2`, `occlusion2`); older
  versions still load (section 10).
- Most generators have a **seed**; change it with `randomize_seed`.

## 1. Material (output) nodes

A new material project already contains one `Material` node (type `material`,
"Static PBR Material"); you do not add it. Other material types replace it only
for special cases.

**`material`** - static PBR material; everything is baked to textures at `size`.
- in: 0:albedo_tex:rgb, 1:metallic_tex:f, 2:roughness_tex:f, 3:emission_tex:rgb,
  4:normal_tex:rgb, 5:ao_tex:f, 6:depth_tex:f, 7:opacity_tex:f, 8:sss_tex:f
- params: `albedo_color` colour (white), `metallic` 0-1 (0), `roughness` 0-1 (1),
  `emission_energy` 0-1 (1), `normal` 0-10 (1), `ao` 0-1 (1), `depth_scale` 0-1
  (0.5), `flags_transparent` bool, `sss` 0-1, `size` (export resolution, 2^v).
- The scalar parameters multiply the connected maps in engine materials, but are
  not baked into exported images. Keep multipliers at 1 and put real values in
  the graph.
- `depth_tex` is **depth, not height**: white = deepest. Feed an inverted height
  (`invert`, or `colorize` white-to-black). `mwf_output`'s Depth output is already
  inverted. Exports write `1 - depth` as the height/displacement map.
- `normal_tex` expects MM's internal normal format, which is what `normal_map2`
  and `mwf_output` produce. Convert foreign normal maps with `normal_map_convert`.

Other material types (same input names unless noted): `material_tesselated`
(static, previews depth as real displacement), `material_dynamic` (maps
generated in the shader: animated or resolution independent, no `size`),
`material_unlit` (one `color_tex:rgba` input, `blend` Add|Mix|Mul|Sub),
`material_3d` (tex3d inputs), `material_raymarching`, `material_dynamic_sky`.

## 2. Simple: uniforms, shapes, gradients, 2D SDF

| type | library item | purpose | in | out | key params |
|---|---|---|---|---|---|
| `uniform` | Simple/Uniform | flat colour | - | 0:Output:rgba | `color` |
| `uniform_greyscale` | Simple/Uniform/Grayscale | flat grey value | - | 0:Output:f | `color` 0-1 (0.5) |
| `shape` | Simple/Shape (+ /Square /Circle /Star /Curved Star /Rays) | white shape on black | 0:radius_map:f, 1:edge_map:f | 0:Output:f | `shape` Circle\|Polygon\|Star\|Curved Star\|Rays (Polygon), `sides` 2-32 (6), `radius` 0-1 (0.85), `edge` 0-1 soft falloff (0.1) |
| `gradient` | Simple/Gradient | linear gradient | - | 0:Output:rgba | `gradient`, `rotate` -180..180, `repeat` 1-32, `mirror` |
| `radial_gradient` | Simple/Gradient/Radial | centre-out gradient | - | 0:Output:rgba | `gradient`, `repeat`, `mirror` |
| `circular_gradient` | Simple/Gradient/Circular | angular sweep | - | 0:Repeat:rgba | `gradient`, `repeat`, `mirror` |
| `spiral_gradient` | Simple/Gradient/Spiral | spiral sweep | - | 0:Gradient:rgba | `amount` 0-20, `perspective` |
| `image` | Simple/Image | load an image file | - | 0:rgba | `image` (file path), `clamp`, `filter`, `fix_ar` |
| `text` | Simple/Text | text as image | - | 0:rgba | `text`, `font`, `font_size` 0-128 (32), `fg`, `bg`, `x`, `y`, `center` |
| `curve` | Simple/Curve | input mapped along a quadratic Bezier | 0:in:rgba | 0:Output:rgba | `ax..cy` control points, `width` 0-0.5 (0.05), `repeat` |
| `polycurve` | Simple/Poly Curve | input mapped along a multi-point curve | 0:in:rgba, 1:width_map:f | 0:Output:rgba | `curve` (polyline), `width`, `repeat` (10), `ends` |
| `profile` | Simple/Profile | draws a gradient as a profile curve | 0:in:f | 0:Output:f | `style` Curve\|Fill, `gradient`, `width` |
| `splines` | Simple/Splines | draws editable splines | 0:in_edge, 1:in_fill, 2:in_guide (rgba) | 0:Output:rgba | `splines` (edit in UI) |
| `pixels` / `pixels_smooth` | Simple/Pixels | tiny hand-drawn pixel image | - | 0:Output:rgba | `pixels` (edit in UI) |

Decorative generators (all `f` out): `seven_segment2`, `sixteen_segment`,
`roman_numerals3`, `japanese_glyphs2`. `sdf` (Simple/Easy SDF) is built in an
editor window and exposes no ports over `describe_node_type`; avoid it over MCP.

**`shape`** - Typical use: a stamp for `tiler`/`splatter` (pebbles, rivets,
studs), a vignette mask, or Polygon with `sides` 4 as a soft square. `edge`
controls the bevel falloff; edge 0 gives a hard mask, 0.3+ a dome.

**`gradient`** - Typical use: directional masks (rust running down, dirt at the
bottom of a wall), stripes with `repeat`, or as an input for `colorize`-style
lookups. Gradients are set as `[{pos, color}]` stops.

### 2D SDF basics

SDF shapes output a distance field (`sdf2d`); combine them with operators, then
turn them into an image with `sdshow`. Coordinates are centred: -0.5..0.5.

- Render: **`sdshow`** (Simple/SDF/sdShow) in 0:in:sdf2d, out 0:Output:f;
  `bevel` 0-1 (0.1) width of the soft edge, `base` 0-1 background value.
  `sdshow2` (sdShow/FixDist) is the same with corrected distances.
- Shapes (no inputs, out 0:Output:sdf2d; most have `cx`, `cy`): `sdcircle` (`r`),
  `sdbox` (`w`, `h`), `sdroundedbox` (`width`, `height`, four corner radii),
  `sdellipse`, `sdline2` (Simple/SDF/Shapes/sdLine: `ax ay bx by`, `r` thickness;
  in 0:profile:f), `sdngon` (`n` 3-12, `r`, `rot`), `sdstar` (`n`, `r`, `ir`),
  `sdstar5`, `sdpolygon` (`polygon` points), `sdtriangle`,
  `sdequilateraltriangle`, `sdisoscelestriangle`, `sdrhombus`,
  `sdparallelogram`, `sdtrapezoid`, `sdarc`, `sdpie`, `sdcross`,
  `sdroundedcross`, `sdroundedx`, `sdheart`, `sdmoon`, `sdegg`, `sdvesica`,
  `sdhexagram`, `sdcutdisk`, `sdunevencapsule`, `sdarrow`, `sdkite`,
  `sdtunnel`, `sdstairs`.
- Operators: `sdboolean_v` (in 0:b, 1:s1; `op1` Union|Subtraction|Intersection),
  `sdsmoothboolean_v` (same plus `k1` 0-1 smoothness, 0.15), `sdroundedshape`
  (`r` grows/rounds), `sdannularshape` (`r` ring width, `ripples`), `sdmorph`
  (in1, in2, `amount`), `sdrepeat` (`rx`, `ry` 1-32 grid, `r` random rotation,
  `variations`), `sdcirclerepeat` (`c` count).
- Transforms: `sdtranslate` (`x`, `y`), `sdrotate` (`a` degrees), `sdscale`
  (`s`), `sdscalexy` (`sx`, `sy`).
- `sd_mask_to_sdf` (Operators/Mask to SDF): greyscale mask to sdf2d (jump flood);
  `param0` size (10), `param1` iterations (30), `param2` tiled, `param3`
  Euclidean|Manhattan|Chebyshev.
- Typical use: custom tile outlines for `custom_tiles`, logos/insets, rivet heads
  (`sdcircle` -> `sdshow` with high `bevel`).

## 3. Pattern

Repeating structural patterns, all tileable. Brick-style nodes output a height-like
`f` (0 in the mortar, rising over `bevel` to 1 on the brick top) plus `fill`
outputs that carry per-brick data for the Fill companion nodes (section 5.7).

**`bricks3`** - Pattern/Bricks; presets Pattern/Bricks/Tiles, /Basket Weave,
/Herringbone, /Spanish Bond.
- in: 0:mortar_map:f, 1:bevel_map:f, 2:round_map:f (optional per-pixel overrides)
- out: 0:Bricks pattern:f, 1:Brick Fill:fill, 2:Corner Fill:fill
- params: `pattern` Running Bond|English Bond|Flemish Bond|Herringbone|Basket
  Weave|Spanish Bond (Running Bond); `rows` 1-64 (6); `columns` 1-64 (3);
  `row_offset` 0-1 (0.5; 0 = stacked grid); `mortar` 0-0.5 (0.1; 0.02-0.05 for
  tight joints); `bevel` 0-0.5 (0.1); `round` 0-0.5 corner radius; `repeat` 1-8.
- Typical use: out 0 is the base height of walls, pavers and floor tiles. Out 1 ->
  `fill_to_random_grey2` for per-brick height/colour variation, -> `fill_to_uv2`
  to texture each brick individually, -> `fill_to_random_color3` for an ID map.
  Feed a noise into `mortar_map`/`bevel_map` for irregular, worn edges.

| type | library item | purpose | out | key params |
|---|---|---|---|---|
| `bricks_uneven2_2` | Pattern/Uneven Bricks | recursive random split (flagstones, ashlar) | 0:Bricks pattern:f, 1:Brick Fill:fill, 2:Corner Fill:fill | `iterations` 1-16 (8), `min_size` 0-0.5 (0.3), `randomness` 0-1, `mortar` (0.1), `bevel` (0.1), `round` |
| `bricks_uneven3_2` | Pattern/Uneven Bricks 2 | rows of random-length bricks (stone walls, planks) | same | `rows` 1-64 (6), `iterations` 0-16, `min_size`, `mortar`, `bevel`, `round` |
| `bricks_uneven4` | Pattern/Uneven Bricks 3 | uneven grid, other algorithm | same | `x`, `y` 2-32 (6), `randomness`, `mortar`, `bevel`, `round` |
| `skewed_bricks` | Pattern/Skewed Bricks | running bond with slanted joints | 0:Bricks Pattern:f, 1:Skewed Bricks UV:rgb, 2:Skewed Corner UV:rgb, 3:Brick Fill:fill, 4:Corner Fill:fill | `rows`, `columns`, `offset`, `randomness`, `mortar`, `bevel` |
| `skewed_uneven_bricks` | Pattern/Skewed Uneven Bricks | uneven bricks with random slanted cuts | same as skewed_bricks | `rows`, `columns` (6), `randomness`, `mortar`, `bevel` |
| `arc_pavement` | Pattern/Arc Pavement | fan/arc cobblestone layout | 0:Bricks pattern:f, 1:Random color:rgb, 2:Brick UV:rgb | `repeat` 1-4 (2), `rows` 4-16 (12), `bricks` 4-16 (8), `mortar` (0.05), `bevel` (0.2) |
| `custom_tiles` | Pattern/Custom Tiles | tiles whose outline comes from an SDF | 0:Tiles pattern:f, 1:Tiles Fill:fill | in 0:shape:sdf2d, 1:mortar_map, 2:bevel_map; `rows` (10), `columns` (7), `row_offset`, `mirror`, `mortar`, `bevel` |
| `beehive2` | Pattern/Beehive | hexagon tiles | 0:Output:f, 1:Fill:fill | `sx`, `sy` 1-64 (4) |
| `cairo` | Pattern/Cairo | Cairo pentagon tiling | 0:Output:f, 1:Fill:fill | `sx`, `sy` (4), `angle` 0-90 (30), `round` (0.5) |
| `weave2` | Pattern/Weave | basket/cloth weave height | 0:Output:f, 1:Horizontal mask:f, 2:Vertical mask:f | in 0:width_map:f; `columns`, `rows` 2-32 (4), `width_x`, `width_y` 0-1 (0.9), `stitch` 0-10 (1) |
| `weave_random` | Pattern/Random Weave | weave with random stitch lengths | same as weave2 | `scale_x`, `scale_y`, `width_x`, `width_y`, `stitch` (2), `random` |
| `diagonal_weave` | Pattern/Diagonal Weave | interlaced diagonal pipes | 0:Output:f | `size` 2-64 (4) |
| `mesh` | Pattern/Mesh | wire mesh / chain-link | 0:Pattern:f, 1:Horizontal Mask:f, 2:Vertical Mask:f | in 0:in:f custom shape; `shape` Shape 1\|Shape 2\|Input, `tiling` 1-16 (2), `diagonal` |
| `truchet` | Pattern/Truchet | random arcs/lines maze | 0:Output:f | `shape` Line\|Circle, `size` 2-64 |
| `pattern` | Pattern/Generic (+ /Checkerboard) | combines X and Y waveforms | 0:Output:f | `x_wave`, `y_wave` Sine\|Triangle\|Square\|Sawtooth\|Constant\|Bounce, `x_scale`, `y_scale` 0-32 (4), `mix` Multiply\|Add\|Max\|Min\|Xor\|Pow |
| `sine_wave` | Pattern/Sine Wave | a sine line | 0:Output:f | `amplitude` (0.25), `frequency` 0-16 (4), `phase` |
| `scratches2` | Pattern/Scratches | white scratches on black | 0:Output:f | see below |
| `runes` / `iching` | Pattern/Runes, Pattern/Runes/I Ching | grid of glyphs | 0:Output:f | `columns`, `rows` 2-32 (4) |

Prebuilt group: **Pattern/Fibers** (`graph`, `library_item` only): out 0:rgba
fibres; one parameter `param0` "Repeat". Good base for brushed or fibrous detail.

**`scratches2`** - params: `length` 0.1-1 (0.25; shorter = more scratches),
`width` 0.1-1 (0.4), `layers` 1-10 (5), `waviness` 0-1 (0.3), `angle` -180..180
(0 = horizontal), `randomness` 0-1 angle spread (0.3). Typical use: multiply
into roughness (lighter scratches on metal), subtract a little from height, or
mask a brighter albedo on painted metal.

**`weave2`** - Typical use: fabric height. Horizontal/Vertical masks let you
colour warp and weft threads differently; add `fbm4` fibre noise and
`directional_blur2` for thread texture.

**`beehive2` / `voronoi2` Fill outputs** - per-cell data, exactly like Brick Fill.

## 4. Noise

All tileable. Scale parameters are integer cell counts across the texture.

**`fbm4`** - Noise/FBM. Octaves of a base noise; the workhorse for organic detail.
- in: 0:offset_in:f (optional, drives `offset`) / out: 0:Output:f
- params: `noise` Value|Perlin|Simplex|Cellular|Cellular 2 ... Cellular 8|Voronoise|Gabor
  (a new node starts on Cellular 7; the library item on Value: always set it);
  `scale_x`, `scale_y` 1-32 (2); `iterations` 1-10 octaves (5); `persistence`
  0-1 (0.5; lower = smoother); `lacunarity` 1-8 (2); `folds` 0-5 (0; 1-2 gives
  ridged, veiny noise); `offset` 0-1 (animate with `$time`).
- Typical use: Perlin/Simplex for grime, cloud-like variation and roughness
  breakup; Cellular types for cracked/cellular stone; folds 1-2 for marble veins
  and ridges. Scale 4-16 for mid detail, 16-32 for fine grain.

**`voronoi2`** - Noise/Voronoi. Cellular noise with several outputs.
- out: 0:Nodes:f (distance to cell centre, domes), 1:Borders:f (cell edges, dark at
  borders), 2:Fill:fill (per-cell data)
- params: `scale_x`, `scale_y` 1-32 (4); `stretch_x`, `stretch_y` 0.01-1;
  `intensity` 0-1 (1); `randomness` 0-1 (0.85; 0 = regular grid).
- Typical use: cobblestones and pebbles (Borders -> `tones_map`/`colorize` as
  height, Fill -> `fill_to_random_grey2` for per-stone height), cracked mud,
  scales, cell-based colour variation.

**`perlin`** - Noise/Value. Value noise octaves. out 0:Output:f. `scale_x`,
`scale_y` 1-32 (4), `iterations` 1-10 (3), `persistence` 0-1 (0.5). Colour
version `perlin_color` (Noise/Value/Color, out rgb). Typical use: soft
large-scale variation masks, cheap colour variation.

| type | library item | purpose | out | key params |
|---|---|---|---|---|
| `noise2` | Noise | blocky random squares | 0:Output:f | in 0:density_in:f; `size` 2-12 grid (4), `density` 0-1 (0.5) |
| `color_noise` | Noise/Color | random-colour squares | 0:Output:rgb | `size` (9) |
| `noise_white` | Noise/White | per-pixel white noise | 0:Output:f | `size` (11) |
| `voronoi_triangle` | Noise/Triangle Voronoi | triangulated cells | 0:Nodes:f, 1:Border:f, 2:Random color:rgb, 3:UV Map:rgb, 4:Normal Map:rgb | `scale_x`, `scale_y`, `stretch_x/y`, `randomness` (0.85) |
| `shard_fbm` | Noise/Shard FBM | sharp faceted fbm (rock, crystal) | 0:Output:f | in 0:sharp_in, 1:offset_in; `sharp` 0-1 (0.7), `sx`, `sy` 1-32 (7), `folds`, `iter` 1-8 (4), `per`, `off` |
| `noise_anisotropic` | Noise/Anisotropic | streaky noise stretched along X | 0:Output:f | `scale_x` 1-32 (4), `scale_y` 1-1024 (256), `smoothness`, `interpolation` |
| `wavelet_noise2` | Noise/Wavelet | band-limited noise | 0:Output:f | `type` Add 1\|Add 2\|Add 3\|Mult 2\|Mult 3, `scale_x/y`, `iterations`, `persistence`, `frequency` 0-2 (2), `offset` |
| `crystal` | Noise/Composite/Crystal | crystal facets from voronoi | 0:Output:f | `param0`, `param1` scale X/Y 1-32 (16) |
| `dirt` | Noise/Composite/Dirt | ready-made dirt/grime noise | 0:port0:f | `param0` Dirt 1\|Dirt 2\|Dirt 3, `d_scale` 1-8 (1), `param1` resolution size (11) |
| `clouds_noise2` | Noise/Composite/Clouds Noise | soft cloudy noise | 0:Output:f | `param1` Clouds 1\|2\|3, `n_scale` 1-8, `param0` resolution (11) |
| `directional_noise` | Noise/Composite/Directional Noise | streaks (brushed metal, wood grain, rain) | 0:port0:f | `param0` Noise 1\|2\|3, `n_scale` 1-8, `param1` resolution (11) |

Prebuilt groups: **Noise/Value/Warp 1** and **Noise/Value/Warp 2** (`graph`,
out 0:rgba): domain-warped value noise, params `param0`/`param1` scale X/Y,
`param2` iterations, `param3` persistence, `param4`/`param5` warp X/Y. Good for
marble, smoke, flowing patterns.

`noise_anisotropic` typical use: wood grain (scale_y high), brushed metal; rotate
with `transform2` for other directions.

## 5. Filter

### 5.1 Tones and color

**`colorize`** - Filter/Colorize (+ /Invert, /Rainbow presets). Greyscale to
colour through a gradient. in 0:input:f / out 0:Output:rgba. `gradient` as
`[{pos, color}]`. Typical use: the main way to make albedo from height or masks
(dark crevice colour at 0, top colour at 1), and to make roughness maps with a
grey gradient. A white-to-black gradient inverts (Filter/Colorize/Invert).

**`tones_map`** - Filter/Tones/Map. Linear remap: `in_min`, `in_max` -> `out_min`,
`out_max` (all 0-1; start 0, 1, 0, 1). in 0:in1:rgba / out 0:Output1:rgba.
Typical use: compress a height into a narrow band (out 0.4-0.6 for subtle
detail), raise contrast (in 0.3-0.7 -> 0-1), or set roughness ranges.

**`tones`** - Filter/Tones, label "Levels". in 0:input:rgba / out 0:rgba.
Colour params `in_min`, `in_mid`, `in_max`, `out_min`, `out_max` (per channel,
RGBA). Behaves like Photoshop Levels; for greyscale use equal R=G=B values.
Typical use: contrast/gamma adjustment of masks.

| type | library item | purpose | in / out | key params |
|---|---|---|---|---|
| `invert` | Filter/Invert | 1 - RGB, alpha kept | 0:in:rgba / 0:Output:rgba | - |
| `brightness_contrast` | Filter/BrightnessContrast | brightness/contrast | rgba / rgba | `brightness` -1..1 (0), `contrast` 0-2 (1) |
| `adjust_hsv` | Filter/Adjust HSV | hue/sat/value shift | rgba / rgba | `hue` -0.5..0.5, `saturation` 0-2, `value` 0-2 |
| `alter_hsv` | Filter/Alter HSV | HSV shift driven by maps | 0:in:rgba, 1:hmap, 2:vmap, 3:smap (f) / rgba | `all` (0.2), `hue`, `value`, `saturation` 0-1 (0.1) |
| `tones_step` | Filter/Tones/Step | threshold around a value | 0:in:rgba / rgba | `value` 0-1 (0.5), `width` 0-1 softness (0.1), `invert` |
| `tones_range` | Filter/Tones/Range | isolate a band of tones | 0:in:f / f | `value` (0.5), `width` (0.25), `contrast` (0.5), `invert` |
| `auto_tones` | Filter/Tones/Auto Tones | stretch to full 0-1 | 0:in:f / f | `size` (11) |
| `tonality` | Filter/Tonality | remap through a curve | 0:input1:f / f | `curve` (serialized curve) |
| `greyscale` | Filter/Grayscale | colour to grey | 0:in:rgb / f | `mode` Lightness\|Average\|Luminosity\|Min\|Max (Luminosity) |
| `colormap` | Filter/Colormap | grey picks colours from a row/column of an image | 0:input:f, 1:colormap:rgba / rgba | `direction` Horizontal\|Vertical, `offset` |
| `quantize` | Filter/Quantize | posterize | rgba / rgba | `steps` 2-32 (4) |
| `palettize` | Filter/Palettize | map to a palette image | 0:in:rgb, 1:palette:rgb / rgb | `size` 0-32 |
| `color_pick` | Filter/Color Pick | mask from an ID colour | 0:in:rgb / 0:Output 1:f | `color1`, `threshold`, `falloff` |
| `color_conversion` | Filter/Color Conversion | linear <-> sRGB | rgba / rgba | `mode` Linear to sRGB\|sRGB to Linear |

`tones_step` typical use: turn a noise into a hard-edged mask (puddles, paint
chips, moss patches); `width` 0.02-0.1 for crisp edges.

### 5.2 Channels and math

**`math`** - Filter/Math. in 0:in1:f (A), 1:in2:f (B) / out 0:Output:f.
- `op`: A+B|A-B|A*B|A/B|log(A)|log2(A)|pow(A, B)|abs(A)|round(A)|floor(A)|ceil(A)|
  trunc(A)|fract(A)|min(A, B)|max(A, B)|A<B|cos(A*B)|sin(A*B)|tan(A*B)|sqrt(1-A²)|
  smoothstep(0.0, 1.0, A)|ping-pong(A, B)|sign(A)|mod(A, B)|atan2(A, B)|asin(A)|
  acos(A)|atan(A)|sinh(A)|cosh(A)|tanh(A)|exp(A)|snap(A, B)|radians(A)|degrees(A)|
  log(A, B)|sqrt(A). `default_in1`, `default_in2` 0-1 (used when the port is not
  connected), `clamp` bool.
- Typical use: combine heights (max for stacking shapes, A*B to mask, A-B to
  carve scratches), scale a map by a constant (A*B with `default_in2`), pow for
  contrast. Turn `clamp` on when the result feeds a mask.

| type | library item | purpose | in / out | key params |
|---|---|---|---|---|
| `math_v3` | Filter/Math/Vec3 | vector math on RGB | 0:in1:rgb, 1:in2:rgb / rgb | `op` (adds length, distance, dot, cross, normalize, rotate), `d_in1_x..d_in2_z`, `clamp` |
| `smooth_minmax` | Filter/Math/Smooth MinMax | min/max with a smooth blend | 0:in1:f, 1:in2:f / f | `op` Min\|Max (Min), `k` 0-1 smoothness, `default_in1/2`, `clamp` |
| `combine` | Filter/Combine | 4 greys -> RGBA | 0:r, 1:g, 2:b, 3:a (f) / rgba | - |
| `decompose` | Filter/Decompose | RGBA -> 4 greys | 0:i:rgba / 0:Red, 1:Green, 2:Blue, 3:Alpha (f) | - |
| `swap_channels` | Filter/Swap Channels | reorder/negate channels | rgba / rgba | `out_r`, `out_g`, `out_b`, `out_a` 0\|1\|R\|-R\|G\|-G\|B\|-B\|A\|-A |
| `set_alpha` | Filter/Set Alpha | set alpha from a grey map | 0:in:rgba, 1:a:f / rgba | - |

`smooth_minmax` typical use: merge two height shapes without a hard crease
(`k` 0.05-0.2).

### 5.3 Blending

**`blend2`** - Filter/Blend. Layer compositing with a mask.
- in: 0:b:rgba (background), 1:l1:rgba (layer), 2:a1:f (mask; unconnected = full)
  / out: 0:Output:rgba
- params: `blend_type1` Normal|Dissolve|Multiply|Screen|Overlay|Hard Light|Soft
  Light|Burn|Dodge|Lighten|Darken|Difference|Additive|AddSub|Linear Light|Vivid
  Light|Pin Light|Hard Mix|Exclusion|Hue|Saturation|Color|Value (Normal);
  `amount1` 0-1 opacity (0.5).
- The node is variadic in the editor (more layer/mask pairs can be added); over
  MCP check the ports with `get_node`.
- Typical use: put dirt/rust/moss colour over albedo with Normal + mask; add
  fine noise into height with Overlay or Multiply at amount 0.2-0.4; combine
  roughness layers with Lighten/Darken. Works on greyscale too.

**`normal_blend2`** - Filter/Normal Map/Blend. Combines two normal maps properly
(do not use `blend2` for normals). in 0:b:rgb (base), 1:l1:rgb (detail), 2:a1:f
mask / out 0:rgb. `amount1` 0-1 (0.5). Typical use: add a detail normal on top
of the main one.

### 5.4 Height to PBR (normal, AO, curvature, edges)

**`normal_map2`** - Filter/Normal Map. Height -> normal map in MM's format.
- in 0:Bump:f / out 0:Output:rgb
- params: `param2` algorithm Sobel|Scharr|Simple|Cheap (Sobel); `size` 4-12
  resolution (10); `strength` 0-2 (1); `buffer` bool (on).
- Typical use: final height -> `normal_map2` -> Material input 4. Strength 0.5-1
  for stone/brick, 1-2 for fine detail; keep `size` equal to the export size.

**`occlusion2`** - Filter/Occlusion. Height -> ambient occlusion (blur based).
- in 0:port0:f / out 0:Output:f
- params: `param0` resolution size (11); `param1` radius 1-256 (20); `param2`
  strength 0-2 (1.5); `param3` quality 0-3 (1).
- Typical use: height -> AO -> Material input 5; also as a crevice mask (invert it,
  or use it directly as a darkening mask in `blend2`).

**`smooth_curvature2`** - Filter/Smooth Curvature 2. Height -> curvature: 0.5
flat, brighter = convex edges, darker = cavities.
- in 0:Heightmap:f / out 0:Output:f
- params: `param0` size (10); `param1` quality 2-16 (4); `param2` strength 0-2
  (1); `param3` radius 0-2 (1); `param4` buffer.
- Typical use: edge-wear mask (`tones_step` above 0.55 on the output) and
  cavity-dirt mask (`tones_step` below 0.45, inverted). The older
  `smooth_curvature` (Filter/Smooth Curvature: in f, out rgba; `param0` size
  (12), `param2` intensity 0-2) does the same.

**`edge_detect`** - Filter/Edge Detect. White lines where the input changes.
in 0:in:rgb / out 0:Output:f. `size` resolution (9), `width` 1-5 (2),
`threshold` 0-1 (0.4). Variants: `edge_detect_1` (Simple), `edge_detect_2`
(Axis Aligned), `edge_detect_3` (Diagonal), each with only `size`. Typical use:
outline masks from an ID map or a stepped height (wear along brick borders,
seams).

| type | library item | purpose | in / out | key params |
|---|---|---|---|---|
| `hbao` | Filter/HBAO | horizon-based AO (crisper than occlusion2) | 0:input:f / 0:AO:f | `param0` size (10), `param1` radius 0-1 (0.1), `param2` angle bias 0-90 (15), `param3` depth scale 0-1 (0.08), `param4` quality 1-12 (4), `param5` intensity 0-5 (1) |
| `emboss2` | Filter/Emboss | directional light/shadow from height | 0:port0:f / f | `param0` size 6-12 (9), `param1` angle, `param2` amount 0-10 (5), `param3` width 1-5 |
| `normal_map_convert` | Filter/Normal Map/Convert | MM <-> OpenGL/DirectX normal | 0:in:rgb / rgb | `op` From/To OpenGL\|From/To DirectX |
| `normal2height` | Filter/Normal to Height | normal (MM format) -> height | 0:normal:rgb / 0:Height:f | `param2` size (10), `param1` base height (0.5), `param0` strength 0-50 (25) |
| `normal2height_simple` | Filter/Normal to Height/Simple | faster approximation | 0:nm:rgb / f | `size` (10), `center_height`, `scale` 0-50 (25) |

### 5.5 Blur and smoothing

**`gaussian_blur`** - Filter/Blur. in 0:input:rgba, 1:amount:f (optional
per-pixel strength) / out 0:Output:rgba. `param0` grid size 4-12 (11), `param1`
sigma 0-50 (4.8), `param2` Both|X|Y, `param3` 32-bit. `gaussian_blur_hq`
(Filter/Blur/HQ) is the higher quality version. Typical use: soften masks before
thresholding, smooth a height before normal_map2 to avoid noise.

**`slope_blur2`** - Filter/Blur/Slope. Blurs its input along the slopes of a
height map, giving flowing, eroded, melted looks.
- in 0:in:rgba (image to smear), 1:heightmap:f (direction source) / out 0:rgba
- params: `param0` grid size 4-12 (9), `param1` sigma 0-50 (20), `param2` 32-bit.
- Typical use: erode stone edges (feed the height into both inputs, or a noise
  as heightmap), rust streaks, water stains, organic rock surfaces.

| type | library item | purpose | in / out | key params |
|---|---|---|---|---|
| `fast_blur` | Filter/Blur/Fast | approximate blur, also high pass and sharpen | 0:input:rgba / 0:Blurred, 1:High Pass, 2:Sharpened (rgba) | `param0` resolution (11), `param1` sigma 1-256 (100), `param2` quality 0-3, `param3` strength 0-10 |
| `directional_blur2` | Filter/Blur/Directional | motion blur along an angle | 0:in:rgba, 1:amount:f / rgba | `param0` size (9), `param1` sigma 0-50 (50), `param2` angle -180..180 (45), `param3` Both\|Single, `param4` 32-bit |
| `denoiser` | Filter/Denoiser | edge-preserving denoise | 0:Input:rgba / rgba | `param0` size (10), `param1` sigma, `param2` kSigma, `param3` sharpening (0.7) |
| `sharpen` | Filter/Sharpen | sharpen | 0:in:rgb / rgb | `size` (6) |
| `binary_smooth` | Filter/Binary Smooth | smooth jagged mask outlines | 0:Height:f / f | `size` (10), `smooth` 1-256 (60), `offset` 0-1 (0.5), `bevel` 0-1 |
| `classic_kuwahara`, `generalized_kuwahara`, `anisotropic_kuwahara`, `symmetric_nearest_neighbor` | Filter/... | painterly edge-preserving smoothing | rgb / rgb | resolution, size |

`directional_blur2` typical use: brushed metal and wood grain from white noise,
rain streaks.

### 5.6 Shape and mask filters

| type | library item | purpose | in / out | key params |
|---|---|---|---|---|
| `bevel` | Filter/Bevel | bevel a mask into a height with a curve profile | 0:port0:f / f | `size` (10), `distance` 0-1 (0.1), `bevel` curve |
| `dilate` | Filter/Dilate | grow white areas (optionally carrying colours) | 0:mask:f, 1:source:rgb / rgb | `param0` size (10), `param1` length 0-1 (0.27), `param2` fill 0-1 (0 = fade to black, 1 = source colour), `param3` Euclidian\|Manhattan\|Chebyshev, `param4` tile |
| `morphology3` | Transform/Morphology | dilate or erode | 0:Input:rgb / rgba | `operation` Dilation\|Erosion, `resolution` 6-12 (10), `distance` 0-0.3 (0.05) |
| `slope` | Transform/Slope | build slopes down from high areas | 0:mask:f / f | `size` (11), `length` 0-1 (0.2), `slope` 0-1 (1 = 45 degrees) |

`bevel` typical use: turn a hard mask (text, shapes, decals) into a rounded
height. `dilate` typical use: padding colours beyond UV islands, thickening masks.

### 5.7 Fill (per-cell) nodes

Patterns with a `fill` output (`bricks3` and the uneven/skewed bricks,
`voronoi2`, `beehive2`, `cairo`, `custom_tiles`) feed these directly. For any
other black/white outline image, first run **`fill2`** (Filter/Fill: in
0:port0:f outlines, out 0:Output:fill; `size` (8, raise to 10 for detail),
`remove_edges`, `adjust` 0-0.2). `fill_from_colors` (rgba ID map -> fill) and
`rgba_to_fill` (Filter/Fill/From RGBA) are other sources.

| type | library item | output | key params |
|---|---|---|---|
| `fill_to_random_grey2` | Filter/Fill/To Random Gray | 0:Output:f, one random grey per cell | `edgecolor` 0-1 (1) |
| `fill_to_random_color3` | Filter/Fill/To Random Color | 0:Output:rgb, random colour per cell (ID map) | `edgecolor` |
| `fill_to_color2` | Filter/Fill/To Color | 0:Output:rgba, each cell takes the colour of map input 1 at its centre | in 1:map:rgba; `edgecolor` |
| `fill_to_uv2` | Filter/Fill/To UV | 0:Output:rgb, a UV map per cell (for `custom_uv2`) | `mode` Stretch\|Square |
| `fill_to_gradient2` | Filter/Fill/To Gradient | 0:Output:rgba, a gradient across each cell | `grad`, `mode`, `layers`, `rotate`, `r_rotate` (180), `r_offset` |
| `fill_to_position2` | Filter/Fill/To Position | 0:Output:f, value from cell position | `axis` X\|Y\|Radial |
| `fill_to_size2` | Filter/Fill/To Size | 0:Output:f, value from cell size | `formula` Area\|Width\|Height\|max(W, H) |
| `fill_to_orientation2` | Filter/Fill/To Orientation | 0:Output:f, white = horizontal cell | `invert` |
| `fill_select` | Filter/Fill/Select | 0:Mask:f, the single cell under a point | `x`, `y` -0.5..0.5 |
| `fill_to_rgba` | Filter/Fill/To RGBA | 0:Output:rgba, raw fill data | - |

All take in 0:in:fill. Typical use of `fill_to_random_grey2`: multiply into the
brick height for uneven bricks, drive `tones_map` -> `colorize` for per-brick
colour, or mask-select a few bricks (`tones_step`) to recolour or chip.
`fill_to_uv2` -> `custom_uv2` puts a texture (wood grain, stone noise) inside
each tile independently with random rotation.

### 5.8 Tiling and resampling

| type | library item | purpose | in / out | key params |
|---|---|---|---|---|
| `make_tileable` | Filter/Make Tileable | hide seams of a non-tiling input (photos) | rgba / rgba | `w` 0-0.25 (0.1) |
| `make_tileable_square` | Filter/Make Tileable Square | same, square blending | rgba / rgba | `fw` 0-1 (0.1) |
| `pixelize` | Filter/Pixelize | pixel-art downsample + dither | 0:i:rgb / rgb | `x`, `y` 1-256 (16), `c` colours 2-32 (8), `d` dither, `t` Random\|Bayer 2x2\|4x4\|8x8\|16x16 |
| `supersample` | Filter/Supersample | resolve sub-pixel detail | rgba / rgba | `size` (9), `count` 2-5, `width` |

## 6. Transform

UV-space operations. Most take 0:i1 or 0:in1 (rgba) and output 0:Output1:rgba.

**`transform2`** - Transform. Translate, rotate and scale, optionally per pixel.
- in: 0:i1:rgba, 1:tx:f, 2:ty:f, 3:r:f, 4:sx:f, 5:sy:f (maps multiply the
  matching parameters) / out: 0:Output1:rgba
- params: `translate_x`, `translate_y` -1..1; `rotate` -720..720 degrees;
  `scale_x`, `scale_y` 0-50 (1; values > 1 zoom in on the input); `mode`
  Clamp|Repeat|Extend (Clamp; use Repeat to keep a texture tiling).
- Typical use: rotate a noise 90 degrees for vertical grain, offset a layer to
  decorrelate it from another copy, or drive translation with a noise for cheap
  distortion.

**`warp`** - Transform/Warp. Distorts its input along the slopes of a height map.
- in: 0:in1:rgba (source), 1:d:f (height map), 2:strength_map:f / out 0:Output1:rgba
- params: `mode` Slope|Distance to top (Distance to top pulls whole slopes from
  the top value, giving mosaic/stained-glass looks); `amount` 0-1 (0.1); `eps`
  0.005-0.2 (0.1) slope sample distance.
- Typical use: wobble straight patterns (bricks, planks, weave) with a low-scale
  fbm (amount 0.02-0.08) so they look hand-made; marble and wood grain from
  stripes warped by noise.

**`tiler`** - Transform/Tiler. Repeats an input on a grid with random variation.
- in: 0:in:f (stamp), 1:mask:f / out: 0:Output:f, 1:Instance map:rgb (random
  colour per instance), 2:Instance UV:rgb, 3:Instance center:rgb
- params: `tx`, `ty` 1-64 (4); `overlap` 0-5 (2; lowest value that still looks
  right); `inputs` 1|4|16 (atlas from `tile2x2`); `scale_x`, `scale_y` 0-2 (0.5);
  `fixed_offset` 0-1 odd-row offset; `offset` 0-1 random offset (0.25); `rotate`
  0-180 random rotation (45); `scale` 0-1 random scale (0.2); `value` 0-1 random
  brightness (1); `variations` (re-seed the input per instance).
- Typical use: pebbles, studs, rivets, planks, leaves from a `shape` or SDF stamp.
  Instance map -> `greyscale` or straight into colour/roughness for per-instance
  variation. `tiler_color` (Transform/Tiler/Color) does the same for an rgba input
  (out 0:Output:rgba, 1:Instance Map:rgb; `opacity` instead of `value`).

**`splatter`** - Transform/Splatter. Scatters copies at random positions.
in 0:in:f, 1:mask:f / out 0:Output:f, 1:Instance map:rgb, 2:Instance UV:rgb.
`count` 1-100 (25), `inputs` 1|4|16, `scale_x/y` 0-2 (1), `rotate` 0-180,
`scale` 0-1 random, `value` 0-1 random brightness (0), `variations`. Colour
version `splatter_color`. Typical use: debris, leaves, stains, decals that must
not look gridded; use the mask to keep them in crevices or areas.

| type | library item | purpose | in / out | key params |
|---|---|---|---|---|
| `translate` | Transform/Translate | offset | 0:i1:rgba / rgba | `translate_x`, `translate_y` -1..1 |
| `rotate` | Transform/Rotate | rotate around a centre | 0:i1 / rgba | `cx`, `cy`, `rotate` |
| `scale` | Transform/Scale | scale around a centre | 0:i1 / rgba | `cx`, `cy`, `scale_x`, `scale_y` |
| `shear` | Transform/Shear | shear | 0:in1 / rgba | `direction` Horizontal\|Vertical, `amount` -1..1, `center` |
| `mirror` | Transform/Mirror | mirror one half | 0:i1 / rgba | `direction`, `offset`, `flip_sides` |
| `kaleidoscope2` | Transform/Kaleidoscope | radial repeat of a wedge | 0:i1 / rgba | `count` 2-10 (5), `offset`, `variations` |
| `swirl` | Transform/Swirl | twist around a point | 0:i1 / rgba | `cx`, `cy`, `angle` (360), `radius`, `tile` |
| `spherize` | Transform/Spherize | bulge as if on a sphere | 0:in1 / 0:Output1:rgba, 1:Mask:f, 2:Falloff:f | `r`, `a`, `cx`, `cy` |
| `circle_map` / `inverse_circle_map` | Transform/Circle Map, /Inverse Circle Map | wrap into / unwrap from a circle | 0:in1 / rgba | `radius`, `repeat` |
| `directional_warp` | Transform/Directional Warp | push pixels in one direction by a map | 0:in1, 1:anglemap:f, 2:strengthmap:f / rgba | `angle`, `strength` -1..1 (0.1) |
| `multi_warp2` | Transform/Multi Warp | iterative warp, stronger and smoother than warp | 0:in:rgba, 1:heightmap:f / rgba | `param0` grid size (10), `param1` intensity 0-16 (4), `param2` quality 1-50 (15), `param3` Min\|Blur\|Max |
| `warp_dilation3` | Transform/Warp Dilation | smear the brightest values along slopes/contours | 0:input:f, 1:heightmap:f / f | `angle` (0 = along slope, 90 = along contours), `s` resolution 7-12 (10), `d` distance 0-0.5, `a` attenuation 0-1 |
| `custom_uv2` | Transform/Custom UV | sample the input through a UV map | 0:in1:rgba, 1:map:rgb / rgba | `inputs` 1\|4\|16, `sx`, `sy`, `rotate` 0-180 random, `scale` random, `mode` Clamp\|Repeat\|Extend, `variations` |
| `tile2x2` | Transform/Tile 2x2 | pack 4 images into an atlas | 0..3:in1-in4:rgba / rgba | - |
| `tile2x2_variations` | Transform/Tile 2x2/Variations | atlas of 4 seed variations of one input | 0:in:rgba / rgba | - |
| `circle_splatter` (+`_color`) | Transform/Circle Splatter | copies on rings/spirals | 0:in:f, 1:mask:f / f + instance maps | `count` (20), `rings` (2), `radius` (0.4), `spiral`, `i_rotate`, `i_scale` |
| `tiler_advanced` (+`_color`) | Transform/Tiler/Advanced | tiler driven by input maps | 0:in, 1:mask, 2:color1, 3:color2, 4:tr_x, 5:tr_y, 6:r, 7:sc_x, 8:sc_y / 0:Output, 1-2:Instance map 1/2, 3:Instance UV | `tx`, `ty`, `overlap`, `translate_x/y`, `rotate`, `scale_x/y` |
| `remap` | Transform/Tiler/Advanced/Remap | grey -> value range for advanced tiler maps | 0:in:f / f | `min` (-1), `max` (1), `step` (snap) |
| `height_to_angle` | Transform/Tiler/Advanced/Height to Angle | rotate map from slope direction | 0:in:f / f | `angle` offset; set the tiler's `rotate` to 180 |
| `height_to_offset` | Transform/Tiler/Advanced/Height to Offset | translate map that slides instances to a height | 0:in:f / 0:Offset.x:f, 1:Offset.y:f | `target` 0-1 |
| `crop` | Transform/Crop | crop a region | 0:in:rgba / 0:Preview, 1:Cropped image | `x1 y1 x2 y2`, `edge` Alpha\|Repeat\|Continous\|Color |
| `distort` | Transform/Distort | lattice deformation | 0:in:rgba / rgba | `lattice` (edit in UI) |
| `trimsheet` | Transform/Trimsheet | stack two inputs into a trim sheet | 0:in1, 1:in2 / rgba | `size1`, `size2` (0.5), `d` Horizontal\|Vertical |

**`tiler_advanced` + `height_to_angle`** typical use: scales, feathers or roof
shingles that follow a surface: height -> `height_to_angle` -> tiler input 6:r
with `rotate` 180, so every instance points down the slope.

**`warp_dilation3`** typical use: drips and streaks (angle 0), lava/flow lines,
growth that creeps along contours.

## 7. Workflow

The workflow nodes build a material from **flat base materials** placed with
**height maps**, so overlapping layers resolve by height (the higher material
wins) instead of by masks. Channels between them are albedo, ORM (R = AO,
G = roughness, B = metallic), emission and normal.

Chain: height -> `mwf_create_map` -> `mwf_map` (+ a base material) -> `mwf_mix`
(with another applied material) -> `mwf_output` -> Material node.

| type | library item | purpose | in | out | params |
|---|---|---|---|---|---|
| `mwf_create_map` | Workflow/Create Map | pack height, orientation and random offset | 0:h:f height, 1:o:f offset seed | 0:Output:rgb (R height, G angle, B offset) | `height` 0-1 max height (0.5), `angle` -180..180 |
| `mwf_mix_maps` | Workflow/Mix Maps | combine up to 4 maps for one base material | 0..3:in1-in4:rgb | 0:Output:rgb | - |
| `mwf_map` | Workflow/Apply Map | apply a map to a base material | 0:map:rgb, 1:mat1 Albedo, 2:mat2 ORM, 3:mat3 Emission, 4:mat4 Normal (rgb) | 0:Height:f, 1:Albedo, 2:ORM, 3:Emission, 4:Normal (rgb) | - |
| `mwf_mix` | Workflow/Mix | keep the highest of two applied materials | 0:h1:f, 1:c1, 2:orm1, 3:em1, 4:nm1, 5:h2:f, 6:c2, 7:orm2, 8:em2, 9:nm2 | 0:Height:f, 1:Albedo, 2:ORM, 3:Emission, 4:Normal | - |
| `mwf_mix_smooth` | Workflow/Mix/Smooth | same with a soft transition | same as mwf_mix | same | `width` 0-0.2 (0.05) |
| `mwf_output` | Workflow/Output | convert to Material inputs, adds normal and AO from height | 0:Height:f, 1:Albedo, 2:ORM, 3:Emission, 4:Normal | 0:Albedo:rgb, 1:Metallic:f, 2:Roughness:f, 3:Emission:rgb, 4:Normal:rgb, 5:Occlusion:f, 6:Depth:f | `param2` occlusion strength 0-2 (1), `param0` base-material normal strength 0-1 (1) |

Base materials (prebuilt groups, `library_item` only, no inputs, out 0:Albedo,
1:ORM, 2:Emission, 3:Normal, all rgb):
- **Workflow/Materials/Template**: `param0` Albedo, `param1` Roughness,
  `param2` Metallic, `param3` Emission. The plain flat material.
- **Workflow/Materials/Metal**: `param0` Aluminum|Chromium|Cobalt|Copper|Gold|Iron|
  Nickel|Platinum|Silver|Titanium, `param1` Roughness.
- **Workflow/Materials/Wood**: `param0` Color, `param1` Waviness, `param2` Scratches.
- **Workflow/Materials/Marble**: `param0` Color 1, `param1` Color 2, `param2` Scratches.

Effects (groups between Apply Map/Mix and Output; in 0:Height, 1:Albedo, 2:ORM,
3:Emission, 4:Normal, 5:Mask; same five outputs): **Workflow/Effects/Paint 1**
(mask f; `param0` Color, `param1` Roughness, `param2` Metallic) and **Paint 2**
(mask rgba). **Workflow/Shapes/Splat** (out 0:rgba; `param0` impact size,
`param1` explosiveness) makes splat height shapes.

Typical use: bricks height -> Create Map -> Apply Map with a stone base; mortar
height -> Create Map -> Apply Map with a sand base; `mwf_mix` the two; `mwf_output`
-> Material (Albedo->0, Metallic->1, Roughness->2, Emission->3, Normal->4,
Occlusion->5, Depth->6). Use `mwf_mix_maps` when several shapes share the same
base material.

## 8. Miscellaneous

| type | library item | purpose | in / out | key params |
|---|---|---|---|---|
| `buffer` | Miscellaneous/Buffer (+ /Advanced) | render input to a texture once; speeds up heavy graphs, required before some filters | 0:in:rgba / 0, 1 (rgba) | `size` (start 4 = 16 px: set 9-11), `lod` |
| `iterate_buffer` | Miscellaneous/Iterate Buffer | feedback loop over a subgraph | 0:in, 1:loop_in / 0, 1 | `size`, `iterations` 1-50, `autostop`, `f32` |
| `switch` | Miscellaneous/Switch | choose between inputs (A/B versions) | inputs created by `choices`/`outputs` / 0:A, 1:B (any) | `outputs` 1-5, `choices` 2-5, `source` |
| `reroute` | Miscellaneous/Reroute | wire tidy-up | 0:in:any / 0:any | - |
| `portal` | Miscellaneous/Aperture/In, /Out | wireless link by name | in / out any | `link` |
| `export` | Miscellaneous/Export | extra texture written on export | 0:in:rgba / - | `size` (10), `format` PNG\|JPG\|WEBP\|EXR, `suffix` |
| `autoexport` | Miscellaneous/Auto Export | writes a file whenever the input changes | 0:in:rgba / - | `size`, `filename` |
| `comment`, `comment_line` | Miscellaneous/Comment(/Line) | notes in the graph | - | - |
| `debug` | Miscellaneous/Debug | shows generated shader code | 0:in:rgba / - | - |
| `variations_greyscale`, `variations_color`, `variations_rgba`, `variations_sdf2d` | Miscellaneous/Variations(/Color, /RGBA, /SDF2D) | 5 seed variations of the input | 0:in / 0..4 | `v1..v5` |
| `controlled_variations`, `iterate_variations`, `layer_variations`, `layer_variations_color` | Miscellaneous/Variations/Controlled, /Iterate, /Layer, /Layer Color | variations driven by `$?1..$?4` variables, combined or layered | 0:in (+1:mask) / 0 | `variable`, `v1`, `v2`, `step`, `combine` Add\|Max\|Min\|Average |
| `randomize` | Miscellaneous/Randomize | new random values for an ID map | 0:in:rgb / rgb | - |
| `meshmap` | Miscellaneous/Mesh Map | baked maps of the custom 3D preview mesh | - / 0:rgb | `map` Position\|Normal\|Tangent\|Maximum Curvature\|Minimum Curvature\|Cavity\|Pointiness\|Ambient occlusion\|Bent normals\|Thickness\|Adjacency |
| `mesh_triplanar` | Miscellaneous/Mesh Triplanar | box-map an image onto the custom mesh | 0:port0:rgba / rgba | `param0` |
| `pack_1x32_to_2x16` etc. | Miscellaneous/Pack/... | bit packing helpers | - | - |

`remote` (Miscellaneous/Remote) and `custom` (Miscellaneous/Custom Shader) are
not addressable by `type`; add them by `library_item`, though both are mainly
configured in the editor UI. `buffer` typical use: put one after an expensive
height (many noises, warps) that feeds several filters.

## 9. 3D nodes (skip for 2D work)

The library's `3D/...` branch holds raymarched SDF modelling nodes (`sdf3d_*`:
shapes, booleans, repeats, transforms) and 3D textures (`tex3d_*`: noise,
colorize, blend, math in object or world space) for the `material_3d` and
`material_raymarching` materials. They use the `sdf3d`, `sdf3dc`, `tex3d` and
`tex3d_gs` port types, which do not connect to 2D nodes. One bridge is useful
in 2D work: **`raymarching`** (3D/SDF/Render, in 0:sdf:sdf3dc) renders a 3D SDF
object top-down to 0:HeightMap:f, 1:NormalMap:rgb, 2:ColorMap:f, which is a way
to model bolts, knobs or embossed details as height. Otherwise skip this branch;
2D SDF work belongs in section 2.

## 10. Superseded types

Older versions remain loadable (and appear in `list_node_types`) but the library
uses the newer ones. Prefer the newer type unless you need a specific output:
`bricks` (outputs 1:Random color, 2-3:Position.x/y, 4:Brick UV, 5:Corner UV,
6:Direction; pattern enum Running Bond|Running Bond 2|Herringbone|Basket Weave|
Spanish Bond) and `bricks2` -> `bricks3`; `fbm`, `fbm2`, `fbm3` (no Gabor, no
lacunarity) -> `fbm4`; `voronoi` (adds 2:Random color, 3:Fill as rgba) ->
`voronoi2`; `blend` (in 0:s1, 1:s2, 2:a; `blend_type`, `amount`) -> `blend2`;
`normal_map` -> `normal_map2`; `normal_blend` -> `normal_blend2`; `occlusion` ->
`occlusion2`; `slope_blur` -> `slope_blur2`; `directional_blur` ->
`directional_blur2`; `warp2` -> `warp`; `weave` -> `weave2`; `beehive` (adds
1:Random color, 2:UV map) -> `beehive2`; `scratches` -> `scratches2`; `noise`
-> `noise2`; `fill`, `fill_to_*` without suffix 2/3 -> the suffixed versions;
`transform` -> `transform2`; `kaleidoscope` -> `kaleidoscope2`; `custom_uv` ->
`custom_uv2`; `morphology`, `morphology2` -> `morphology3`; `multi_warp` ->
`multi_warp2`; `warp_dilation*` -> `warp_dilation3`; `wavelet_noise` ->
`wavelet_noise2`; `clouds_noise` -> `clouds_noise2`; `emboss` -> `emboss2`.

## 11. Picking nodes by goal

Recipes name the node types; wire height first, then derive normal
(`normal_map2` -> Material 4), AO (`occlusion2` -> 5), depth (inverted height
-> 6), colour (`colorize` -> 0) and roughness (`colorize` grey or `tones_map`
-> 2) from it.

- **Bricks / brick wall**: `bricks3` (Running Bond, mortar 0.03-0.06, bevel
  0.05-0.15) -> `blend2` Multiply with `fbm4` (Perlin, scale 8-16) for surface
  grain. Brick Fill -> `fill_to_random_grey2` -> `math` A*B into height (0.8-1
  range via `tones_map`) for uneven bricks, and -> `tones_map` -> `colorize` /
  `blend2` for per-brick colour. Mortar mask = `tones_step` (low value) on the
  brick height; give it its own colour and rougher value. Chipped edges: noise
  into `bevel_map` or `slope_blur2` on the height. Workflow alternative:
  Create Map + Apply Map for brick and mortar, `mwf_mix`, `mwf_output`.
- **Stone / rock**: `bricks_uneven2_2` or `bricks_uneven3_2` (walls) or
  `voronoi2` (cobbles: Borders/Nodes as height, Fill for per-stone variation);
  add `shard_fbm` or `fbm4` Cellular for faceting; `slope_blur2` (noise as
  heightmap, sigma 10-30) to erode; `warp` with low fbm to break straight
  joints. Colour by `colorize` of height plus per-stone grey; AO and curvature
  darken crevices.
- **Wood**: `noise_anisotropic` (scale_y 128-512) or `directional_noise` for grain,
  stretched `fbm4` warped by `warp` for rings; `colorize` with 3-5 browns. Planks:
  `bricks3` (Running Bond, rows 6-10, columns 1-2, mortar 0.01-0.02) or
  `bricks_uneven3_2`; Brick Fill -> `fill_to_uv2` -> `custom_uv2` (with `rotate`
  0, `scale` small) so every plank gets its own grain offset; Fill ->
  `fill_to_random_grey2` for per-plank tint. Library shortcut:
  Workflow/Materials/Wood.
- **Metal**: albedo a flat `uniform` (grey-tinted for steel, warm for brass),
  metallic `uniform_greyscale` 1; detail lives in roughness: `directional_blur2`
  on `noise_white` or `noise_anisotropic` for brushed metal, `scratches2`
  blended Lighten/Darken into roughness, `fbm4` for smudges. Panels: `bricks3`
  Tiles preset (mortar 0.01, bevel 0.02) plus rivets from `tiler` of `shape`
  (Circle, edge 0.5). Library shortcut: Workflow/Materials/Metal.
- **Rust**: mask = `fbm4` (Perlin, scale 4-8, persistence 0.6) -> `tones_step`
  (width 0.05) multiplied with the cavity mask (inverted `occlusion2` or dark side
  of `smooth_curvature2`); `blend2` Normal with that mask puts a `colorize`d
  orange-brown noise over the metal albedo, sets metallic to 0 and roughness to
  0.8-0.95 inside it; `warp_dilation3` (angle 0) or `directional_blur2` (angle
  90) for streaks running down; add a slight height bump from the mask.
- **Fabric**: `weave2` or `weave_random` (rows/columns 16-32, stitch 1-3) as height;
  thread texture from `fbm4` + `directional_blur2`; colour warp and weft from the
  Horizontal/Vertical masks with `blend2`; roughness high (0.8-1), normal
  strength low. Knits/meshes: `mesh`; fibres: Pattern/Fibers.
- **Ground / soil / sand**: several `fbm4` layers (scales 2, 8, 24) combined with
  `blend2` Overlay; pebbles via `splatter` or `tiler` of `shape` (random scale and
  rotate) merged with `math` max or `smooth_minmax`; cracked mud = `voronoi2`
  Borders -> `tones_step` -> subtract from height; sand ripples = `sine_wave` or
  `pattern` (Sine) warped by fbm (`warp`); puddles = `tones_step` on a large
  fbm, flattened in height (`math` max) and roughness near 0.05.
- **Tiles / floor tiles**: `bricks3` with library item Pattern/Bricks/Tiles
  (row_offset 0, mortar 0.02-0.05), or `beehive2` (hex), `cairo`, `custom_tiles`
  (SDF outline), Herringbone/Basket Weave presets for parquet. Grout colour from
  the mortar mask; per-tile tint with `fill_to_random_grey2`; per-tile height
  tilt with `fill_to_gradient2` (small `r_rotate`) blended at low amount.
- **Scratches**: `scratches2` (layers 3-6, length 0.1-0.3, width 0.1-0.3) ->
  roughness via `blend2` (Lighten for shiny scratches on matte paint, Darken on
  rough metal) and a slight negative height (`math` A-B with B scaled). Restrict
  to edges with a curvature mask in the blend mask input.
- **Edge wear**: `smooth_curvature2` (or `edge_detect` on a stepped height)
  -> `tones_step` (value about 0.55-0.6) -> multiply with a noise (`fbm4`
  -> `tones_step`) for chipped, broken edges -> `blend2` mask that reveals a
  lighter or bare-metal layer and lowers roughness. For brick/tile borders, the
  pattern height `tones_range` around the bevel band is an easy edge mask.
- **Dirt in crevices**: cavity mask = inverted `occlusion2` (or `hbao`), or the
  dark side of `smooth_curvature2`, multiplied with `dirt` or `fbm4` for
  breakup -> `blend2` (Normal or Multiply, amount 0.5-0.9) with a dark brown
  albedo; also raise roughness in the same mask. Bottom-heavy grime: multiply
  with a `gradient`.
- **Variation per tile/brick/plank**: any `fill` output -> `fill_to_random_grey2`
  (values), `fill_to_random_color3` (ID map, then `color_pick` or `randomize`),
  `fill_to_uv2` -> `custom_uv2` (separate texture per cell), `fill_to_gradient2`
  (tilted cells). Instancing nodes give the same via `tiler`/`splatter` outputs
  1:Instance map and 2:Instance UV. Seeds: `randomize_seed` on the pattern or
  noise.
- **Moss / growth on top**: mask = height `tones_step` (high values) or
  `smooth_curvature2` convex side, broken with `fbm4`; `blend2` green
  `colorize`d noise into albedo, roughness 0.9, small height add; use `mwf_mix`
  for a height-correct overlap in workflow graphs.
- **Wet / glossy patches**: `tones_step` on large fbm -> roughness `blend2`
  Darken toward 0.05-0.2 and darken albedo slightly (Multiply 0.2-0.3).
- **Decals, logos, insets**: `text` or SDF shapes -> `sdshow`/`bevel` for height;
  place with `transform2` (mode Clamp); fade into the base with `blend2` mask.
