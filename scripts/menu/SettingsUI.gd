extends RefCounted
## Shared settings UI: builds the full options list into any container.
## Used by the main menu AND the in-game Esc pause panel — one source of truth.

static func build(v: VBoxContainer, vp: Viewport, extra_apply := Callable()) -> void:
	var ap := func():
		Settings.save_cfg()
		Settings.apply_display()
		Settings.apply_audio()
		Settings.apply_viewport(vp)
		if extra_apply.is_valid():
			extra_apply.call()

	_sec(v, "DISPLAY")
	_opt(v, "Window", ["Windowed", "Fullscreen  (F11)"], 1 if Settings.data.fullscreen else 0,
		func(i): Settings.data.fullscreen = (i == 1); ap.call())
	_opt(v, "Resolution", ["1280 x 720", "1600 x 900", "1920 x 1080", "2560 x 1440"],
		{"1280": 0, "1600": 1, "1920": 2, "2560": 3}.get(str(int(Settings.data.res_w)), 2),
		func(i):
			var r: Array = [[1280, 720], [1600, 900], [1920, 1080], [2560, 1440]][i]
			Settings.data.res_w = r[0]
			Settings.data.res_h = r[1]
			ap.call())
	_chk(v, "VSync", Settings.data.vsync, func(on): Settings.data.vsync = on; ap.call())
	_chk(v, "FPS counter", Settings.data.show_fps, func(on): Settings.data.show_fps = on; ap.call())

	_sec(v, "GRAPHICS")
	_opt(v, "Anti-aliasing (MSAA)", ["Off", "2x", "4x", "8x"], int(Settings.data.msaa),
		func(i): Settings.data.msaa = i; ap.call())
	_chk(v, "FXAA", Settings.data.fxaa, func(on): Settings.data.fxaa = on; ap.call())
	_chk(v, "TAA (softer, can ghost)", Settings.data.taa, func(on): Settings.data.taa = on; ap.call())
	_opt(v, "Shadows", ["Low", "Medium", "High"], {2048: 0, 4096: 1, 8192: 2}.get(int(Settings.data.shadow_size), 2),
		func(i): Settings.data.shadow_size = [2048, 4096, 8192][i]; ap.call())
	_chk(v, "Ambient occlusion (SSAO)", Settings.data.ssao, func(on): Settings.data.ssao = on; ap.call())
	_chk(v, "Bounce light (SSIL)", Settings.data.ssil, func(on): Settings.data.ssil = on; ap.call())
	_chk(v, "Bloom / glow", Settings.data.glow, func(on): Settings.data.glow = on; ap.call())
	_sld(v, "3D render scale %", 50, 100, Settings.data.render_scale * 100.0,
		func(val): Settings.data.render_scale = val / 100.0; ap.call())

	_sec(v, "AUDIO")
	_sld(v, "Volume %", 0, 100, Settings.data.volume * 100.0,
		func(val): Settings.data.volume = val / 100.0; ap.call())

	_sec(v, "GAMEPLAY")
	_sld(v, "Field of view", 60, 110, Settings.data.fov,
		func(val): Settings.data.fov = val; ap.call())
	_sld(v, "Mouse sensitivity %", 30, 200, Settings.data.sensitivity * 100.0,
		func(val): Settings.data.sensitivity = val / 100.0; ap.call())

static func _sec(parent: Control, txt: String) -> void:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.45, 0.75, 0.6))
	parent.add_child(l)

static func _row(parent: Control, txt: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var l := Label.new()
	l.text = txt
	l.custom_minimum_size = Vector2(230, 0)
	h.add_child(l)
	parent.add_child(h)
	return h

static func _opt(parent: Control, txt: String, items: Array, sel: int, cb: Callable) -> void:
	var h := _row(parent, txt)
	var o := OptionButton.new()
	for it in items:
		o.add_item(it)
	o.selected = clampi(sel, 0, items.size() - 1)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.item_selected.connect(cb)
	h.add_child(o)

static func _chk(parent: Control, txt: String, on: bool, cb: Callable) -> void:
	var h := _row(parent, txt)
	var c := CheckButton.new()
	c.button_pressed = on
	c.toggled.connect(cb)
	h.add_child(c)

static func _sld(parent: Control, txt: String, lo: float, hi: float, val: float, cb: Callable) -> void:
	var h := _row(parent, txt)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = 1
	sl.value = val
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.value_changed.connect(cb)
	h.add_child(sl)
