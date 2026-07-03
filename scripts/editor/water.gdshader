shader_type spatial;
render_mode cull_disabled;

// Depth-absorbing stylised water: clear turquoise in the shallows (you see the sandy bottom),
// fading to OPAQUE deep blue in deep water. That hides the terrain's underwater edge/seafloor
// and makes open ocean read as endless. Ripples from a seamless noise normal map + fresnel.
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 shallow_color : source_color = vec3(0.30, 0.92, 0.88);
uniform vec3 deep_color : source_color = vec3(0.05, 0.48, 0.60);
uniform float shallow_alpha = 0.55;
uniform float depth_fade = 9.0;       // metres of water depth to reach full opacity / deep colour
uniform float uv_scale_a = 0.085;
uniform float uv_scale_b = 0.17;
uniform vec2 flow_a = vec2(0.024, 0.016);
uniform vec2 flow_b = vec2(-0.020, 0.028);
uniform float wave_strength = 0.7;
uniform float fresnel_power = 5.0;
uniform float foam_width = 1.4;
uniform vec3 foam_color : source_color = vec3(0.92, 0.97, 1.0);
uniform float day_mult = 1.0;   // day/night compositor dims the water at night

varying vec3 v_wpos;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// animated surface normal from two scrolling noise layers
	vec2 p = v_wpos.xz;
	vec3 na = texture(normal_map, p * uv_scale_a + TIME * flow_a).xyz * 2.0 - 1.0;
	vec3 nb = texture(normal_map, p * uv_scale_b + TIME * flow_b).xyz * 2.0 - 1.0;
	vec2 tang = (na.xy + nb.xy) * wave_strength;
	vec3 world_n = normalize(vec3(tang.x, 1.0, tang.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);

	// how much water sits between the surface and whatever is behind it (seafloor / open void)
	float raw = texture(DEPTH_TEXTURE, SCREEN_UV).x;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	float scene_z = vp.z / vp.w;                       // view-space z of scene behind (negative)
	float depth_m = VERTEX.z - scene_z;                // >0, larger = deeper water column
	float depth = clamp(depth_m / depth_fade, 0.0, 1.0);  // 0 shallow .. 1 deep

	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fres = pow(1.0 - facing, fresnel_power);

	vec3 col = mix(shallow_color, deep_color, depth);
	col = mix(col, shallow_color * 1.15, fres * 0.25);  // faint bright rim at grazing angles

	// shoreline foam: bright band where the water is very shallow, broken up by the ripple noise
	float shore = 1.0 - smoothstep(0.0, foam_width, depth_m);
	float fn = texture(normal_map, p * 0.2 + vec2(TIME * 0.03, TIME * 0.02)).x;
	shore = clamp(shore * (0.5 + fn), 0.0, 1.0);
	shore = shore * shore;
	col = mix(col, foam_color, shore);

	ALBEDO = col * day_mult;
	ROUGHNESS = 0.02;
	METALLIC = 0.0;
	SPECULAR = 1.0;
	ALPHA = max(mix(shallow_alpha, 1.0, depth), shore * 0.9);
}
