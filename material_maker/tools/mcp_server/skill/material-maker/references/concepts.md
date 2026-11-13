# Material Maker concepts for agents

Background knowledge for building procedural PBR materials in Material Maker (MM) 1.8 through
its MCP server. Facts marked "(verified)" were checked against the running app's
`describe_node_type` / `get_graph` / `list_export_targets` or the node definition files
(`addons/material_maker/nodes/*.mmg`).

## Contents

1. Mental model
2. Port data types and conversions
3. Material node types
4. The Static PBR Material node in detail
5. Height-first workflow (how experienced users build materials)
6. Workflow nodes (Create Map, Mix Maps, Apply Map, Mix, Output)
7. Buffers and performance
8. Randomness, seeds and expressions
9. Remote nodes, named parameters and groups (subgraphs)
10. Other organising nodes (Switch, Variations, Export, Reroute, Aperture)
11. Exporting
12. Common pitfalls
13. Glossary

---

## 1. Mental model

- A material is a **graph of nodes**. Exactly one **Material node** (named `Material` in the
  graph, it cannot be deleted or duplicated) collects the final channels.
- Almost every node is a **shader node**: its output is not a stored image but a GLSL function
  of the UV coordinate (or of a 3D point for SDF3D/TEX3D). Connecting nodes composes their
  code into one combined shader that the GPU evaluates. Consequently most of the graph is
  **resolution independent**; resolution only matters when something is actually rendered:
  a preview, a Buffer, a convolution-style filter, or the export.
- UV space is the unit square [0,1]x[0,1]. Generators (patterns, noises) are designed to
  **tile seamlessly** across that square, so a finished material is a tileable texture set
  by default. Tiling is easy to break with transforms (see pitfalls).
- Only two kinds of nodes really hold pixels ("texture nodes"): **Image** (a file) and
  **Buffer** (renders its input into a texture). Several library filters (blurs, Normal Map,
  Occlusion, HBAO, Supersample...) contain buffers internally and therefore have a fixed
  resolution of their own.
- Each input accepts exactly one connection; one output can feed many inputs. Connecting to an
  input that is already fed replaces the old link. Unconnected inputs use a default value
  (for the Material node: white albedo, roughness 1, flat normal, no emission...).
- Previews: selecting a node shows its first output in the 2D preview (the frame marks the
  tile bounds, so seams are visible); the 3D preview shows the whole material on a mesh.
  Over MCP use `render_output` for a single node output and `render_material_preview` for
  the 3D result.

## 2. Port data types and conversions

Type ids are what the MCP reports in port `type` (from `io_types.mmt`, verified):

| id | Label | GLSL value | Port colour | Meaning |
|----|-------|-----------|-------------|---------|
| `f` | Grayscale | float | grey | One channel per UV: heights, masks, roughness |
| `rgb` | Color | vec3 | light blue | Colour (albedo, emission, normal maps, ORM packs) |
| `rgba` | RGBA | vec4 | darker blue | Colour plus alpha |
| `sdf2d` | SDF2D | float | orange | 2D signed distance (negative inside a shape) |
| `sdf3d` | SDF3D | float of vec3 p | orange-red | 3D signed distance |
| `sdf3dc` | SDF3D-C | vec2 (distance, colour index) | red | 3D SDF with a colour/material index |
| `tex3d_gs` | Grayscale TEX3D | float of vec4 p | violet | Greyscale 3D texture |
| `tex3d` | TEX3D | vec3 of vec4 p | pink-violet | Colour 3D texture |
| `fill` | Fill | vec4 | green | Bounding-box info from Fill / some patterns, for Fill companion nodes |
| `v4v4` | V4->V4 | vec4 | brown | Special transform signal (rare) |
| `any` | any | - | light grey | Used by Switch and similar pass-through nodes |

Compatibility and automatic conversion:
- **f, rgb and rgba interconvert automatically.** Grey -> colour copies the value into R,G,B
  (alpha 1). Colour -> grey is the plain average `(r+g+b)/3`, *not* luminance. RGBA -> RGB drops
  alpha.
- `sdf3d` <-> `sdf3dc` convert (index 0 added / dropped); `tex3d` <-> `tex3d_gs` convert.
- Everything else is incompatible across families. An SDF2D must go through **sdShow**
  (`sdshow`, outputs `f`) to become a greyscale mask; an SDF3D scene goes through the **Render**
  node to get a height map and a normal map. 3D textures feed only 3D/Raymarching materials or
  TEX3D-to-2D nodes.
- `connect_nodes` refuses incompatible types; read port types with `describe_node_type` first.

## 3. Material node types

The project's single Material node decides what kind of material is produced (switchable in
the UI from the node's context menu). Types (verified with `list_node_types`):

| Type id | Label | What it is | Inputs | Export targets |
|---------|-------|-----------|--------|----------------|
| `material` | Static PBR Material | Default. All channels baked to image files | 9 PBR channels | Blender, GLTF/Plane, Godot 3 Spatial, Godot 4 ORM, Godot 4 Standard, Unity 3D/HDRP/URP, Unreal Engine 4, Unreal Engine 5 |
| `material_tesselated` | Static PBR Material Displacement | Same as Static PBR, but the 3D preview displaces geometry by depth (needs tessellation enabled in Model -> Configure) | same 9 | same family (no GLTF) |
| `material_dynamic` | Dynamic PBR Material | Channels exported as shader code instead of images: animated (`$time`), resolution independent, non-repeating | 8 (no sss) | Godot 3, Godot 4, Unity, Unreal 4/5 (Unreal gets code for a Custom node) |
| `material_3d` | 3D PBR Material | Channels are TEX3D functions of world or local 3D position (`world` toggle) | albedo, metallic, roughness, emission, ao (TEX3D) | Godot 3/4, Unity, Unreal |
| `material_raymarching` | Raymarching Material | Raymarches an SDF3D-C surface and shades it | `distance` (sdf3dc), albedo, metallic, roughness, emission (TEX3D) | Godot 3/4, Unity, Unreal 4/5 |
| `material_unlit` | Dynamic Unlit Material | One RGBA colour, `blend` mode Add/Mix/Mul/Sub | `color_tex` (rgba) | Godot 3/4 CanvasItem and Spatial, Unity, Unreal 4/5 |
| `material_dynamic_sky` | Dynamic Sky Material | Sky shader from a TEX3D | `sky_tex` | Godot 4 Dynamic Sky |

For texture sets for a game engine or DCC tool, use **Static PBR** (the default).

## 4. The Static PBR Material node in detail

Input ports (index, name, type; verified):

| # | Port | Type | Default if unconnected | Expects |
|---|------|------|------------------------|---------|
| 0 | `albedo_tex` | rgb | white | Base colour in sRGB, no baked lighting. Metals: their tint. |
| 1 | `metallic_tex` | f | the `metallic` parameter | 0 = dielectric, 1 = metal; mostly pure 0 or 1 masks |
| 2 | `roughness_tex` | f | 1.0 | 0 = mirror glossy, 1 = fully matte |
| 3 | `emission_tex` | rgb | black | Emitted light colour; black = none |
| 4 | `normal_tex` | rgb | flat | Tangent-space normal **in MM's own format** (see below) |
| 5 | `ao_tex` | f | 1.0 | Ambient occlusion: 1 = unoccluded, darker = crevices |
| 6 | `depth_tex` | f | 0.0 | **Depth, not height**: 0 = top surface, 1 = deepest |
| 7 | `opacity_tex` | f | 1.0 | Alpha; only used when `flags_transparent` is on |
| 8 | `sss_tex` | f | 0.0 | Subsurface scattering mask |

Parameters (verified defaults; a fresh project may show different starting values):

| Parameter | Range | Role |
|-----------|-------|------|
| `albedo_color` | colour, default white | Tint multiplied with the albedo texture |
| `metallic` | 0..1, default 1 | Multiplier for the metallic channel |
| `roughness` | 0..1, default 1 | Multiplier for the roughness channel |
| `emission_energy` | 0..1, default 1 | Emission strength multiplier |
| `normal` | 0..10, default 1 | Normal map strength in the engine material |
| `ao` | 0..1, default 1 | How much AO affects lighting (Godot's AO light affect) |
| `depth_scale` | 0..1, default 0.5 | Parallax/height scale in the engine material |
| `flags_transparent` | bool, default off | Enables alpha from `opacity_tex` |
| `sss` | 0..1, default 0 | Subsurface scattering strength |
| `size` | size 6..13, default 11 | Export resolution, 2^v pixels (10 = 1024, 11 = 2048, 12 = 4096) |

How parameters and inputs combine. This matters:
- The parameters are **not baked into the exported textures**. The images contain the raw
  connected inputs. The parameters are written into the engine material file (e.g. Godot's
  `albedo_color`, `metallic`, `roughness`, `normal_scale`, `emission_energy`,
  `heightmap_scale = 25 * depth_scale`) and used by the 3D preview, where texture x parameter
  is applied.
- So for targets that only write images (Blender, mostly Unreal), tints, normal strength
  and roughness multipliers are lost. **Put the real values into the graph** (colorize,
  tone-map, set Normal Map `strength`) and leave the multipliers at 1.0 (`albedo_color` white).
- Unconnected `metallic_tex` defaults to the `metallic` value. If metallic, roughness or AO is
  connected, an ORM image is written whose blue channel is that value and the engine
  multiplies it by `metallic` again. Simplest rule: drive metallic and roughness with
  explicit greyscale inputs (Uniform/Grayscale for constants) and keep the multipliers at 1.
  Or leave metallic unconnected with the parameter at 0 for non-metals.

Normal map convention:
- MM's internal normal format looks **yellowish**, not blue: a flat normal is
  (0.5, 0.5, 0.0). The Normal Map node, the 3D SDF Render node and the workflow Output node
  produce this format, and the Material node converts it per target at export (OpenGL for
  Godot, Unity, Blender and GLTF; DirectX for Unreal).
- Do **not** wire a standard OpenGL or DirectX normal map image straight into `normal_tex`.
  Pass it through **Convert Normal Map** (`normal_map_convert`, op "From/To OpenGL" or
  "From/To DirectX") first. Use the same node to turn an MM normal into a standard one for an
  Export node or a 2D-preview render.
- Combine two normal maps with **Normal Blend** (`normal_blend2`, reoriented normal blending),
  not with a colour Blend.

Depth convention: `depth_tex` is inverted height. The examples always feed it through a
Colorize with a white-to-black gradient or an Invert node. Exports convert it back where an
engine wants height (Godot 4 `_heightmap`, Unity/Unreal `_height` = 1 - depth).

## 5. Height-first workflow

This is how the shipped examples (bricks, stone_wall, floor1, beehive...) are built. Design one
good greyscale **height map**, then derive every channel from it and from masks:

1. **Shape the height**: patterns (Bricks, Tiles, Voronoi, Weave...) and SDF shapes via sdShow,
   combined with Blend (`blend2`: Normal, Multiply, Lighten/Darken = max/min...) and Math.
   Add detail with noise (FBM, Perlin, Voronoi) at low opacity, distort with Warp, and shape
   profiles with Tones Map / Tones Step / Curve / Colorize-to-grey.
2. **Normal**: height -> **Normal Map** (`normal_map2`, library "Filter/Normal Map") ->
   `normal_tex`. Main parameters: `strength`, `size` (its internal buffer resolution, 2^v) and
   `param2` (algorithm: 0 Sobel, 1 Scharr, 2 Simple, 3 Cheap); `buffer` on is faster but less
   precise. Strength is the main "how bumpy" control.
3. **AO**: height -> **Occlusion** (`occlusion2`; Resolution, Strength, Radius, Quality) or
   **HBAO** (`hbao`) -> `ao_tex`. A hand-made alternative is Colorize of the height with a
   gradient from dark grey to white.
4. **Depth**: height -> Colorize (white at 0, black at 1) or Invert -> `depth_tex`. Keep
   `depth_scale` small (0.05-0.2) for parallax.
5. **Albedo**: **Colorize** (gradient parameter) of the height or of masks gives colour ramps.
   Layer colour variation with Blend using noise as the opacity mask, and use per-tile
   random-value outputs of patterns (Bricks, Tiler) for per-piece variation.
6. **Roughness**: Colorize or Tones Map the height or masks into a narrow grey range. Crevices
   are often rougher, worn tops slightly glossier. Add subtle noise. Avoid exactly 0 or 1.
7. **Metallic**: a clean mask (0 or 1), e.g. a thresholded (Tones Step) mask of where bare metal
   shows.
8. **Emission**: only where something glows: colorize a mask, black elsewhere.

Rule of thumb: one height drives normal, AO and depth so they always agree. Colour and roughness
use the same masks, so material regions line up.

## 6. Workflow nodes

The "Workflow" library section is a second, more structured approach. You build simple
homogeneous **base materials** and paint them onto shapes described by **maps**.
- A base material is four colour signals: **Albedo, ORM** (R = occlusion, G = roughness,
  B = metallic), **Emission, Normal**. Ready-made ones: `Workflow/Materials/Marble`, `Metal`,
  `Wood`... (library items whose type is `graph`, so add them by `library_item`).
- **Create Map** (`mwf_create_map`): inputs `h` (height, f) and optional `o` (offset seed map,
  f); parameters `height` (max height, 0..1) and `angle` (-180..180). Outputs one RGB map:
  R = height, G = orientation, B = random offset. The offset makes each piece (e.g. each brick)
  sample the base material at a different place. It is seeded.
- **Mix Maps** (`mwf_mix_maps`): merges up to 4 maps (highest wins) that will receive the same
  base material.
- **Apply Map** (`mwf_map`): map + the 4 base-material channels -> Height, Albedo, ORM,
  Emission, Normal of that material laid onto the map (rotated and offset).
- **Mix** (`mwf_mix`): takes two applied sets (h, albedo, orm, emission, normal x 2) and keeps
  whichever is **higher** per pixel. Variadic, so more sets can be chained. **Smooth Mix**
  (`mwf_mix_smooth`, `width` 0..0.2) blends the transition.
- **Output** (`mwf_output`): converts the final applied set into Material channels: Albedo,
  Metallic, Roughness, Emission, Normal, Occlusion, Depth. It builds normal and occlusion from
  the height and blends in the base materials' normals. Parameters: `param2` = Occlusion
  amount, `param0` = "Mat Normal" (strength of base-material normals). Connect its 7 outputs to
  `albedo_tex, metallic_tex, roughness_tex, emission_tex, normal_tex, ao_tex, depth_tex`.

Use the workflow when a material is "material A in these shapes, material B in those shapes"
(mortar plus bricks, wood planks plus metal studs). Use the plain height-first approach for
single-surface materials.

## 7. Buffers and performance

- **Buffer** (`buffer`, library "Miscellaneous/Buffer", preset size 9 = 512): renders its RGBA
  input into a texture of `size` (2^v). Output 0 = the image; output 1 = a mip level chosen
  by `lod` (cheap blur or pixelation). "Miscellaneous/Buffer/Advanced" adds `filter` and
  `mipmap` toggles. **Iterate Buffer** (`iterate_buffer`) feeds its result back through a loop
  input N times (`iterations`, `autostop`) for multi-pass effects.
- Why buffers exist: the combined shader is re-evaluated for every sample. Nodes that sample
  their input many times (blur, normal from height, AO, warp, edge detect) multiply the cost of
  everything upstream. A Buffer before such a node evaluates the upstream once and turns the
  rest into cheap texture reads. It is also the standard fix when previews get very slow or the
  FPS meter drops.
- Costs: each buffer is another image to render, and it **freezes resolution**. A 512 buffer
  feeding a 2048 export makes everything downstream blurry or blocky. Match buffer sizes (and
  the `size` of Normal Map, Occlusion, blur nodes) to the Material `size` before the final
  export.
- Buffers also cut seed propagation: Variations nodes re-roll upstream randomness only "until a
  buffer, text or image node is reached".
- Dynamic PBR materials export shader code, so internal buffers are a problem there. The manual
  says to switch the Normal Map buffer off and use the Cheap algorithm for dynamic materials.
- Heavy nodes to use sparingly: high-quality blurs, Supersample (`count` 2..5), Iterate Buffer
  with many iterations, Kuwahara filters, deep chains of warps, and Fill nodes at high
  resolution.

## 8. Randomness, seeds and expressions

- Nodes with random output (`has_randomness: true` in `describe_node_type`, e.g. noises,
  Bricks, Tiler, Create Map) have a hidden **seed**. `randomize_seed` gives a new seed, or a
  specific one. A seed can be locked in the UI so parents and variations do not change it.
- Groups have their own seed and pass it to their children (a per-group toggle controls this),
  so re-seeding a group re-rolls everything inside it.
- **Float parameters accept GLSL expressions** (as strings) instead of numbers:
  - other parameters of the same node, or named parameters from a Remote, with a `$` prefix:
    `$scale_x`, `2.0*$tiles`;
  - `$time` for animation. It works in Dynamic, Unlit and Raymarching materials. A Static PBR
    export is still a single frame (useful for exporting variants at different times);
  - `$rnd(min, max)` (float) and `$rndi(min, max)` (integer, inclusive) for values that follow
    the node's seed;
  - `$?1` .. `$?4`: variables set by the Controlled / Iterate / Layer Variations nodes.
- Size, enum, boolean, colour and gradient parameters take plain values, not expressions.

## 9. Remote nodes, named parameters and groups

- **Remote** (library "Miscellaneous/Remote", type `remote`): no ports. It exposes controls for
  parameters of other nodes:
  - *linked controls*: one widget drives the same kind of parameter on several nodes;
  - *configuration controls*: named presets of a set of parameters;
  - *named parameters*: floats usable as `$name` in expressions anywhere in the same graph
    level.
- **Groups / subgraphs** (`create_group`, like Ctrl+G): the selected nodes become one node of
  type `graph`. `get_graph` reports `is_group` and `group_path`; `open_graph` enters it. Inside
  there are:
  - an **Input** node (`gen_inputs`) and an **Output** node (`gen_outputs`) whose ports become
    the group's ports;
  - a **Parameters** node (`gen_parameters`, a Remote) whose widgets become the group's
    parameters. On the outside they appear as `param0`, `param1`... unless named.
  Many library nodes (Normal Map, Occlusion, HBAO, workflow Output, the Workflow/Materials) are
  such groups, so their parameter names look like `param2`. Always use the names that
  `describe_node_type` reports.
- Identical copies of a named group can be updated together ("Propagate changes" in the UI).

## 10. Other organising nodes

- **Switch** (`switch`): picks one of 2..N input sets for 1..5 outputs (`source` = current
  choice). Good for material variants.
- **Variations** / **Controlled Variations** / **Iterate Variations** / **Layer Variations**:
  render the upstream branch several times with different seeds or `$?n` values, as separate
  outputs or combined/stacked (useful for scattering differently seeded copies).
- **Export** (`export`): an extra texture written next to the material files on export, or alone
  via Quick Export. Params: `size`, `format` (PNG/JPG/WEBP/EXR), `suffix` filename pattern
  (`$project`, `$node`, `$idx`, `$resolution`). **Auto Export** rewrites its file whenever
  its input changes.
- **Reroute** and **Aperture** (in/out pairs linked by a label) only tidy wiring; no effect on
  output. **Comment** nodes are notes/frames.
- **Image** (`image`): loads a file (BMP, EXR, HDR, JPEG, PNG, SVG, TGA, WebP, DDS); options
  `fix_ar`, `clamp` (disables tiling), `filter`. **Uniform** (`uniform`, colour) and
  **Uniform/Grayscale** give constants.
- **Mesh Map** / **Mesh Triplanar**: bake or project using the custom mesh loaded in the 3D
  preview (for mesh-specific texturing rather than tileable materials).

## 11. Exporting

- `list_export_targets` lists the targets the current Material node offers and its
  `material_size` (2^size). `export_material` runs one without dialogs. Textures render at the
  Material node `size`. Files are written only for connected channels, named
  `<prefix>_<suffix>` where the prefix is the chosen output path/name.

Static PBR targets (verified from `material.mmg`):

| Target | Files |
|--------|-------|
| Godot/Godot 4 Standard, Godot 4 ORM | `.tres` material + `_albedo.png`, `_orm.png`, `_emission.png`, `_normal.png` (OpenGL), `_heightmap.png` (= 1-depth), `_sss.png` |
| Godot/Godot 3 Spatial | `.tres` + albedo, orm, emission, normal, `_depth.png`, sss |
| Unity/3D, Unity/URP | `.mat` + `.meta` files; `_albedo`, `_metal_smoothness` (RGB metallic, A = 1-roughness), `_normal` (OpenGL), `_height`, `_occlusion`, `_emission` |
| Unity/HDRP | `.mat`; `_albedo`, `_maskmap` (R metallic, G AO, B 1, A smoothness), `_normal`, `_height`, `_emission` |
| Unreal/Unreal Engine 5 | Python script `.py` (path copied to clipboard; run it in Unreal's Python console after adding MM's `export` folder to Unreal's Python paths) + albedo, orm, emission, `_normal` (DirectX), `_height` |
| Unreal/Unreal Engine 4 | `.mm2ue` instructions + same textures; material built by hand |
| Blender | Images only: `_albedo.png`, `_rough.exr`, `_metal.exr`, `_normal.png` (OpenGL), `_displace.exr` (height), `_occlusion.exr`, `_emission.png`, `_sss.exr`. Build the shader yourself (Node Wrangler's Principled setup helps) |
| GLTF/Plane | `.gltf` plane + albedo, orm, emission, normal |

- **ORM packing**: R = ambient occlusion, G = roughness, B = metallic (glTF/Godot/Unreal
  convention). Unity packs differently (see table). Packing is automatic.
- A Static PBR export is one static frame; Dynamic materials export shaders.
- Command line equivalent: `material_maker --export-material --target <Blender|Godot|Unity|Unreal> -o <dir> <files.ptex>`.

## 12. Common pitfalls

- **Nothing connected to the Material node**: the 3D preview stays white and the export only
  writes the files for connected channels. Check `get_graph` that every intended channel has a
  `source`.
- **Raw normal map into `normal_tex`**: standard blue OpenGL/DirectX maps must go through
  Convert Normal Map first. And never colour-blend normals; use Normal Blend.
- **Height into `depth_tex`**: depth is inverted height. Invert it, or bumps become dents in
  parallax/height exports.
- **Normal strength only on the Material node**: the `normal` parameter is not baked. Set the
  bump amount on the Normal Map node's `strength` so it survives every target. Same for
  `albedo_color` and the metallic/roughness multipliers.
- **Over-strong normals**: strengths that look fine in 2D often look like plastic noise in 3D.
  Check with `render_material_preview`. Fine noise detail wants a much lower contribution to
  height than large shapes.
- **Colour fed to a greyscale port**: it is silently averaged `(r+g+b)/3`, which may not be the
  value you meant. Convert deliberately (Decompose a channel, Grayscale filter, or Colorize to
  grey).
- **Greyscale into albedo**: works (grey copied to RGB) but gives a colourless material. Use
  Colorize.
- **Tiling seams from transforms**: Transform (`transform2`) defaults to `mode` = Clamp. Use
  Repeat when the result must tile. Even in Repeat mode, rotations other than multiples of 90
  degrees and scales that do not fit a whole number of repeats into the unit square break the
  seam. Prefer the pattern's own tile-count or scale parameters over a Transform. Check the
  2D preview's tile frame, or use Make Tileable on non-tiling input such as photos.
- **Low buffer resolution**: Buffer (preset 512), Normal Map (`size` 10 = 1024) and blur nodes
  cap detail regardless of the Material `size`. Raise them to match the export size before the
  final export (or accept blur on purpose).
- **Too many heavy filters stacked**: insert a Buffer before expensive filters, avoid
  needlessly high Supersample/Iterate counts. Slow previews mean the next agent call waits too.
- **Pure 0/1 roughness, mid-grey metallic**: real surfaces rarely have roughness exactly 0, and
  metallic should be 0 or 1 except at transitions.
- **Lighting baked into albedo**: keep shadows and AO out of the albedo (AO has its own
  channel), or the material looks wrong under engine lighting.
- **Group parameter names**: library groups expose `param0`, `param1`... Read
  `describe_node_type` instead of guessing names like `strength`.
- **Size values are exponents**: `size: 11` means 2048 px, not 11 px.

## 13. Glossary

- **Albedo**: base colour without lighting.
- **AO / Ambient occlusion**: how much ambient light reaches a point (white = open).
- **Buffer**: node that renders its input into a fixed-size texture.
- **Colorize**: maps greyscale 0..1 onto a gradient; the main way to make colour, roughness and
  depth from a height map.
- **Depth**: inverted height used for parallax/displacement (0 = surface top).
- **Dynamic material**: material whose channels are exported as shader code (animated,
  resolution independent).
- **Editable node (Ctrl+W)**: UI mode exposing a node's code or group contents. Not needed for
  normal authoring.
- **Export target / profile**: named recipe on a Material node listing files and templates to
  generate for one engine or tool.
- **Gradient**: parameter type (list of colour stops plus interpolation) used by Colorize and
  some patterns.
- **Graph / group / subgraph**: a node of type `graph` that contains nodes, with Input, Output
  and Parameters (Remote) nodes inside.
- **Height map**: greyscale image where white is high. The usual source of normal, AO and depth.
- **Library item**: an entry in the Library panel (path like `Filter/Normal Map`). It may be a
  plain node type with preset parameters, or a prebuilt group.
- **LOD output**: the Buffer's second output, a lower mip level.
- **Material node**: the single sink node of a project; its type sets the material kind.
- **Named parameter**: float declared in a Remote, referenced as `$name` in expressions.
- **ORM**: packed texture, R = occlusion, G = roughness, B = metallic.
- **PBR**: physically based rendering (metallic/roughness model).
- **.ptex**: Material Maker material project file (JSON). **.mmpp**: paint project.
- **Remote**: node exposing linked controls, configurations and named parameters.
- **SDF (signed distance function)**: shape described by distance to its edge. SDF2D for 2D
  shapes, SDF3D for raymarched solids.
- **Seed**: per-node random seed; changing it re-rolls the random pattern.
- **Shader node**: a node defined by GLSL code. Most nodes are shader nodes.
- **Size parameter**: power-of-two exponent for a resolution (v -> 2^v pixels).
- **Static PBR Material**: default material type; channels baked to images on export.
- **TEX3D**: texture defined over 3D space, used by 3D/Raymarching/Sky materials.
- **Tileable / seamless**: texture whose edges match so it repeats without seams.
- **Variadic node**: node with a variable number of ports (e.g. Blend layers, Mix sets, Tones
  Map).
