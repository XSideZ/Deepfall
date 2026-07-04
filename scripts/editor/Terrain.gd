extends Node3D
## Runtime heightmap terrain with brush sculpting.
## 1 unit = 1 cell (so HeightMapShape3D needs no scaling — GodotPhysics can't do
## non-uniform scale on it). Visual mesh is an ArrayMesh rebuilt per edit; only the
## touched region is recomputed on the CPU. Collision is a HeightMapShape3D.

# Tidal-Nomad elevation bands (fractions of the generation amplitude):
# below DESERT = forest 1, DESERT..FOREST2 = desert, FOREST2..SNOW = forest 2, above = snow
const BAND_DESERT := 0.30
const BAND_FOREST2 := 0.52
const BAND_SNOW := 0.74

# Sculpt modes (match LevelEditor tool ints)
const RAISE := 0
const LOWER := 1
const SMOOTH := 2
const FLATTEN := 3

var grid: int = 160                 # cells per side; verts per side = grid + 1
var heights := PackedFloat32Array()
var mesas: Array = []               # { x, z (world), top_r, h } — for waterfall decoration
var hm_dirty := true                # height texture needs a refresh
var _hm_tex: ImageTexture
var biomes := PackedFloat32Array()  # per-vertex biome 0..1 (desert..plains..jungle)
var _biome_tex: ImageTexture

var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()

var mesh_instance: MeshInstance3D
var array_mesh: ArrayMesh
var body: StaticBody3D
var hshape: HeightMapShape3D

func build(n: int, ground_layer: int, material: Material) -> void:
	grid = n
	var side := grid + 1
	heights = PackedFloat32Array()
	heights.resize(side * side)      # zero-filled -> flat

	# --- collision (HeightMapShape3D, unit spacing, centered) ---
	body = StaticBody3D.new()
	body.collision_layer = ground_layer
	body.collision_mask = 0
	add_child(body)
	hshape = HeightMapShape3D.new()
	hshape.map_width = side
	hshape.map_depth = side
	hshape.map_data = heights
	var cs := CollisionShape3D.new()
	cs.shape = hshape
	body.add_child(cs)

	# --- visual mesh ---
	array_mesh = ArrayMesh.new()
	mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = array_mesh
	if material:
		mesh_instance.material_override = material
	add_child(mesh_instance)

	_build_static_arrays()
	_verts.resize(side * side)
	_normals.resize(side * side)
	update_region(0, grid, 0, grid)
	_upload()
	_update_collision()

func _build_static_arrays() -> void:
	var side := grid + 1
	_uvs = PackedVector2Array()
	_uvs.resize(side * side)
	for z in side:
		for x in side:
			_uvs[z * side + x] = Vector2(float(x) / grid, float(z) / grid)
	_indices = PackedInt32Array()
	for z in grid:
		for x in grid:
			var i00 := z * side + x
			var i10 := i00 + 1
			var i01 := i00 + side
			var i11 := i01 + 1
			_indices.append_array([i00, i01, i11, i00, i11, i10])

func _h(x: int, z: int) -> float:
	x = clampi(x, 0, grid)
	z = clampi(z, 0, grid)
	return heights[z * (grid + 1) + x]

func update_region(x0: int, x1: int, z0: int, z1: int) -> void:
	var side := grid + 1
	var half := grid * 0.5
	x0 = maxi(x0 - 1, 0); x1 = mini(x1 + 1, grid)
	z0 = maxi(z0 - 1, 0); z1 = mini(z1 + 1, grid)
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var i := z * side + x
			_verts[i] = Vector3(x - half, heights[i], z - half)
			_normals[i] = Vector3(_h(x - 1, z) - _h(x + 1, z), 2.0, _h(x, z - 1) - _h(x, z + 1)).normalized()

func _upload() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_INDEX] = _indices
	array_mesh.clear_surfaces()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func _update_collision() -> void:
	hshape.map_data = heights
	hm_dirty = true

## Heights as an RF texture (direct view of the height array — cheap to refresh).
func height_texture() -> ImageTexture:
	if _hm_tex == null or hm_dirty:
		var side := grid + 1
		var img := Image.create_from_data(side, side, false, Image.FORMAT_RF, heights.to_byte_array())
		if _hm_tex == null:
			_hm_tex = ImageTexture.create_from_image(img)
		else:
			_hm_tex.update(img)
		hm_dirty = false
	return _hm_tex

## Biome value at a world position (0 desert .. 0.5 plains .. 1 jungle).
func biome_at(wx: float, wz: float) -> float:
	var side := grid + 1
	if biomes.size() != side * side:
		return 0.5
	var x := clampi(int(round(wx + grid * 0.5)), 0, grid)
	var z := clampi(int(round(wz + grid * 0.5)), 0, grid)
	return biomes[z * side + x]

## Biome weights as an RF texture (0 desert .. 0.5 plains .. 1 jungle) for the shader.
func biome_texture() -> ImageTexture:
	var side := grid + 1
	if biomes.size() != side * side:
		return null
	var img := Image.create_from_data(side, side, false, Image.FORMAT_RF, biomes.to_byte_array())
	if _biome_tex == null:
		_biome_tex = ImageTexture.create_from_image(img)
	else:
		_biome_tex.update(img)
	return _biome_tex

func _neighbor_avg(x: int, z: int) -> float:
	return (_h(x - 1, z) + _h(x + 1, z) + _h(x, z - 1) + _h(x, z + 1)) * 0.25

## Apply a brush stroke centered on a world-space point.
func sculpt(world_pos: Vector3, radius: float, amount: float, mode: int, target_h: float) -> void:
	var side := grid + 1
	var half := grid * 0.5
	var cx := world_pos.x + half
	var cz := world_pos.z + half
	var x0 := maxi(int(floor(cx - radius)), 0)
	var x1 := mini(int(ceil(cx + radius)), grid)
	var z0 := maxi(int(floor(cz - radius)), 0)
	var z1 := mini(int(ceil(cz + radius)), grid)
	if x0 > x1 or z0 > z1:
		return
	var rate := clampf(absf(amount), 0.0, 1.0)
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var dx := x - cx
			var dz := z - cz
			var d := sqrt(dx * dx + dz * dz)
			if d > radius:
				continue
			var f := 1.0 - d / radius
			f = f * f * (3.0 - 2.0 * f)     # smoothstep falloff
			var i := z * side + x
			match mode:
				RAISE:
					heights[i] += amount * f
				LOWER:
					heights[i] -= amount * f
				SMOOTH:
					heights[i] = lerpf(heights[i], _neighbor_avg(x, z), rate * f)
				FLATTEN:
					heights[i] = lerpf(heights[i], target_h, rate * f)
	update_region(x0, x1, z0, z1)
	_upload()
	_update_collision()

## Fill the whole terrain from layered noise (mountains / valleys).
## Dramatic terrain: domain-warped base hills + ridged-multifractal mountain ridges,
## with terraced cliff bands in the highlands. Heightmap (no overhangs) but the
## terracing + steep ridges give strong verticality and readable cliffs.
## tree/progress: when given, generation yields every few rows so the window stays
## responsive (Huge = ~2.4M vertices of pure script noise — it froze "not responding").
func generate(noise_seed: int, amplitude: float, frequency: float, tree: SceneTree = null, progress := Callable()) -> void:
	var n_base := FastNoiseLite.new()
	n_base.seed = noise_seed
	n_base.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n_base.frequency = frequency
	n_base.fractal_type = FastNoiseLite.FRACTAL_FBM
	n_base.fractal_octaves = 5
	# domain-warp field: twists the whole landscape so nothing looks grid-aligned
	var warp := FastNoiseLite.new()
	warp.seed = noise_seed + 111
	warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp.frequency = frequency * 0.55
	warp.fractal_octaves = 3
	# ridged field: 1-|noise| gives sharp knife-edge ridges (mountains, cliffs)
	var ridge := FastNoiseLite.new()
	ridge.seed = noise_seed + 271
	ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ridge.frequency = frequency * 0.95
	ridge.fractal_type = FastNoiseLite.FRACTAL_FBM
	ridge.fractal_octaves = 3
	# mask: where the world turns mountainous vs rolling lowland
	# BIOME field (low frequency = big regions): 0 desert .. 0.5 plains .. 1 jungle highlands
	var biome_n := FastNoiseLite.new()
	biome_n.seed = noise_seed + 907
	biome_n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	biome_n.frequency = frequency * 0.45
	biome_n.fractal_octaves = 2
	# PLATEAU field (low freq, smooth): quantized into distinct flat shelves that step up
	# the highlands with steep cliffs between them (buildable elevated spots)
	var plateau_n := FastNoiseLite.new()
	plateau_n.seed = noise_seed + 1301
	plateau_n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	plateau_n.frequency = frequency * 0.34   # lower = bigger flat shelves + gentler ramps
	plateau_n.fractal_octaves = 3
	# REGION TIERS: split the map into a few big SECTIONS, each at a distinct base
	# elevation with cliff edges — this is what makes verticality READ (stand on a high
	# section, walk to the edge, see the drop). Count + span scale with map size.
	var num_tiers := clampi(3 + int(grid / 512), 3, 6)
	var sections_across: float = clampf(2.2 + float(grid) / 620.0, 2.2, 5.5)
	var region_n := FastNoiseLite.new()
	region_n.seed = noise_seed + 4201
	region_n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	region_n.frequency = sections_across / float(grid)
	region_n.fractal_octaves = 2
	# PASS field: where it runs high, the section cliff softens into a walkable
	# valley ramp — natural paths up between tiers instead of sheer walls everywhere
	var pass_n := FastNoiseLite.new()
	pass_n.seed = noise_seed + 6007
	pass_n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	pass_n.frequency = frequency * 1.15
	# CLIFF-HEIGHT variation: a slow field that scales the whole tier ladder region by
	# region — some cliff edges are short hops, others are towering walls. Quantized
	# (with its own soft risers) so the flat tier tops STAY flat.
	var cliffvar_n := FastNoiseLite.new()
	cliffvar_n.seed = noise_seed + 7717
	cliffvar_n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	cliffvar_n.frequency = sections_across * 0.75 / float(grid)

	biomes = PackedFloat32Array()
	biomes.resize((grid + 1) * (grid + 1))
	var warp_amp := 20.0
	var plateau_levels := 5.0
	var side := grid + 1
	var half := grid * 0.5
	for z in side:
		if tree and (z % 48) == 0:
			if progress.is_valid():
				progress.call(float(z) / float(side) * 0.9)
			await tree.process_frame
		for x in side:
			var fx := float(x)
			var fz := float(z)
			# domain warp the sample position
			var wx := fx + warp.get_noise_2d(fx, fz) * warp_amp
			var wz := fz + warp.get_noise_2d(fx + 517.0, fz + 517.0) * warp_amp
			# TIDAL-NOMAD biomes are ELEVATION BANDS (assigned after height below);
			# here only the plains/jungle mix shapes the terrain
			var b01 := clampf(biome_n.get_noise_2d(fx, fz) * 0.5 + 0.5, 0.0, 1.0)
			b01 = clampf((b01 - 0.5) * 1.8 + 0.5, 0.0, 1.0)
			var w_desert := 0.0
			var w_ice := 0.0
			var w_jungle := smoothstep(0.55, 0.78, b01)
			var w_plain: float = 1.0 - w_jungle

			# rolling base hills
			var b := clampf(n_base.get_noise_2d(wx, wz) * 0.5 + 0.5, 0.0, 1.0)
			b = pow(b, 1.8)

			# BIG FLAT SHELVES: a smooth field quantized into wide dead-flat treads (~80% of
			# each step, great to build on) joined by CLIMBABLE ramps (18% of the raw slope
			# blended back in, so you can naturally walk up between levels).
			var plat := clampf(plateau_n.get_noise_2d(wx, wz) * 0.5 + 0.5, 0.0, 1.0)
			var lp := plat * plateau_levels
			var pstep: float = floor(lp)
			var pfrac: float = lp - pstep
			var priser := smoothstep(0.56, 1.0, pfrac)   # wide riser = walkable curvy hill shoulders
			var plateau_h: float = lerpf((pstep + priser) / plateau_levels, plat, 0.14)
			# soft low-freq ridge crown so the highest shelves aren't perfectly table-flat
			var r := 1.0 - absf(ridge.get_noise_2d(wx, wz))
			r = pow(clampf(r, 0.0, 1.0), 1.4)
			var peak := r * 0.07 * smoothstep(0.65, 1.0, plat)

			# plains = gentle shelved hills (the dominant look); jungle = taller shelved highlands
			var h_plain: float = lerpf(b * 0.4, plateau_h, 0.6) * 0.82
			var h_mtn: float = (plateau_h * 0.95 + peak) * 1.35
			# desert: big smooth dunes
			var dune := clampf(n_base.get_noise_2d(wx * 0.5, wz * 0.5) * 0.5 + 0.5, 0.0, 1.0)
			var h_desert := pow(dune, 1.4) * 0.6 + sin((wx + wz) * 0.045) * 0.04 + 0.05
			# LOCAL detail: gentle hills + small shelves that live INSIDE each region tier
			# (the ice field is shaped like the plains — snowy shelved hills)
			var local_norm: float = h_plain * (w_plain + w_ice) + h_desert * w_desert + h_mtn * w_jungle

			# REGION TIER: the dominant base elevation of this big section (flat, with a
			# cliff at its boundary). Lowest tier sits underwater so seas form in the basins.
			var region_v := clampf(region_n.get_noise_2d(fx, fz) * 0.5 + 0.5, 0.0, 1.0)
			var rlp := region_v * float(num_tiers)
			var rstep: float = floor(rlp)
			var rfrac: float = rlp - rstep
			var rriser := smoothstep(0.46, 1.0, rfrac)   # long ramped ascent — a real path up to each plateau
			# valley passes: stretches of each cliff soften into a long climbable ramp
			var pass_v := clampf(pass_n.get_noise_2d(fx, fz) * 0.5 + 0.5, 0.0, 1.0)
			var pass_w := smoothstep(0.52, 0.70, pass_v)   # more/wider valley routes
			rriser = lerpf(rriser, rfrac, pass_w)
			var tier_norm: float = (rstep + rriser) / float(num_tiers)
			# scale the ladder by the quantized cliff-height field (0.7x .. 1.3x): whole
			# stretches of cliff run short (hoppable) or tall (grapple walls)
			var cv := clampf(cliffvar_n.get_noise_2d(fx, fz) * 0.5 + 0.5, 0.0, 1.0)
			var cvl := cv * 4.0
			var cvstep: float = floor(cvl)
			var cvriser := smoothstep(0.7, 0.97, cvl - cvstep)
			var tier_scale: float = 0.7 + 0.6 * ((cvstep + cvriser) / 4.0)
			var tier_base: float = lerpf(-0.22, 1.0, tier_norm) * tier_scale   # tier 0 = underwater basin

			# a high section reads as high because its flat top sits well above the next,
			# with the hills adding texture on top
			var hnorm: float = tier_base * 0.72 + local_norm * 0.42
			var height := hnorm * amplitude
			# radial falloff: sink land to an ocean floor before the map edge
			var nx := (fx - half) / half
			var nz := (fz - half) / half
			var rr := sqrt(nx * nx + nz * nz)
			var fall := 1.0 - smoothstep(0.55, 0.95, rr)
			var idx := z * side + x
			heights[idx] = lerpf(-16.0, height, fall)
			# TIDAL-NOMAD biome sandwich by ELEVATION: beach (waterline sand band in the
			# shader) -> forest -> desert -> forest 2 -> snow peaks; boundaries rippled
			# by noise so bands wander instead of reading as contour lines
			var hb := heights[idx] + biome_n.get_noise_2d(fx * 1.8, fz * 1.8) * amplitude * 0.045
			var bio_v := 0.5                       # forest 1 (bright plains green)
			if hb > amplitude * BAND_SNOW:
				bio_v = 1.7                        # snow peaks
			elif hb > amplitude * BAND_FOREST2:
				bio_v = 1.0                        # forest 2 (deep jungle green)
			elif hb > amplitude * BAND_DESERT:
				bio_v = 0.05                       # desert belt
			biomes[idx] = bio_v

	# mesa buttes: wide flat-topped rock rises blended smoothly into the ground
	# (lerp toward the plateau height -> no pedestal ring / square base), kept below
	# the snow line so they stay red rock instead of snow-capped blobs
	var mrng := RandomNumberGenerator.new()
	mrng.seed = noise_seed + 7707
	mesas.clear()
	var mesa_count := clampi(grid / 128, 2, 4)
	var placed_mesas := 0
	var tries := 0
	while placed_mesas < mesa_count and tries < 60:
		tries += 1
		var mx := int(half + mrng.randf_range(-0.42, 0.42) * grid)
		var mz := int(half + mrng.randf_range(-0.42, 0.42) * grid)
		var base := heights[mz * side + mx]
		if base < 2.0 or base > 18.0:
			continue
		var top_r := mrng.randf_range(7.0, 14.0)
		var fall_w := mrng.randf_range(7.0, 12.0)
		var target := minf(base + mrng.randf_range(14.0, 26.0), 44.0)
		var reach := int(ceil(top_r + fall_w))
		for dz in range(-reach, reach + 1):
			for dx in range(-reach, reach + 1):
				var px := mx + dx
				var pz := mz + dz
				if px < 0 or px > grid or pz < 0 or pz > grid:
					continue
				var d := sqrt(float(dx * dx + dz * dz))
				var t := clampf(1.0 - (d - top_r) / fall_w, 0.0, 1.0)
				var prof := t * t * (3.0 - 2.0 * t)   # smooth at BOTH the rim and the base
				var idx := pz * side + px
				if target > heights[idx]:
					heights[idx] = lerpf(heights[idx], target, prof)
		mesas.append({ "x": float(mx) - half, "z": float(mz) - half, "top_r": top_r, "h": target })
		placed_mesas += 1

	# round off every crest, terrace lip, and warp artifact (fewer passes on huge grids)
	await _smooth_heights(2 if grid <= 768 else 1, tree, progress)
	if progress.is_valid():
		progress.call(1.0)

	update_region(0, grid, 0, grid)
	_upload()
	_update_collision()

## Separable 5-tap gaussian blur over the heightmap — curves hill shoulders and
## terrace lips into smooth rolls while leaving broad shapes (cliffs, tiers) intact.
## Yields + reports progress (0.9 -> 1.0) — this pass froze the bar at "92%".
func _smooth_heights(iterations: int, tree: SceneTree = null, progress := Callable()) -> void:
	var side := grid + 1
	var tmp := PackedFloat32Array()
	tmp.resize(side * side)
	var total_rows := float(iterations * side * 2)
	var done_rows := 0.0
	for _it in iterations:
		for z in side:
			if tree and (z % 64) == 0:
				if progress.is_valid():
					progress.call(0.9 + 0.1 * done_rows / total_rows)
				await tree.process_frame
			done_rows += 1.0
			var row := z * side
			for x in side:
				var xm2 := row + clampi(x - 2, 0, grid)
				var xm1 := row + clampi(x - 1, 0, grid)
				var xp1 := row + clampi(x + 1, 0, grid)
				var xp2 := row + clampi(x + 2, 0, grid)
				tmp[row + x] = (heights[xm2] + 4.0 * heights[xm1] + 6.0 * heights[row + x] \
					+ 4.0 * heights[xp1] + heights[xp2]) * 0.0625
		for z in side:
			if tree and (z % 64) == 0:
				if progress.is_valid():
					progress.call(0.9 + 0.1 * done_rows / total_rows)
				await tree.process_frame
			done_rows += 1.0
			var zm2 := clampi(z - 2, 0, grid) * side
			var zm1 := clampi(z - 1, 0, grid) * side
			var zc := z * side
			var zp1 := clampi(z + 1, 0, grid) * side
			var zp2 := clampi(z + 2, 0, grid) * side
			for x in side:
				heights[zc + x] = (tmp[zm2 + x] + 4.0 * tmp[zm1 + x] + 6.0 * tmp[zc + x] \
					+ 4.0 * tmp[zp1 + x] + tmp[zp2 + x]) * 0.0625

func flatten_all(h: float) -> void:
	for i in heights.size():
		heights[i] = h
	update_region(0, grid, 0, grid)
	_upload()
	_update_collision()

## Replace the whole heightmap (used by Load). Returns false on size mismatch.
func set_heights(arr: PackedFloat32Array) -> bool:
	if arr.size() != (grid + 1) * (grid + 1):
		return false
	heights = arr
	update_region(0, grid, 0, grid)
	_upload()
	_update_collision()
	return true


## Bilinear height sample at a world XZ (for Flatten's target).
func height_at(wx: float, wz: float) -> float:
	var half := grid * 0.5
	var fx := clampf(wx + half, 0.0, grid)
	var fz := clampf(wz + half, 0.0, grid)
	var x0 := int(floor(fx)); var z0 := int(floor(fz))
	var x1 := mini(x0 + 1, grid); var z1 := mini(z0 + 1, grid)
	var tx := fx - x0; var tz := fz - z0
	var side := grid + 1
	var h00 := heights[z0 * side + x0]
	var h10 := heights[z0 * side + x1]
	var h01 := heights[z1 * side + x0]
	var h11 := heights[z1 * side + x1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
