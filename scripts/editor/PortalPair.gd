extends Node
## A linked pair of see-through, walk-through portals (tree door <-> interior).
##
## Each side shows a quad textured from a SubViewport whose camera mirrors the main
## camera's pose mapped through the portal (A-space -> B-space with a 180° flip), and
## the quad samples that texture in SCREEN SPACE — the classic portal trick, so the
## parallax through the opening is correct. Walking across the plane teleports the
## body with the same mapping, so the step through is seamless.
##
## Markers: each side is a Node3D whose -Z axis points OUT of the portal, toward the
## player approaching it. Portal quads live on visual layer 2 and the portal cameras
## cull layer 2, so a portal never renders itself (no infinite recursion).

var size_a := 1.5        # circular portal diameter per side (tree arch vs interior tunnel)
var size_b := 1.5

var side_a: Node3D
var side_b: Node3D
var body: Node3D = null                 # tracked body (the test player), set via set_body
var body_cam: Node3D = null             # crossing is detected at the CAMERA for a seamless step
var crossed: Callable = Callable()      # crossed.call(went_a_to_b: bool)

var _vp_a: SubViewport   # what you see THROUGH A (rendered from B's side)
var _vp_b: SubViewport
var _cam_a: Camera3D
var _cam_b: Camera3D
var _flip := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
var _prev_za := 0.0
var _prev_zb := 0.0
var _cooldown := 0.0

func setup(a: Node3D, b: Node3D, sa := 1.5, sb := 1.5) -> void:
	side_a = a
	side_b = b
	size_a = sa
	size_b = sb
	_vp_a = _make_viewport()
	_cam_a = _make_cam(_vp_a)
	_vp_b = _make_viewport()
	_cam_b = _make_cam(_vp_b)
	_add_quad(side_a, _vp_a, sa)
	_add_quad(side_b, _vp_b, sb)

func set_body(b: Node3D) -> void:
	body = b
	body_cam = b.cam if (b != null and "cam" in b) else null
	_cooldown = 0.2

func _make_viewport() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(1024, 1024)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	return vp

func _make_cam(vp: SubViewport) -> Camera3D:
	var cam := Camera3D.new()
	cam.cull_mask = 1               # layer 1 only: portal quads (layer 2) are invisible to it
	vp.add_child(cam)
	cam.current = true
	return cam

func _add_quad(marker: Node3D, vp: SubViewport, size: float) -> void:
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(size, size)
	quad.mesh = qm
	quad.layers = 2                 # visual layer 2 (main camera sees 1|2 by default)
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/editor/portal.gdshader")
	mat.set_shader_parameter("view_tex", vp.get_texture())
	quad.material_override = mat
	quad.rotation.y = PI            # QuadMesh faces +Z; flip so it faces the marker's -Z (approach side)
	marker.add_child(quad)

func _process(delta: float) -> void:
	if side_a == null or side_b == null or not is_instance_valid(side_a) or not is_instance_valid(side_b):
		return
	var main := get_viewport().get_camera_3d()
	if main == null:
		return
	# keep render targets matched to the window for crispness
	var wsize := Vector2i(get_viewport().size)
	if _vp_a.size != wsize:
		_vp_a.size = wsize
		_vp_b.size = wsize
	# map the main camera through the portal for each side's view
	var a_to_b := side_b.global_transform * _flip * side_a.global_transform.affine_inverse()
	var b_to_a := side_a.global_transform * _flip * side_b.global_transform.affine_inverse()
	_cam_a.global_transform = a_to_b * main.global_transform
	_cam_b.global_transform = b_to_a * main.global_transform
	_cam_a.fov = main.fov
	_cam_b.fov = main.fov
	# clip everything between the portal camera and the portal plane (approximate
	# oblique clipping) — otherwise trunk/shell geometry behind the doorway blocks
	# the view as soon as you step away from the portal
	_cam_a.near = clampf(_cam_a.global_position.distance_to(side_b.global_position) - 0.45, 0.05, 500.0)
	_cam_b.near = clampf(_cam_b.global_position.distance_to(side_a.global_position) - 0.45, 0.05, 500.0)

	# walk-through teleport, detected at the CAMERA so the view swap is seamless
	if _cooldown > 0.0:
		_cooldown -= delta
	if body == null or not is_instance_valid(body) or _cooldown > 0.0:
		return
	var probe: Vector3
	if body_cam != null and is_instance_valid(body_cam):
		probe = body_cam.global_position
	else:
		probe = body.global_position + Vector3(0, 0.9, 0)
	var la := side_a.to_local(probe)
	var lb := side_b.to_local(probe)
	if _try_cross(la, _prev_za, a_to_b, true, size_a):
		pass
	elif _try_cross(lb, _prev_zb, b_to_a, false, size_b):
		pass
	_prev_za = la.z
	_prev_zb = lb.z

func _try_cross(l: Vector3, prev_z: float, xform: Transform3D, a_to_b: bool, size: float) -> bool:
	# approach from the -Z (outward) side, cross to +Z, within the doorway
	if prev_z < -0.001 and l.z >= -0.001 and l.z < 0.6 \
			and absf(l.x) < size * 0.6 and l.y > -1.8 and l.y < size * 0.7:
		body.global_transform = xform * body.global_transform
		if "velocity" in body:
			body.velocity = xform.basis * body.velocity
		_cooldown = 0.25
		_prev_za = 0.0
		_prev_zb = 0.0
		if crossed.is_valid():
			crossed.call(a_to_b)
		return true
	return false
