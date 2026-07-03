extends Node
## Runtime audio: ambient loops (wind / waves / rain / interior hum / underwater)
## crossfaded from game state each frame, plus one-shot effects. All sounds are
## synthesized at boot by AudioGen — no audio files needed.

const AudioGenScript := preload("res://scripts/editor/AudioGen.gd")

var editor
var loops := {}          # name -> AudioStreamPlayer
var vols := {}           # name -> current linear volume
var fx := {}             # name -> AudioStreamWAV
var pool: Array = []
var _pool_idx := 0

func setup(ed) -> void:
	editor = ed
	loops["wind"] = _looper(AudioGenScript.noise_loop(3.0, 0.045, 2.4, 11))
	loops["waves"] = _looper(AudioGenScript.waves_loop())
	loops["rain"] = _looper(AudioGenScript.noise_loop(2.0, 0.30, 0.9, 22))
	loops["hum"] = _looper(AudioGenScript.hum_loop())
	loops["under"] = _looper(AudioGenScript.noise_loop(3.0, 0.018, 3.4, 33))
	for k in loops:
		vols[k] = 0.0
	fx["hit"] = AudioGenScript.pop(420.0, 150.0, 0.09, 0.5)
	fx["break"] = AudioGenScript.pop(200.0, 55.0, 0.22, 0.7)
	fx["chime"] = AudioGenScript.chime(660.0, 990.0)
	fx["portal"] = AudioGenScript.chime(880.0, 1320.0)
	fx["grow"] = AudioGenScript.whoosh()
	fx["thud"] = AudioGenScript.thud()
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.volume_db = -6.0
		add_child(p)
		pool.append(p)

func _looper(stream: AudioStreamWAV) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = -80.0
	add_child(p)
	p.play()
	return p

func play(name: String, pitch_var := 0.08, vol_db := -6.0) -> void:
	if not fx.has(name):
		return
	var p: AudioStreamPlayer = pool[_pool_idx]
	_pool_idx = (_pool_idx + 1) % pool.size()
	p.stream = fx[name]
	p.pitch_scale = randf_range(1.0 - pitch_var, 1.0 + pitch_var)
	p.volume_db = vol_db
	p.play()

func _process(delta: float) -> void:
	if editor == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var underwater: bool = editor._underwater
	var interior: bool = editor.in_interior
	var h: float = cam.global_position.y - editor._eff_water()
	var muffled := underwater or interior

	var targets := {
		"wind": 0.0 if muffled else clampf(0.30 + h / 160.0, 0.22, 0.85) * (1.0 + editor.rain_intensity * 0.4),
		"waves": 0.0 if muffled else clampf(1.0 - absf(h) / 40.0, 0.0, 1.0) * 0.8,
		"rain": 0.0 if muffled else editor.rain_intensity,
		"hum": 0.9 if interior else 0.0,
		"under": 0.9 if underwater else 0.0,
	}
	for k in loops:
		vols[k] = lerpf(vols[k], targets[k], clampf(delta * 2.5, 0.0, 1.0))
		var p: AudioStreamPlayer = loops[k]
		p.volume_db = linear_to_db(maxf(vols[k] * 0.8, 0.0001))
