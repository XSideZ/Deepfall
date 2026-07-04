extends Control
## DeepFall main menu: Play (world manager, Subnautica-style), Editor, Settings.

const GAME_SCENE := "res://scenes/LevelEditor.tscn"

var home_center: CenterContainer
var home_box: VBoxContainer
var play_center: CenterContainer
var play_panel: PanelContainer
var settings_center: CenterContainer
var settings_panel: PanelContainer
var worlds_list: VBoxContainer
var new_name: LineEdit

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.05, 0.045)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# CenterContainer fills the screen and centres whatever child it holds — this is
	# what actually keeps the menu centred at any resolution (raw anchors don't).
	home_center = CenterContainer.new()
	home_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(home_center)

	home_box = VBoxContainer.new()
	home_box.add_theme_constant_override("separation", 14)
	home_center.add_child(home_box)

	var title := Label.new()
	title.text = "D E E P F A L L"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(0.55, 1.0, 0.75))
	home_box.add_child(title)
	var sub := Label.new()
	sub.text = "bring a dead world back to life"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", Color(0.42, 0.62, 0.52))
	home_box.add_child(sub)
	home_box.add_child(_spacer(18))

	home_box.add_child(_menu_btn("Play", _show_play))
	home_box.add_child(_menu_btn("Editor", _launch_editor))
	home_box.add_child(_menu_btn("Settings", _show_settings))
	home_box.add_child(_menu_btn("Quit", func(): get_tree().quit()))

	_build_play_panel()
	_build_settings_panel()

func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _menu_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 46)
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(cb)
	return b

func _launch_editor() -> void:
	Session.mode = "editor"
	Session.world_dir = ""
	get_tree().change_scene_to_file(GAME_SCENE)

# --- Play: the world manager -------------------------------------------------------

func _build_play_panel() -> void:
	play_center = CenterContainer.new()
	play_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	play_center.visible = false
	add_child(play_center)
	play_panel = PanelContainer.new()
	play_center.add_child(play_panel)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(560, 420)
	v.add_theme_constant_override("separation", 10)
	play_panel.add_child(v)

	var head := Label.new()
	head.text = "YOUR WORLDS"
	head.add_theme_font_size_override("font_size", 22)
	head.add_theme_color_override("font_color", Color(0.55, 1.0, 0.75))
	v.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	worlds_list = VBoxContainer.new()
	worlds_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	worlds_list.add_theme_constant_override("separation", 6)
	scroll.add_child(worlds_list)

	v.add_child(HSeparator.new())
	var nl := Label.new()
	nl.text = "NEW WORLD"
	nl.add_theme_color_override("font_color", Color(0.45, 0.75, 0.6))
	v.add_child(nl)
	new_name = LineEdit.new()
	new_name.placeholder_text = "World name..."
	v.add_child(new_name)
	var sizes := HBoxContainer.new()
	sizes.add_theme_constant_override("separation", 8)
	v.add_child(sizes)
	for s in ["Small", "Medium", "Large", "Huge"]:
		var sb := Button.new()
		sb.text = s
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.pressed.connect(_create_world.bind(s))
		sizes.add_child(sb)

	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_show_home)
	v.add_child(back)

func _show_home() -> void:
	play_center.visible = false
	settings_center.visible = false
	home_center.visible = true

func _show_play() -> void:
	home_center.visible = false
	settings_center.visible = false
	play_center.visible = true
	_refresh_worlds()

func _refresh_worlds() -> void:
	for c in worlds_list.get_children():
		c.queue_free()
	var worlds: Array = Session.list_worlds()
	if worlds.is_empty():
		var none := Label.new()
		none.text = "no worlds yet — create one below"
		none.add_theme_color_override("font_color", Color(0.45, 0.55, 0.5))
		worlds_list.add_child(none)
	for w in worlds:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		worlds_list.add_child(row)
		var info := Label.new()
		info.text = "%s   ·   %s  ·  Day %d  ·  bloom %d%%" % [
			String(w.get("name", "?")), String(w.get("size", "?")),
			int(w.get("day", 1)), int(float(w.get("terraform", 0.0)) * 100.0)]
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		var pb := Button.new()
		pb.text = "Play"
		pb.pressed.connect(_play_world.bind(String(w.dir)))
		row.add_child(pb)
		var db := Button.new()
		db.text = "✕"
		db.tooltip_text = "Delete world (double-click)"
		db.pressed.connect(_confirm_delete.bind(db, String(w.dir)))
		row.add_child(db)

func _confirm_delete(btn: Button, dir: String) -> void:
	if btn.text == "✕":
		btn.text = "sure?"
		await get_tree().create_timer(2.0).timeout
		if is_instance_valid(btn):
			btn.text = "✕"
	else:
		Session.delete_world(dir)
		_refresh_worlds()

func _create_world(size_label: String) -> void:
	var wname := new_name.text.strip_edges()
	if wname == "":
		wname = "New world"
	var dir: String = Session.create_world(wname, size_label)
	_play_world(dir)

func _play_world(dir: String) -> void:
	Session.mode = "game"
	Session.world_dir = dir
	Session.meta = Session.load_meta(dir)
	Session.meta["last_played"] = Time.get_unix_time_from_system()
	Session.save_meta(dir, Session.meta)
	get_tree().change_scene_to_file(GAME_SCENE)

# --- settings -----------------------------------------------------------------------

func _build_settings_panel() -> void:
	settings_center = CenterContainer.new()
	settings_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_center.visible = false
	add_child(settings_center)
	settings_panel = PanelContainer.new()
	settings_center.add_child(settings_panel)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(520, 0)
	v.add_theme_constant_override("separation", 8)
	settings_panel.add_child(v)
	var head := Label.new()
	head.text = "SETTINGS"
	head.add_theme_font_size_override("font_size", 22)
	head.add_theme_color_override("font_color", Color(0.55, 1.0, 0.75))
	v.add_child(head)

	_sec(v, "DISPLAY")
	_opt(v, "Window", ["Windowed", "Fullscreen  (F11)"], 1 if Settings.data.fullscreen else 0,
		func(i): Settings.data.fullscreen = (i == 1); _apply())
	_opt(v, "Resolution", ["1280 x 720", "1600 x 900", "1920 x 1080", "2560 x 1440"],
		{"1280": 0, "1600": 1, "1920": 2, "2560": 3}.get(str(int(Settings.data.res_w)), 2),
		func(i):
			var r: Array = [[1280, 720], [1600, 900], [1920, 1080], [2560, 1440]][i]
			Settings.data.res_w = r[0]
			Settings.data.res_h = r[1]
			_apply())
	_chk(v, "VSync", Settings.data.vsync, func(on): Settings.data.vsync = on; _apply())
	_chk(v, "FPS counter", Settings.data.show_fps, func(on): Settings.data.show_fps = on; _apply())

	_sec(v, "GRAPHICS")
	_opt(v, "Anti-aliasing (MSAA)", ["Off", "2x", "4x", "8x"], int(Settings.data.msaa),
		func(i): Settings.data.msaa = i; _apply())
	_chk(v, "FXAA", Settings.data.fxaa, func(on): Settings.data.fxaa = on; _apply())
	_chk(v, "TAA (softer, can ghost)", Settings.data.taa, func(on): Settings.data.taa = on; _apply())
	_opt(v, "Shadows", ["Low", "Medium", "High"], {2048: 0, 4096: 1, 8192: 2}.get(int(Settings.data.shadow_size), 2),
		func(i): Settings.data.shadow_size = [2048, 4096, 8192][i]; _apply())
	_chk(v, "Ambient occlusion (SSAO)", Settings.data.ssao, func(on): Settings.data.ssao = on; _apply())
	_chk(v, "Bounce light (SSIL)", Settings.data.ssil, func(on): Settings.data.ssil = on; _apply())
	_chk(v, "Bloom / glow", Settings.data.glow, func(on): Settings.data.glow = on; _apply())
	_sld(v, "3D render scale %", 50, 100, Settings.data.render_scale * 100.0,
		func(val): Settings.data.render_scale = val / 100.0; _apply())

	_sec(v, "AUDIO")
	_sld(v, "Volume %", 0, 100, Settings.data.volume * 100.0,
		func(val): Settings.data.volume = val / 100.0; _apply())

	_sec(v, "GAMEPLAY")
	_sld(v, "Field of view", 60, 110, Settings.data.fov,
		func(val): Settings.data.fov = val; _apply())
	_sld(v, "Mouse sensitivity %", 30, 200, Settings.data.sensitivity * 100.0,
		func(val): Settings.data.sensitivity = val / 100.0; _apply())

	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_show_home)
	v.add_child(back)

func _show_settings() -> void:
	home_center.visible = false
	play_center.visible = false
	settings_center.visible = true

func _apply() -> void:
	Settings.save_cfg()
	Settings.apply_display()
	Settings.apply_audio()
	Settings.apply_viewport(get_viewport())

func _sec(parent: Control, txt: String) -> void:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.45, 0.75, 0.6))
	parent.add_child(l)

func _row(parent: Control, txt: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var l := Label.new()
	l.text = txt
	l.custom_minimum_size = Vector2(230, 0)
	h.add_child(l)
	parent.add_child(h)
	return h

func _opt(parent: Control, txt: String, items: Array, sel: int, cb: Callable) -> void:
	var h := _row(parent, txt)
	var o := OptionButton.new()
	for it in items:
		o.add_item(it)
	o.selected = clampi(sel, 0, items.size() - 1)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.item_selected.connect(cb)
	h.add_child(o)

func _chk(parent: Control, txt: String, on: bool, cb: Callable) -> void:
	var h := _row(parent, txt)
	var c := CheckButton.new()
	c.button_pressed = on
	c.toggled.connect(cb)
	h.add_child(c)

func _sld(parent: Control, txt: String, lo: float, hi: float, val: float, cb: Callable) -> void:
	var h := _row(parent, txt)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = 1
	sl.value = val
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.value_changed.connect(cb)
	h.add_child(sl)
