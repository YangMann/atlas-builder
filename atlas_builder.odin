/*
This atlas builder looks into a 'textures' folder for pngs, ase and aseprite 
files and makes an atlas from those. It outputs both `atlas.png` and
`atlas.odin`. The odin file you compile as part of your game. It contains
metadata about where in the atlas the textures ended up.

See README.md for additional documentation.

Uses aseprite loader by blob1807: https://github.com/blob1807/odin-aseprite

By Karl Zylinski, http://zylinski.se
*/

package atlas_builder

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import ase "aseprite"
import stbim "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"

// ---------------------
// CONFIGURATION OPTIONS
// ---------------------

Atlas_Type :: enum {
	Game,
	UI,
	Glyphs,
}

Atlas_Config :: struct {
	type:                Atlas_Type,
	name:                string, // e.g., "game", "ui", "font"
	input_dir:           string,
	input_file_prefix:   string, // e.g., "ui_"
	process_subfolders:  bool,
	size:                int, // 1024, 2048, etc
	crop:                bool,
	output_png_path:     string,
	output_odin_path:    string,
	output_odin_package: string,
}

Atlas_Build_Result :: struct {
	config:       Atlas_Config,
	textures:     [dynamic]Atlas_Texture_Rect,
	animations:   [dynamic]Animation,
	tilesets:     [dynamic]Tileset,
	glyphs:       [dynamic]Atlas_Glyph,
	shapes_rect:  Rect,
	cropped_size: Vec2i,
}

ATLAS_CONFIGS := [?]Atlas_Config {
	{
		type                = .Game,
		name                = "game",
		input_dir           = "assets/aseprite/game",
		input_file_prefix   = "", // No prefix needed, it processes everything in the folder
		process_subfolders  = true,
		size                = 1024,
		crop                = true,
		output_png_path     = "assets/atlas_game.png",
		output_odin_path    = "source/engine/graphics/atlas_game.odin",
		output_odin_package = "graphics",
	},
	{
		type                = .UI,
		name                = "ui",
		input_dir           = "assets/aseprite/ui",
		input_file_prefix   = "", // We'll just process the whole folder
		process_subfolders  = false,
		size                = 1024,
		crop                = true,
		output_png_path     = "assets/atlas_ui.png",
		output_odin_path    = "source/engine/graphics/atlas_ui.odin",
		output_odin_package = "graphics",
	},
	{
		type                = .Glyphs,
		name                = "glyphs",
		input_dir           = "assets/fonts", // Or wherever your .ttf is
		input_file_prefix   = "",
		process_subfolders  = false,
		size                = 1024,
		crop                = true,
		output_png_path     = "assets/atlas_font.png",
		output_odin_path    = "source/engine/graphics/atlas_font.odin",
		output_odin_package = "graphics",
	},
}

// Path to output final atlas PNG to
ATLAS_PNG_OUTPUT_PATH :: "assets/atlas.png"

// Path to output atlas Odin metadata file to. Compile this as part of your game to get metadata
// about where in atlas your textures etc are.
ATLAS_ODIN_OUTPUT_PATH :: "source/engine/graphics/atlas.odin"

// The NxN size of each tile (you can import tilesets by giving textures the prefix `tileset_`)
// Note that the width and height of the tileset image must be multiple of TILE_SIZE.
TILE_SIZE :: 16

// Add padding to tiles by adding a pixel border around it and copying there.
// This helps with bleeding when doing subpixel camera movements.
TILE_ADD_PADDING :: true

// for package line at top of atlas Odin metadata file
PACKAGE_NAME :: "graphics"

// The folder within which to look for textures
TEXTURES_DIR :: "assets/aseprite"

// The letters to extract from the font
LETTERS_IN_FONT :: " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890?!&.,_:[]-+测试"

// The font size of letters extracted from font
FONT_SIZE :: 24


// ---------------------
// ATLAS BUILDER PROGRAM
// ---------------------

Vec2i :: [2]int

Rect :: struct {
	x, y, width, height: int,
}

Color :: [4]u8

// Note that types such as Atlas_Texture_Rect are internal types used during the
// atlas generation. The types written into the atlas.odin file are similar but
// may be slightly different, see the end of `main` where .odin file is written.
Shapes_Texture_Rect :: struct {
	rect: Rect,
	size: Vec2i,
}

Atlas_Texture_Rect :: struct {
	rect:          Rect,
	size:          Vec2i,
	offset_top:    int,
	offset_right:  int,
	offset_bottom: int,
	offset_left:   int,
	name:          string,
	duration:      f32,
}

Atlas_Tile_Rect :: struct {
	rect:  Rect,
	coord: Vec2i,
}

Glyph :: struct {
	value:     rune,
	image:     Image,
	offset:    Vec2i,
	advance_x: int,
}

Atlas_Glyph :: struct {
	rect:  Rect,
	glyph: Glyph,
}

Texture_Data :: struct {
	source_size:   Vec2i,
	source_offset: Vec2i,
	document_size: Vec2i,
	offset:        Vec2i,
	name:          string,
	pixels_size:   Vec2i,
	pixels:        []Color,
	duration:      f32,
	is_tile:       bool,
	tile_coord:    Vec2i,
}

Tileset :: struct {
	name:                string,
	pixels:              []Color,
	pixels_size:         Vec2i,
	visible_pixels_size: Vec2i,
	offset:              Vec2i,
	packed_rects:        [dynamic]Atlas_Tile_Rect,
}

Animation :: struct {
	name:           string,
	first_texture:  string,
	last_texture:   string,
	document_size:  Vec2i,
	loop_direction: ase.Tag_Loop_Dir,
	repeat:         u16,
}

Image :: struct {
	data:   []Color,
	width:  int,
	height: int,
}

Color_F32 :: [4]f32

color_f32 :: proc(c: Color) -> Color_F32 {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
}

color_from_f32 :: proc(c: Color_F32) -> Color {
	return {u8(c.r * 255), u8(c.g * 255), u8(c.b * 255), u8(c.a * 255)}
}

draw_image :: proc(to: ^Image, from: Image, source: Rect, pos: Vec2i) {
	for sxf in 0 ..< source.width {
		for syf in 0 ..< source.height {
			sx := int(source.x + sxf)
			sy := int(source.y + syf)

			if sx < 0 || sx >= from.width {
				continue
			}

			if sy < 0 || sy >= from.height {
				continue
			}

			dx := pos.x + int(sxf)
			dy := pos.y + int(syf)

			if dx < 0 || dx >= to.width {
				continue
			}

			if dy < 0 || dy >= to.height {
				continue
			}

			from_idx := sy * from.width + sx
			to_idx := dy * to.width + dx


			if to.data[to_idx].a == 0 {
				to.data[to_idx] = from.data[from_idx]
			} else {
				f := color_f32(from.data[from_idx])
				t := color_f32(to.data[to_idx])

				to.data[to_idx] = color_from_f32(t * (1 - f.a) + f * f.a)
			}
		}
	}
}

draw_image_rectangle :: proc(to: ^Image, rect: Rect, color: Color) {
	for dxf in 0 ..< rect.width {
		for dyf in 0 ..< rect.height {
			dx := int(rect.x) + int(dxf)
			dy := int(rect.y) + int(dyf)

			if dx < 0 || dx >= to.width {
				continue
			}

			if dy < 0 || dy >= to.height {
				continue
			}

			to_idx := dy * to.width + dx
			to.data[to_idx] = color
		}
	}
}

get_image_pixel :: proc(img: Image, x: int, y: int) -> Color {
	idx := img.width * y + x

	if idx < 0 || idx >= len(img.data) {
		return {}
	}

	return img.data[idx]
}

// Returns the format I want for names in atlas.odin. Takes the name from a path
// and turns it from player_jump.png to Player_Jump.
asset_name :: proc(path: string) -> string {
	return fmt.tprintf("%s", strings.to_ada_case(slashpath.name(slashpath.base(path))))
}

load_png_tileset :: proc(filename: string) -> (Tileset, bool) {
	data, data_ok := os.read_entire_file(filename)

	if !data_ok {
		log.error("Failed loading tileset", filename)
		return {}, false
	}

	defer delete(data)

	img, err := png.load_from_bytes(data)

	if err != nil {
		log.error("PNG load error", err)
		return {}, false
	}

	defer png.destroy(img)

	if img.depth != 8 && img.channels != 4 {
		log.error(
			"Only 8 bpp, 4 channels PNG supported (this can probably be fixed by doing some work in `load_png_texture_data`",
		)
		return {}, false
	}

	assert(img.width % TILE_SIZE == 0, "Tileset width is not divisbile by TILE_SIZE!")
	assert(img.height % TILE_SIZE == 0, "Tileset height is not divisbile by TILE_SIZE!")

	t := Tileset {
		pixels              = slice.clone(slice.reinterpret([]Color, img.pixels.buf[:])),
		offset              = {0, 0},
		pixels_size         = {img.width, img.height},
		visible_pixels_size = {img.width, img.height},
	}

	return t, true
}

// Loads a tileset. Currently only supports .ase tilesets
load_tileset :: proc(filename: string) -> (Tileset, bool) {
	data, data_ok := os.read_entire_file(filename)

	if !data_ok {
		log.error("Failed loading tileset", filename)
		return {}, false
	}

	defer delete(data)
	doc: ase.Document

	umerr := ase.unmarshal(&doc, data[:])
	if umerr != nil {
		log.error("Aseprite unmarshal error", umerr)
		return {}, false
	}

	defer ase.destroy_doc(&doc)

	indexed := doc.header.color_depth == .Indexed
	palette: ase.Palette_Chunk
	if indexed {
		for f in doc.frames {
			for c in f.chunks {
				if p, ok := c.(ase.Palette_Chunk); ok {
					palette = p
					break
				}
			}
		}
	}

	if indexed && len(palette.entries) == 0 {
		log.error("Document is indexed, but found no palette!")
	}

	combined_layers := Image {
		data   = make([]Color, int(doc.header.width * doc.header.height)),
		width  = int(doc.header.width),
		height = int(doc.header.height),
	}

	for f in doc.frames {
		for c in f.chunks {
			#partial switch cv in c {
			case ase.Cel_Chunk:
				if cl, ok := cv.cel.(ase.Com_Image_Cel); ok {
					cel_pixels: []Color

					if indexed {
						cel_pixels = make([]Color, int(cl.width) * int(cl.height))
						for p, idx in cl.pixels {
							if p == 0 {
								continue
							}

							cel_pixels[idx] = Color(palette.entries[u32(p)].color)
						}
					} else {
						cel_pixels = slice.reinterpret([]Color, cl.pixels)
					}

					from := Image {
						data   = cel_pixels,
						width  = int(cl.width),
						height = int(cl.height),
					}

					source := Rect{0, 0, int(cl.width), int(cl.height)}

					dest_pos := Vec2i{int(cv.x), int(cv.y)}

					draw_image(&combined_layers, from, source, dest_pos)
				}
			}
		}
	}


	t := Tileset {
		pixels              = combined_layers.data,
		pixels_size         = {combined_layers.width, combined_layers.height},
		visible_pixels_size = {combined_layers.width, combined_layers.height},
	}

	return t, true
}

load_ase_texture_data :: proc(filename: string, textures: ^[dynamic]Texture_Data, animations: ^[dynamic]Animation) {
	data, data_ok := os.read_entire_file(filename)

	if !data_ok {
		return
	}

	doc: ase.Document

	umerr := ase.unmarshal(&doc, data[:])
	if umerr != nil {
		log.error("Aseprite unmarshal error", umerr)
		return
	}

	defer ase.destroy_doc(&doc)

	document_rect := Rect{0, 0, int(doc.header.width), int(doc.header.height)}

	base_name := asset_name(filename)
	frame_idx := 0
	animated := len(doc.frames) > 1
	skip_writing_main_anim := false
	indexed := doc.header.color_depth == .Indexed
	palette: ase.Palette_Chunk
	if indexed {
		for f in doc.frames {
			for c in f.chunks {
				if p, ok := c.(ase.Palette_Chunk); ok {
					palette = p
					break
				}
			}
		}
	}

	if indexed && len(palette.entries) == 0 {
		log.error("Document is indexed, but found no palette!")
	}

	visible_layers := make(map[u16]bool)
	defer delete(visible_layers)
	layer_index: u16
	for f in doc.frames {
		for &c in f.chunks {
			#partial switch &c in c {
			case ase.Layer_Chunk:
				if ase.Layer_Chunk_Flag.Visiable in c.flags {
					visible_layers[layer_index] = true
				}
				layer_index += 1
			}
		}
	}

	if len(visible_layers) == 0 {
		log.error("No visible layers in document", filename)
		return
	}

	for f in doc.frames {
		duration: f32 = f32(f.header.duration) / 1000.0

		cels: [dynamic]^ase.Cel_Chunk
		cel_min := Vec2i{max(int), max(int)}
		cel_max := Vec2i{min(int), min(int)}

		for &c in f.chunks {
			#partial switch &c in c {
			case ase.Cel_Chunk:
				if c.layer_index in visible_layers {
					if cl, ok := &c.cel.(ase.Com_Image_Cel); ok {
						cel_min.x = min(cel_min.x, int(c.x))
						cel_min.y = min(cel_min.y, int(c.y))
						cel_max.x = max(cel_max.x, int(c.x) + int(cl.width))
						cel_max.y = max(cel_max.y, int(c.y) + int(cl.height))
						append(&cels, &c)
					}
				}
			case ase.Tags_Chunk:
				for tag in c {
					a := Animation {
						name           = fmt.tprint(base_name, strings.to_ada_case(tag.name), sep = "_"),
						first_texture  = fmt.tprint(base_name, tag.from_frame, sep = ""),
						last_texture   = fmt.tprint(base_name, tag.to_frame, sep = ""),
						loop_direction = tag.loop_direction,
						repeat         = tag.repeat,
					}

					skip_writing_main_anim = true
					append(animations, a)
				}
			}
		}

		if len(cels) == 0 {
			continue
		}

		slice.sort_by(cels[:], proc(i, j: ^ase.Cel_Chunk) -> bool {
			return i.layer_index < j.layer_index
		})

		s := cel_max - cel_min
		pixels := make([]Color, int(s.x * s.y))

		combined_layers := Image {
			data   = pixels,
			width  = s.x,
			height = s.y,
		}

		for c in cels {
			cl := c.cel.(ase.Com_Image_Cel)
			cel_pixels: []Color

			if indexed {
				cel_pixels = make([]Color, int(cl.width) * int(cl.height))
				for p, idx in cl.pixels {
					if p == 0 {
						continue
					}

					cel_pixels[idx] = Color(palette.entries[u32(p)].color)
				}
			} else {
				cel_pixels = slice.reinterpret([]Color, cl.pixels)
			}

			source := Rect{0, 0, int(cl.width), int(cl.height)}

			from := Image {
				data   = cel_pixels,
				width  = int(cl.width),
				height = int(cl.height),
			}

			dest_pos := Vec2i{int(c.x) - cel_min.x, int(c.y) - cel_min.y}

			draw_image(&combined_layers, from, source, dest_pos)
		}

		cels_rect := Rect{cel_min.x, cel_min.y, s.x, s.y}

		rect_intersect :: proc(r1, r2: Rect) -> Rect {
			x1 := max(r1.x, r2.x)
			y1 := max(r1.y, r2.y)
			x2 := min(r1.x + r1.width, r2.x + r2.width)
			y2 := min(r1.y + r1.height, r2.y + r2.height)
			if x2 < x1 {x2 = x1}
			if y2 < y1 {y2 = y1}
			return {x1, y1, x2 - x1, y2 - y1}
		}

		source_rect := rect_intersect(cels_rect, document_rect)

		td := Texture_Data {
			source_size   = {int(source_rect.width), int(source_rect.height)},
			source_offset = {int(source_rect.x - cels_rect.x), int(source_rect.y - cels_rect.y)},
			pixels_size   = s,
			document_size = {int(doc.header.width), int(doc.header.height)},
			duration      = duration,
			name          = animated ? fmt.tprint(base_name, frame_idx, sep = "") : base_name,
			pixels        = pixels,
		}

		if cel_min.x > 0 {
			td.offset.x = cel_min.x
		}

		if cel_min.y > 0 {
			td.offset.y = cel_min.y
		}

		append(textures, td)
		frame_idx += 1
	}

	if animated && frame_idx > 1 && !skip_writing_main_anim {
		a := Animation {
			name          = base_name,
			first_texture = fmt.tprint(base_name, 0, sep = ""),
			last_texture  = fmt.tprint(base_name, frame_idx - 1, sep = ""),
			document_size = {int(document_rect.width), int(document_rect.height)},
		}

		append(animations, a)
	}
}

load_png_texture_data :: proc(filename: string, textures: ^[dynamic]Texture_Data) {
	data, data_ok := os.read_entire_file(filename)

	if !data_ok {
		log.error("Failed loading tileset", filename)
		return
	}

	defer delete(data)

	img, err := png.load_from_bytes(data)

	if err != nil {
		log.error("PNG load error", err)
		return
	}

	defer png.destroy(img)

	if img.depth != 8 && img.channels != 4 {
		log.error(
			"Only 8 bpp, 4 channels PNG supported (this can probably be fixed by doing some work in `load_png_texture_data`",
		)
		return
	}

	td := Texture_Data {
		source_size   = {img.width, img.height},
		pixels_size   = {img.width, img.height},
		document_size = {img.width, img.height},
		duration      = 0,
		name          = asset_name(filename),
		pixels        = slice.clone(slice.reinterpret([]Color, img.pixels.buf[:])),
	}

	append(textures, td)
}

load_ase_ui_texture_data :: proc(filename: string, textures: ^[dynamic]Texture_Data) {
	data, data_ok := os.read_entire_file(filename)
	if !data_ok {
		return
	}
	defer delete(data)

	doc: ase.Document
	umerr := ase.unmarshal(&doc, data[:])
	if umerr != nil {
		log.error("Aseprite unmarshal error", umerr)
		return
	}
	defer ase.destroy_doc(&doc)

	base_name := asset_name(filename)

	// 1. First, build a map of layer index to layer name for easy lookup.
	layer_map := make(map[u16]ase.Layer_Chunk)
	defer delete(layer_map)
	layer_index: u16 = 0
	for f in doc.frames {
		for &c in f.chunks {
			#partial switch &c in c {
			case ase.Layer_Chunk:
				// Only consider visible layers that are not reference layers.
				if ase.Layer_Chunk_Flag.Visiable in c.flags && ase.Layer_Chunk_Flag.Ref_Layer not_in c.flags {
					layer_map[layer_index] = c
				}
				layer_index += 1
			}
		}
		// We only need to scan for layers once.
		if len(layer_map) > 0 {
			break
		}
	}

	if len(layer_map) == 0 {
		log.error("No visible layers found in UI document", filename)
		return
	}

	// 2. Process each frame and create a texture for each layer's cel.
	for f, frame_idx in doc.frames {
		for &c in f.chunks {
			#partial switch &c in c {
			case ase.Cel_Chunk:
				// Check if this cel belongs to one of our visible layers.
				if layer_chunk, ok := layer_map[c.layer_index]; ok {
					if cl, cel_ok := c.cel.(ase.Com_Image_Cel); cel_ok {
						// We have a valid cel on a visible layer. Create a texture from it.

						// The pixel data for this specific cel.
						cel_pixels := slice.reinterpret([]Color, cl.pixels)

						// The output name will be "Filename_LayerName".
						// If the file is animated, it will be "Filename_LayerName_FrameIndex".
						texture_name := fmt.tprintf("%s_%s", base_name, strings.to_ada_case(layer_chunk.name))
						if len(doc.frames) > 1 {
							texture_name = fmt.tprintf("%s_%v", texture_name, frame_idx)
						}

						td := Texture_Data {
							name          = texture_name,
							pixels        = slice.clone(cel_pixels),
							pixels_size   = {int(cl.width), int(cl.height)},
							source_size   = {int(cl.width), int(cl.height)},
							document_size = {int(doc.header.width), int(doc.header.height)},
							offset        = {int(c.x), int(c.y)}, // The cel's position is the offset.
							duration      = f32(f.header.duration) / 1000.0,
						}
						append(textures, td)
					}
				}
			}
		}
	}
}

dir_path_to_file_infos :: proc(path: string) -> []os.File_Info {
	d, derr := os.open(path, os.O_RDONLY)
	if derr != nil {
		log.panicf("No %s folder found", path)
	}
	defer os.close(d)

	{
		file_info, ferr := os.fstat(d)
		defer os.file_info_delete(file_info)

		if ferr != nil {
			log.panic("stat failed")
		}
		if !file_info.is_dir {
			log.panic("not a directory")
		}
	}

	file_infos, _ := os.read_dir(d, -1)
	return file_infos
}

build_atlas_image :: proc(config: Atlas_Config) -> Atlas_Build_Result {
	log.infof("--- Building Atlas Image: %s ---", config.name)

	// --- 1. Load Assets based on config type ---
	textures: [dynamic]Texture_Data
	animations: [dynamic]Animation
	tilesets: [dynamic]Tileset
	glyphs: []Glyph // This is temporary for font loading

	// (The asset loading logic is the same as your original file, but scoped to the config)
	switch config.type {
	case .Game:
		file_infos := dir_path_to_file_infos(config.input_dir)
		slice.sort_by(
			file_infos,
			proc(i, j: os.File_Info) -> bool {return time.diff(i.creation_time, j.creation_time) > 0},
		)
		for fi in file_infos {
			is_ase := strings.has_suffix(fi.name, ".ase") || strings.has_suffix(fi.name, ".aseprite")
			is_png := strings.has_suffix(fi.name, ".png")
			if is_ase || is_png {
				path := fmt.tprintf("%s/%s", config.input_dir, fi.name)
				if strings.has_prefix(fi.name, "tileset") {
					t: Tileset
					t_ok: bool
					if is_ase {
						t, t_ok = load_tileset(path)
					} else {
						t, t_ok = load_png_tileset(path)
					}
					// t, t_ok := is_ase ? load_tileset(path) : load_png_tileset(path)
					if t_ok {t.name = slashpath.name(fi.name); append(&tilesets, t)}
				} else if is_ase {
					load_ase_texture_data(path, &textures, &animations)
				} else if is_png {
					load_png_texture_data(path, &textures)
				}
			}
		}
	case .UI:
		file_infos := dir_path_to_file_infos(config.input_dir)
		for fi in file_infos {
			if strings.has_suffix(fi.name, ".ase") || strings.has_suffix(fi.name, ".aseprite") {
				path := fmt.tprintf("%s/%s", config.input_dir, fi.name)
				load_ase_ui_texture_data(path, &textures)
			}
		}
	case .Glyphs:
		font_file_infos := dir_path_to_file_infos(config.input_dir)

		font_datas: [dynamic][]u8; defer {for d in font_datas {delete(d)}}
		font_infos: [dynamic]stbtt.fontinfo

		for fi in font_file_infos {
			if !strings.has_suffix(fi.name, ".ttf") {
				continue
			}

			font_path := fmt.tprintf("%s/%s", config.input_dir, fi.name)
			if data, ok := os.read_entire_file(font_path); ok {
				append(&font_datas, data)

				info: stbtt.fontinfo
				if stbtt.InitFont(&info, raw_data(data), 0) {
					append(&font_infos, info)
					log.infof("Loaded font: %s", fi.name)
				}
			}
		}

		if len(font_infos) == 0 {
			log.warnf("No .ttf files found in %s", config.input_dir)

		} else {

			letters := utf8.string_to_runes(LETTERS_IN_FONT)
			glyphs = make([]Glyph, len(letters))

			for r, r_idx in letters {
				glyph_found_in_any_font := false

				// Iterate through all loaded fonts to find one that has the glyph
				for &fi in font_infos {
					glyph_index := stbtt.FindGlyphIndex(&fi, r)
					if glyph_index != 0 {
						// Found a font with the glyph, render it and move to the next character
						scale_factor := stbtt.ScaleForPixelHeight(&fi, FONT_SIZE)
						ascent: c.int; stbtt.GetFontVMetrics(&fi, &ascent, nil, nil)

						w, h, ox, oy: c.int
						data := stbtt.GetCodepointBitmap(&fi, scale_factor, scale_factor, r, &w, &h, &ox, &oy)

						advance_x: c.int
						stbtt.GetCodepointHMetrics(&fi, r, &advance_x, nil)

						rgba_data := make([]Color, w * h)
						for i in 0 ..< w * h {rgba_data[i] = {255, 255, 255, data[i]}}

						glyphs[r_idx] = {
							image = {data = rgba_data, width = int(w), height = int(h)},
							value = r,
							offset = {int(ox), int(f32(oy) + f32(ascent) * scale_factor)},
							advance_x = int(f32(advance_x) * scale_factor),
						}

						glyph_found_in_any_font = true
						break // Exit the font search loop
					}
				}

				if !glyph_found_in_any_font {
					log.warnf("Character '%c' (U+%04X) not found in any provided font.", r, r)
				}
			}
		}
	}

	// --- 2. Pack Rects ---
	// (This entire section is identical to your original file, using config.size)
	rc: stbrp.Context
	rc_nodes := make([]stbrp.Node, config.size); defer delete(rc_nodes)
	stbrp.init_target(&rc, i32(config.size), i32(config.size), raw_data(rc_nodes[:]), i32(len(rc_nodes)))
	Pack_Rect_Type :: enum {
		Texture,
		Glyph,
		Tile,
		ShapesTexture,
	}
	Pack_Rect_Item :: struct {
		type:      Pack_Rect_Type,
		idx, x, y: int,
	}
	pack_rects: [dynamic]stbrp.Rect; pack_rects_items: [dynamic]Pack_Rect_Item
	for r, r_idx in glyphs {
		// log.debugf("Glyph U+%04X size: %dx%d", r.value, r.image.width, r.image.height)
		append(
			&pack_rects,
			stbrp.Rect {
				id = i32(len(pack_rects_items)),
				w = stbrp.Coord(r.image.width) + 2,
				h = stbrp.Coord(r.image.height) + 2,
			},
		)
		append(&pack_rects_items, Pack_Rect_Item{type = .Glyph, idx = r_idx})
	}
	for t, idx in textures {
		append(
			&pack_rects,
			stbrp.Rect {
				id = i32(len(pack_rects_items)),
				w = stbrp.Coord(t.source_size.x) + 1,
				h = stbrp.Coord(t.source_size.y) + 1,
			},
		)
		append(&pack_rects_items, Pack_Rect_Item{type = .Texture, idx = idx})
	}
	for &t, idx in tilesets {
		if t.pixels_size.x != 0 && t.pixels_size.y != 0 {
			h := t.pixels_size.y / TILE_SIZE
			w := t.pixels_size.x / TILE_SIZE
			top_left := -t.offset

			t_img := Image {
				data   = t.pixels,
				width  = t.pixels_size.x,
				height = t.pixels_size.y,
			}

			for x in 0 ..< w {
				for y in 0 ..< h {
					tx := TILE_SIZE * x + top_left.x
					ty := TILE_SIZE * y + top_left.y

					all_blank := true
					txx_loop: for txx in tx ..< tx + TILE_SIZE {
						for tyy in ty ..< ty + TILE_SIZE {
							if get_image_pixel(t_img, int(txx), int(tyy)) != {} {
								all_blank = false
								break txx_loop
							}
						}
					}

					if all_blank {
						continue
					}

					pad: stbrp.Coord = TILE_ADD_PADDING ? 3 : 1

					append(
						&pack_rects,
						stbrp.Rect{id = i32(len(pack_rects_items)), w = TILE_SIZE + pad, h = TILE_SIZE + pad},
					)

					append(&pack_rects_items, Pack_Rect_Item{type = .Tile, idx = idx, x = x, y = y})
				}
			}
		}
	}
	append(&pack_rects, stbrp.Rect{id = i32(len(pack_rects_items)), w = 11, h = 11})
	append(&pack_rects_items, Pack_Rect_Item{type = .ShapesTexture})
	if stbrp.pack_rects(&rc, raw_data(pack_rects), i32(len(pack_rects))) != 1 {
		log.errorf("Failed to pack some rects for atlas '%s'. Size of %d may be too small.", config.name, config.size)
	}

	// --- 3. Draw Atlas Image & Collect Metadata ---
	result: Atlas_Build_Result; result.config = config
	result.animations = animations
	result.tilesets = tilesets
	atlas_pixels := make([]Color, config.size * config.size); defer delete(atlas_pixels)
	atlas := Image {
		data   = atlas_pixels,
		width  = config.size,
		height = config.size,
	}
	for rp in pack_rects {
		item := pack_rects_items[rp.id]

		switch item.type {
		case .ShapesTexture:
			result.shapes_rect = Rect{int(rp.x), int(rp.y), 10, 10}
			draw_image_rectangle(&atlas, result.shapes_rect, {255, 255, 255, 255})
		case .Texture:
			idx := item.idx
			t := textures[idx]
			t_img := Image {
				data   = t.pixels,
				width  = t.pixels_size.x,
				height = t.pixels_size.y,
			}
			source := Rect{t.source_offset.x, t.source_offset.y, t.source_size.x, t.source_size.y}
			draw_image(&atlas, t_img, source, {int(rp.x), int(rp.y)})
			atlas_rect := Rect{int(rp.x), int(rp.y), source.width, source.height}
			offset_right := t.document_size.x - (atlas_rect.width + t.offset.x)
			offset_bottom := t.document_size.y - (atlas_rect.height + t.offset.y)
			ar := Atlas_Texture_Rect {
				rect          = atlas_rect,
				size          = t.document_size,
				offset_top    = t.offset.y,
				offset_right  = offset_right,
				offset_bottom = offset_bottom,
				offset_left   = t.offset.x,
				name          = t.name,
				duration      = t.duration,
			}
			append(&result.textures, ar)
		case .Glyph:
			idx := item.idx
			g := glyphs[idx]
			img := g.image
			source := Rect{0, 0, img.width, img.height}
			dest := Rect{int(rp.x) + 1, int(rp.y) + 1, source.width, source.height}
			draw_image(&atlas, img, source, {dest.x, dest.y})
			ag := Atlas_Glyph {
				rect  = dest,
				glyph = g,
			}
			append(&result.glyphs, ag)
		case .Tile:
			ix, iy := item.x, item.y
			tileset := &result.tilesets[item.idx]
			x := TILE_SIZE * ix
			y := TILE_SIZE * iy
			top_left := -tileset.offset
			t_img := Image {
				data   = tileset.pixels,
				width  = tileset.pixels_size.x,
				height = tileset.pixels_size.y,
			}
			source := Rect{x + top_left.x, y + top_left.y, TILE_SIZE, TILE_SIZE}
			offset := TILE_ADD_PADDING == true ? 1 : 0
			dest := Rect{int(rp.x) + offset, int(rp.y) + offset, source.width, source.height}
			draw_image(&atlas, t_img, source, {dest.x, dest.y})
			when TILE_ADD_PADDING {
				ts :: TILE_SIZE
				{psource := Rect{source.x, source.y, ts, 1}; draw_image(&atlas, t_img, psource, {dest.x, dest.y - 1})}
				{psource := Rect{source.x, source.y + ts - 1, ts, 1}
					draw_image(&atlas, t_img, psource, {dest.x, dest.y + ts})}
				{psource := Rect{source.x, source.y, 1, ts}; draw_image(&atlas, t_img, psource, {dest.x - 1, dest.y})}
				{psource := Rect{source.x + ts - 1, source.y, 1, ts}
					draw_image(&atlas, t_img, psource, {dest.x + ts, dest.y})}
			}
			at := Atlas_Tile_Rect {
				rect  = dest,
				coord = {ix, iy},
			}
			append(&tileset.packed_rects, at)
		}
	}

	// --- 4. Crop and Write PNG ---
	// (This is the same, but uses config for paths and a local context for the callback)
	result.cropped_size = {config.size, config.size}
	if config.crop {
		max_x, max_y: int
		for c, ci in atlas_pixels {
			x := ci % config.size
			y := ci / config.size
			if c != {} {
				if x > max_x {max_x = x}
				if y > max_y {max_y = y}
			}
		}
		result.cropped_size.x = max_x + 1
		result.cropped_size.y = max_y + 1
	}

	img_write_context := struct {
		path: string,
	}{config.output_png_path}
	img_write :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
		context = default_context
		write_ctx := cast(^struct {
			path: string,
		})ctx
		dir := slashpath.dir(write_ctx.path); if dir != "" {os.make_directory(dir)}
		os.write_entire_file(write_ctx.path, slice.bytes_from_ptr(data, int(size)))
	}
	stbim.write_png_to_func(
		img_write,
		&img_write_context,
		c.int(result.cropped_size.x),
		c.int(result.cropped_size.y),
		4,
		raw_data(atlas_pixels),
		i32(config.size * size_of(Color)),
	)

	log.infof("%s created.", config.output_png_path)
	return result
}

write_consolidated_odin_file :: proc(results: []Atlas_Build_Result) {
	log.info("--- Writing Consolidated Atlas Odin File ---")

	if len(results) == 0 {
		return
	}
	output_path := ATLAS_ODIN_OUTPUT_PATH
	package_name := PACKAGE_NAME

	f, f_err := os.open(output_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
	if f_err != nil {
		log.errorf("Failed to open output file for writing: %s", output_path)
		return
	}
	defer os.close(f)

	// --- 1. Write Header and Common Structs ---
	fmt.fprintln(f, "// This file is generated by running the atlas_builder.")
	fmt.fprintf(f, "package %s\n\n", package_name)
	fmt.fprintln(f, "// import \"core:slice\"")
	fmt.fprintln(f, "")
	fmt.fprintln(f, "/*\nNote: This file assumes the existence of a type Rect... (rest of comment)\n*/\n")

	fmt.fprintln(f, "Atlas_Texture :: struct {")
	fmt.fprintln(f, "\trect:          Rect,")
	fmt.fprintln(f, "\tuvs:           [4]f32,")
	fmt.fprintln(f, "\toffset_top:    f32,")
	fmt.fprintln(f, "\toffset_right:  f32,")
	fmt.fprintln(f, "\toffset_bottom: f32,")
	fmt.fprintln(f, "\toffset_left:   f32,")
	fmt.fprintln(f, "\tdocument_size: [2]f32,")
	fmt.fprintln(f, "\tduration:      f32,")
	fmt.fprintln(f, "}\n")

	fmt.fprintln(f, "Tag_Loop_Dir :: enum { Forward, Reverse, Ping_Pong, Ping_Pong_Reverse }\n")

	// --- 2. Write Consolidated Enums ---
	fmt.fprintln(f, "Texture_Name :: enum { None,")
	for result in results {
		for t in result.textures {
			fmt.fprintf(f, "\t%s,\n", t.name)
		}
	}
	fmt.fprintln(f, "}\n")

	fmt.fprintln(f, "Animation_Name :: enum { None,")
	for result in results {
		for a in result.animations {
			fmt.fprintf(f, "\t%s,\n", a.name)
		}
	}
	fmt.fprintln(f, "}\n")

	// --- 3. Write Structs that depend on Enums ---
	fmt.fprintln(f, "Atlas_Animation :: struct {")
	fmt.fprintln(f, "\tfirst_frame:     Texture_Name,")
	fmt.fprintln(f, "\tlast_frame:      Texture_Name,")
	fmt.fprintln(f, "\tdocument_size:   [2]f32,")
	fmt.fprintln(f, "\tloop_direction:  Tag_Loop_Dir,")
	fmt.fprintln(f, "\trepeat:          u16,")
	fmt.fprintln(f, "}\n")

	fmt.fprintfln(f, "Tile :: struct {{ rect: Rect, uvs: [4]f32 }}\n")

	fmt.fprintln(f, "Atlas_Glyph :: struct {")
	fmt.fprintln(f, "\trect:      Rect,")
	fmt.fprintln(f, "\tuvs:       [4]f32,")
	fmt.fprintln(f, "\tvalue:     rune,")
	fmt.fprintln(f, "\toffset_x:  int,")
	fmt.fprintln(f, "\toffset_y:  int,")
	fmt.fprintln(f, "\tadvance_x: int,")
	fmt.fprintln(f, "}\n")

	// --- 4. Write Constants for each Atlas ---
	for result in results {
		atlas_name_upper := strings.to_upper(result.config.name)
		cropped_size := result.cropped_size
		shapes_rect := result.shapes_rect

		fmt.fprintf(f, "// --- Atlas: %s ---\n", result.config.name)
		fmt.fprintf(f, "%s_ATLAS_FILENAME :: \"%s\"\n", atlas_name_upper, result.config.output_png_path)
		fmt.fprintfln(f, "%s_ATLAS_SIZE :: [2]int{{%v, %v}}", atlas_name_upper, cropped_size.x, cropped_size.y)

		if result.config.type == .Glyphs {
			fmt.fprintf(f, "ATLAS_FONT_SIZE :: %v\n", FONT_SIZE)
			fmt.fprintf(f, "LETTERS_IN_FONT :: \"%s\"\n", LETTERS_IN_FONT)
		}

		fmt.fprintfln(
			f,
			"%s_SHAPES_TEXTURE_RECT :: Rect{{%v, %v, %v, %v}}",
			atlas_name_upper,
			shapes_rect.x,
			shapes_rect.y,
			shapes_rect.width,
			shapes_rect.height,
		)
		fmt.fprintfln(
			f,
			"%s_SHAPES_TEXTURE_UVS :: [4]f32{{%v, %v, %v, %v}}\n",
			atlas_name_upper,
			f32(shapes_rect.x) / f32(cropped_size.x),
			f32(shapes_rect.y) / f32(cropped_size.y),
			f32(shapes_rect.x + shapes_rect.width) / f32(cropped_size.x),
			f32(shapes_rect.y + shapes_rect.height) / f32(cropped_size.y),
		)
	}

	// --- 5. Write Consolidated Maps ---
	fmt.fprintln(f, "// --- Consolidated Maps ---")
	fmt.fprintln(f, "atlas_textures := [Texture_Name]Atlas_Texture {")
	fmt.fprintln(f, "\t.None = {},")
	for result in results {
		cropped_size := result.cropped_size
		for t in result.textures {
			fmt.fprintfln(
				f,
				"\t.%s = {{ rect = {{%v, %v, %v, %v}}, uvs = {{%v, %v, %v, %v}}, offset_top = %v, offset_right = %v, offset_bottom = %v, offset_left = %v, document_size = {{%v, %v}}, duration = %f}},",
				t.name,
				t.rect.x,
				t.rect.y,
				t.rect.width,
				t.rect.height,
				f32(t.rect.x) / f32(cropped_size.x),
				f32(t.rect.y) / f32(cropped_size.y),
				f32(t.rect.x + t.rect.width) / f32(cropped_size.x),
				f32(t.rect.y + t.rect.height) / f32(cropped_size.y),
				t.offset_top,
				t.offset_right,
				t.offset_bottom,
				t.offset_left,
				t.size.x,
				t.size.y,
				t.duration,
			)
		}
	}
	fmt.fprintln(f, "}\n")

	fmt.fprintln(f, "atlas_animations := [Animation_Name]Atlas_Animation {")
	fmt.fprintln(f, "\t.None = {},")
	for result in results {
		for a in result.animations {
			fmt.fprintfln(
				f,
				"\t.%s = {{ first_frame = .%s, last_frame = .%s, loop_direction = .%s, repeat = %v, document_size = {{%v, %v}} }},",
				a.name,
				a.first_texture,
				a.last_texture,
				a.loop_direction,
				a.repeat,
				a.document_size.x,
				a.document_size.y,
			)
		}
	}
	fmt.fprintln(f, "}\n")

	// --- 6. Write Tileset and Glyph Data ---
	fmt.fprintln(f, "// --- Tilesets and Glyphs ---")
	for result in results {
		if len(result.tilesets) > 0 {
			cropped_size := result.cropped_size
			for t in result.tilesets {
				w := t.pixels_size.x / TILE_SIZE
				h := t.pixels_size.y / TILE_SIZE
				map_name := fmt.tprintf("%s", t.name)
				fmt.fprintfln(f, "// The rect inside the atlas where each tile has ended up.")
				fmt.fprintfln(f, "// Index using %s[x][y].", map_name)
				fmt.fprintfln(f, "%s := [%v][%v]Tile {{", map_name, w, h)

				slice.sort_by(t.packed_rects[:], proc(i, j: Atlas_Tile_Rect) -> bool {
					if i.coord.x == j.coord.x {return i.coord.y < j.coord.y}
					return i.coord.x < j.coord.x
				})

				current_col := -1
				for p in t.packed_rects {
					if p.coord.x != current_col {
						if current_col != -1 {fmt.fprint(f, "\t},\n")}
						fmt.fprintfln(f, "\t%v = {{", p.coord.x)
						current_col = p.coord.x
					}
					fmt.fprintfln(
						f,
						"\t\t%v = {{rect = {{%v, %v, %v, %v}}, uvs = {{%v, %v, %v, %v}}}},",
						p.coord.y,
						p.rect.x,
						p.rect.y,
						p.rect.width,
						p.rect.height,
						f32(p.rect.x) / f32(cropped_size.x),
						f32(p.rect.y) / f32(cropped_size.y),
						f32(p.rect.x + p.rect.width) / f32(cropped_size.x),
						f32(p.rect.y + p.rect.height) / f32(cropped_size.y),
					)
				}
				if len(t.packed_rects) > 0 {
					fmt.fprint(f, "\t},\n")
				}
				fmt.fprintln(f, "}\n")
			}
		}

		if len(result.glyphs) > 0 {
			fmt.fprintln(f, "atlas_glyphs: []Atlas_Glyph = {")
			for g in result.glyphs {
				fmt.fprintfln(
					f,
					"\t{{ rect = {{%v, %v, %v, %v}}, uvs = {{%v, %v, %v, %v}}, value = %q, offset_x = %v, offset_y = %v, advance_x = %v}},",
					g.rect.x,
					g.rect.y,
					g.rect.width,
					g.rect.height,
					f32(g.rect.x) / f32(result.cropped_size.x),
					f32(g.rect.y) / f32(result.cropped_size.y),
					f32(g.rect.x + g.rect.width) / f32(result.cropped_size.x),
					f32(g.rect.y + g.rect.height) / f32(result.cropped_size.y),
					g.glyph.value,
					g.glyph.offset.x,
					g.glyph.offset.y,
					g.glyph.advance_x,
				)
			}
			fmt.fprintln(f, "}\n")
		}
	}

	log.infof("%s created.", output_path)
}

default_context: runtime.Context

main :: proc() {
	context.logger = log.create_console_logger(opt = {.Level})
	default_context = context
	start_time := time.now()

	// 1. Build all atlas images and collect their metadata
	results: [dynamic]Atlas_Build_Result
	defer delete(results)
	for config in ATLAS_CONFIGS {
		result := build_atlas_image(config)
		append(&results, result)
	}

	// 2. Write a single Odin file containing all collected metadata
	write_consolidated_odin_file(results[:])

	run_time_ms := time.duration_milliseconds(time.diff(start_time, time.now()))
	log.infof(ATLAS_PNG_OUTPUT_PATH + " and " + ATLAS_ODIN_OUTPUT_PATH + " created in %.2f ms", run_time_ms)
}
