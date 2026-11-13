---
name: material-maker
description: Build and edit procedural PBR materials and seamless textures in Material Maker through its built-in MCP server (the mcp__material-maker__* tools) — node graphs of patterns, noises and filters feeding albedo, roughness, metallic, normal, AO and height, rendered, saved as .ptex and exported to Godot, Unity, Unreal or Blender. Use this skill whenever the user wants a material, texture, tileable pattern, trim sheet, PBR map set, normal/roughness/height map or .ptex file made or changed in Material Maker, or asks for procedural textures for a game engine while Material Maker is available — even if they only say "make me a mossy stone texture" or "tweak the bricks", and even if they never name Material Maker.
---

# Material Maker through MCP

Material Maker is a node-based procedural texture editor (built on Godot). You
describe a material as a graph: generator nodes (patterns, noises, shapes)
produce greyscale or color images, filter nodes reshape them, and everything
ends in a **Material** node whose inputs are the PBR channels. Every node is a
GPU shader evaluated per pixel over UV space, so results are resolution
independent and tile seamlessly unless you deliberately break that.

The MCP server lives *inside* the running app. Every edit appears live in the
person's window and lands on the normal undo stack, one step per tool call.
Treat the editor as a shared workspace: the person may be watching or editing
at the same time.

Read `references/concepts.md` when you need detail on data types, the
Material node, buffers, groups or export. Read `references/nodes.md` to pick
nodes for a look (it ends with a "Picking nodes by goal" section). Both were
written from the official manual and checked against the live server.

## 0. Connect

Call `get_status` first. It lists open project tabs (`index`, file, unsaved
changes) and which graph is shown. If the tools are missing or the call fails,
Material Maker is not running or not registered; tell the person to start it
(the server listens on `http://127.0.0.1:8790/mcp`) or to register it with
`claude mcp add --transport http material-maker http://127.0.0.1:8790/mcp`.

Unless the person asked you to change an existing project, start your own tab
with `new_material` so you never overwrite their work. Pass that `project`
index to every later call; the person may switch tabs while you work.

## 1. Find nodes before guessing

Never invent type names or parameter names; they are short, versioned and
unusual (`bricks3`, `fbm4`, `normal_map2`, `blend2`, `param2`...). Older
versions (`bricks`, `fbm2`) still exist; prefer the one the library uses.

1. `search_library {query}` — the curated library the person sees in the
   Library panel, e.g. "bricks", "noise", "normal", "wood". Results give a
   `library_item` path and the node `type`. Items marked *prebuilt group*
   (type `graph`, e.g. `Workflow/Materials/Wood`) are complete sub-materials:
   add them with `library_item`, not `type`.
2. `describe_node_type {type}` or `{library_item}` — every parameter (type,
   range, enum labels, label) with the `value` a new node starts with, and
   every port with its index and data type. Do this for each node type before
   you first use it, and set the parameters you care about explicitly: start
   values are often not what you want (FBM starts as "Cellular 7").
3. `list_node_types {filter}` — the raw list of ~430 types when search misses.

Ports are referenced by **0-based index**. Data types: `f` greyscale,
`rgb`, `rgba`, `sdf2d`, `sdf3d`, `tex3d`... A greyscale output connects to a
color input (it becomes grey); the server refuses truly incompatible pairs.

## 2. The Material node

Every material project has a node named `Material` ("Static PBR Material").
Its inputs, by index:

| # | name | type | meaning |
|---|------|------|---------|
| 0 | albedo_tex | rgb | base color, no lighting baked in |
| 1 | metallic_tex | f | 0 = dielectric, 1 = metal; use near 0 or 1 |
| 2 | roughness_tex | f | 0 = mirror, 1 = matte |
| 3 | emission_tex | rgb | glow color |
| 4 | normal_tex | rgb | normal map in Material Maker's own format (from `normal_map2`) |
| 5 | ao_tex | f | ambient occlusion, 1 = unoccluded |
| 6 | depth_tex | f | **depth, i.e. inverted height**: 0 = top surface, 1 = deepest |
| 7 | opacity_tex | f | alpha (only with `flags_transparent` on) |
| 8 | sss_tex | f | subsurface scattering amount |

Two conventions trip everyone up:
- **Depth is inverted height.** Feed `depth_tex` from your height through an
  `invert` node (or a white→black `colorize`), never the height itself, or
  bumps become dents. Exports flip it back where an engine wants height.
- **Normals use Material Maker's own (yellowish) format.** `normal_map2`
  produces it and the Material node converts per engine at export. A normal
  map *image* from elsewhere must go through `normal_map_convert` first.

The node's own parameters (`albedo_color`, `metallic`, `roughness`,
`emission_energy`, `normal`, `ao`, `depth_scale`) multiply the inputs in the
3D preview and are written into engine material files, but they are **not
baked into exported textures**. Put the real look into the graph (gradients,
Normal Map `strength`) and leave the multipliers near 1. An unconnected
roughness input means fully matte (roughness parameter defaults to 1). `size`
is the export resolution as a power of two (10 = 1024, 11 = 2048, 12 = 4096).
Check the current values with `get_node {node: "Material"}`.

## 3. Build height-first

Experienced Material Maker users build almost every material around one
greyscale **height map**, then derive the other channels from it so they agree
with each other:

1. **Shape** — a pattern (`bricks3`, `voronoi2`, shapes, tiles from the
   library) gives the large structure.
2. **Detail** — mix noises (`fbm4`, `perlin`...) into the height with `blend2`
   (Multiply/Overlay at low amount) or `math`; distort with `warp`.
3. **Normal** — height → `normal_map2` → Material input 4. Its `strength` is
   the main knob for how bumpy the surface reads.
4. **AO** — height → `occlusion2` → Material input 5.
5. **Color** — height (or masks from it) → `colorize` with a gradient →
   Material input 0. Layer dirt, moss or wear with `blend2` using a mask in its
   opacity input (port 2): crevices = inverted height/AO, edges = edge
   detection or curvature.
6. **Roughness** — height or masks → `colorize` with a grey gradient, or a
   `tones`/levels node → Material input 2. Crevices and dirt rougher, worn
   tops smoother.
7. **Depth** — height → `invert` → Material input 6 (parallax/displacement).
8. **Metallic** — only for metal: a clean 0/1 mask (e.g. `tones_step` of a
   mask) → input 1. Leave it unconnected for non-metals.

One height drives normal, AO and depth so they always agree; color and
roughness reuse the same masks so regions line up.

For "material A in these shapes, material B in those" (bricks and mortar,
planks with metal studs) there is a second approach, the **Workflow** nodes:
base materials (`Workflow/Materials/Wood`, `Metal`, `Marble`, `Template`;
prebuilt groups, add by `library_item`) are laid onto height maps with
`mwf_create_map` → `mwf_map`, combined with `mwf_mix`, and `mwf_output` turns
the result into the Material's channels. See `references/concepts.md` §6.
Adding a prebuilt group and reading it with `get_graph {graph: "<name>"}` is
also a good way to learn how a material is built.

## 4. Edit with few, large calls

`add_nodes` creates several nodes and their connections in one call (one undo
step). Give each node an `id`; connections may use new ids or existing node
names. The returned `name`s are what you use afterwards (a clash gets renamed,
e.g. `noise_2`). Leave out positions and nodes are laid out left of the
graph in data-flow order.

```json
{"project": 2, "nodes": [
  {"id": "tiles",  "type": "bricks3", "parameters": {"pattern": "Running Bond", "rows": 6, "columns": 3, "mortar": 0.04, "bevel": 0.15}},
  {"id": "grain",  "type": "fbm4",   "parameters": {"noise": "Perlin", "scale_x": 12, "scale_y": 12, "iterations": 5}},
  {"id": "height", "type": "blend2", "parameters": {"blend_type1": "Multiply", "amount1": 0.35}},
  {"id": "normal", "type": "normal_map2"},
  {"id": "ao",     "type": "occlusion2"},
  {"id": "color",  "type": "colorize", "parameters": {"gradient": [{"pos": 0, "color": "#2b2622"}, {"pos": 0.5, "color": "#6e655c"}, {"pos": 1, "color": "#a39a8f"}]}},
  {"id": "rough",  "type": "colorize", "parameters": {"gradient": [{"pos": 0, "color": "#f0f0f0"}, {"pos": 1, "color": "#a0a0a0"}]}},
  {"id": "depth",  "type": "invert"}
 ],
 "connections": [
  {"from": "tiles", "to": "height", "to_port": 0}, {"from": "grain", "to": "height", "to_port": 1},
  {"from": "height", "to": "normal"}, {"from": "height", "to": "ao"},
  {"from": "height", "to": "color"}, {"from": "height", "to": "rough"},
  {"from": "color", "to": "Material", "to_port": 0}, {"from": "rough", "to": "Material", "to_port": 2},
  {"from": "normal", "to": "Material", "to_port": 4}, {"from": "ao", "to": "Material", "to_port": 5},
  {"from": "height", "to": "depth"}, {"from": "depth", "to": "Material", "to_port": 6}
 ]}
```

Parameter values (`set_parameters`, or `parameters` in `add_nodes`):
- numbers for `float`; float parameters also take expressions like `"$time"`;
- enums by label (`"Multiply"`) or index;
- colors as `"#rrggbb"` / `"#rrggbbaa"`;
- gradients as a list of `{pos, color}` stops (pos 0..1, left = black input);
- `size` parameters are powers of two (9 = 512, 10 = 1024);
- unknown names come back as an error listing the valid ones.

Other edits: `connect_nodes` (an input holds one connection; connecting
replaces it), `disconnect_nodes`, `delete_nodes`, `move_nodes`,
`randomize_seed` (new variation of a random pattern), `create_group` (tidy a
finished sub-network into a group), `open_graph` (show a group). Groups are
addressed with `graph: "group_name"` on any graph tool.

If something went wrong, `undo` reverts your last call exactly.

## 5. Look at the result, every time

You cannot judge a material from its graph. After each meaningful change:

- `render_output {node, output, size: 256-512}` shows one node's image. Check
  intermediate nodes (the height!) before blaming the end result. To see fine
  detail, render big and zoom: `size: 2048, region: {x: 0.45, y: 0.45,
  width: 0.08, height: 0.08}` returns that small area at full resolution,
  enlarged. A whole-texture render shrunk to 1024 px hides exactly the detail
  (strands, pores, stitching) that makes a material convincing.
- `render_material_preview {shape: "sphere" | "cube" | "cylinder" | "current"}`
  shows the lit material. It waits for rendering to finish; a `warning` field
  means some buffers were still rendering, so render again before judging.
- `capture_view {area: "graph"}` shows the graph as the person sees it.
- `set_preview {node}` puts a node in the person's 2D preview panel.

Read the images critically: is the scale right (how many bricks per tile?),
does the normal read as bumps or noise, are crevices darker in AO and color,
does roughness vary, is anything tiling with visible seams or repetition?
Adjust and render again. Two or three rounds is normal.

Diagnosing:
- **Magenta / purple surfaces**: missing or failed textures. Render the
  individual nodes; check `get_console` for shader errors.
- **Flat-looking**: normal `strength` too low, or nothing connected to
  normal/depth; the height may have too little contrast (check its render).
- **Plastic-looking**: roughness uniform; feed it from height or masks.
- **Muddy color**: gradient too dark or too narrow; albedo should not contain
  shading, AO does that.

## 6. Working from a reference image

When the person gives you a photo, the photo is the specification, and its
fine detail is what separates a convincing material from a generic one. A
glance at the whole photo gives you colours and layout; it does not tell you
how a weave is built. So study it before you build, and compare against it
up close before you finish.

1. **Look at the whole image** with `inspect_image {path}` for layout,
   proportions, colours and how the light falls.
2. **Zoom into the fine detail** with `inspect_image {path, region}`. Take
   several small regions (5–15 % of the image) where the detail is sharpest
   and best lit, typically near the camera: a patch of the main surface, a
   border or edge, a seam, any ornament. Zoom further if the structure is
   still unclear. Write down what you actually see:
   - the repeating element (a strand, fibre, grain, tile, stitch) and its
     cross-section: rounded, flat, ridged? Where is it light and dark?
   - **direction**: which way the elements run relative to the edges and
     borders of the object (e.g. across or along a border), and which way
     any fine structure runs *inside* each element (fibres along a strand,
     grain along a plank). Getting a direction wrong is the most visible
     mistake a close-up reveals; check it again in your own render.
   - how elements are arranged and bound: row length, offsets, binding
     threads or stitches, and their rhythm;
   - variation between elements: colour shifts strand to strand, thickness
     irregularity, gaps, fibres sticking out;
   - real-world scale: count elements across a feature of known size (a
     tatami mat is about 88 × 176 cm, a brick 21 × 6.5 cm, a floor plank
     10–20 cm wide) to choose repeat counts per texture.
3. **Build the element, not just a stripe.** A row of `0.5 + 0.5·sin` lines
   reads as ruled paper, not woven rush. Model one element's profile (a
   rounded shape or gradient pushed through `tones_map`/`colorize`), repeat
   it with a pattern that gives per-element data (e.g. `bricks3` output 1
   "Brick Fill" → `fill_to_random_grey2` for a random value per element, or
   → `fill_to_uv2` to shape each element individually; more in
   `references/nodes.md` §5.7), and drive colour, height and roughness
   variation from those values.
4. **Compare at matched zoom.** Render the albedo (and height) with
   `render_output {size: 2048, region}` over an area showing the same number
   of elements as your reference crop, then look at the two side by side.
   List the differences explicitly (direction, profile, spacing, segment
   breaks, contrast, colour variance, binding detail, border motif) and fix
   the biggest one. Repeat
   until the close-ups match, then check the whole texture again for
   scale and repetition.
5. **Only claim what you have seen.** Before you describe the result, check
   every feature you mention in a render (a seam, a stitch, an offset). If it
   is not visible, either fix it or don't claim it.

## 7. Save and export

- `save_project {project, path: "C:/.../name.ptex"}` (absolute path; later
  saves without `path` reuse it). Do not leave the person with an unsaved tab
  they did not ask for: save it, or tell them it is unsaved.
- `list_export_targets` then `export_material {target, path, size}`. The
  `path` is a prefix, `C:/exports/stone` → `stone_albedo.png`,
  `stone_normal.png`, ... plus engine files for the target (e.g. a Godot
  `.tres`). Targets include Godot 3/4, Unity, Unreal 4/5 and Blender; pick the
  one for the person's engine. Export overwrites the textures but keeps files
  the profile would normally ask about.
- `close_project` refuses unsaved work unless `discard_changes: true`; only
  discard tabs you created.

## Etiquette

- Say what you are building before a large `add_nodes`, and show the person
  the final preview image(s).
- Don't delete or rewire nodes you did not create in someone else's project
  without being asked.
- Keep graphs readable: meaningful ids (`height`, `moss_mask`), and group big
  sub-networks once they work.
