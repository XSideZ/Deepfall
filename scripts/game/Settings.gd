extends Node
## Global settings (autoload): loads/saves user://settings.cfg and applies
## display/graphics/audio/gameplay everywhere. F11 toggles fullscreen anywhere.

const PATH := "user://settings.cfg"

var data := {
	"fullscreen": false,
	"res_w": 1920, "res_h": 1080,
	"vsync": true,
	"render_scale": 1.0,     # 3D resolution scale (0.5 - 1.0)
	"msaa": 2,               # 0 off, 1 2x, 2 4x, 3 8x
	"fxaa": true,
	"taa": false,
	"shadow_size": 8192,     # 2048 / 4096 / 8192
	"ssao": true,
	"ssil": true,
	"glow": true,
	"volume": 1.0,
	"fov": 75.0,
	"sensitivity": 1.0,
	"show_fps": true,
}

var _fps_label: Label

func _ready() -> void:
	load_cfg()
	apply_display()
	apply_audio()
	# FPS counter (top-right, all scenes)
	var lay := CanvasLayer.new()
	lay.layer = 95
	add_child(lay)
	_fps_label = Label.new()
	_fps_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_fps_label.position = Vector2(-86, 8)
	_fps_label.add_theme_font_size_override("font_size", 15)
	_fps_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.75))
	_fps_label.add_theme_constant_override("outline_size", 4)
	_fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	lay.add_child(_fps_label)

func _process(_d: float) -> void:
	_fps_label.visible = bool(data.show_fps)
	if _fps_label.visible:
		_fps_label.text = "%d FPS" % Engine.get_frames_per_second()

func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_F11:
		data.fullscreen = not data.fullscreen
		apply_display()
		save_cfg()

func load_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for k in data.keys():
		data[k] = cfg.get_value("s", k, data[k])

func save_cfg() -> void:
	var cfg := ConfigFile.new()
	for k in data.keys():
		cfg.set_value("s", k, data[k])
	cfg.save(PATH)

# --- appliers ------------------------------------------------------------------

func apply_display() -> void:
	if data.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(int(data.res_w), int(data.res_h)))
		# centre on the current screen
		var scr := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
		var pos := DisplayServer.screen_get_position(DisplayServer.window_get_current_screen())
		DisplayServer.window_set_position(pos + (scr - DisplayServer.window_get_size()) / 2)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if data.vsync else DisplayServer.VSYNC_DISABLED)
	RenderingServer.directional_shadow_atlas_set_size(int(data.shadow_size), true)

func apply_audio() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(float(data.volume), 0.001)))

## Call from any 3D scene once it's in the tree.
func apply_viewport(vp: Viewport) -> void:
	vp.msaa_3d = int(data.msaa) as Viewport.MSAA
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if data.fxaa else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = bool(data.taa)
	vp.scaling_3d_scale = clampf(float(data.render_scale), 0.5, 1.0)

## Call after building an Environment (post-fx toggles).
func apply_env(env: Environment) -> void:
	env.ssao_enabled = bool(data.ssao)
	env.ssil_enabled = bool(data.ssil)
	env.glow_enabled = bool(data.glow)

func apply_all_runtime(vp: Viewport, env: Environment) -> void:
	apply_display()
	apply_audio()
	apply_viewport(vp)
	if env:
		apply_env(env)
