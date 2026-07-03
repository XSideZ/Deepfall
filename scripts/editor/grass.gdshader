shader_type spatial;
render_mode cull_disabled;

// Grass blades for the foliage MultiMesh: dark base -> bright tip gradient + wind sway.
uniform vec3 base_col : source_color = vec3(0.37, 0.56, 0.08);
uniform vec3 tip_col : source_color = vec3(0.80, 0.95, 0.20);
uniform float wind = 0.18;
uniform float wind_speed = 1.6;

void vertex() {
	// per-instance world position drives the sway phase so blades don't move in lockstep
	vec3 wp = MODEL_MATRIX[3].xyz;
	float phase = wp.x * 0.25 + wp.z * 0.25;
	float sway = sin(TIME * wind_speed + phase) * wind * UV.y;
	VERTEX.x += sway;
	VERTEX.z += sway * 0.6;
}

void fragment() {
	ALBEDO = mix(base_col, tip_col, UV.y);
	ROUGHNESS = 0.9;
	SPECULAR = 0.1;
}
