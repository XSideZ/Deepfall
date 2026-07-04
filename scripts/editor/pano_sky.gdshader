shader_type sky;

// Panorama skybox + the LIVE sun: the DirectionalLight's disc/halo is drawn on top
// of the painted sky and the whole image follows the day/night cycle — so any
// skybox gets real sunrise light, a moving sun ball, and honest nights.
uniform sampler2D pano : source_color, filter_linear, repeat_enable;
uniform vec3 sun_dir = vec3(0.55, 0.62, 0.55);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.85);
uniform float day_mult = 1.0;      // compositor: bright day -> dim night
uniform float sun_strength = 1.0;  // 0 hides the drawn sun (for skies with one baked in)

void sky() {
	vec3 dir = normalize(EYEDIR);
	vec2 uv = vec2(atan(dir.x, -dir.z) / (2.0 * PI) + 0.5,
		clamp(0.5 - asin(clamp(dir.y, -1.0, 1.0)) / PI, 0.001, 0.999));
	vec3 col = texture(pano, uv).rgb * day_mult;

	// the sun: hot disc + soft halo, synced to the world DirectionalLight
	float sd = max(dot(dir, normalize(sun_dir)), 0.0);
	col += sun_color * (pow(sd, 1400.0) * 8.0 + pow(sd, 60.0) * 0.35) * sun_strength * clamp(day_mult + 0.15, 0.0, 1.0);

	COLOR = col;
}
