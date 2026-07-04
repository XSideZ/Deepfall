shader_type spatial;
render_mode cull_disabled;

// Wind sway for scattered flora. Weighted by vertex height so bases stay planted.
// Phase comes from world position so every clump moves on its own beat.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, hint_default_white;
uniform vec4 albedo_col : source_color = vec4(1.0);
uniform float sway = 0.06;
uniform float mesh_h = 1.0;
uniform float force_a = 0.0;   // 1 = ignore texture alpha (solid-geometry models)
// bloom grow-in: each blade scales up from the ground as the spreading front passes it
uniform vec2 bloom_origin = vec2(0.0, 0.0);
uniform float bloom_front = 1.0e9;   // editor default = everything full-grown
uniform float grow_band = 5.0;       // metres over which a blade grows from 0 -> full

void vertex() {
	// grow factor from how far the front has passed this blade's base
	vec3 base_w = MODEL_MATRIX[3].xyz;
	float dist = distance(base_w.xz, bloom_origin);
	float g = clamp((bloom_front - dist) / grow_band, 0.0, 1.0);
	g = g * g * (3.0 - 2.0 * g);
	VERTEX *= g;                      // scale toward the mesh base (grows up out of the soil)

	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = clamp(VERTEX.y / max(mesh_h, 0.001), 0.0, 1.0);
	w *= w;   // tips move, roots don't
	float ph = wpos.x * 0.37 + wpos.z * 0.29;
	float gust = 0.7 + 0.3 * sin(TIME * 0.23 + wpos.x * 0.013);
	VERTEX.x += sin(TIME * 1.6 + ph) * sway * w * gust;
	VERTEX.z += cos(TIME * 1.25 + ph * 1.7) * sway * w * gust * 0.7;
}

void fragment() {
	vec4 c = texture(albedo_tex, UV) * albedo_col;
	ALBEDO = c.rgb;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	// alpha-cutout leaves/petals: without this, transparent texels rendered as
	// solid blocks (the "blocky red bushes"). A2C smooths the edges under MSAA.
	// force_a=1 for solid-geometry models whose atlas has junk alpha (the flower
	// pack is 64% transparent-alpha — scissor made every petal invisible).
	ALPHA = max(c.a, force_a);
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	ALPHA_ANTIALIASING_EDGE = 0.35;
}
