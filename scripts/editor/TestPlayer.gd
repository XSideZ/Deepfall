extends CharacterBody3D
## First-person play-test character. WASD move, Shift sprint, Space jump,
## double-tap Space to toggle fly (Space up / Ctrl down while flying).
## Swims when submerged (moves where you look, Space up / Ctrl down, buoyant).
## Collides with terrain (layer 1) and props (layer 2).

const WALK := 7.0
const SPRINT := 18.0
const JUMP := 7.0
const GRAVITY := 20.0
const FLY := 32.0
const FLY_SPRINT := 75.0
const SWIM := 4.5
const SWIM_SPRINT := 8.0
const MOUSE_SENS := 0.0028
const DOUBLE_TAP := 0.30

const EYE := Vector3(0, 1.6, 0)
const MOTE_RANGE := 5.5

## Emitted once per successful harvest hit (resource type, amount).
signal harvested(type: String, amount: int)
## Emitted when a resource is destroyed (third hit).
signal broke
## A build piece was destroyed — the editor unregisters it from the BuildSystem.
signal build_broken(body: Node)
## A scattered resource was destroyed at a spot (game mode schedules a timed respawn).
signal resource_broke(pos: Vector3, type: String)

const RES_COLORS := {
	"Stone": Color(0.72, 0.72, 0.75), "Wood": Color(0.65, 0.42, 0.22),
	"Crystal": Color(0.45, 0.90, 1.0), "Coral": Color(1.0, 0.55, 0.45),
	"Shard": Color(1.0, 0.22, 0.14), "Fruit": Color(1.0, 0.52, 0.62),
	"Biomass": Color(0.50, 1.0, 0.60), "Metal": Color(0.80, 0.82, 0.90),
}

var flying := false
var water_level := -1e9   # set by the editor on activate
var speed_mult := 1.0     # survival penalty: low meters slow you down
var suppress_shoot := false   # true while the build ghost / radial menu is active
var orb_motes: Array = []
var _mote_free := [true, true, true]   # all three orb motes fire independently
var _last_shot := 0.0
var _absorb_pulse := 0.0
var _pitch := 0.0
var _last_space := -10.0
var bob := 0.0

# vine grapple (RMB): latch where the crosshair aims, winch in, release to fling
const GRAP_RANGE := 55.0
const GRAP_ACCEL := 46.0
const GRAP_MAX := 34.0
const GRAP_LOOK_STEER := 1.5   # how hard looking bends the swing while attached
const AIR_LOOK_STEER := 1.9    # how hard looking bends the flight after release
var _grappling := false
var _grap_point := Vector3.ZERO
var _fling_t := 0.0          # post-release window where momentum is preserved
var _vine: MeshInstance3D
var grapple_aim_ok := false  # crosshair is on a latchable point (editor tints the reticle)

var cam: Camera3D
var cam_arm: Node3D
var hand: Node3D
var model: Node3D            # third-person character (Jay's Meshy GLB)
var _anim: AnimationPlayer   # present once a rigged export replaces player.glb
var third := false           # middle click toggles third person
var _land_t := 0.0
var _was_floor := true

func _ready() -> void:
	var caps := CapsuleShape3D.new()
	caps.radius = 0.4
	caps.height = 1.8
	var col := CollisionShape3D.new()
	col.shape = caps
	col.position.y = 0.9
	add_child(col)

	collision_layer = 4          # own layer (editor rays ignore us)
	collision_mask = 1 | 2       # collide with terrain + props
	floor_snap_length = 0.5      # stick to ramps and steps

	# camera hangs off a pitch arm so third person can boom back behind the player
	cam_arm = Node3D.new()
	cam_arm.position = EYE
	add_child(cam_arm)
	cam = Camera3D.new()
	cam_arm.add_child(cam)

	# first-person "hand" = a floating alien spore orb (we ARE the alien seed).
	# DISABLED while the character-model era begins — all mote logic still anchors
	# to it, so it stays in the tree, just invisible.
	hand = _make_hand()
	hand.position = Vector3(0.26, -0.22, -0.48)
	cam.add_child(hand)
	hand.visible = false

	# Jay's character model. Unrigged today -> procedural puppet animation;
	# the moment a rigged export lands, clips are picked up and played by name.
	var mp := "res://assets/player/player.glb"
	if ResourceLoader.exists(mp):
		var mres = load(mp)
		if mres is PackedScene:
			model = Node3D.new()
			var inst: Node3D = (mres as PackedScene).instantiate()
			inst.position = Vector3(0, 0.95, 0)   # mesh origin is at the waist
			inst.rotation.y = PI                  # GLBs usually face +Z; Godot walks -Z
			model.add_child(inst)
			add_child(model)
			_anim = inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
			model.visible = false                 # only shown in third person

	# ambient spores drifting in the air around the player (atmosphere)
	var spores := GPUParticles3D.new()
	spores.amount = 36
	spores.lifetime = 7.0
	spores.preprocess = 4.0
	spores.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(9.0, 3.0, 9.0)
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.08
	pm.initial_velocity_max = 0.35
	pm.gravity = Vector3(0, -0.02, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.35
	pm.turbulence_noise_scale = 2.0
	spores.process_material = pm
	var sm := SphereMesh.new()
	sm.radius = 0.016
	sm.height = 0.032
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.75, 1.0, 0.85, 0.8)
	smat.emission_enabled = true
	smat.emission = Color(0.45, 1.0, 0.75)
	smat.emission_energy_multiplier = 1.3
	sm.material = smat
	spores.draw_pass_1 = sm
	spores.position = Vector3(0, 1.5, 0)
	add_child(spores)

## Called by the editor when entering test mode.
func activate(yaw: float) -> void:
	rotation.y = yaw
	_pitch = 0.0
	cam_arm.rotation.x = 0.0
	cam.current = true
	_set_third(false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Middle click: first person <-> third person (to watch the character animate).
func _set_third(t: bool) -> void:
	third = t
	if model:
		model.visible = t
	cam.position = Vector3(0.45, 0.35, 3.4) if t else Vector3.ZERO

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation.y -= e.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - e.relative.y * MOUSE_SENS, -1.5, 1.5)
		cam_arm.rotation.x = _pitch
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_MIDDLE \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_set_third(not third)
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not suppress_shoot:
		if e.pressed:
			_try_grapple()
		else:
			_release_grapple(false)
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not suppress_shoot:
		_throw_mote()
	elif e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_SPACE:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_space < DOUBLE_TAP:
			flying = not flying
			velocity.y = 0.0
			_release_grapple(false)
		_last_space = now
		if not flying and is_on_floor():
			velocity.y = JUMP

func _process(dt: float) -> void:
	# the spore orb drifts, spins its motes, softly breathes — and swells when feeding
	if hand:
		var t := Time.get_ticks_msec() / 1000.0
		hand.position.y = -0.22 + sin(t * 1.4) * 0.008
		hand.rotation.y = t * 0.7
		_absorb_pulse = maxf(_absorb_pulse - dt * 1.4, 0.0)
		var pulse := 1.0 + sin(t * 2.3) * 0.05 + _absorb_pulse
		hand.scale = Vector3(pulse, pulse, pulse)

## Teleport up small ledges when walking into them (max ~0.65 m).
func _try_step(dir: Vector3) -> void:
	var step := 0.65
	var xf := global_transform
	# only step when actually BLOCKED ahead — grazing along a wall must not trigger
	# (stepping forward every frame while sliding was a free speed boost)
	if not test_move(xf, dir * 0.4):
		return
	if test_move(xf, Vector3.UP * step):
		return          # ceiling in the way
	xf.origin += Vector3.UP * step
	if test_move(xf, dir * 0.4):
		return          # still blocked at raised height -> a real wall
	xf.origin += dir * 0.4
	var q := PhysicsRayQueryParameters3D.create(xf.origin + Vector3.UP * 0.1,
		xf.origin + Vector3.DOWN * (step + 0.2), 1 | 2, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	global_position = Vector3(xf.origin.x, hit.position.y + 0.03, xf.origin.z)

func is_swimming() -> bool:
	# chest below the surface counts as swimming
	return not flying and global_position.y + 1.1 < water_level

func _physics_process(delta: float) -> void:
	var dir := Vector3.ZERO
	var b := global_transform.basis
	if Input.is_key_pressed(KEY_W): dir -= b.z
	if Input.is_key_pressed(KEY_S): dir += b.z
	if Input.is_key_pressed(KEY_A): dir -= b.x
	if Input.is_key_pressed(KEY_D): dir += b.x

	var fast := Input.is_key_pressed(KEY_SHIFT)

	if flying:
		dir = dir.normalized()
		var spd := (FLY_SPRINT if fast else FLY) * speed_mult
		velocity = dir * spd
		if Input.is_key_pressed(KEY_SPACE): velocity.y += spd
		if Input.is_key_pressed(KEY_CTRL): velocity.y -= spd
	elif is_swimming():
		# swim where you look: W follows the camera pitch
		var look := -cam.global_transform.basis.z
		var swim_dir := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): swim_dir += look
		if Input.is_key_pressed(KEY_S): swim_dir -= look
		if Input.is_key_pressed(KEY_A): swim_dir -= b.x
		if Input.is_key_pressed(KEY_D): swim_dir += b.x
		if Input.is_key_pressed(KEY_SPACE): swim_dir += Vector3.UP
		if Input.is_key_pressed(KEY_CTRL): swim_dir -= Vector3.UP
		swim_dir = swim_dir.normalized() if swim_dir != Vector3.ZERO else Vector3.ZERO
		var spd := (SWIM_SPRINT if fast else SWIM) * speed_mult
		# smooth drag toward the wish velocity; gentle sink when idle
		var target := swim_dir * spd + (Vector3.DOWN * 0.6 if swim_dir == Vector3.ZERO else Vector3.ZERO)
		velocity = velocity.lerp(target, clampf(delta * 4.0, 0.0, 1.0))
		# don't swim above the surface: at the top, Space pops you out instead
		if global_position.y + 1.3 > water_level and velocity.y > 0.0:
			if Input.is_key_pressed(KEY_SPACE) and Input.is_key_pressed(KEY_W):
				velocity.y = JUMP   # haul out onto the shore
			else:
				velocity.y = minf(velocity.y, 0.5)
	elif _grappling:
		# winch toward the anchor: strong pull along the vine, perpendicular drift
		# damped so it feels like being sucked in, gravity mostly countered
		var to := (_grap_point - (global_position + Vector3(0, 1.2, 0)))
		var d := to.length()
		if d < 2.8:
			_release_grapple(true)   # arrived — pop off with momentum kept
		else:
			var pull := to / d
			# grinding along terrain: move_and_slide redirects the pull into surface
			# slide every frame, which COMPOUNDS — winch gently while touching, and
			# hard-cap total speed so contact can never build a rocket-sled
			var touching := is_on_floor() or is_on_wall()
			var along := velocity.dot(pull)
			var perp := velocity - pull * along
			along = minf(along + GRAP_ACCEL * (0.4 if touching else 1.0) * delta, GRAP_MAX)
			velocity = pull * along + perp * maxf(1.0 - (3.5 if touching else 2.2) * delta, 0.0)
			# swing steering: bend momentum toward where you LOOK (spiderman feel) —
			# aim past the anchor to whip around it, aim aside to arc the swing
			if not touching:
				var look := -cam.global_transform.basis.z
				velocity = velocity.lerp(look * velocity.length(), clampf(GRAP_LOOK_STEER * delta, 0.0, 0.5))
			velocity.y -= GRAVITY * 0.25 * delta
			velocity = velocity.limit_length(GRAP_MAX * 1.15)
	else:
		dir.y = 0.0
		dir = dir.normalized()
		var spd := (SPRINT if fast else WALK) * speed_mult
		if _fling_t > 0.0 and not is_on_floor():
			# flung: keep momentum; LOOKING bends your flight path (speed preserved,
			# gravity untouched), WASD adds a little extra air control on top
			var hv := Vector3(velocity.x, 0, velocity.z)
			var hsp := hv.length()
			if hsp > 3.0:
				var look_h := -cam.global_transform.basis.z
				look_h.y = 0.0
				if look_h.length() > 0.1:
					var bent := hv.normalized().slerp(look_h.normalized(), clampf(AIR_LOOK_STEER * delta, 0.0, 1.0))
					velocity.x = bent.x * hsp
					velocity.z = bent.z * hsp
			velocity.x += dir.x * spd * delta * 2.6
			velocity.z += dir.z * spd * delta * 2.6
		else:
			_fling_t = 0.0
			velocity.x = dir.x * spd
			velocity.z = dir.z * spd
		if not is_on_floor():
			velocity.y -= GRAVITY * delta

	_fling_t = maxf(_fling_t - delta, 0.0)
	# grapple aim hint for the crosshair (cheap single ray)
	if _grappling:
		grapple_aim_ok = true
	elif cam and not flying:
		var gq := PhysicsRayQueryParameters3D.create(cam.global_position,
			cam.global_position + (-cam.global_transform.basis.z) * GRAP_RANGE, 1 | 2)
		grapple_aim_ok = not get_world_3d().direct_space_state.intersect_ray(gq).is_empty()
	else:
		grapple_aim_ok = false
	move_and_slide()

	# auto-step low ledges (foundation edges, doorway sills) instead of forcing a jump
	if not flying and not is_swimming() and is_on_floor() and is_on_wall():
		var h_vel := Vector3(velocity.x, 0, velocity.z)
		if h_vel.length() > 0.6:
			_try_step(h_vel.normalized())

	# footprints on sand + snow
	if not flying and not is_swimming() and is_on_floor() and Vector2(velocity.x, velocity.z).length() > 0.5:
		_footstep_check()

	# head bob when walking / running on the ground
	var horiz := Vector2(velocity.x, velocity.z).length()
	if not flying and is_on_floor() and horiz > 0.5:
		bob += delta * (2.0 + horiz * 0.6)
		if not third:
			var amp := 0.03 + horiz * 0.0015
			cam.position = Vector3(sin(bob) * amp * 0.7, sin(bob * 2.0) * amp, 0.0)
	elif not third:
		cam.position = cam.position.lerp(Vector3.ZERO, delta * 10.0)
		bob = 0.0

	_update_vine()
	_animate_model(delta, horiz)

# --- vine grapple ----------------------------------------------------------------

func _exit_tree() -> void:
	# the vine lives in the scene root (not under us) — take it along
	if _vine and is_instance_valid(_vine):
		_vine.queue_free()

func _try_grapple() -> void:
	if flying or _grappling or cam == null:
		return
	var from: Vector3 = cam.global_position
	var to := from + (-cam.global_transform.basis.z) * GRAP_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 | 2)   # terrain + props
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	_grappling = true
	_grap_point = hit.position
	_fling_t = 0.0
	if _vine == null:
		_vine = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.035
		cm.bottom_radius = 0.05
		cm.height = 1.0
		_vine.mesh = cm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.32, 0.58, 0.26)
		m.emission_enabled = true
		m.emission = Color(0.35, 0.9, 0.5)
		m.emission_energy_multiplier = 0.6
		m.roughness = 0.85
		_vine.material_override = m
		get_tree().current_scene.add_child(_vine)
	_vine.visible = true

func _release_grapple(arrived: bool) -> void:
	if not _grappling:
		return
	_grappling = false
	_fling_t = 3.0   # momentum window: fly with whatever speed you built up
	if arrived:
		velocity.y = maxf(velocity.y, 6.5)   # small pop so you crest the ledge
	if _vine:
		_vine.visible = false

func _update_vine() -> void:
	if _vine == null or not _vine.visible:
		return
	var a: Vector3 = (hand.global_position if hand else global_position + Vector3(0, 1.2, 0))
	var b := _grap_point
	var mid := (a + b) * 0.5
	var len := a.distance_to(b)
	_vine.global_position = mid
	if len > 0.01:
		_vine.look_at(b, Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.RIGHT)
		_vine.rotate_object_local(Vector3.RIGHT, PI * 0.5)   # cylinder axis = Y -> aim it
		_vine.scale = Vector3(1, len, 1)

# --- footprints (sand + snow) --------------------------------------------------
const SNOW_LEVEL := 52.0
var snow_level := SNOW_LEVEL
var _last_print := Vector3(1e9, 0, 0)
var _print_pool: Array = []
var _print_next := 0
var _print_left := true
var _fp_tex: Texture2D

func _footstep_check() -> void:
	var foot := global_position
	if foot.distance_to(_last_print) < 0.85:
		return
	# sand near the waterline, snow up high — nothing in between
	var is_snow := foot.y > snow_level - 4.0
	var is_sand := foot.y < water_level + 3.2 and foot.y > water_level - 0.5
	if not is_snow and not is_sand:
		return
	_last_print = foot
	_drop_print(foot, Color(0.15, 0.13, 0.10, 0.5) if is_sand else Color(0.55, 0.6, 0.72, 0.45))

## A soft radial texture so prints read as a pressed oval, not a hard rectangle.
func _footprint_tex() -> Texture2D:
	if _fp_tex == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.85), Color(1, 1, 1, 0.0)])
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 48
		t.height = 48
		_fp_tex = t
	return _fp_tex

func _drop_print(pos: Vector3, col: Color) -> void:
	if _print_pool.size() < 48:
		var mi := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.26, 0.4)   # elongated -> reads as a footfall, not a square
		qm.orientation = PlaneMesh.FACE_Y
		mi.mesh = qm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_texture = _footprint_tex()
		mi.material_override = m
		get_tree().current_scene.add_child(mi)
		_print_pool.append(mi)
	var fp: MeshInstance3D = _print_pool[_print_next % _print_pool.size()] if _print_pool.size() >= 48 else _print_pool[_print_pool.size() - 1]
	_print_next += 1
	var side := 0.18 if _print_left else -0.18
	_print_left = not _print_left
	var right := global_transform.basis.x
	fp.global_position = pos + right * side + Vector3(0, 0.035, 0)
	fp.rotation.y = rotation.y + randf_range(-0.12, 0.12)
	var mat := fp.material_override as StandardMaterial3D
	mat.albedo_color = col
	fp.visible = true
	var tw := create_tween()
	tw.tween_interval(6.0)
	tw.tween_property(mat, "albedo_color:a", 0.0, 5.0)

## Character animation. Rigged export -> play clips by name; unrigged (today) ->
## full-body puppet: run bob + lean, strafe banking, air stretch, landing squash.
func _animate_model(delta: float, horiz: float) -> void:
	var grounded := is_on_floor()
	if grounded and not _was_floor:
		_land_t = 0.16
	_was_floor = grounded
	_land_t = maxf(_land_t - delta, 0.0)
	if model == null or not model.visible:
		return
	if _anim:
		var want := "idle"
		if is_swimming():
			want = "swim"
		elif not grounded:
			want = "jump"
		elif horiz > 9.0:
			want = "run"
		elif horiz > 0.5:
			want = "walk"
		var clip := _best_clip(want)
		if clip != "" and _anim.current_animation != clip:
			_anim.play(clip, 0.2)
		return
	var t := Time.get_ticks_msec() / 1000.0
	var lean := clampf(horiz * 0.014, 0.0, 0.32) if grounded else 0.14
	model.rotation.x = lerpf(model.rotation.x, -lean, delta * 8.0)
	var local_v := global_transform.basis.inverse() * velocity
	model.rotation.z = lerpf(model.rotation.z, clampf(-local_v.x * 0.02, -0.28, 0.28), delta * 8.0)
	var target_y := 0.0
	var sy := 1.0
	if not grounded:
		sy = 1.07   # stretched in the air
	elif _land_t > 0.0:
		sy = 0.90   # landing squash
	elif horiz > 0.5:
		target_y = absf(sin(bob)) * 0.10   # gallop bounce synced with the head bob
		sy = 1.0 + sin(bob * 2.0) * 0.025
	else:
		sy = 1.0 + sin(t * 2.0) * 0.012    # idle breathe
	model.position.y = lerpf(model.position.y, target_y, delta * 10.0)
	var sxz := 1.0 + (1.0 - sy) * 0.6      # rough volume preservation
	model.scale = model.scale.lerp(Vector3(sxz, sy, sxz), delta * 12.0)

func _best_clip(want: String) -> String:
	for a in _anim.get_animation_list():
		if String(a).to_lower().contains(want):
			return a
	if want == "swim" or want == "jump":
		return _best_clip("idle")
	return ""

# --- first-person hand viewmodel --------------------------------------------

func _make_hand() -> Node3D:
	var path := _find_viewmodel_glb()
	if path != "" and ResourceLoader.exists(path):
		var res = ResourceLoader.load(path)
		if res is PackedScene:
			var model: Node3D = res.instantiate()
			var holder := Node3D.new()
			holder.add_child(model)
			_autofit(model, 0.45)   # normalise any GLB to ~0.45 m so scale doesn't matter
			return holder
	return _make_spore_orb()

func _find_viewmodel_glb() -> String:
	var dir := DirAccess.open("res://assets/viewmodel/")
	if dir == null:
		return ""
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.get_extension().to_lower() == "glb":
			dir.list_dir_end()
			return "res://assets/viewmodel/" + f
		f = dir.get_next()
	dir.list_dir_end()
	return ""

func _autofit(model: Node3D, target: float) -> void:
	var box := _node_aabb(model, Transform3D.IDENTITY)
	var m: float = max(box.size.x, max(box.size.y, box.size.z))
	if m > 0.0001:
		var s := target / m
		model.scale = Vector3(s, s, s)
		model.position = -box.get_center() * s

func _node_aabb(node: Node, xform: Transform3D) -> AABB:
	var out := AABB()
	var has := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		out = xform * (node as MeshInstance3D).mesh.get_aabb()
		has = true
	for c in node.get_children():
		var cx := xform
		if c is Node3D:
			cx = xform * (c as Node3D).transform
		var ca := _node_aabb(c, cx)
		if ca.size.length() > 0.0:
			out = out.merge(ca) if has else ca
			has = true
	return out

## Floating alien spore orb "hand": translucent shell, pulsing emissive core,
## three orbiting spore motes. Animated in _process (bob / spin / breathe).
func _make_spore_orb() -> Node3D:
	var root := Node3D.new()

	var shell_mat := StandardMaterial3D.new()
	shell_mat.albedo_color = Color(0.5, 0.95, 0.75, 0.30)
	shell_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shell_mat.roughness = 0.15
	shell_mat.rim_enabled = true
	shell_mat.rim = 0.9
	var shell := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.055
	sm.height = 0.11
	shell.mesh = sm
	shell.material_override = shell_mat
	root.add_child(shell)

	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = Color(0.55, 1.0, 0.8)
	core_mat.emission_enabled = true
	core_mat.emission = Color(0.35, 1.0, 0.7)
	core_mat.emission_energy_multiplier = 3.5
	var core := MeshInstance3D.new()
	var cm := SphereMesh.new()
	cm.radius = 0.026
	cm.height = 0.052
	core.mesh = cm
	core.material_override = core_mat
	root.add_child(core)

	var mote_mat := StandardMaterial3D.new()
	mote_mat.albedo_color = Color(0.7, 1.0, 0.85)
	mote_mat.emission_enabled = true
	mote_mat.emission = Color(0.5, 1.0, 0.8)
	mote_mat.emission_energy_multiplier = 2.5
	for i in 3:
		var mote := MeshInstance3D.new()
		var mm := SphereMesh.new()
		mm.radius = 0.007
		mm.height = 0.014
		mote.mesh = mm
		mote.material_override = mote_mat
		var ang := float(i) * TAU / 3.0
		mote.position = Vector3(cos(ang) * 0.085, sin(ang * 1.7) * 0.03, sin(ang) * 0.085)
		root.add_child(mote)
		orb_motes.append(mote)

	return root

# --- mote throw: the harvest tool ---------------------------------------------
# All THREE orbiting motes fire independently (rapid clicks chain shots). A hit
# sparks; the third hit SHATTERS the resource into glowing shards that get
# vacuumed back into the orb, which pulses as it absorbs the matter.

func _throw_mote() -> void:
	if cam == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_shot < 0.12:
		return
	var idx := _mote_free.find(true)
	if idx == -1:
		return
	_mote_free[idx] = false
	_last_shot = now
	if idx < orb_motes.size() and is_instance_valid(orb_motes[idx]):
		orb_motes[idx].visible = false

	var from: Vector3 = cam.global_position
	var aim: Vector3 = -cam.global_transform.basis.z
	var to := from + aim * MOTE_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to, 2)   # props layer
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var target := to
	var target_body: Node = null
	if not hit.is_empty():
		target = hit.position
		target_body = hit.collider

	var mote := _glow_ball(0.05, Color(0.7, 1.0, 0.85), 3.0)
	get_tree().current_scene.add_child(mote)
	mote.global_position = hand.global_position if hand else from

	var tw := create_tween()
	tw.tween_property(mote, "global_position", target, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# bind the body's ID, not the object — it may be freed while the mote is in flight
	tw.tween_callback(_mote_impact.bind(target_body.get_instance_id() if target_body else 0, target))
	tw.tween_property(mote, "global_position", hand.global_position if hand else from, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_mote_done.bind(mote, idx))

func _mote_impact(body_id: int, impact_pos: Vector3) -> void:
	var body := instance_from_id(body_id) if body_id != 0 else null
	if body == null or not is_instance_valid(body):
		return
	# build pieces take 2 hits and crumble (no matter absorbed)
	if body.has_meta("build"):
		var bhits: int = int(body.get_meta("hits", 2)) - 1
		body.set_meta("hits", bhits)
		_hit_sparks(impact_pos, Color(0.8, 0.7, 0.5))
		if bhits <= 0 and body is Node3D:
			broke.emit()
			build_broken.emit(body)
			_break_ring((body as Node3D).global_position + Vector3(0, 1.0, 0), Color(0.8, 0.7, 0.5))
			body.queue_free()
		return
	if not body.has_meta("resource_type"):
		return
	var type := String(body.get_meta("resource_type"))
	var col: Color = RES_COLORS.get(type, Color.WHITE)
	var hits: int = int(body.get_meta("hits", 3)) - 1
	body.set_meta("hits", hits)
	harvested.emit(type, 1)
	_hit_sparks(impact_pos, col)
	if body is Node3D:
		var b3 := body as Node3D
		if hits <= 0:
			broke.emit()
			resource_broke.emit(b3.global_position, type)
			_absorb_burst(b3.global_position + Vector3(0, 0.6, 0), col)
			_break_ring(b3.global_position + Vector3(0, 0.5, 0), col)
			# squash flat, then vanish — the matter has left the husk
			var s: Vector3 = b3.get_meta("base_scale", b3.scale)
			var tw := b3.create_tween()
			tw.tween_property(b3, "scale", Vector3(s.x * 1.25, s.y * 0.12, s.z * 1.25), 0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.tween_property(b3, "scale", Vector3(0.02, 0.02, 0.02), 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			tw.tween_callback(b3.queue_free)
		else:
			var s2: Vector3 = b3.get_meta("base_scale", b3.scale)
			var tw2 := b3.create_tween()
			tw2.tween_property(b3, "scale", s2 * 0.84, 0.05)
			tw2.tween_property(b3, "scale", s2, 0.14).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

func _mote_done(mote: Node, idx: int) -> void:
	if is_instance_valid(mote):
		mote.queue_free()
	if idx < _mote_free.size():
		_mote_free[idx] = true
	if idx < orb_motes.size() and is_instance_valid(orb_motes[idx]):
		orb_motes[idx].visible = true

# --- harvest juice -------------------------------------------------------------

func _glow_ball(r: float, col: Color, energy: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	mi.material_override = m
	return mi

## Small coloured sparks kicked out of the impact point (every hit).
func _hit_sparks(pos: Vector3, col: Color) -> void:
	for k in 4:
		var spark := _glow_ball(0.035, col, 2.4)
		get_tree().current_scene.add_child(spark)
		spark.global_position = pos
		var dir := Vector3(randf_range(-1, 1), randf_range(0.4, 1.2), randf_range(-1, 1)).normalized()
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(spark, "global_position", pos + dir * randf_range(0.5, 1.1), 0.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(spark, "scale", Vector3(0.05, 0.05, 0.05), 0.28)
		tw.chain().tween_callback(spark.queue_free)

## On break: shards fly out, hang, then get VACUUMED into the orb (staggered).
func _absorb_burst(pos: Vector3, col: Color) -> void:
	for k in 8:
		var shard := _glow_ball(randf_range(0.05, 0.09), col, 2.8)
		get_tree().current_scene.add_child(shard)
		var start := pos + Vector3(randf_range(-0.7, 0.7), randf_range(-0.2, 0.9), randf_range(-0.7, 0.7))
		shard.global_position = start
		var tw := create_tween()
		tw.tween_interval(0.04 * k)
		tw.tween_method(_shard_step.bind(shard, start), 0.0, 1.0, randf_range(0.30, 0.45)) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_callback(_shard_arrived.bind(shard))

func _shard_step(t: float, shard: Node3D, start: Vector3) -> void:
	if not is_instance_valid(shard):
		return
	var goal := hand.global_position if (hand and is_instance_valid(hand)) else global_position + Vector3(0, 1.4, 0)
	shard.global_position = start.lerp(goal, t)
	var s := 1.0 - t * 0.75
	shard.scale = Vector3(s, s, s)

func _shard_arrived(shard: Node3D) -> void:
	if is_instance_valid(shard):
		shard.queue_free()
	_absorb_pulse = minf(_absorb_pulse + 0.20, 0.6)   # the orb swells as it feeds

## Expanding fading ring at the break point.
func _break_ring(pos: Vector3, col: Color) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.22
	tm.outer_radius = 0.30
	ring.mesh = tm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(col.r, col.g, col.b, 0.85)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 2.2
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring.material_override = m
	get_tree().current_scene.add_child(ring)
	ring.global_position = pos
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3(5.0, 5.0, 5.0), 0.38).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.38)
	tw.chain().tween_callback(ring.queue_free)
