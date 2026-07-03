shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

// Dense ground-cover carpet (land grass / sea grass). A static MultiMesh grid rides
// with the camera (node snaps to cells); THIS shader gives every instance its real
// position: per-cell hash jitter/yaw/scale, height from the terrain heightmap, and
// gating by water line, biome, bloom front and camera distance. Instances the player
// shouldn't see collapse to scale 0 on the GPU — no CPU rescatter, ever.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform sampler2D heightmap : filter_linear;
uniform sampler2D biome_map : filter_linear;
uniform float terrain_span = 0.0;    // 0 = not wired yet -> everything hidden
uniform float cell = 0.62;
uniform float base_scale = 1.0;      // normalises the pack mesh to real-world size
uniform float mesh_h = 0.5;          // native mesh height (pre-normalise)
uniform float fade_start = 30.0;
uniform float fade_end = 42.0;
uniform float water_level = 8.0;
uniform int mode = 0;                // 0 = land grass, 1 = sea grass
uniform vec2 bloom_origin = vec2(0.0);
uniform float bloom_front = 1000000.0;
uniform float grow_band = 6.0;

// land tints
uniform vec3 col_plain_a : source_color = vec3(0.55, 0.86, 0.18);
uniform vec3 col_plain_b : source_color = vec3(0.38, 0.72, 0.10);
uniform vec3 col_jungle : source_color = vec3(0.16, 0.55, 0.12);
// sea tints (vivid carpet + teal/blue/red accent cells, PC underwater ref)
uniform vec3 col_sea_a : source_color = vec3(0.25, 0.85, 0.22);
uniform vec3 col_sea_b : source_color = vec3(0.12, 0.62, 0.30);
uniform vec3 col_sea_teal : source_color = vec3(0.15, 0.55, 0.85);
uniform vec3 col_sea_red : source_color = vec3(0.95, 0.35, 0.28);

varying vec3 v_tint;
varying float v_extra;   // land: flower flag / sea: emission boost
varying float v_tip;

float hashc(vec2 p) {
	p = fract(p * vec2(0.1031, 0.1129));
	p += dot(p, p.yx + 33.33);
	return fract((p.x + p.y) * p.x);
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 local = VERTEX - origin;

	vec2 cid = round(origin.xz / cell);
	float h1 = hashc(cid);
	float h2 = hashc(cid + 17.7);
	float h3 = hashc(cid + 41.3);
	vec2 wxz = cid * cell + (vec2(h1, h2) - 0.5) * cell * 0.95;

	float ok = terrain_span > 1.0 ? 1.0 : 0.0;
	vec2 uv = (wxz + terrain_span * 0.5) / max(terrain_span, 1.0);
	float gy = textureLod(heightmap, uv, 0.0).r;
	float bio = textureLod(biome_map, uv, 0.0).r + (h1 - 0.5) * 0.10;

	if (mode == 0) {
		// land: dry above the waterline, out of desert + ice
		if (gy < water_level + 0.9) { ok = 0.0; }
		if (bio < 0.30 || bio > 1.33) { ok = 0.0; }
	} else {
		// sea: properly submerged only
		if (gy > water_level - 0.7) { ok = 0.0; }
	}

	// bloom front: land carpet grows in with the spreading green
	float g = 1.0;
	if (mode == 0) {
		float d = distance(wxz, bloom_origin) + (h3 - 0.5) * 9.0;
		g = clamp((bloom_front - d) / grow_band, 0.0, 1.0);
		g = g * g * (3.0 - 2.0 * g);
	}

	// organic drifts: patch noise carves gaps + density waves (ref spacing, not a lawn-grid)
	float patch = hashc(floor(cid * 0.16) + 5.1);
	float patch2 = hashc(floor(cid * 0.05) + 57.9);
	if (patch * 0.6 + patch2 * 0.4 < 0.22) { ok = 0.0; }

	// distance fade, DITHERED per clump (each fades at its own distance -> no visible
	// ring of grass popping in and out as you walk)
	float cd = distance(wxz, CAMERA_POSITION_WORLD.xz) + (h1 - 0.5) * 14.0;
	float df = 1.0 - smoothstep(fade_start, fade_end, cd);

	float sc = (0.72 + h2 * 0.55) * base_scale * ok * g * df;

	float ya = h3 * 6.2831853;
	float cy = cos(ya);
	float sy = sin(ya);
	local.xz = mat2(vec2(cy, -sy), vec2(sy, cy)) * local.xz;
	local *= sc;

	// sway: tips ride a gentle wind (land) or a slow current (sea)
	v_tip = clamp(local.y / max(mesh_h * max(sc, 0.001), 0.001), 0.0, 1.0);
	float tipw = v_tip * v_tip;
	float ph = wxz.x * 0.35 + wxz.y * 0.29;
	float samt = mode == 0 ? 0.055 : 0.13;
	float sfrq = mode == 0 ? 1.7 : 0.8;
	local.x += sin(TIME * sfrq + ph) * samt * tipw;
	local.z += cos(TIME * sfrq * 0.77 + ph * 1.7) * samt * tipw * 0.8;

	VERTEX = vec3(wxz.x, gy - 0.04, wxz.y) + local;
	NORMAL = vec3(0.0, 1.0, 0.0);   // up-facing normals = soft unified carpet shading

	// tints
	v_extra = 0.0;
	if (mode == 0) {
		vec3 t = mix(col_plain_b, col_plain_a, h1);
		t = mix(t, col_jungle, smoothstep(0.58, 0.85, bio));
		v_tint = t;
		if (hashc(cid + 91.7) < 0.045) { v_extra = 1.0; }   // rare flower clump
	} else {
		vec3 t = mix(col_sea_b, col_sea_a, h1);
		float acc = hashc(cid + 63.1);
		if (acc < 0.13) { t = mix(col_sea_teal, t, 0.25); v_extra = 0.5; }
		else if (acc < 0.17) { t = mix(col_sea_red, t, 0.2); v_extra = 0.8; }
		v_tint = t;
	}
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	// keep the pack texture's own colour as the base; tint layers biome/accent on top
	float lum = clamp(dot(tex.rgb, vec3(0.45)) + 0.55, 0.55, 1.25);
	vec3 col = mix(tex.rgb, v_tint * lum, mode == 0 ? 0.55 : 0.8);
	col *= 0.72 + 0.28 * v_tip;   // darker at the roots -> depth inside the carpet
	if (mode == 0 && v_extra > 0.5) {
		col = mix(col, vec3(0.98, 0.97, 0.92), smoothstep(0.55, 0.95, v_tip));  // flower heads
	}
	ALBEDO = col;
	if (mode == 1) {
		// near-zero emission: bright ALBEDO does the pop — real emission made the
		// screen-space GI smear moving light blobs ("shadows moving all over")
		EMISSION = col * (0.02 + v_extra * 0.05);
	}
	ROUGHNESS = 0.9;
	SPECULAR = 0.15;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.4;
}
