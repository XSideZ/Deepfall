extends Node3D
## In-game level editor for DeepFall.
## Three modes: PLACE props, SCULPT terrain, DELETE props.
## Fly with RMB+WASD. Save/Load writes the map + heightmap to user://.

const AssetLibraryScript := preload("res://scripts/editor/AssetLibrary.gd")
const EditorCameraScript := preload("res://scripts/editor/EditorCamera.gd")
const TerrainScript := preload("res://scripts/editor/Terrain.gd")
const TestPlayerScript := preload("res://scripts/editor/TestPlayer.gd")
const FloraScatterScript := preload("res://scripts/editor/FloraScatter.gd")
const ResourceScatterScript := preload("res://scripts/editor/ResourceScatter.gd")
const HomeTreeScript := preload("res://scripts/editor/HomeTree.gd")
const TreeInteriorScript := preload("res://scripts/editor/TreeInterior.gd")
const PortalPairScript := preload("res://scripts/editor/PortalPair.gd")
const GameAudioScript := preload("res://scripts/editor/GameAudio.gd")
const BuildSystemScript := preload("res://scripts/editor/BuildSystem.gd")

const SAVE_PATH := "user://deepfall_map.json"
const HEIGHTS_PATH := "user://deepfall_heights.bin"
const SETTINGS_PATH := "user://editor_settings.json"
# skies: assets/sky/*.png|hdr are auto-discovered and cycled by the Sky button
const GROUND_LAYER := 1
const PROP_LAYER := 2

const SIZES := { "Small": 256, "Medium": 512, "Large": 768, "Huge": 1536 }

# modes
const MODE_PLACE := 0
const MODE_SCULPT := 1
const MODE_DELETE := 2
const MODE_FOG := 3

var lib
var camera
var terrain
var flora
var flora_density := 100   # percent
var carpets: Array = []    # dense GPU ground-cover layers (land + sea)
var resource_scatter
var rock_count := 60
var tree_count := 50
var crystal_count := 30
var coral_count := 45
var starfish_count := 20
var kelp_count := 60
var satellite_count := 10
var water_debounce: Timer
var meteor_timer: Timer
var _underwater := false

# weather: rain raises the tide above the base water level; dry spells pull it back
var weather_offset := 0.0
var game_mode                    # GameMode node when Session.mode == "game", else null
var _game_bloom := 1.0           # editor default = fully lush
var rain_intensity := 0.0     # 0 = dry, 1 = full storm
var rain_time_left := 0.0
var rain_duration := 0.0
var rain_timer: Timer
var rain_fx: GPUParticles3D
var rain_splash: GPUParticles3D
var underwater_bubbles: GPUParticles3D
var god_rays: Node3D
var _rain_mix := 0.0
var _last_eff_water := -1e9

# home-tree / interior (the base-building concept)
const INTERIOR_ORIGIN := Vector3(0, -500, 0)
var home_tree
var tree_interior
var portal_pair
var in_interior := false
var _plant_pos := Vector3.INF
var interact_label: Label

# inventory: "spore sacs" that swell as the alien absorbs matter
const RES_COLORS := {
	"Stone": Color(0.72, 0.72, 0.75), "Wood": Color(0.65, 0.42, 0.22),
	"Quartz": Color(0.85, 0.92, 1.0), "Crystal": Color(0.35, 0.70, 1.0),
	"Coral": Color(1.0, 0.55, 0.45),
	"Biomass": Color(0.50, 1.0, 0.60), "Metal": Color(0.80, 0.82, 0.90),
	"Shard": Color(1.0, 0.22, 0.14), "Fruit": Color(1.0, 0.52, 0.62), "Shell": Color(0.95, 0.88, 0.78),
}
const INV_BASE := 20
var inv_capacity := 20           # +8 per Storage sac room
var inv_slots: Array = []        # entries: null or { "type": String, "count": int }
var inv_box: HBoxContainer
var inv_pods := {}
var inv_panel: PanelContainer
var inv_grid: GridContainer
var _drag_from := -1             # slot being dragged (drag & drop)
var _drag_preview: Label

# growth terminal UI (bird's-eye home map + seed crafting)
const TERM_MAP_SIZE := Vector2(460, 340)
const SEED_NAMES := ["Small pod", "Grand pod", "Stairwell", "Storage sac", "Refinery gland"]
const SEED_COSTS := [
	{ "Stone": 6 },                   # Small pod
	{ "Stone": 12, "Quartz": 4 },     # Grand pod
	{ "Wood": 8, "Stone": 4 },        # Stairwell
	{ "Wood": 10 },                   # Storage sac (+8 spore slots)
	{ "Stone": 8, "Metal": 4 },       # Refinery gland (5 Stone -> 2 Metal)
]
var term_panel: PanelContainer
var term_map: Control
var term_craft_btns: Array = []
var held_seed := -1              # crafted upgrade seed being carried (-1 = none)
var fog_density_setting := 0.0011
var fog_enabled_setting := true   # aerial perspective on by default — soft horizon
var player
var props_root: Node3D
var fog_root: Node3D
var preview: Node3D
var water: MeshInstance3D
var brush_ring: MeshInstance3D
var brush_torus: TorusMesh
var terrain_material: ShaderMaterial
var world_env: WorldEnvironment
var env_sky: Sky
var sun: DirectionalLight3D
var sky_mode := "space"
var sky_button: Button
var time_button: Button
var audio
var testing := false

# base building (Ark/Rust-style): hold Q for the radial menu, LMB places the ghost
const DEMOLISH := 99
const MODULE_BASE := 1000   # build_piece >= this selects build.modules[i - MODULE_BASE]
var build
var build_menu: Control
var build_menu_open := false
var build_piece := -1        # piece selected (-1 none, DEMOLISH = wrecking mode)
var _build_valid := false

# day/night cycle: phase 0 = sunrise, 0.25 = noon, 0.5 = sunset, 0.75 = midnight.
# Days are long, nights short and punchy.
const DAY_SECONDS := 420.0    # 7 min of daylight
const NIGHT_SECONDS := 120.0  # 2 min of night
var cycle_enabled := true
var day_phase := 0.28
var _day_f := 1.0        # 0 = night, 1 = full noon (drives LUX photosynthesis)

# survival meters (the alien's needs)
var sap := 100.0         # hydration
var lux := 100.0         # light / photosynthesis charge
var bio := 100.0         # nutrients
var meter_fills := {}
var _meter_warned := {}

var mode := MODE_PLACE
var current_id := ""
var current_rot_deg := 0.0
var current_scale := 1.0
var grid_size := 512
var undo_stack: Array[Node3D] = []

# sculpt state
var sculpt_tool := 0            # Terrain.RAISE/LOWER/SMOOTH/FLATTEN
var brush_radius := 8.0
var brush_strength := 14.0
var water_level := -1.0
var _sculpt_target := 0.0

# local fog
var local_fog_size := 60.0
var local_fog_density := 0.4


# UI
var ui_layer: CanvasLayer
var test_layer: CanvasLayer
var palette_panel: PanelContainer
var sculpt_panel: PanelContainer
var fog_panel: PanelContainer
var palette_box: VBoxContainer
var mode_buttons := {}
var tool_buttons := {}
var hint_label: Label
var flash_label: Label
var crosshair: Label
var import_dialog: FileDialog

func _ready() -> void:
	_load_settings()
	inv_slots.resize(inv_capacity)
	lib = AssetLibraryScript.new()
	lib.build()

	_setup_environment()
	Settings.apply_viewport(get_viewport())

	props_root = Node3D.new()
	props_root.name = "Props"
	add_child(props_root)

	fog_root = Node3D.new()
	fog_root.name = "FogVolumes"
	add_child(fog_root)

	_setup_terrain_material()
	_build_terrain(grid_size)
	flora = FloraScatterScript.new()
	add_child(flora)
	# dense near-field carpets, layered like the refs: short lawn + tall wisps +
	# clover on land; seagrass + leafy anemone-ish clusters below the waves
	var GrassCarpetScript := load("res://scripts/editor/GrassCarpet.gd")
	var layer_specs := [
		[0, "Grass_Common_Short.fbx", 0.68, 54.0, 0.5],
		[0, "Grass_Wispy_Tall.fbx", 1.5, 46.0, 0.85],
		[0, "Clover_1.fbx", 1.9, 30.0, 0.16],
		[1, "Grass_Common_Short.fbx", 0.95, 42.0, 0.62],
		[1, "Plant_1.fbx", 2.6, 38.0, 0.75],
	]
	for spec in layer_specs:
		var c = GrassCarpetScript.new()
		add_child(c)
		c.setup(spec[0], spec[1], spec[2], spec[3], spec[4])
		carpets.append(c)
	resource_scatter = ResourceScatterScript.new()
	add_child(resource_scatter)
	resource_scatter.setup(self)
	resource_scatter.yield_tree = get_tree()   # rescatters yield frames (no freezes)
	water_debounce = Timer.new()
	water_debounce.one_shot = true
	water_debounce.wait_time = 0.4
	water_debounce.timeout.connect(_scatter_resources)
	add_child(water_debounce)
	meteor_timer = Timer.new()
	meteor_timer.one_shot = true
	meteor_timer.timeout.connect(_meteor_shower)
	add_child(meteor_timer)
	# first shower comes quickly so it's actually seen; later ones are spaced out
	meteor_timer.wait_time = randf_range(35.0, 60.0)
	meteor_timer.start()
	rain_timer = Timer.new()
	rain_timer.one_shot = true
	rain_timer.timeout.connect(_start_rain)
	rain_timer.wait_time = randf_range(90.0, 180.0)
	add_child(rain_timer)
	rain_timer.start()
	_setup_rain_fx()
	audio = GameAudioScript.new()
	add_child(audio)
	audio.setup(self)
	build = BuildSystemScript.new()
	add_child(build)
	build.setup(terrain)
	_setup_water()
	_setup_brush_ring()

	camera = EditorCameraScript.new()
	camera.position = Vector3(0, 80, 150)
	camera.rotation_degrees = Vector3(-28, 0, 0)
	add_child(camera)
	camera.current = true

	_build_ui()
	_set_mode(MODE_PLACE)

	if not lib.items.is_empty():
		_set_current(lib.items[0].id)

	if _is_game_mode():
		# hand the world over to the barren->bloom game controller
		ui_layer.visible = false
		var GameModeScript := load("res://scripts/game/GameMode.gd")
		game_mode = GameModeScript.new()
		add_child(game_mode)
		await game_mode.setup(self)
	else:
		_grow_grass()
		_scatter_resources()

func _is_game_mode() -> bool:
	var s = _session()
	return s != null and s.mode == "game"

func _session():
	# Session is an autoload; guard so the editor scene still runs if launched alone
	if has_node("/root/Session"):
		return get_node("/root/Session")
	return null

# --- world ------------------------------------------------------------------

func _setup_environment() -> void:
	var env := Environment.new()
	env_sky = Sky.new()
	env.sky = env_sky
	env.background_mode = Environment.BG_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC   # filmic keeps hues saturated as they brighten
	env.tonemap_exposure = 1.25
	env.tonemap_white = 6.0   # soft highlight rolloff — snow/sand/water stop clipping to flat white

	# lighting "life": vivid bloom (sun glitter on water, crystal glow) + punchy colour
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.22
	env.adjustment_contrast = 1.04
	# soft contact shadows ground the props/terrain
	env.ssao_enabled = true
	env.ssao_intensity = 1.5
	# screen-space bounce light: grass glows green near grass, warmth pools in valleys
	env.ssil_enabled = true
	env.ssil_intensity = 1.1
	Settings.apply_env(env)   # user post-fx toggles (ssao/ssil/glow) win
	# punchier stylized grade (Planet Crafter ref): saturated colours, gentle contrast
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.14
	env.adjustment_contrast = 1.03

	# global distance fog (OFF by default; toggle in the Fog panel). Tuned as sky-tinted
	# aerial haze: distant land fades toward the horizon colour, sky stays crisp.
	env.fog_enabled = fog_enabled_setting
	env.fog_light_color = Color(0.70, 0.85, 0.95)   # re-tinted per frame by the compositor
	env.fog_density = fog_density_setting
	env.fog_sky_affect = 0.0          # fog eats terrain into the sky, never the sky itself
	env.fog_aerial_perspective = 0.6  # distant land shifts toward sky colour = depth cue
	env.fog_sun_scatter = 0.12
	env.fog_aerial_perspective = 0.85
	env.fog_sky_affect = 0.25
	# volumetric fog so local FogVolumes render (0 global density = only placed patches)
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0
	env.volumetric_fog_albedo = Color(0.9, 0.93, 0.97)

	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.light_volumetric_fog_energy = 3.2   # strong underwater god rays
	sun.rotation_degrees = Vector3(-52, -42, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 220.0   # mountains keep their shadows at range
	sun.shadow_blur = 2.2                          # softer, friendlier shadow edges
	sun.light_angular_distance = 1.1               # gentle penumbra (higher was noisy/"tweaky" underwater)
	add_child(sun)

	_apply_sky()

## Every panorama in assets/sky becomes a cyclable sky (Jay's skybox collection).
func _sky_panoramas() -> Array:
	var out: Array = []
	var d := DirAccess.open("res://assets/sky")
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var ext := f.get_extension().to_lower()
		if not d.current_is_dir() and (ext == "png" or ext == "jpg" or ext == "hdr" or ext == "exr"):
			out.append("res://assets/sky/" + f)
		f = d.get_next()
	d.list_dir_end()
	out.sort()
	return out

func _apply_sky() -> void:
	var env := world_env.environment
	if sky_mode == "space":
		var sm := ShaderMaterial.new()
		sm.shader = load("res://scripts/editor/space_sky.gdshader")
		env_sky.sky_material = sm
		# space sky gives no useful ambient, so we drive lighting ourselves (day/night)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	elif sky_mode.begins_with("pano:"):
		var path := "res://assets/sky/" + sky_mode.substr(5)
		if ResourceLoader.exists(path):
			# panorama + the LIVE sun disc + day/night dimming (pano_sky shader)
			var pano_sm := ShaderMaterial.new()
			pano_sm.shader = load("res://scripts/editor/pano_sky.gdshader")
			pano_sm.set_shader_parameter("pano", load(path))
			env_sky.sky_material = pano_sm
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		else:
			sky_mode = "dynamic"
			env_sky.sky_material = PhysicalSkyMaterial.new()
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	else:
		env_sky.sky_material = PhysicalSkyMaterial.new()  # dynamic, sun-synced
		sky_mode = "dynamic"
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	if sky_button:
		var label := sky_mode
		if sky_mode.begins_with("pano:"):
			label = sky_mode.substr(5).get_basename().replace("_2k", "")
		sky_button.text = "Sky: " + label.capitalize()
	_apply_lighting()

## Lighting is driven per-frame by the day/night compositor (_update_daynight).
func _apply_lighting() -> void:
	if time_button:
		time_button.text = "Cycle: " + ("On" if cycle_enabled else "Paused")
	_update_daynight(0.0)

## The compositor: sun orbit + colours from the day phase, with storm/rain darkness
## layered on top. Runs every frame; every sky/sun write lives HERE (no tween fights).
func _update_daynight(delta: float) -> void:
	if sun == null or world_env == null:
		return
	if cycle_enabled:
		# asymmetric clock: the day half runs slow, the night half runs fast
		var half_secs := DAY_SECONDS if sin(day_phase * TAU) >= 0.0 else NIGHT_SECONDS
		day_phase = fposmod(day_phase + delta / (2.0 * half_secs), 1.0)
	var elev := sin(day_phase * TAU)             # >0 day, <0 night
	# steepened: full daylight for ~80% of the day instead of a slow sine ramp
	# (Jay: "the lighting feels really dark a lot of the time")
	_day_f = clampf(elev * 2.3, 0.0, 1.0)
	var dusk := clampf(1.0 - absf(elev) * 2.8, 0.0, 1.0)   # warm band at sunrise/sunset (long golden hour)
	sun.rotation_degrees = Vector3(-day_phase * 360.0, -42.0, 0.0)

	# weather dimming stacks on the daylight level
	var dim := (1.0 - 0.45 * _storm_mix) * (1.0 - 0.4 * _rain_mix * clampf(rain_intensity + 0.4, 0.5, 1.0))
	# lighter, moonlit nights (sandbox feel) — the night floor is well above black
	sun.light_energy = (0.55 + 1.55 * _day_f) * dim
	var col := Color(0.58, 0.66, 0.92).lerp(Color(1.0, 0.95, 0.84), _day_f)
	col = col.lerp(Color(1.0, 0.55, 0.30), dusk * 0.7)
	col = col.lerp(Color(1.0, 0.45, 0.30), _storm_mix)
	sun.light_color = col
	# the water's foam/shallow tints are albedo constants — without this they GLOW at night
	if water and water.material_override is ShaderMaterial:
		(water.material_override as ShaderMaterial).set_shader_parameter(
			"day_mult", (0.22 + 0.78 * _day_f) * dim)

	var env := world_env.environment
	env.background_energy_multiplier = 1.0
	# painted skybox: live sun disc + day/night dim through the pano_sky shader
	if sky_mode.begins_with("pano:") and env_sky and env_sky.sky_material is ShaderMaterial:
		var psm := env_sky.sky_material as ShaderMaterial
		psm.set_shader_parameter("sun_dir", sun.global_transform.basis.z)
		psm.set_shader_parameter("sun_color", col)
		psm.set_shader_parameter("day_mult", (0.16 + 0.84 * _day_f) * dim)
	if sky_mode == "space":
		env.ambient_light_color = Color(0.30, 0.36, 0.52).lerp(Color(0.60, 0.68, 0.82), _day_f)
		# midday ambient a touch lower than before -> sun shadows keep some depth
		env.ambient_light_energy = (0.90 + 0.42 * _day_f) * dim
		var bot := Color(0.16, 0.22, 0.34).lerp(Color(0.40, 0.80, 0.92), _day_f)
		bot = bot.lerp(Color(0.95, 0.55, 0.35), dusk * 0.55)
		bot = bot.lerp(Color(0.60, 0.24, 0.16), _storm_mix).lerp(Color(0.38, 0.44, 0.50), _rain_mix * 0.8)
		# distance fog matches the horizon band -> land melts into the sky seamlessly
		env.fog_light_color = bot.lightened(0.1)
		if env_sky and env_sky.sky_material is ShaderMaterial:
			var sm := env_sky.sky_material as ShaderMaterial
			var top := Color(0.09, 0.12, 0.24).lerp(Color(0.06, 0.28, 0.62), _day_f)
			top = top.lerp(Color(0.20, 0.05, 0.09), _storm_mix).lerp(Color(0.16, 0.20, 0.28), _rain_mix * 0.8)
			sm.set_shader_parameter("space_top", top)
			sm.set_shader_parameter("space_bottom", bot)
			sm.set_shader_parameter("sun_dir", sun.global_transform.basis.z)
			sm.set_shader_parameter("sun_color", col)

func _toggle_sky() -> void:
	# cycle: space -> dynamic -> every panorama in assets/sky -> back to space
	var modes: Array = ["space", "dynamic"]
	for p in _sky_panoramas():
		modes.append("pano:" + String(p).get_file())
	var i := modes.find(sky_mode)
	sky_mode = modes[(i + 1) % modes.size()]
	_apply_sky()

func _toggle_time() -> void:
	cycle_enabled = not cycle_enabled
	if time_button:
		time_button.text = "Cycle: " + ("On" if cycle_enabled else "Paused")


func _setup_terrain_material() -> void:
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = load("res://scripts/editor/terrain.gdshader")
	var texs := {
		"tex_grass": "res://assets/textures/grass.jpg",
		"tex_rock": "res://assets/textures/rock.jpg",
		"tex_sand": "res://assets/textures/sand.jpg",
		"tex_snow": "res://assets/textures/snow.jpg",
	}
	for param in texs:
		if ResourceLoader.exists(texs[param]):
			terrain_material.set_shader_parameter(param, load(texs[param]))
	terrain_material.set_shader_parameter("tile_scale", 0.12)
	terrain_material.set_shader_parameter("snow_level", 52.0)
	terrain_material.set_shader_parameter("snow_amount", 0.0)   # no snow by default
	terrain_material.set_shader_parameter("water_level", water_level)

## Push the biome map + world span to the terrain shader AND the carpets
## (after each generate/load).
func _refresh_terrain_biome() -> void:
	if terrain_material == null or terrain == null:
		return
	var bt = terrain.biome_texture()
	if bt:
		terrain_material.set_shader_parameter("biome_map", bt)
	terrain_material.set_shader_parameter("terrain_span", float(grid_size))
	var hm = terrain.height_texture()
	for c in carpets:
		c.wire(hm, bt, float(grid_size))

func _build_terrain(n: int) -> void:
	grid_size = n
	if resource_scatter:
		resource_scatter._gen += 1   # abort any yielded scatter against the old terrain
	if flora:
		flora.clear()
	if resource_scatter:
		resource_scatter.clear()
	if terrain and is_instance_valid(terrain):
		terrain.queue_free()
	terrain = TerrainScript.new()
	terrain.name = "Terrain"
	add_child(terrain)
	terrain.build(n, GROUND_LAYER, terrain_material)
	if build:
		build.setup(terrain)

func _setup_water() -> void:
	water = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(4000, 4000)
	water.mesh = pm
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/editor/water.gdshader")

	# smooth seamless simplex noise baked into a normal map -> no blocky grid
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.03
	var nt := NoiseTexture2D.new()
	nt.width = 512
	nt.height = 512
	nt.seamless = true
	nt.as_normal_map = true
	nt.bump_strength = 6.0
	nt.noise = noise
	mat.set_shader_parameter("normal_map", nt)
	# draw the water surface AFTER other transparents so submerged props (crystals, corals)
	# are correctly tinted by the water instead of popping crisply on top of it
	mat.render_priority = 2

	water.material_override = mat
	water.position.y = water_level
	add_child(water)

	# rising bubbles, shown only while the camera is submerged (follows the camera)
	underwater_bubbles = GPUParticles3D.new()
	underwater_bubbles.amount = 140
	underwater_bubbles.lifetime = 4.5
	underwater_bubbles.emitting = false
	underwater_bubbles.local_coords = false
	underwater_bubbles.visibility_aabb = AABB(Vector3(-12, -4, -12), Vector3(24, 30, 24))
	var bpm := ParticleProcessMaterial.new()
	bpm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	bpm.emission_box_extents = Vector3(11, 4, 11)
	bpm.direction = Vector3(0, 1, 0)
	bpm.spread = 12.0
	bpm.initial_velocity_min = 0.4
	bpm.initial_velocity_max = 1.1
	bpm.gravity = Vector3(0, 0.6, 0)
	bpm.scale_min = 0.7
	bpm.scale_max = 2.6
	underwater_bubbles.process_material = bpm
	var bmesh := SphereMesh.new()
	bmesh.radius = 0.045
	bmesh.height = 0.09
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.8, 0.95, 1.0, 0.45)
	bmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bmat.roughness = 0.05
	bmat.rim_enabled = true
	bmat.rim = 1.0
	bmat.emission_enabled = true
	bmat.emission = Color(0.5, 0.85, 1.0)
	bmat.emission_energy_multiplier = 0.35
	bmesh.material = bmat
	underwater_bubbles.draw_pass_1 = bmesh
	add_child(underwater_bubbles)

	# god-ray shafts (the ref-shot "light beams" — additive slanted planes, NOT ray
	# tracing). A generated gradient texture feathers every edge to zero so they read
	# as columns of light, never as floating rectangles.
	god_rays = Node3D.new()
	god_rays.visible = false
	add_child(god_rays)
	var beam_img := Image.create(64, 256, false, Image.FORMAT_RGBA8)
	for py in 256:
		for px in 64:
			var u := float(px) / 63.0
			var v := float(py) / 255.0
			# bright soft core falling to 0 at the sides; fades out toward the bottom
			var core := pow(maxf(sin(u * PI), 0.0), 2.6)
			var tall := (1.0 - v) * smoothstep(0.0, 0.12, v)   # soft top edge too
			beam_img.set_pixel(px, py, Color(1, 1, 1, core * tall))
	var beam_tex := ImageTexture.create_from_image(beam_img)
	var ray_rng := RandomNumberGenerator.new()
	ray_rng.seed = 60217
	for i in 12:
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(ray_rng.randf_range(3.0, 6.5), 44.0)
		qm.center_offset = Vector3(0, -22.0, 0)   # hangs DOWN from the surface anchor
		q.mesh = qm
		var rm := StandardMaterial3D.new()
		rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		rm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
		rm.albedo_texture = beam_tex
		rm.albedo_color = Color(0.45, 0.85, 1.0, ray_rng.randf_range(0.05, 0.10))
		q.material_override = rm
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ang := ray_rng.randf() * TAU
		q.position = Vector3(cos(ang), 0.0, sin(ang)) * ray_rng.randf_range(6.0, 24.0)
		q.rotation.z = deg_to_rad(ray_rng.randf_range(8.0, 16.0))   # slant like sun shafts
		q.set_meta("phase", ray_rng.randf() * TAU)
		god_rays.add_child(q)

func _setup_brush_ring() -> void:
	brush_ring = MeshInstance3D.new()
	brush_torus = TorusMesh.new()
	brush_torus.inner_radius = brush_radius * 0.92
	brush_torus.outer_radius = brush_radius
	brush_ring.mesh = brush_torus
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.2, 1.0, 0.8)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	brush_torus.material = m
	brush_ring.visible = false
	add_child(brush_ring)

# --- selection & preview ----------------------------------------------------

func _set_current(id: String) -> void:
	current_id = id
	if preview and is_instance_valid(preview):
		preview.queue_free()
	preview = null
	if current_id == "":
		return
	preview = lib.instantiate(current_id)
	if preview == null:
		return
	_set_transparency(preview, 0.55)
	add_child(preview)
	_refresh_palette_highlight()

func _set_transparency(node: Node, amount: float) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).transparency = amount
	for c in node.get_children():
		_set_transparency(c, amount)

func _process(delta: float) -> void:
	_update_daynight(delta)
	_update_weather(delta)
	_update_underwater()
	if testing:
		# keep the player's water level in sync with the tide
		if player and not in_interior:
			player.water_level = _eff_water()
		_update_survival(delta)
		_update_build(delta)
		_update_interact()
		_update_drag()
		if crosshair and player:
			crosshair.add_theme_color_override("font_color",
				Color(0.35, 1.0, 0.55, 0.95) if player.grapple_aim_ok else Color(1, 1, 1, 0.55))
		return
	# brush ring + terrain sculpting in SCULPT mode
	if mode == MODE_SCULPT:
		var s_hit := _ray(GROUND_LAYER)
		var over: bool = not s_hit.is_empty() and not _pointer_over_ui() and not camera.is_looking()
		brush_ring.visible = over
		if over:
			brush_ring.global_position = s_hit.position + Vector3(0, 0.2, 0)
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
				var amount := brush_strength * delta
				terrain.sculpt(s_hit.position, brush_radius, amount, sculpt_tool, _sculpt_target)
	# prop preview in PLACE mode
	if preview:
		if mode != MODE_PLACE or _pointer_over_ui() or camera.is_looking() or current_id == "":
			preview.visible = false
		else:
			var p_hit := _ray(GROUND_LAYER)
			if p_hit.is_empty():
				preview.visible = false
			else:
				preview.visible = true
				preview.global_position = p_hit.position
				preview.rotation.y = deg_to_rad(current_rot_deg)
				preview.scale = Vector3.ONE * current_scale

func _ray(layer: int) -> Dictionary:
	var mouse := get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse)
	var to: Vector3 = from + camera.project_ray_normal(mouse) * 8000.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = layer
	return get_world_3d().direct_space_state.intersect_ray(q)

func _pointer_over_ui() -> bool:
	return get_viewport().gui_get_hovered_control() != null

# --- placement / deletion ---------------------------------------------------

func _place() -> void:
	var hit := _ray(GROUND_LAYER)
	if hit.is_empty() or current_id == "":
		return
	var visual: Node3D = lib.instantiate(current_id)
	if visual == null:
		return
	var body := _make_placeable(visual, current_id)
	props_root.add_child(body)
	body.global_position = hit.position
	body.rotation.y = deg_to_rad(current_rot_deg)
	body.scale = Vector3.ONE * current_scale
	undo_stack.append(body)

func _make_placeable(visual: Node3D, id: String) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.collision_layer = PROP_LAYER
	b.collision_mask = 0
	b.add_child(visual)
	b.set_meta("asset_id", id)
	# depth-safe foliage everywhere (alpha scissor + A2C) — covers editor-placed
	# props too, so NOTHING renders blocky leaves or sorts under the water plane
	ResourceScatterScript.force_opaque(visual)
	var aabb := _local_aabb(visual, Transform3D.IDENTITY)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = aabb.size if aabb.size.length() > 0.01 else Vector3.ONE
	cs.shape = box
	cs.position = aabb.get_center()
	b.add_child(cs)
	return b

func _local_aabb(node: Node, xform: Transform3D) -> AABB:
	var out := AABB()
	var has := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		out = xform * (node as MeshInstance3D).mesh.get_aabb()
		has = true
	for c in node.get_children():
		var cx := xform
		if c is Node3D:
			cx = xform * (c as Node3D).transform
		var ca := _local_aabb(c, cx)
		if ca.size.length() > 0.0:
			out = out.merge(ca) if has else ca
			has = true
	return out

func _delete_at_cursor() -> void:
	var hit := _ray(PROP_LAYER)
	if hit.is_empty() or not hit.has("collider"):
		return
	var c: Node = hit.collider
	while c and not c.has_meta("asset_id"):
		c = c.get_parent()
	if c:
		undo_stack.erase(c)
		c.queue_free()

func _undo() -> void:
	while not undo_stack.is_empty():
		var n: Node3D = undo_stack.pop_back()
		if is_instance_valid(n):
			n.queue_free()
			return

func _rotate_by(deg: float) -> void:
	current_rot_deg = fmod(current_rot_deg + deg, 360.0)

func _scale_by(f: float) -> void:
	current_scale = clampf(current_scale * f, 0.1, 20.0)

# --- input ------------------------------------------------------------------

func _unhandled_input(e: InputEvent) -> void:
	# Esc always toggles out of test mode; while testing the player owns all other input.
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_ESCAPE:
		if not testing:
			_toggle_pause_panel()
			return
		if testing:
			if build_menu_open:
				_close_build_menu()
			elif build_piece != -1:
				_stop_building()
			elif term_panel and term_panel.visible:
				_close_terminal()
			elif inv_panel and inv_panel.visible:
				_close_inventory()   # Esc closes open panels before leaving test mode
			elif game_mode:
				_exit_to_menu()      # game mode: save + back to the main menu
			else:
				_exit_test()
		return
	if testing:
		# Q toggles the fabricator panel
		if e is InputEventKey and e.keycode == KEY_Q and e.pressed and not e.echo:
			if build_menu_open:
				_close_build_menu()
			else:
				_open_build_menu()
			return
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT \
				and build_piece != -1 and not build_menu_open:
			if build_piece == DEMOLISH:
				_try_demolish()
			else:
				_try_place()
			return
		if e is InputEventKey and e.pressed and not e.echo:
			if e.keycode == KEY_E:
				_try_interact()
			elif e.keycode == KEY_TAB:
				if inv_panel.visible:
					_close_inventory()
				else:
					_open_inventory()
			elif e.keycode == KEY_M:
				_meteor_shower()   # manual trigger to watch the event play out
			elif e.keycode == KEY_R:
				if build_piece != -1 and build:
					build.rot_offset = (build.rot_offset + 1) % 4   # cycle snap edge
			elif e.keycode == KEY_F:
				_toggle_rain()     # start rain / cut it short
			elif e.keycode == KEY_G:
				_graze()           # consume Biomass to restore nutrients
		return

	if e is InputEventMouseButton and e.pressed:
		match e.button_index:
			MOUSE_BUTTON_LEFT:
				if not _pointer_over_ui() and not camera.is_looking():
					if mode == MODE_PLACE:
						_place()
					elif mode == MODE_DELETE:
						_delete_at_cursor()
					elif mode == MODE_FOG:
						_place_fog()
					elif mode == MODE_SCULPT:
						var hit := _ray(GROUND_LAYER)
						if not hit.is_empty():
							_sculpt_target = terrain.height_at(hit.position.x, hit.position.z)
			MOUSE_BUTTON_WHEEL_UP:
				if mode == MODE_SCULPT: _set_brush_radius(brush_radius + 1.0)
				elif Input.is_key_pressed(KEY_SHIFT): _scale_by(1.1)
				else: _rotate_by(15.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mode == MODE_SCULPT: _set_brush_radius(brush_radius - 1.0)
				elif Input.is_key_pressed(KEY_SHIFT): _scale_by(1.0 / 1.1)
				else: _rotate_by(-15.0)
	elif e is InputEventKey and e.pressed and not e.echo:
		if e.keycode == KEY_1: _set_mode(MODE_PLACE)
		elif e.keycode == KEY_2: _set_mode(MODE_SCULPT)
		elif e.keycode == KEY_3: _set_mode(MODE_DELETE)
		elif e.keycode == KEY_4: _set_mode(MODE_FOG)
		elif e.keycode == KEY_T: _enter_test()
		elif e.keycode == KEY_BRACKETRIGHT: _scale_by(1.1)
		elif e.keycode == KEY_BRACKETLEFT: _scale_by(1.0 / 1.1)
		elif e.keycode == KEY_R: current_rot_deg = randf() * 360.0
		elif e.keycode == KEY_Z and e.ctrl_pressed: _undo()
		elif e.keycode == KEY_DELETE or e.keycode == KEY_BACKSPACE: _undo()
		elif e.keycode == KEY_S and e.ctrl_pressed: _save()
		elif e.keycode == KEY_L and e.ctrl_pressed: _load()

func _set_brush_radius(r: float) -> void:
	brush_radius = clampf(r, 2.0, 40.0)
	brush_torus.inner_radius = brush_radius * 0.92
	brush_torus.outer_radius = brush_radius

# --- modes ------------------------------------------------------------------

func _set_mode(m: int) -> void:
	mode = m
	palette_panel.visible = (m == MODE_PLACE)
	sculpt_panel.visible = (m == MODE_SCULPT)
	fog_panel.visible = (m == MODE_FOG)
	if preview:
		preview.visible = false
	if brush_ring:
		brush_ring.visible = false
	for key in mode_buttons:
		mode_buttons[key].button_pressed = (key == m)

# --- fog --------------------------------------------------------------------

func _place_fog() -> void:
	var hit := _ray(GROUND_LAYER)
	if hit.is_empty():
		return
	var fv := FogVolume.new()
	fv.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	fv.size = Vector3(local_fog_size, 24.0, local_fog_size)
	var fm := FogMaterial.new()
	fm.density = local_fog_density
	fm.albedo = Color(0.86, 0.9, 0.95)
	fv.material = fm
	fog_root.add_child(fv)
	fv.global_position = hit.position + Vector3(0, 10.0, 0)

func _clear_fog() -> void:
	for c in fog_root.get_children():
		c.queue_free()

func _on_global_fog_toggled(pressed: bool) -> void:
	fog_enabled_setting = pressed
	if not _underwater:
		world_env.environment.fog_enabled = pressed

func _on_fog_density(v: float) -> void:
	fog_density_setting = v
	if not _underwater:
		world_env.environment.fog_density = v

## Dense turquoise fog while the active camera is below the surface, restored on exit.
func _update_underwater() -> void:
	if world_env == null or water == null:
		return
	var cam3d := get_viewport().get_camera_3d()
	if cam3d == null:
		return
	var below := cam3d.global_position.y < _eff_water() and not in_interior
	if below == _underwater:
		return
	_underwater = below
	var env := world_env.environment
	if _underwater:
		# turquoise depth fog (graded per frame in _update_weather) + god-ray volumetrics
		env.fog_enabled = true
		env.fog_density = 0.026
		env.fog_light_color = Color(0.13, 0.52, 0.62)
		env.fog_sun_scatter = 0.0
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = 0.07
		env.volumetric_fog_albedo = Color(0.30, 0.75, 0.88)
		env.volumetric_fog_emission = Color(0.04, 0.22, 0.32)
		env.volumetric_fog_length = 140.0
		env.ssil_enabled = false   # screen-space GI smears swaying seagrass into moving blobs
		if underwater_bubbles:
			underwater_bubbles.emitting = true
		if god_rays:
			god_rays.visible = true
	else:
		env.fog_enabled = fog_enabled_setting
		env.fog_density = fog_density_setting
		env.fog_light_color = Color(0.70, 0.85, 0.95)
		env.fog_sun_scatter = 0.12
		env.volumetric_fog_density = 0.0
		env.ssil_enabled = true
		if underwater_bubbles:
			underwater_bubbles.emitting = false
		if god_rays:
			god_rays.visible = false

func _on_local_fog_size(v: float) -> void:
	local_fog_size = v

func _on_local_fog_density(v: float) -> void:
	local_fog_density = v

# --- test mode --------------------------------------------------------------

func _enter_test() -> void:
	if testing:
		return
	testing = true
	if preview: preview.visible = false
	if brush_ring: brush_ring.visible = false
	ui_layer.visible = false
	test_layer.visible = true

	# stop the editor camera from processing/capturing while we play
	camera.set_process(false)
	camera.set_process_unhandled_input(false)
	camera.current = false

	player = TestPlayerScript.new()
	add_child(player)
	player.global_position = camera.global_position
	player.water_level = _eff_water()
	player.harvested.connect(_on_harvested)
	player.broke.connect(_on_broke)
	player.build_broken.connect(_on_build_broken)
	if game_mode:
		player.resource_broke.connect(game_mode.on_resource_broke)
	if build:
		build.door_user = player   # vine doors part as you approach
	player.activate(camera.rotation.y)
	if portal_pair:
		portal_pair.set_body(player)

func _exit_test() -> void:
	if not testing:
		return
	testing = false
	var stand_pos: Vector3 = player.global_position + Vector3(0, 1.6, 0)
	var stand_yaw: float = player.rotation.y
	# leaving test while inside the tree: come back out at the door
	if in_interior:
		in_interior = false
		if home_tree:
			stand_pos = home_tree.door_global() + Vector3(0, 1.6, 1.5)
	if interact_label:
		interact_label.text = ""
	if inv_panel:
		_close_inventory()
	_stop_building()
	build_menu_open = false
	if build_menu:
		build_menu.visible = false
	if term_panel:
		term_panel.visible = false
	if portal_pair:
		portal_pair.set_body(null)
	if build:
		build.door_user = null
	player.queue_free()
	player = null

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# drop the editor camera where the player was standing, facing the same way
	camera.global_position = stand_pos
	camera.rotation = Vector3(0, stand_yaw, 0)
	camera.sync_from_rotation()
	camera.set_process(true)
	camera.set_process_unhandled_input(true)
	camera.current = true

	test_layer.visible = false
	ui_layer.visible = true

# --- home-tree / interior interactions (base-building concept) ----------------

## Decide which prompt/action applies this frame (test mode only).
## Entering/leaving the home is now the walk-through portal, not a key press.
func _update_interact() -> void:
	if interact_label == null or player == null:
		return
	var ppos: Vector3 = player.global_position
	# game mode: the Heart Seed "spread the bloom" prompt takes priority near the seed
	if game_mode and not in_interior and game_mode.game_update_interact(ppos):
		return
	var text := ""
	if in_interior:
		if tree_interior:
			var near_refiner := false
			for rp in tree_interior.refiner_globals():
				if ppos.distance_to(rp) < 2.8:
					near_refiner = true
					break
			if held_seed >= 0 and not tree_interior.nearest_socket(ppos).is_empty():
				text = "E  —  plant the %s seed here" % SEED_NAMES[held_seed]
			elif near_refiner:
				text = "E  —  refine  (5 Stone -> 2 Metal)"
			elif ppos.distance_to(tree_interior.terminal_global()) < 3.2:
				text = "E  —  growth terminal"
			elif held_seed >= 0:
				text = "carrying a %s seed — find a glowing socket" % SEED_NAMES[held_seed]
	elif home_tree == null:
		# plant in front of the player, on dry land (game mode: only after finding a seed)
		if game_mode == null or game_mode.has_seed:
			var fwd: Vector3 = -player.global_transform.basis.z
			var px: float = ppos.x + fwd.x * 3.5
			var pz: float = ppos.z + fwd.z * 3.5
			var h: float = terrain.height_at(px, pz)
			if h > water_level + 1.0:
				_plant_pos = Vector3(px, h - 0.05, pz)
				text = "E  —  plant the Heart Seed"
			else:
				_plant_pos = Vector3.INF
		else:
			_plant_pos = Vector3.INF
	elif not home_tree.grown:
		if ppos.distance_to(home_tree.global_position) < 12.0:
			text = "your home is growing..."
	interact_label.text = text

	# safety net: anyone who slips out of bounds gets pulled back
	if in_interior:
		if ppos.y < INTERIOR_ORIGIN.y - 30.0 and tree_interior:
			player.global_position = tree_interior.spawn_global()
			player.velocity = Vector3.ZERO
	elif ppos.y < -80.0:
		player.global_position = Vector3(ppos.x, terrain.height_at(ppos.x, ppos.z) + 2.0, ppos.z)
		player.velocity = Vector3.ZERO

func _try_interact() -> void:
	if player == null:
		return
	var ppos: Vector3 = player.global_position
	if game_mode and not in_interior and game_mode.game_try_interact(ppos):
		return
	if in_interior:
		if tree_interior == null:
			return
		if held_seed >= 0:
			var sock: Dictionary = tree_interior.nearest_socket(ppos)
			if not sock.is_empty():
				if tree_interior.expand(int(sock.room), int(sock.dir), held_seed):
					_flash("Your home grows...")
					held_seed = -1
					tree_interior.hide_sockets()
					_recalc_capacity()
					if audio:
						audio.play("grow")
				else:
					_flash("That space is blocked")
				return
		# refinery glands: digest stone into metal
		for rp in tree_interior.refiner_globals():
			if ppos.distance_to(rp) < 2.8:
				if _type_total("Stone") >= 5:
					_consume_type("Stone", 5)
					_update_inv_pod("Stone")
					_on_harvested("Metal", 2)
					if audio:
						audio.play("chime")
					_flash("Refined: 5 Stone -> 2 Metal")
				else:
					_flash("Need 5 Stone to refine")
				return
		if ppos.distance_to(tree_interior.terminal_global()) < 3.2:
			_open_terminal()
	elif home_tree == null and _plant_pos != Vector3.INF:
		home_tree = HomeTreeScript.new()
		add_child(home_tree)
		home_tree.global_position = _plant_pos
		tree_interior = TreeInteriorScript.new()
		add_child(tree_interior)
		tree_interior.global_position = INTERIOR_ORIGIN
		home_tree.fully_grown.connect(_on_tree_grown)
		if audio:
			audio.play("chime")
		_flash("Home seed planted")
		if game_mode:
			game_mode.on_planted(_plant_pos)

## The tree finished growing: open the see-through, walk-through portal.
func _on_tree_grown() -> void:
	portal_pair = PortalPairScript.new()
	add_child(portal_pair)
	# tree side matches the arch; interior side fills the whole tunnel mouth
	portal_pair.setup(home_tree.door_marker, tree_interior.portal_marker, 1.5, 2.9)
	portal_pair.crossed = _on_portal_crossed
	if testing and player:
		portal_pair.set_body(player)

func _on_portal_crossed(went_inside: bool) -> void:
	in_interior = went_inside
	if audio:
		audio.play("portal")
	if player:
		# no swimming inside the pocket dimension
		player.water_level = (-1e9) if went_inside else _eff_water()

# --- meteor showers (world event: sky-crystals rain down) -----------------------

var meteors_enabled := false   # OFF for testing (Jay) — toolbar button flips it

func _arm_meteors() -> void:
	if not meteors_enabled:
		return
	meteor_timer.wait_time = randf_range(120.0, 240.0)
	meteor_timer.start()

var _storm_active := false
var _storm_mix := 0.0

func _meteor_shower() -> void:
	if not meteors_enabled:
		return
	if _storm_active:
		return
	_storm_active = true
	_flash("METEOR STORM!")
	_storm_tint(true)
	# 26-32 impacts spread across ~45s. With 8-13s flights that keeps ~8 rocks
	# airborne at once — dozens of concurrent lights/particle systems piling up at
	# the shower's tail was overloading the GPU (the silent end-of-shower crash).
	var n := randi_range(26, 32)
	for i in n:
		_spawn_meteor(float(i) * 1.5 + randf() * 1.2)
	var ender := get_tree().create_timer(50.0)
	ender.timeout.connect(_end_storm)

func _end_storm() -> void:
	_storm_tint(false)
	_storm_active = false
	_arm_meteors()

## Ominous sky during the storm: space gradient goes dark red, sun dims warm.
func _storm_tint(on: bool) -> void:
	var tw := create_tween()
	tw.tween_method(_set_storm_mix, _storm_mix, 1.0 if on else 0.0, 3.0)

func _set_storm_mix(v: float) -> void:
	_storm_mix = v   # the day/night compositor reads this every frame

var _fire_pm: ParticleProcessMaterial
var _fire_mesh: SphereMesh

## Shared across every meteor — building these per rock piled up GPU resources.
func _meteor_fire_pm() -> ParticleProcessMaterial:
	if _fire_pm == null:
		_fire_pm = ParticleProcessMaterial.new()
		_fire_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		_fire_pm.emission_sphere_radius = 0.9
		_fire_pm.gravity = Vector3(0, 2.5, 0)          # flames curl upward off the trail
		_fire_pm.initial_velocity_min = 0.2
		_fire_pm.initial_velocity_max = 1.2
		_fire_pm.scale_min = 0.6
		_fire_pm.scale_max = 2.2
		var fcurve := Curve.new()
		fcurve.add_point(Vector2(0.0, 1.0))
		fcurve.add_point(Vector2(1.0, 0.05))
		var fct := CurveTexture.new()
		fct.curve = fcurve
		_fire_pm.scale_curve = fct
		var fgrad := Gradient.new()
		fgrad.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
		fgrad.colors = PackedColorArray([Color(1.0, 0.85, 0.3, 0.9), Color(1.0, 0.35, 0.05, 0.6), Color(0.25, 0.1, 0.08, 0.0)])
		var fgt := GradientTexture1D.new()
		fgt.gradient = fgrad
		_fire_pm.color_ramp = fgt
	return _fire_pm

func _meteor_fire_mesh() -> SphereMesh:
	if _fire_mesh == null:
		_fire_mesh = SphereMesh.new()
		_fire_mesh.radius = 0.5
		_fire_mesh.height = 1.0
		var fmat := StandardMaterial3D.new()
		fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fmat.vertex_color_use_as_albedo = true
		_fire_mesh.material = fmat
	return _fire_mesh

var _live_meteors := 0

func _spawn_meteor(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	if terrain == null:
		return
	# HARD concurrency cap — pile-ups of live trails/lights at the shower's tail
	# were overloading the GPU (the freeze/crash). Extra rocks just skip.
	if _live_meteors >= 8:
		return
	_live_meteors += 1
	# most impacts spread across the whole island; ~30% bias near the player for show
	var target := Vector3.ZERO
	var found := false
	for attempt in 12:
		var cx := 0.0
		var cz := 0.0
		if testing and player and not in_interior and randf() < 0.3:
			cx = player.global_position.x + randf_range(-60.0, 60.0)
			cz = player.global_position.z + randf_range(-60.0, 60.0)
		else:
			cx = randf_range(-0.45, 0.45) * grid_size
			cz = randf_range(-0.45, 0.45) * grid_size
		var h: float = terrain.height_at(cx, cz)
		if h > water_level + 1.0:
			target = Vector3(cx, h, cz)
			found = true
			break
	if not found:
		_live_meteors = maxi(_live_meteors - 1, 0)
		return

	# a PHYSICAL burning rock: dark tumbling core, fire-hot glow, and a long
	# world-space flame trail — drifting slowly across the whole sky (PC style)
	var rock := Node3D.new()
	var core := MeshInstance3D.new()
	var rm := SphereMesh.new()
	rm.radius = 1.1
	rm.height = 2.0
	rm.radial_segments = 9    # chunky low-poly = reads as rock, not a ball
	rm.rings = 5
	core.mesh = rm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.11, 0.09)   # charred stone
	mat.roughness = 1.0
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.38, 0.08)        # molten heat bleeding through
	mat.emission_energy_multiplier = 2.4
	core.material_override = mat
	rock.add_child(core)
	# ~a third of the rocks carry a light (dozens of live dynamic lights was crash fuel)
	var glow: OmniLight3D = null
	if randi() % 3 == 0:
		glow = OmniLight3D.new()
		glow.light_color = Color(1.0, 0.55, 0.2)
		glow.light_energy = 2.4
		glow.omni_range = 18.0
		rock.add_child(glow)
	# flame trail: shared config resources (built once), tight cull box
	var fire := GPUParticles3D.new()
	fire.amount = 56
	fire.lifetime = 1.5
	fire.local_coords = false
	fire.visibility_aabb = AABB(Vector3(-45, -45, -45), Vector3(90, 90, 90))
	fire.process_material = _meteor_fire_pm()
	fire.draw_pass_1 = _meteor_fire_mesh()
	rock.add_child(fire)
	add_child(rock)

	# long, shallow, SLOW arc across the sky (8-13s flight)
	var start := target + Vector3(randf_range(-420.0, -260.0), randf_range(190.0, 260.0), randf_range(-320.0, 320.0))
	var mid := (start + target) * 0.5 + Vector3(0, randf_range(30.0, 60.0), 0)
	rock.global_position = start
	var flight := randf_range(8.0, 13.0)
	var spin := Vector3(randf_range(0.4, 1.2), randf_range(0.3, 0.9), randf_range(0.2, 0.7))
	var fly := func(t: float) -> void:
		if not is_instance_valid(rock):
			return
		var p01 := start.lerp(mid, t)
		var p12 := mid.lerp(target, t)
		rock.global_position = p01.lerp(p12, t)   # quadratic bezier arc
		core.rotation += spin * 0.016              # slow tumble
	var tw := create_tween()
	tw.tween_method(fly, 0.0, 1.0, flight).set_trans(Tween.TRANS_LINEAR)
	await tw.finished
	if not is_instance_valid(rock):
		return
	# impact: hot flash + the fire dies where it lands
	fire.emitting = false
	var flash_tw := create_tween()
	flash_tw.tween_property(core, "scale", Vector3(3.4, 3.4, 3.4), 0.16)
	flash_tw.parallel().tween_property(mat, "emission_energy_multiplier", 9.0, 0.06)
	flash_tw.chain().tween_property(mat, "emission_energy_multiplier", 0.0, 0.3)
	if glow:
		flash_tw.parallel().tween_property(glow, "light_energy", 0.0, 0.35)
	await flash_tw.finished
	# let straggler flame particles finish before freeing
	await get_tree().create_timer(1.2).timeout
	_live_meteors = maxi(_live_meteors - 1, 0)
	if is_instance_valid(rock):
		rock.queue_free()
	if audio:
		audio.play("thud", 0.15, -12.0)
	# only some impacts leave a meteorite shard (~1 in 4)
	if resource_scatter and randf() < 0.25:
		resource_scatter.spawn_meteor_shard(target + Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5)))

# --- base building ------------------------------------------------------------------

## Q toggles the fabricator panel (Subnautica / Planet Crafter style): base pieces
## on top, prefab STRUCTURES below (any .glb dropped into assets/modules/).
func _open_build_menu() -> void:
	if build_menu == null:
		_make_build_panel()
	_refresh_build_panel()
	build_menu_open = true
	build_menu.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _close_build_menu() -> void:
	build_menu_open = false
	if build_menu:
		build_menu.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _stop_building() -> void:
	build_piece = -1
	if build:
		build.hide_ghost()

var _fab_buttons: Array = []   # piece buttons, refreshed for affordability

func _make_build_panel() -> void:
	build_menu = PanelContainer.new()
	build_menu.set_anchors_preset(Control.PRESET_CENTER)
	build_menu.add_theme_stylebox_override("panel",
		_organic_style(Color(0.04, 0.10, 0.08, 0.95), Color(0.30, 1.0, 0.65, 0.5), 14, 2, 16))
	test_layer.add_child(build_menu)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(560, 0)
	v.add_theme_constant_override("separation", 10)
	build_menu.add_child(v)

	var title := Label.new()
	title.text = "◈  FABRICATOR"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.55, 1.0, 0.75))
	v.add_child(title)

	# NOTE (2026-07-03): base pieces pulled from the menu per Jay — modular
	# structures are the direction. The piece system stays intact underneath.
	_fab_buttons.clear()

	var sec2 := Label.new()
	sec2.text = "STRUCTURES  (drop .glb files into assets/modules/)"
	sec2.add_theme_font_size_override("font_size", 12)
	sec2.add_theme_color_override("font_color", Color(0.45, 0.75, 0.6))
	v.add_child(sec2)
	var mgrid := GridContainer.new()
	mgrid.columns = 4
	mgrid.add_theme_constant_override("h_separation", 8)
	mgrid.add_theme_constant_override("v_separation", 8)
	v.add_child(mgrid)
	if build.modules.is_empty():
		var none := Label.new()
		none.text = "none found yet — your Meshy buildings will appear here"
		none.add_theme_color_override("font_color", Color(0.5, 0.62, 0.55))
		mgrid.add_child(none)
	for mi in build.modules.size():
		var mb := Button.new()
		mb.custom_minimum_size = Vector2(128, 52)
		var cost_txt := ""
		for t in build.MODULE_COST:
			cost_txt += "%d %s  " % [build.MODULE_COST[t], t]
		mb.text = "%s\n%s" % [build.modules[mi].name, cost_txt.strip_edges()]
		mb.pressed.connect(_pick_build.bind(MODULE_BASE + mi))
		mgrid.add_child(mb)
	if not build.modules.is_empty():
		var dem := Button.new()
		dem.custom_minimum_size = Vector2(128, 52)
		dem.text = "Demolish\nhalf refund"
		dem.add_theme_color_override("font_color", Color(1.0, 0.65, 0.5))
		dem.pressed.connect(_pick_build.bind(DEMOLISH))
		mgrid.add_child(dem)

	var away := Button.new()
	away.text = "Put tool away  (Esc)"
	away.pressed.connect(_pick_build.bind(-1))
	v.add_child(away)

func _refresh_build_panel() -> void:
	for i in _fab_buttons.size():
		var b := _fab_buttons[i] as Button
		var cost_txt := ""
		for t in build.piece_cost(i):
			cost_txt += "%d %s  " % [build.piece_cost(i)[t], t]
		b.text = "%s\n%s" % [build.piece_name(i), cost_txt.strip_edges()]
		b.disabled = not _can_afford_dict(build.piece_cost(i))

func _pick_build(i: int) -> void:
	if i == -1:
		_stop_building()
	elif i == DEMOLISH:
		build_piece = DEMOLISH
		_flash("Demolish — LMB wrecks a piece (half refund) · Esc stop")
	elif i >= MODULE_BASE:
		build_piece = i
		_flash("Structure: %s — LMB place · R rotate · Esc stop" % build.modules[i - MODULE_BASE].name)
	else:
		build_piece = i
		_flash("Building: %s — LMB place · R rotate · Esc stop" % build.piece_name(i))
	_close_build_menu()

func _update_build(_delta: float) -> void:
	if player:
		player.suppress_shoot = build_menu_open or build_piece != -1
	if build_menu_open:
		return
	if build_piece == DEMOLISH:
		build.hide_ghost()
		return
	if build_piece >= MODULE_BASE and player and player.cam:
		_build_valid = build.update_ghost_module(build_piece - MODULE_BASE, player.cam) \
			and _can_afford_dict(build.MODULE_COST)
	elif build_piece >= 0 and player and player.cam:
		_build_valid = build.update_ghost(build_piece, player.cam) and _can_afford_dict(build.piece_cost(build_piece))

## LMB in demolish mode: wreck the aimed piece, refund half its cost.
func _try_demolish() -> void:
	if player == null or player.cam == null:
		return
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var to := from + (-cam.global_transform.basis.z) * 9.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 2)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or not (hit.collider is Node) or not (hit.collider as Node).has_meta("build"):
		return
	var body := hit.collider as Node
	var piece := int(body.get_meta("b_piece", -1))
	var refund: Dictionary = {}
	if piece >= 0:
		refund = build.piece_cost(piece)
	elif body.has_meta("b_module"):
		refund = build.MODULE_COST
	for t in refund:
		var back := maxi(1, int(refund[t]) / 2)
		_on_harvested(t, back)
	build.remove_by_body(body)
	if audio:
		audio.play("break")
	body.queue_free()

func _try_place() -> void:
	if build_piece < 0 or build_piece == DEMOLISH or not _build_valid:
		return
	var cost: Dictionary = build.MODULE_COST if build_piece >= MODULE_BASE else build.piece_cost(build_piece)
	if not _can_afford_dict(cost):
		_flash("Not enough matter")
		return
	if build.place_pending() >= 0:
		for t in cost:
			_consume_type(t, int(cost[t]))
			_update_inv_pod(t)
		if audio:
			audio.play("grow", 0.15, -10.0)

func _on_build_broken(body: Node) -> void:
	if build:
		build.remove_by_body(body)

func _can_afford_dict(cost: Dictionary) -> bool:
	for t in cost:
		if _type_total(t) < int(cost[t]):
			return false
	return true

# --- survival: the alien's needs ---------------------------------------------------

func _make_meter(parent: Control, mname: String, color: Color) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = mname
	lbl.custom_minimum_size = Vector2(34, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	row.add_child(lbl)
	var track := PanelContainer.new()
	track.custom_minimum_size = Vector2(130, 14)
	track.add_theme_stylebox_override("panel",
		_organic_style(Color(0.05, 0.09, 0.08, 0.8), Color(color.r, color.g, color.b, 0.45), 8, 1, 2))
	row.add_child(track)
	var fill := ColorRect.new()
	fill.color = Color(color.r, color.g, color.b, 0.9)
	fill.custom_minimum_size = Vector2(124, 8)
	fill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	track.add_child(fill)
	meter_fills[mname] = fill
	_meter_warned[mname] = false

func _update_survival(delta: float) -> void:
	if player == null:
		return
	# SAP (hydration): drains slowly; swimming refills fast, rain refills outside
	sap -= delta * 0.28
	if player.is_swimming():
		sap += delta * 9.0
	elif rain_intensity > 0.0 and not in_interior:
		sap += delta * 2.5
	# LUX (photosynthesis): charges in daylight outdoors, drains at night and inside
	if not in_interior and _day_f > 0.25:
		lux += delta * 7.0 * _day_f
	else:
		lux -= delta * 0.33
	# BIO (nutrients): steady burn; graze Biomass (G) to refill
	bio -= delta * 0.15
	sap = clampf(sap, 0.0, 100.0)
	lux = clampf(lux, 0.0, 100.0)
	bio = clampf(bio, 0.0, 100.0)

	var vals := { "SAP": sap, "LUX": lux, "BIO": bio }
	for k in vals:
		var fill: ColorRect = meter_fills[k]
		fill.custom_minimum_size.x = maxf(vals[k] / 100.0 * 124.0, 2.0)
		if vals[k] <= 0.5 and not _meter_warned[k]:
			_meter_warned[k] = true
			_flash("%s depleted — you feel weak..." % k)
		elif vals[k] > 20.0:
			_meter_warned[k] = false
	# depleted meters slow the vessel down
	player.speed_mult = 0.55 if (sap <= 0.5 or lux <= 0.5 or bio <= 0.5) else 1.0

## G: eat. Desert fruit first (rich — nutrients AND water), else raw Biomass.
func _graze() -> void:
	if _type_total("Fruit") >= 1:
		_consume_type("Fruit", 1)
		bio = minf(bio + 52.0, 100.0)
		sap = minf(sap + 14.0, 100.0)
		_update_inv_pod("Fruit")
		if audio:
			audio.play("chime")
		_flash("Desert bloom — sweet with stored water")
		return
	if _type_total("Biomass") < 1:
		_flash("Nothing to eat — pick desert blooms or harvest kelp / cacti")
		return
	_consume_type("Biomass", 1)
	bio = minf(bio + 40.0, 100.0)
	_update_inv_pod("Biomass")
	if audio:
		audio.play("chime")
	_flash("Biomass absorbed")

## Inventory capacity grows with Storage sac rooms (+8 each).
func _recalc_capacity() -> void:
	var cap := INV_BASE
	if tree_interior:
		cap += 8 * tree_interior.storage_count()
	inv_capacity = cap
	if inv_slots.size() < inv_capacity:
		inv_slots.resize(inv_capacity)

func _consume_type(type: String, n: int) -> void:
	var need := n
	for i in inv_slots.size():
		if need <= 0:
			break
		var s = inv_slots[i]
		if s != null and s.type == type:
			var take: int = mini(need, int(s.count))
			s.count -= take
			need -= take
			if s.count <= 0:
				inv_slots[i] = null

# --- growth terminal --------------------------------------------------------------

func _open_terminal() -> void:
	term_panel.visible = true
	_refresh_terminal()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _close_terminal() -> void:
	term_panel.visible = false
	if testing:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _cost_text(t: int) -> String:
	var parts: Array = []
	for type in SEED_COSTS[t]:
		parts.append("%d %s" % [SEED_COSTS[t][type], type])
	return " + ".join(parts)

func _can_afford(t: int) -> bool:
	for type in SEED_COSTS[t]:
		if _type_total(type) < int(SEED_COSTS[t][type]):
			return false
	return true

func _consume_cost(t: int) -> void:
	for type in SEED_COSTS[t]:
		_consume_type(type, int(SEED_COSTS[t][type]))
		_update_inv_pod(type)

## Craft an upgrade seed (consumes resources): sockets light up at every valid spot.
func _term_craft(t: int) -> void:
	if not _can_afford(t):
		_flash("Not enough matter — need %s" % _cost_text(t))
		return
	_consume_cost(t)
	held_seed = t
	if tree_interior:
		tree_interior.show_sockets(t)
	if audio:
		audio.play("chime")
	_close_terminal()
	_flash("%s seed ready — plant it at a glowing socket" % SEED_NAMES[t])

## world XZ -> map pixels: [scale, world_center: Vector2, screen_center: Vector2]
func _term_map_params() -> Array:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for room in tree_interior.rooms:
		var r: float = tree_interior.ROOM_DEFS[room.type].radius
		lo = lo.min(Vector2(room.center.x - r, room.center.z - r))
		hi = hi.max(Vector2(room.center.x + r, room.center.z + r))
	lo -= Vector2(7, 7)
	hi += Vector2(7, 7)
	var span := hi - lo
	var s: float = minf(TERM_MAP_SIZE.x / maxf(span.x, 1.0), TERM_MAP_SIZE.y / maxf(span.y, 1.0))
	return [minf(s, 20.0), (lo + hi) * 0.5, TERM_MAP_SIZE * 0.5]

func _term_screen(p: Vector3, pr: Array) -> Vector2:
	return pr[2] + (Vector2(p.x, p.z) - pr[1]) * pr[0]

func _refresh_terminal() -> void:
	if tree_interior == null:
		return
	for t in SEED_NAMES.size():
		(term_craft_btns[t] as Button).disabled = not _can_afford(t)
	term_map.queue_redraw()

func _draw_term_map() -> void:
	if tree_interior == null or not term_panel.visible:
		return
	var pr := _term_map_params()
	for cor in tree_interior.corridors:
		term_map.draw_line(_term_screen(cor.from, pr), _term_screen(cor.to, pr), Color(0.30, 0.55, 0.45, 0.9), 5.0)
	var font := term_map.get_theme_default_font()
	for i in tree_interior.room_count():
		var room = tree_interior.rooms[i]
		var r: float = tree_interior.ROOM_DEFS[room.type].radius
		var c := _term_screen(room.center, pr)
		var border := Color(0.30, 1.0, 0.65)
		if room.type == tree_interior.ROOM_LARGE:
			border = Color(0.75, 0.55, 1.0)
		elif room.type == tree_interior.ROOM_STAIR:
			border = Color(1.0, 0.85, 0.35)
		elif room.type == tree_interior.ROOM_STORAGE:
			border = Color(0.55, 1.0, 0.55)
		elif room.type == tree_interior.ROOM_REFINER:
			border = Color(1.0, 0.60, 0.30)
		var fill := Color(0.10, 0.20, 0.17, 0.95)
		if room.center.y > 2.0:
			fill = Color(0.16, 0.24, 0.28, 0.95)   # upper-floor rooms read lighter
		term_map.draw_circle(c, r * pr[0], fill)
		term_map.draw_arc(c, r * pr[0], 0, TAU, 40, border, 2.5)
		if room.type == tree_interior.ROOM_STAIR:
			term_map.draw_arc(c, r * pr[0] * 0.45, 0.6, 5.2, 20, border, 2.0)
		if room.center.y > 2.0:
			term_map.draw_string(font, c + Vector2(-8, 5), "2F", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 1.0, 0.92))
	# the front door
	var r0: float = tree_interior.ROOM_DEFS[tree_interior.rooms[0].type].radius
	var door := _term_screen(Vector3(0, 0, -r0 - 2.2), pr)
	term_map.draw_circle(door, 5.0, Color(0.30, 1.0, 0.65))
	term_map.draw_string(font, door + Vector2(9, 5), "door", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.55, 0.85, 0.70))


# --- rain & tides -----------------------------------------------------------------

func _eff_water() -> float:
	return water_level + weather_offset

func _setup_rain_fx() -> void:
	rain_fx = GPUParticles3D.new()
	rain_fx.amount = 1200
	rain_fx.lifetime = 1.1
	rain_fx.emitting = false
	rain_fx.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# tall emission volume so rain surrounds the camera — visible looking DOWN too
	pm.emission_box_extents = Vector3(26.0, 14.0, 26.0)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 3.0
	pm.initial_velocity_min = 22.0
	pm.initial_velocity_max = 30.0
	pm.gravity = Vector3(0, -12, 0)
	rain_fx.process_material = pm
	rain_fx.lifetime = 1.5
	var drop := BoxMesh.new()
	drop.size = Vector3(0.02, 0.55, 0.02)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.65, 0.80, 0.95, 0.45)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop.material = dm
	rain_fx.draw_pass_1 = drop
	add_child(rain_fx)

	# impact splashes: rings that snap to the REAL terrain / water height at each
	# landing spot (custom particle shader + heightmap), so slopes look right
	rain_splash = GPUParticles3D.new()
	rain_splash.amount = 420
	rain_splash.lifetime = 0.4
	rain_splash.emitting = false
	rain_splash.local_coords = false
	rain_splash.visibility_aabb = AABB(Vector3(-40, -220, -40), Vector3(80, 440, 80))
	var sm2 := ShaderMaterial.new()
	sm2.shader = load("res://scripts/editor/rain_splash.gdshader")
	rain_splash.process_material = sm2
	var ring := TorusMesh.new()
	ring.inner_radius = 0.07
	ring.outer_radius = 0.11
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(0.85, 0.95, 1.0, 0.5)
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.vertex_color_use_as_albedo = true
	ring.material = ring_mat
	rain_splash.draw_pass_1 = ring
	add_child(rain_splash)

func _start_rain() -> void:
	rain_intensity = randf_range(0.25, 1.0)
	rain_duration = randf_range(180.0, 480.0)
	rain_time_left = rain_duration
	rain_fx.amount_ratio = clampf(rain_intensity, 0.15, 1.0)
	rain_fx.emitting = true
	rain_splash.amount_ratio = clampf(rain_intensity, 0.15, 1.0)
	if terrain:
		var spm := rain_splash.process_material as ShaderMaterial
		spm.set_shader_parameter("heightmap", terrain.height_texture())
		spm.set_shader_parameter("span", float(grid_size))
		spm.set_shader_parameter("water_y", _eff_water())
	rain_splash.emitting = true
	_rain_tint(true)
	_flash("A storm rolls in..." if rain_intensity > 0.7 else "Rain begins to fall...")

func _end_rain() -> void:
	rain_intensity = 0.0
	rain_fx.emitting = false
	rain_splash.emitting = false
	_rain_tint(false)
	water_debounce.start()
	if not game_mode:   # game mode schedules its own rain (gated to later days)
		rain_timer.wait_time = randf_range(240.0, 480.0)
		rain_timer.start()
	_flash("The rain passes")

## Toolbar / R key: start rain immediately, or cut a running rain short.
func _toggle_rain() -> void:
	if rain_intensity > 0.0:
		rain_time_left = 0.0
	else:
		rain_timer.stop()
		_start_rain()

func _update_weather(delta: float) -> void:
	# rain sheets follow the active camera; splashes hug the ground / water below it
	var cam3d := get_viewport().get_camera_3d()
	if cam3d:
		# carpets ride with the camera; refresh the height texture after sculpts
		if terrain and terrain.hm_dirty:
			terrain.height_texture()   # updates in place (same RID all shaders sample)
		for c in carpets:
			c.follow(cam3d.global_position, _eff_water())
	if _underwater and underwater_bubbles and cam3d:
		underwater_bubbles.global_position = cam3d.global_position + Vector3(0, -1.0, 0)
		# shafts hang from the surface, drift slowly, breathe in brightness
		if god_rays:
			god_rays.global_position = Vector3(cam3d.global_position.x, _eff_water(), cam3d.global_position.z)
			var tnow := Time.get_ticks_msec() / 1000.0
			for q in god_rays.get_children():
				var qi := q as MeshInstance3D
				var m := qi.material_override as StandardMaterial3D
				var ph: float = qi.get_meta("phase", 0.0)
				var base_a := 0.045 + 0.04 * (0.5 + 0.5 * sin(tnow * 0.35 + ph))
				# rays live near the surface, die with depth + at night
				var depth_k := clampf(1.0 - (_eff_water() - cam3d.global_position.y) / 30.0, 0.0, 1.0)
				m.albedo_color.a = base_a * depth_k * (0.25 + 0.75 * _day_f)
		# depth grading: bright turquoise near the surface -> dark deep blue below
		var dep := clampf((_eff_water() - cam3d.global_position.y) / 26.0, 0.0, 1.0)
		var env := world_env.environment
		env.fog_density = lerpf(0.018, 0.05, dep)
		env.fog_light_color = Color(0.16, 0.60, 0.70).lerp(Color(0.03, 0.14, 0.28), dep)
		env.volumetric_fog_density = lerpf(0.085, 0.03, dep)   # rays strongest near the light
	if rain_fx and cam3d:
		rain_fx.global_position = cam3d.global_position + Vector3(0, 4.0, 0)
		if rain_splash and terrain:
			rain_splash.global_position = cam3d.global_position
			if rain_intensity > 0.0:
				var pm2 := rain_splash.process_material as ShaderMaterial
				pm2.set_shader_parameter("water_y", _eff_water())
				pm2.set_shader_parameter("span", float(grid_size))
				if terrain.hm_dirty:
					pm2.set_shader_parameter("heightmap", terrain.height_texture())
	if rain_intensity > 0.0:
		rain_time_left -= delta
		if game_mode == null:
			# a full storm can push the tide ~18 m up — but it creeps, never surges
			var cap := 3.0 + rain_intensity * 15.0
			weather_offset = move_toward(weather_offset, cap, delta * cap / maxf(rain_duration * 1.7, 1.0))
		if rain_time_left <= 0.0 and game_mode == null:
			_end_rain()
	elif weather_offset > 0.0:
		# dry spell: the tide retreats slowly — and only ever down to the map's
		# BASE water level (weather_offset is always >= 0, never below it)
		weather_offset = move_toward(weather_offset, 0.0, delta * 0.02)
		if weather_offset < 0.01:
			weather_offset = 0.0
			water_debounce.start()   # tide fully out: settle sea life on the base line
	_apply_eff_water()

func _apply_eff_water() -> void:
	var w := _eff_water()
	if absf(w - _last_eff_water) < 0.0005:
		return
	_last_eff_water = w
	if water:
		water.position.y = w
	if terrain_material:
		terrain_material.set_shader_parameter("water_level", w)
	if player and not in_interior:
		player.water_level = w

func _rain_tint(on: bool) -> void:
	var tw := create_tween()
	tw.tween_method(_set_rain_mix, _rain_mix, 1.0 if on else 0.0, 4.0)

func _set_rain_mix(v: float) -> void:
	_rain_mix = v   # the day/night compositor reads this every frame

# --- inventory ("spore sacs") ---------------------------------------------------

func _type_total(type: String) -> int:
	var total := 0
	for s in inv_slots:
		if s != null and s.type == type:
			total += int(s.count)
	return total

func _on_broke() -> void:
	if audio:
		audio.play("break")

func _on_harvested(type: String, amount: int) -> void:
	if audio:
		audio.play("hit", 0.12, -10.0)
	# stack onto an existing sac of this type, else sprout a new one in the first free slot
	var placed := false
	for s in inv_slots:
		if s != null and s.type == type:
			s.count += amount
			placed = true
			break
	if not placed:
		for i in inv_capacity:
			if inv_slots[i] == null:
				inv_slots[i] = { "type": type, "count": amount }
				placed = true
				break
	if not placed:
		_flash("Spore sacs full!")
		return
	_update_inv_pod(type)

func _update_inv_pod(type: String) -> void:
	if not inv_pods.has(type):
		var pod := PanelContainer.new()
		var pcol: Color = RES_COLORS.get(type, Color.WHITE)
		pod.add_theme_stylebox_override("panel",
			_organic_style(Color(0.05, 0.10, 0.085, 0.85), Color(pcol.r, pcol.g, pcol.b, 0.6), 14, 2))
		var hb := HBoxContainer.new()
		pod.add_child(hb)
		var dot := Label.new()
		dot.text = "●"
		dot.add_theme_color_override("font_color", RES_COLORS.get(type, Color.WHITE))
		dot.add_theme_constant_override("outline_size", 3)
		dot.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
		hb.add_child(dot)
		var cnt := Label.new()
		hb.add_child(cnt)
		inv_box.add_child(pod)
		inv_pods[type] = cnt
	var cnt_label: Label = inv_pods[type]
	cnt_label.text = "%s  %d" % [type, _type_total(type)]
	# the sac swells when fed
	var pod_ctrl := cnt_label.get_parent().get_parent() as Control
	pod_ctrl.pivot_offset = pod_ctrl.size * 0.5
	pod_ctrl.scale = Vector2(1.25, 1.25)
	var tw := create_tween()
	tw.tween_property(pod_ctrl, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if inv_panel and inv_panel.visible:
		_refresh_inv_panel()

## Rounded, glowing-bordered organic panel style (the plant-alien UI language).
func _organic_style(bg: Color, border: Color, radius: int, bw: int, margin: int = 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = margin * 0.6
	sb.content_margin_bottom = margin * 0.6
	return sb

func _open_inventory() -> void:
	inv_panel.visible = true
	_refresh_inv_panel()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # free the cursor to move sacs around

func _close_inventory() -> void:
	inv_panel.visible = false
	if _drag_from != -1:
		_cancel_drag()
	if testing:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Full inventory (Tab): Planet Crafter-style slot grid, plant-alien themed.
## Click a sac to pick it up, click another slot to move/swap it there.
func _refresh_inv_panel() -> void:
	for c in inv_grid.get_children():
		c.queue_free()
	for i in inv_capacity:
		var entry = inv_slots[i]
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(92, 92)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.gui_input.connect(_on_slot_gui_input.bind(i))
		var dragging := (i == _drag_from)
		if entry != null:
			var col: Color = RES_COLORS.get(entry.type, Color.WHITE)
			slot.modulate.a = 0.45 if dragging else 1.0
			slot.add_theme_stylebox_override("panel", _organic_style(
				Color(0.07, 0.13, 0.11, 0.92),
				Color(col.r, col.g, col.b, 0.8),
				16, 2))
			var v := VBoxContainer.new()
			v.alignment = BoxContainer.ALIGNMENT_CENTER
			v.mouse_filter = Control.MOUSE_FILTER_IGNORE
			slot.add_child(v)
			var dot := Label.new()
			dot.text = "●"
			dot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			dot.add_theme_font_size_override("font_size", 26)
			dot.add_theme_color_override("font_color", col)
			v.add_child(dot)
			var nm := Label.new()
			nm.text = String(entry.type)
			nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			nm.add_theme_font_size_override("font_size", 12)
			nm.add_theme_color_override("font_color", Color(0.85, 0.95, 0.90))
			v.add_child(nm)
			var ct := Label.new()
			ct.text = "x%d" % int(entry.count)
			ct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			ct.add_theme_font_size_override("font_size", 13)
			ct.add_theme_color_override("font_color", Color(0.55, 1.0, 0.80))
			v.add_child(ct)
		else:
			slot.add_theme_stylebox_override("panel", _organic_style(
				Color(0.06, 0.10, 0.09, 0.45),
				Color(1.0, 1.0, 0.85, 0.6) if dragging else Color(0.20, 0.38, 0.32, 0.35),
				16, 1))
			var dorm := Label.new()
			dorm.text = "·"
			dorm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			dorm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			dorm.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dorm.add_theme_color_override("font_color", Color(0.25, 0.42, 0.36, 0.5))
			slot.add_child(dorm)
		inv_grid.add_child(slot)

func _on_slot_gui_input(e: InputEvent, idx: int) -> void:
	# drag & drop: press on a sac to pick it up, release over a slot to drop it
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT \
			and _drag_from == -1 and inv_slots[idx] != null:
		_drag_from = idx
		var entry = inv_slots[idx]
		_drag_preview = Label.new()
		_drag_preview.text = "●"
		_drag_preview.add_theme_font_size_override("font_size", 30)
		_drag_preview.add_theme_color_override("font_color", RES_COLORS.get(entry.type, Color.WHITE))
		_drag_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_drag_preview.z_index = 100
		test_layer.add_child(_drag_preview)
		_refresh_inv_panel()

## Called from _process while dragging: follow the mouse, finish on release.
func _update_drag() -> void:
	if _drag_from == -1:
		return
	if not inv_panel.visible:
		_cancel_drag()
		return
	var mouse := get_viewport().get_mouse_position()
	if is_instance_valid(_drag_preview):
		_drag_preview.position = mouse - Vector2(10, 20)
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var target := -1
		for i in inv_grid.get_child_count():
			var slot := inv_grid.get_child(i) as Control
			if slot and slot.get_global_rect().has_point(mouse):
				target = i
				break
		if target >= 0 and target != _drag_from and target < inv_capacity:
			var a = inv_slots[_drag_from]
			var b = inv_slots[target]
			if b != null and a != null and b.type == a.type:
				b.count += a.count
				inv_slots[_drag_from] = null
			else:
				inv_slots[target] = a
				inv_slots[_drag_from] = b
		_cancel_drag()

func _cancel_drag() -> void:
	_drag_from = -1
	if is_instance_valid(_drag_preview):
		_drag_preview.queue_free()
	_drag_preview = null
	_refresh_inv_panel()

# --- editor settings persistence (survives closing the game) -----------------

func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return
	sky_mode = str(d.get("sky_mode", sky_mode))
	day_phase = float(d.get("day_phase", day_phase))
	cycle_enabled = bool(d.get("cycle_on", cycle_enabled))
	fog_enabled_setting = bool(d.get("fog_on", fog_enabled_setting))
	fog_density_setting = float(d.get("fog_density", fog_density_setting))
	water_level = float(d.get("water", water_level))
	grid_size = int(d.get("grid", grid_size))
	flora_density = int(d.get("flora", flora_density))
	rock_count = int(d.get("rocks", rock_count))
	tree_count = int(d.get("trees", tree_count))
	crystal_count = int(d.get("crystals", crystal_count))
	coral_count = int(d.get("corals", coral_count))
	starfish_count = int(d.get("starfish", starfish_count))
	kelp_count = int(d.get("kelp", kelp_count))
	satellite_count = int(d.get("satellites", satellite_count))
	brush_radius = float(d.get("brush_radius", brush_radius))
	brush_strength = float(d.get("brush_strength", brush_strength))

func _save_settings() -> void:
	var d := {
		"sky_mode": sky_mode, "day_phase": day_phase, "cycle_on": cycle_enabled,
		"fog_on": fog_enabled_setting, "fog_density": fog_density_setting,
		"water": water_level, "grid": grid_size, "flora": flora_density,
		"rocks": rock_count, "trees": tree_count, "crystals": crystal_count,
		"corals": coral_count, "starfish": starfish_count, "kelp": kelp_count,
		"satellites": satellite_count,
		"brush_radius": brush_radius, "brush_strength": brush_strength,
	}
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d, "\t"))
		f.close()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		_save_settings()

# --- save / load ------------------------------------------------------------

func _save() -> void:
	var data := { "grid": grid_size, "water": water_level, "props": [] }
	# game state: home tree, interior size, inventory
	if home_tree:
		data["home"] = {
			"pos": [home_tree.global_position.x, home_tree.global_position.y, home_tree.global_position.z],
			"grown": home_tree.grown,
			"rooms": tree_interior.build_log if tree_interior else [],
		}
	var inv_data := []
	for s in inv_slots:
		inv_data.append(null if s == null else { "type": s.type, "count": s.count })
	data["inv"] = inv_data
	if build:
		data["build"] = build.serialize()
	for n in props_root.get_children():
		if n is Node3D:
			data.props.append({
				"id": String(n.get_meta("asset_id", "")),
				"pos": [n.position.x, n.position.y, n.position.z],
				"rot": rad_to_deg(n.rotation.y),
				"scale": n.scale.x,
			})
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		_flash("Save failed"); return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

	var hf := FileAccess.open(HEIGHTS_PATH, FileAccess.WRITE)
	if hf:
		hf.store_buffer(terrain.heights.to_byte_array())
		hf.close()
	_flash("Saved %d props + terrain" % props_root.get_child_count())

func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		_flash("No saved map yet"); return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		_flash("Save file unreadable"); return

	for n in props_root.get_children():
		n.queue_free()
	undo_stack.clear()

	_build_terrain(int(data.get("grid", grid_size)))
	if FileAccess.file_exists(HEIGHTS_PATH):
		var hf := FileAccess.open(HEIGHTS_PATH, FileAccess.READ)
		var buf := hf.get_buffer(hf.get_length())
		hf.close()
		terrain.set_heights(buf.to_float32_array())

	water_level = float(data.get("water", water_level))
	water.position.y = water_level

	for p in data.get("props", []):
		var id := String(p.get("id", ""))
		if not lib.has_item(id) and id.begins_with("glb:"):
			lib.import_glb(id.substr(4))
		var visual: Node3D = lib.instantiate(id)
		if visual == null:
			continue
		var body := _make_placeable(visual, id)
		props_root.add_child(body)
		var pos = p.get("pos", [0, 0, 0])
		body.position = Vector3(pos[0], pos[1], pos[2])
		body.rotation.y = deg_to_rad(float(p.get("rot", 0.0)))
		body.scale = Vector3.ONE * float(p.get("scale", 1.0))

	# restore game state: home tree + interior + inventory
	if home_tree and is_instance_valid(home_tree):
		home_tree.queue_free()
		home_tree = null
	if tree_interior and is_instance_valid(tree_interior):
		tree_interior.queue_free()
		tree_interior = null
	if portal_pair and is_instance_valid(portal_pair):
		portal_pair.queue_free()
		portal_pair = null
	in_interior = false
	if data.has("home") and data.home != null:
		var hp = data.home.pos
		home_tree = HomeTreeScript.new()
		home_tree.instant = bool(data.home.get("grown", true))
		add_child(home_tree)
		home_tree.global_position = Vector3(hp[0], hp[1], hp[2])
		tree_interior = TreeInteriorScript.new()
		add_child(tree_interior)
		tree_interior.global_position = INTERIOR_ORIGIN
		tree_interior.replay(data.home.get("rooms", []))
		_recalc_capacity()
		if home_tree.grown:
			_on_tree_grown()
		else:
			home_tree.fully_grown.connect(_on_tree_grown)
	if data.has("inv"):
		inv_slots.clear()
		var inv_data: Array = data.inv
		inv_slots.resize(maxi(inv_capacity, inv_data.size()))
		for i in mini(inv_data.size(), inv_slots.size()):
			if inv_data[i] != null:
				inv_slots[i] = { "type": String(inv_data[i].type), "count": int(inv_data[i].count) }
		# rebuild the quick strip
		for c in inv_box.get_children():
			c.queue_free()
		inv_pods.clear()
		var seen := {}
		for s in inv_slots:
			if s != null and not seen.has(s.type):
				seen[s.type] = true
				_update_inv_pod(s.type)

	if build and data.has("build"):
		build.deserialize(data.build)

	_refresh_palette()
	_flash("Loaded map")

# --- UI ---------------------------------------------------------------------

func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	var layer := ui_layer

	# top toolbar
	var top := PanelContainer.new()
	top.position = Vector2(8, 8)
	layer.add_child(top)
	var row := HBoxContainer.new()
	top.add_child(row)
	for key in SIZES.keys():
		var sz: int = SIZES[key]
		var b := Button.new(); b.text = key
		b.pressed.connect(_build_terrain.bind(sz))
		row.add_child(b)
	row.add_child(VSeparator.new())
	_mode_button(row, "Place (1)", MODE_PLACE)
	_mode_button(row, "Sculpt (2)", MODE_SCULPT)
	_mode_button(row, "Delete (3)", MODE_DELETE)
	_mode_button(row, "Fog (4)", MODE_FOG)
	row.add_child(VSeparator.new())
	sky_button = Button.new()
	sky_button.text = "Sky: " + sky_mode.capitalize()
	sky_button.pressed.connect(_toggle_sky)
	row.add_child(sky_button)
	time_button = Button.new()
	time_button.text = "Cycle: On"
	time_button.pressed.connect(_toggle_time)
	row.add_child(time_button)
	row.add_child(VSeparator.new())
	var metb := Button.new(); metb.text = "Meteors: Off"
	metb.pressed.connect(func():
		meteors_enabled = not meteors_enabled
		metb.text = "Meteors: On" if meteors_enabled else "Meteors: Off"
		if meteors_enabled:
			_arm_meteors()
		else:
			meteor_timer.stop())
	row.add_child(metb)
	var rainb := Button.new(); rainb.text = "Rain"; rainb.pressed.connect(_toggle_rain); row.add_child(rainb)
	var tstb := Button.new(); tstb.text = "Test (T)"; tstb.pressed.connect(_enter_test); row.add_child(tstb)
	row.add_child(VSeparator.new())
	var sb := Button.new(); sb.text = "Save"; sb.pressed.connect(_save); row.add_child(sb)
	var lb := Button.new(); lb.text = "Load"; lb.pressed.connect(_load); row.add_child(lb)
	var ib := Button.new(); ib.text = "Import .glb"; ib.pressed.connect(_open_import); row.add_child(ib)

	# palette (PLACE)
	palette_panel = PanelContainer.new()
	palette_panel.position = Vector2(8, 54)
	palette_panel.custom_minimum_size = Vector2(150, 460)
	layer.add_child(palette_panel)
	var scroll := ScrollContainer.new()
	palette_panel.add_child(scroll)
	palette_box = VBoxContainer.new()
	palette_box.custom_minimum_size = Vector2(140, 0)
	scroll.add_child(palette_box)
	_refresh_palette()

	# sculpt tools (SCULPT) — scrollable, the panel has a lot of controls now
	sculpt_panel = PanelContainer.new()
	sculpt_panel.position = Vector2(8, 54)
	sculpt_panel.custom_minimum_size = Vector2(250, 560)
	layer.add_child(sculpt_panel)
	var s_scroll := ScrollContainer.new()
	s_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sculpt_panel.add_child(s_scroll)
	var sv := VBoxContainer.new()
	sv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s_scroll.add_child(sv)
	_tool_button(sv, "Raise", 0)
	_tool_button(sv, "Lower", 1)
	_tool_button(sv, "Smooth", 2)
	_tool_button(sv, "Flatten", 3)
	sv.add_child(HSeparator.new())
	_slider(sv, "Brush size", 2, 40, brush_radius, 1, _set_brush_radius)
	_slider(sv, "Strength", 1, 60, brush_strength, 1, _on_strength_changed)
	# max reaches above the tallest tiers on any map size -> maxed out floods ~everything
	_slider(sv, "Water level", -20, 170, water_level, 0.5, _on_water_changed)
	_slider(sv, "Water waves", 0.0, 1.5, 0.7, 0.05, _on_water_waves)
	sv.add_child(HSeparator.new())
	var gen := Button.new(); gen.text = "Generate mountains"
	gen.pressed.connect(_generate_mountains)
	sv.add_child(gen)
	var flat := Button.new(); flat.text = "Flatten all"
	flat.pressed.connect(func(): terrain.flatten_all(0.0))
	sv.add_child(flat)
	sv.add_child(HSeparator.new())
	var grow := Button.new(); grow.text = "Grow flora"
	grow.pressed.connect(_grow_grass)
	sv.add_child(grow)
	_slider(sv, "Flora density %", 0, 250, flora_density, 10, _on_flora_density)
	_slider(sv, "Time of day %", 0, 100, int(day_phase * 100.0), 1, _on_time_slider)
	sv.add_child(HSeparator.new())
	var scat := Button.new(); scat.text = "Scatter resources"
	scat.pressed.connect(_scatter_resources)
	sv.add_child(scat)
	_slider(sv, "Rocks", 0, 300, rock_count, 5, _on_rock_count)
	_slider(sv, "Trees", 0, 300, tree_count, 5, _on_tree_count)
	_slider(sv, "Crystals", 0, 200, crystal_count, 5, _on_crystal_count)
	_slider(sv, "Corals", 0, 200, coral_count, 5, _on_coral_count)
	_slider(sv, "Starfish", 0, 100, starfish_count, 5, _on_starfish_count)
	_slider(sv, "Kelp", 0, 150, kelp_count, 5, _on_kelp_count)
	_slider(sv, "Satellites", 0, 60, satellite_count, 2, _on_satellite_count)

	# fog tools (FOG)
	fog_panel = PanelContainer.new()
	fog_panel.position = Vector2(8, 54)
	fog_panel.custom_minimum_size = Vector2(200, 0)
	layer.add_child(fog_panel)
	var fv := VBoxContainer.new()
	fog_panel.add_child(fv)
	var gfog := CheckButton.new()
	gfog.text = "Global fog"
	gfog.button_pressed = fog_enabled_setting
	gfog.toggled.connect(_on_global_fog_toggled)
	fv.add_child(gfog)
	_slider(fv, "Global density", 0.0, 0.02, fog_density_setting, 0.0005, _on_fog_density)
	fv.add_child(HSeparator.new())
	var fhint := Label.new(); fhint.text = "LMB: drop a fog patch"
	fv.add_child(fhint)
	_slider(fv, "Patch size", 10, 150, local_fog_size, 5, _on_local_fog_size)
	_slider(fv, "Patch density", 0.0, 1.0, local_fog_density, 0.02, _on_local_fog_density)
	var clrfog := Button.new(); clrfog.text = "Clear fog patches"
	clrfog.pressed.connect(_clear_fog)
	fv.add_child(clrfog)

	# hint bar
	hint_label = Label.new()
	hint_label.add_theme_color_override("font_color", Color.WHITE)
	hint_label.add_theme_color_override("font_outline_color", Color.BLACK)
	hint_label.add_theme_constant_override("outline_size", 4)
	hint_label.text = "1 Place · 2 Sculpt · 3 Delete    RMB look · WASD move · Q/E up·down · Shift fast    LMB act · Wheel rotate/brush · [ ] scale · R spin · Ctrl+Z undo · Ctrl+S save · Ctrl+L load"
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.offset_top = -28
	layer.add_child(hint_label)

	# flash
	flash_label = Label.new()
	flash_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	flash_label.add_theme_color_override("font_outline_color", Color.BLACK)
	flash_label.add_theme_constant_override("outline_size", 4)
	flash_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	flash_label.offset_top = 14
	flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(flash_label)

	# import dialog
	import_dialog = FileDialog.new()
	import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	import_dialog.use_native_dialog = true
	import_dialog.filters = PackedStringArray(["*.glb ; GLTF Binary", "*.gltf ; GLTF Text"])
	import_dialog.file_selected.connect(_on_import_selected)
	layer.add_child(import_dialog)

	# test-mode HUD (separate layer so it stays visible when the editor UI is hidden)
	test_layer = CanvasLayer.new()
	add_child(test_layer)
	var tl := Label.new()
	tl.add_theme_color_override("font_color", Color.WHITE)
	tl.add_theme_color_override("font_outline_color", Color.BLACK)
	tl.add_theme_constant_override("outline_size", 4)
	tl.text = "TEST MODE  ·  WASD · Shift sprint · Space jump · 2x Space fly · LMB harvest · hold Q build (R rotate) · E interact · G graze · F rain · Tab bag"
	tl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	tl.offset_top = 14
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	test_layer.add_child(tl)
	# crosshair: soft dot, tints green when the vine grapple (RMB) can latch
	crosshair = Label.new()
	crosshair.text = "·"
	crosshair.add_theme_font_size_override("font_size", 34)
	crosshair.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	crosshair.add_theme_constant_override("outline_size", 3)
	crosshair.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.4))
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.position = Vector2(-8, -24)
	test_layer.add_child(crosshair)
	# interaction prompt ("E — plant your home seed" ...)
	interact_label = Label.new()
	interact_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.85))
	interact_label.add_theme_color_override("font_outline_color", Color.BLACK)
	interact_label.add_theme_constant_override("outline_size", 5)
	interact_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	interact_label.offset_top = -110
	interact_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	test_layer.add_child(interact_label)
	# survival vials, bottom-right: SAP (hydration) / LUX (light) / BIO (nutrients)
	var vials := VBoxContainer.new()
	vials.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	vials.position = Vector2(-190, -128)
	vials.add_theme_constant_override("separation", 7)
	test_layer.add_child(vials)
	_make_meter(vials, "SAP", Color(0.35, 0.75, 1.0))
	_make_meter(vials, "LUX", Color(1.0, 0.88, 0.40))
	_make_meter(vials, "BIO", Color(0.50, 1.0, 0.60))

	# spore-sac inventory, bottom-left; sacs only appear once you've absorbed something
	inv_box = HBoxContainer.new()
	inv_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	inv_box.position = Vector2(16, -56)
	inv_box.add_theme_constant_override("separation", 10)
	test_layer.add_child(inv_box)
	# full inventory panel (Tab) — organic "spore vessel" theme
	inv_panel = PanelContainer.new()
	inv_panel.set_anchors_preset(Control.PRESET_CENTER)
	# grow from the middle as content fills in, so the panel stays centred
	# instead of extending off the bottom of the screen
	inv_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	inv_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	inv_panel.add_theme_stylebox_override("panel",
		_organic_style(Color(0.04, 0.09, 0.075, 0.95), Color(0.30, 1.0, 0.65, 0.55), 22, 2, 18))
	inv_panel.visible = false
	test_layer.add_child(inv_panel)
	var iv := VBoxContainer.new()
	iv.add_theme_constant_override("separation", 8)
	inv_panel.add_child(iv)
	var ititle := Label.new()
	ititle.text = "S P O R E   S A C S"
	ititle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ititle.add_theme_font_size_override("font_size", 24)
	ititle.add_theme_color_override("font_color", Color(0.55, 1.0, 0.80))
	iv.add_child(ititle)
	var isub := Label.new()
	isub.text = "matter absorbed by your vessel"
	isub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	isub.add_theme_font_size_override("font_size", 12)
	isub.add_theme_color_override("font_color", Color(0.45, 0.62, 0.55))
	iv.add_child(isub)
	inv_grid = GridContainer.new()
	inv_grid.columns = 5
	inv_grid.add_theme_constant_override("h_separation", 10)
	inv_grid.add_theme_constant_override("v_separation", 10)
	iv.add_child(inv_grid)
	var ihint := Label.new()
	ihint.text = "Tab — close"
	ihint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ihint.add_theme_font_size_override("font_size", 11)
	ihint.add_theme_color_override("font_color", Color(0.40, 0.55, 0.48))
	iv.add_child(ihint)

	# growth terminal panel (E at the terminal stump)
	term_panel = PanelContainer.new()
	term_panel.set_anchors_preset(Control.PRESET_CENTER)
	term_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	term_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	term_panel.add_theme_stylebox_override("panel",
		_organic_style(Color(0.04, 0.09, 0.075, 0.95), Color(1.0, 0.85, 0.35, 0.55), 22, 2, 18))
	term_panel.visible = false
	test_layer.add_child(term_panel)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 10)
	term_panel.add_child(tv)
	var ttitle := Label.new()
	ttitle.text = "G R O W T H   T E R M I N A L"
	ttitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttitle.add_theme_font_size_override("font_size", 22)
	ttitle.add_theme_color_override("font_color", Color(1.0, 0.88, 0.45))
	tv.add_child(ttitle)
	var tsub := Label.new()
	tsub.text = "craft an upgrade seed, then plant it at a glowing socket on your walls"
	tsub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tsub.add_theme_font_size_override("font_size", 12)
	tsub.add_theme_color_override("font_color", Color(0.55, 0.62, 0.50))
	tv.add_child(tsub)
	# craft grid (grows as new room purposes are added)
	var trow := GridContainer.new()
	trow.columns = 3
	trow.add_theme_constant_override("h_separation", 8)
	trow.add_theme_constant_override("v_separation", 8)
	tv.add_child(trow)
	for t in SEED_NAMES.size():
		var tb := Button.new()
		tb.text = "%s\n%s" % [SEED_NAMES[t], _cost_text(t)]
		tb.pressed.connect(_term_craft.bind(t))
		trow.add_child(tb)
		term_craft_btns.append(tb)
	# bird's-eye map of the home (view)
	term_map = Control.new()
	term_map.custom_minimum_size = TERM_MAP_SIZE
	term_map.draw.connect(_draw_term_map)
	tv.add_child(term_map)
	var thint := Label.new()
	thint.text = "Esc — close"
	thint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	thint.add_theme_font_size_override("font_size", 11)
	thint.add_theme_color_override("font_color", Color(0.40, 0.55, 0.48))
	tv.add_child(thint)
	test_layer.visible = false

func _mode_button(parent: Control, text: String, m: int) -> void:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.pressed.connect(_set_mode.bind(m))
	parent.add_child(b)
	mode_buttons[m] = b

func _tool_button(parent: Control, text: String, t: int) -> void:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.pressed.connect(_select_tool.bind(t))
	parent.add_child(b)
	tool_buttons[t] = b
	if t == sculpt_tool:
		b.button_pressed = true

func _generate_mountains() -> void:
	# Big features scaled to the world, tall peaks. Frequency ~2.5 features across the map.
	var freq := 2.5 / float(terrain.grid)
	_show_loading("Growing the world...")
	await terrain.generate(randi(), _terrain_amplitude(), freq, get_tree(), _loading_progress)
	_hide_loading()
	_refresh_terrain_biome()
	_grow_grass()
	_scatter_resources()

## Peaks scale GENTLY with map size (bigger maps a bit taller, not linearly huge —
## keeps natural climbable slopes and stops the whole map reading as mountain).
func _terrain_amplitude() -> float:
	return 72.0 * pow(float(grid_size) / 256.0, 0.42)

# --- game-mode API (called by GameMode.gd) -----------------------------------------

func flash_msg(s: String) -> void:
	_flash(s)

# --- world-generation loading overlay (Huge maps take a while; keep it visible) ---
var _load_layer: CanvasLayer
var _load_label: Label
var _load_bar: ProgressBar

func _show_loading(msg: String) -> void:
	if _load_layer == null:
		_load_layer = CanvasLayer.new()
		_load_layer.layer = 90
		add_child(_load_layer)
		var bg := ColorRect.new()
		bg.color = Color(0.02, 0.05, 0.045, 0.94)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		_load_layer.add_child(bg)
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		_load_layer.add_child(center)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 16)
		center.add_child(v)
		_load_label = Label.new()
		_load_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_load_label.add_theme_font_size_override("font_size", 28)
		_load_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.75))
		v.add_child(_load_label)
		_load_bar = ProgressBar.new()
		_load_bar.custom_minimum_size = Vector2(440, 22)
		_load_bar.min_value = 0.0
		_load_bar.max_value = 100.0
		_load_bar.show_percentage = true
		v.add_child(_load_bar)
	_load_layer.visible = true
	_load_label.text = msg
	_load_bar.value = 0.0

func _loading_progress(f: float) -> void:
	if _load_bar:
		_load_bar.value = f * 100.0

func _hide_loading() -> void:
	if _load_layer:
		_load_layer.visible = false

# --- Esc pause panel (editor mode): resume / settings / menu / quit ---------------
var _pause_layer: CanvasLayer

func _toggle_pause_panel() -> void:
	if _pause_layer and _pause_layer.visible:
		_pause_layer.visible = false
		return
	if _pause_layer == null:
		_pause_layer = CanvasLayer.new()
		_pause_layer.layer = 85
		add_child(_pause_layer)
		var bg := ColorRect.new()
		bg.color = Color(0.02, 0.05, 0.045, 0.85)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		_pause_layer.add_child(bg)
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		_pause_layer.add_child(center)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 10)
		center.add_child(v)
		var title := Label.new()
		title.text = "PAUSED"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.add_theme_font_size_override("font_size", 26)
		title.add_theme_color_override("font_color", Color(0.55, 1.0, 0.75))
		v.add_child(title)
		var res_b := Button.new()
		res_b.text = "Resume"
		res_b.custom_minimum_size = Vector2(260, 40)
		res_b.pressed.connect(func(): _pause_layer.visible = false)
		v.add_child(res_b)
		# full settings, live-applied (same UI as the main menu)
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(560, 420)
		v.add_child(scroll)
		var sv := VBoxContainer.new()
		sv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(sv)
		var SettingsUI := load("res://scripts/menu/SettingsUI.gd")
		SettingsUI.build(sv, get_viewport(), func():
			if world_env:
				Settings.apply_env(world_env.environment))
		var menu_b := Button.new()
		menu_b.text = "Main menu"
		menu_b.custom_minimum_size = Vector2(260, 40)
		menu_b.pressed.connect(_exit_to_menu)
		v.add_child(menu_b)
		var quit_b := Button.new()
		quit_b.text = "Quit"
		quit_b.custom_minimum_size = Vector2(260, 40)
		quit_b.pressed.connect(func(): get_tree().quit())
		v.add_child(quit_b)
	_pause_layer.visible = true

func _exit_to_menu() -> void:
	if game_mode:
		game_mode.save_now()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")

## Build (or load) the world for game mode. Fresh worlds start BARREN + dry.
func generate_world_for_game(seed_v: int, grid: int, barren_water_y: float) -> void:
	var dir: String = _session().world_dir if _session() else ""
	if dir != "" and FileAccess.file_exists(dir + "/world.json"):
		load_world_from(dir)
		return
	grid_size = grid
	water_level = barren_water_y
	_build_terrain(grid)
	var freq := 2.5 / float(terrain.grid)
	_show_loading("Growing the world...")
	await terrain.generate(seed_v, _terrain_amplitude(), freq, get_tree(), _loading_progress)
	_hide_loading()
	_refresh_terrain_biome()
	if water and is_instance_valid(water):
		water.position.y = water_level
	terrain_material.set_shader_parameter("water_level", water_level)

## Push the spatial bloom field to the terrain shader (origin + spreading radius).
func set_bloom_field(origin: Vector2, radius: float, cap: float) -> void:
	_game_bloom = cap
	if terrain_material:
		terrain_material.set_shader_parameter("bloom", cap)
		terrain_material.set_shader_parameter("bloom_origin", origin)
		terrain_material.set_shader_parameter("bloom_radius", radius)

## Barren world: scatter dead trees + rocks ONCE and pre-plan (but don't spawn) the
## living trees. Living growth is driven later by the spreading bloom front.
func scatter_barren_world() -> void:
	if resource_scatter == null or terrain == null:
		return
	var map_r := grid_size * 0.5
	var mul := _area_mult()
	# vegetation bands aim at the DESIGN sea level in game mode (the ocean isn't
	# born yet, but palms/shore plants must be right once it fills)
	var veg_water := 8.0 if game_mode else maxf(water_level, 0.0)
	await resource_scatter.scatter_barren(terrain, map_r, maxf(water_level, 0.0),
		int(rock_count * mul), int((tree_count + 8) * mul), int(satellite_count * mul), int(tree_count * mul),
		_terrain_amplitude() * 1.35, veg_water)
	if flora:
		flora.clear()

## Place all flora blades out to `radius` (they exist but the shader keeps them at
## scale 0 until the grow-in front passes — see set_flora_front). Called once per spread.
func plant_flora_field(origin: Vector2, radius: float) -> void:
	if flora and terrain:
		flora.rebuild(terrain, grid_size * 0.5, maxf(water_level, 0.0), _terrain_amplitude() * 1.35, 1.3 * _area_mult(), origin, radius)

## Move the flora grow-in front (per frame — grass/flowers rise out of the soil).
func set_flora_front(origin: Vector2, front: float) -> void:
	if flora:
		flora.set_grow_front(origin, front)
	for c in carpets:
		c.set_bloom(origin, front)   # sea layers ignore the front in-shader

## Sprout living trees / wither dead ones out to `front` (throttled, incremental).
func grow_trees_front(origin: Vector2, front: float, instant := false) -> void:
	if resource_scatter:
		resource_scatter.grow_front(origin, front, instant)

## Fog density from bloom proximity: thin/clear inside the living bloom, thick mist in
## the barren wastes. Skipped underwater (that state owns the fog).
func game_set_bloom_fog(density: float) -> void:
	if world_env and not _underwater:
		world_env.environment.fog_density = density

## Heavier fog in game mode so the barren basin fades into mist instead of a hard edge.
func game_denser_fog() -> void:
	if world_env == null:
		return
	var env := world_env.environment
	env.fog_enabled = true
	env.fog_density = 0.006
	env.fog_aerial_perspective = 0.85

## Drive the ocean level directly (barren -> birth -> rising tide).
func set_game_water(v: float) -> void:
	if absf(v - water_level) < 0.000001:   # NOT 0.001: per-frame tide steps are ~0.0005
		return
	water_level = v
	if water and is_instance_valid(water):
		water.position.y = water_level
	if terrain_material:
		terrain_material.set_shader_parameter("water_level", water_level)
	if player and not in_interior:
		player.water_level = _eff_water()

func start_rain_game() -> void:
	_start_rain()

## Place the player on the island centre and enter play.
func spawn_player_for_game() -> void:
	var h: float = terrain.height_at(0.0, 0.0)
	camera.global_position = Vector3(0, maxf(h, water_level) + 2.0, 0)
	camera.rotation = Vector3(0, 0, 0)
	if camera.has_method("sync_from_rotation"):
		camera.sync_from_rotation()
	_enter_test()

## Tidal Nomad start: the LOWEST walkable shore — beaches first, climb as it rises.
func spawn_player_lowest() -> void:
	var best := Vector3(0, 1e9, 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(Session.meta.get("seed", 1)) + 77
	for i in 500:
		# the WEST beach strip — the staircase always starts there
		var x := randf_range(-0.44, -0.30) * grid_size
		var z := randf_range(-0.33, 0.33) * grid_size
		var h: float = terrain.height_at(x, z)
		if h > water_level + 0.8 and h < best.y:
			best = Vector3(x, h, z)
	if best.y > 1e8:
		best = Vector3(0, terrain.height_at(0, 0), 0)
	camera.global_position = best + Vector3(0, 2.0, 0)
	camera.rotation = Vector3(0, 0, 0)
	if camera.has_method("sync_from_rotation"):
		camera.sync_from_rotation()
	_enter_test()

func stop_rain_game() -> void:
	_end_rain()

## After a storm settles: sea life fills the newly-drowned band, land life
## rescatters above the new waterline (silent, frame-yielding).
func rescatter_after_tide() -> void:
	await _scatter_resources(false)

## Serialize the whole world (terrain + props + build + home + inventory) into a
## world folder. Terraform/day live in meta.json (handled by GameMode).
func save_world_to(dir: String) -> void:
	if dir == "" or terrain == null:
		return
	var data := { "grid": grid_size, "water": water_level, "props": [] }
	if home_tree:
		data["home"] = {
			"pos": [home_tree.global_position.x, home_tree.global_position.y, home_tree.global_position.z],
			"grown": home_tree.grown,
			"rooms": tree_interior.build_log if tree_interior else [],
		}
	var inv_data := []
	for s in inv_slots:
		inv_data.append(null if s == null else { "type": s.type, "count": s.count })
	data["inv"] = inv_data
	if build:
		data["build"] = build.serialize()
	for n in props_root.get_children():
		if n is Node3D:
			data.props.append({
				"id": String(n.get_meta("asset_id", "")),
				"pos": [n.position.x, n.position.y, n.position.z],
				"rot": rad_to_deg(n.rotation.y), "scale": n.scale.x,
			})
	var f := FileAccess.open(dir + "/world.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()
	var hf := FileAccess.open(dir + "/heights.bin", FileAccess.WRITE)
	if hf:
		hf.store_buffer(terrain.heights.to_byte_array())
		hf.close()

func load_world_from(dir: String) -> void:
	var f := FileAccess.open(dir + "/world.json", FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		return
	for n in props_root.get_children():
		n.queue_free()
	_build_terrain(int(data.get("grid", grid_size)))
	if FileAccess.file_exists(dir + "/heights.bin"):
		var hf := FileAccess.open(dir + "/heights.bin", FileAccess.READ)
		terrain.set_heights(hf.get_buffer(hf.get_length()).to_float32_array())
		hf.close()
	water_level = float(data.get("water", water_level))
	if water and is_instance_valid(water):
		water.position.y = water_level
	terrain_material.set_shader_parameter("water_level", water_level)
	_refresh_terrain_biome()   # re-wire height/biome textures for shaders + carpets
	for p in data.get("props", []):
		var id := String(p.get("id", ""))
		if not lib.has_item(id) and id.begins_with("glb:"):
			lib.import_glb(id.substr(4))
		var visual: Node3D = lib.instantiate(id)
		if visual == null:
			continue
		var body := _make_placeable(visual, id)
		props_root.add_child(body)
		var pos = p.get("pos", [0, 0, 0])
		body.position = Vector3(pos[0], pos[1], pos[2])
		body.rotation.y = deg_to_rad(float(p.get("rot", 0.0)))
		body.scale = Vector3.ONE * float(p.get("scale", 1.0))
	if home_tree and is_instance_valid(home_tree):
		home_tree.queue_free()
		home_tree = null
	if data.has("home") and data.home != null:
		var hp = data.home.pos
		home_tree = HomeTreeScript.new()
		home_tree.instant = bool(data.home.get("grown", true))
		add_child(home_tree)
		home_tree.global_position = Vector3(hp[0], hp[1], hp[2])
		tree_interior = TreeInteriorScript.new()
		add_child(tree_interior)
		tree_interior.global_position = INTERIOR_ORIGIN
		tree_interior.replay(data.home.get("rooms", []))
		_recalc_capacity()
		if home_tree.grown:
			_on_tree_grown()
		else:
			home_tree.fully_grown.connect(_on_tree_grown)
	if data.has("inv"):
		inv_slots.clear()
		var inv_data: Array = data.inv
		inv_slots.resize(maxi(inv_capacity, inv_data.size()))
		for i in mini(inv_data.size(), inv_slots.size()):
			if inv_data[i] != null:
				inv_slots[i] = { "type": String(inv_data[i].type), "count": int(inv_data[i].count) }
		for c in inv_box.get_children():
			c.queue_free()
		inv_pods.clear()
		var seen := {}
		for s in inv_slots:
			if s != null and not seen.has(s.type):
				seen[s.type] = true
				_update_inv_pod(s.type)
	if build and data.has("build"):
		build.deserialize(data.build)

## Bigger maps get proportionally more grass/resources (capped for performance).
func _area_mult() -> float:
	return clampf(pow(float(grid_size) / 512.0, 2.0), 0.5, 8.0)

func _grow_grass() -> void:
	if flora and terrain:
		var mult := minf(float(flora_density) / 100.0 * _area_mult(), 5.0)
		flora.rebuild(terrain, grid_size * 0.5, water_level, _terrain_amplitude() * 1.35, mult)

func _on_flora_density(v: float) -> void:
	flora_density = int(v)

## Time slider: scrub the sun to any hour (pauses the cycle so it stays put).
func _on_time_slider(v: float) -> void:
	day_phase = clampf(v / 100.0, 0.0, 0.999)
	cycle_enabled = false
	if time_button:
		time_button.text = "Cycle: Paused"
	_update_daynight(0.0)


func _scatter_resources(show_overlay := true) -> void:
	if resource_scatter and terrain:
		if show_overlay:
			_show_loading(_tide_msg if _tide_msg != "" else "Scattering life...")
		_tide_msg = ""
		var mul := _area_mult()
		await resource_scatter.rebuild_land(terrain, grid_size * 0.5, water_level,
			int(rock_count * mul), int(tree_count * mul), int(satellite_count * mul),
			0, Vector2.ZERO, 1e9, _terrain_amplitude() * 0.9)
		if show_overlay:
			_loading_progress(0.6)
		await resource_scatter.rebuild_sea(terrain, grid_size * 0.5, water_level,
			int(crystal_count * mul), int(coral_count * mul), int(starfish_count * mul), int(kelp_count * mul))
		if show_overlay:
			_hide_loading()

func _on_rock_count(v: float) -> void:
	rock_count = int(v)

func _on_tree_count(v: float) -> void:
	tree_count = int(v)

func _on_crystal_count(v: float) -> void:
	crystal_count = int(v)

func _on_coral_count(v: float) -> void:
	coral_count = int(v)

func _on_starfish_count(v: float) -> void:
	starfish_count = int(v)

func _on_kelp_count(v: float) -> void:
	kelp_count = int(v)

func _on_satellite_count(v: float) -> void:
	satellite_count = int(v)

func _select_tool(t: int) -> void:
	sculpt_tool = t
	for k in tool_buttons:
		tool_buttons[k].button_pressed = (k == t)

func _on_strength_changed(v: float) -> void:
	brush_strength = v

var _tide_msg := ""

func _on_water_changed(v: float) -> void:
	_tide_msg = "Raising the tide..." if v > water_level else "Lowering the tide..."
	water_level = v
	_last_eff_water = -1e9   # force the effective level (base + tide) to re-apply
	_apply_eff_water()
	# re-scatter resources once the slider settles (crystals stay underwater, rocks on land)
	if water_debounce:
		water_debounce.start()

func _on_water_waves(v: float) -> void:
	if water and water.material_override:
		water.material_override.set_shader_parameter("wave_strength", v)

func _slider(parent: Control, label: String, mn: float, mx: float, val: float, step: float, cb: Callable) -> void:
	var l := Label.new(); l.text = label
	parent.add_child(l)
	var row := HBoxContainer.new()
	parent.add_child(row)
	# slider for coarse drag + spinbox for exact stepped increments (arrows / typing)
	var s := HSlider.new()
	s.min_value = mn; s.max_value = mx; s.step = step; s.value = val
	s.custom_minimum_size = Vector2(120, 0)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(s)
	var sb := SpinBox.new()
	sb.min_value = mn; sb.max_value = mx; sb.step = step; sb.value = val
	sb.custom_minimum_size = Vector2(84, 0)
	row.add_child(sb)
	s.value_changed.connect(func(v): sb.set_value_no_signal(v); cb.call(v))
	sb.value_changed.connect(func(v): s.set_value_no_signal(v); cb.call(v))

func _refresh_palette() -> void:
	if palette_box == null:
		return
	for c in palette_box.get_children():
		c.queue_free()
	for it in lib.items:
		var b := Button.new()
		b.text = it.name
		b.toggle_mode = true
		b.set_meta("item_id", it.id)
		var id: String = it.id
		b.pressed.connect(func(): _set_current(id))
		palette_box.add_child(b)
	_refresh_palette_highlight()

func _refresh_palette_highlight() -> void:
	if palette_box == null:
		return
	for c in palette_box.get_children():
		if c is Button:
			c.button_pressed = (String(c.get_meta("item_id", "")) == current_id)

func _open_import() -> void:
	import_dialog.popup_centered_ratio(0.6)

func _on_import_selected(path: String) -> void:
	var id: String = lib.import_glb(path)
	if id == "":
		_flash("Import failed"); return
	_refresh_palette()
	_set_mode(MODE_PLACE)
	_set_current(id)
	_flash("Imported " + path.get_file())

func _flash(msg: String) -> void:
	if flash_label == null:
		return
	flash_label.text = msg
	var t := get_tree().create_timer(1.8)
	t.timeout.connect(func():
		if is_instance_valid(flash_label) and flash_label.text == msg:
			flash_label.text = "")
