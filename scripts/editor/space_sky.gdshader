shader_type sky;

// Space backdrop: dark gradient + stars + faint nebula + a big shaded planet on the horizon.
// bright terraformed-atmosphere look: deep blue zenith -> bright cyan horizon (not black space)
uniform vec3 space_top : source_color = vec3(0.06, 0.28, 0.62);
uniform vec3 space_bottom : source_color = vec3(0.40, 0.80, 0.92);
uniform float star_threshold = 0.992;   // higher = fewer stars (bright sky)
uniform float nebula_strength = 0.14;

uniform vec3 sun_dir = vec3(0.55, 0.62, 0.55);       // set from the DirectionalLight
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.85);

uniform vec3 planet_dir = vec3(0.35, 0.10, -1.0);
uniform float planet_size = 0.24;         // angular radius (radians)
uniform vec3 planet_light_dir = vec3(-0.6, 0.35, 0.4);
uniform vec3 planet_ocean : source_color = vec3(0.45, 0.75, 0.92);  // bright icy blue (PC ref)
uniform vec3 planet_land : source_color = vec3(0.82, 0.93, 0.97);   // white-cyan continents

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			   mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm3(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + 1.7;
		a *= 0.5;
	}
	return s;
}

float star_layer(vec3 dir, float scale, float thresh) {
	vec3 g = dir * scale;
	float h = hash13(floor(g));
	if (h < thresh) {
		return 0.0;
	}
	vec3 f = fract(g) - 0.5;
	return smoothstep(0.35, 0.0, length(f)) * ((h - thresh) / (1.0 - thresh));
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	vec3 col = mix(space_bottom, space_top, clamp(dir.y * 0.5 + 0.5, 0.0, 1.0));

	// nebula
	float n = pow(clamp(fbm3(dir * 2.5), 0.0, 1.0), 3.0);
	vec3 neb = mix(vec3(0.15, 0.02, 0.25), vec3(0.02, 0.12, 0.30), fbm3(dir * 1.7 + 9.0));
	col += neb * n * nebula_strength;

	// the sun: hot disc + soft halo, follows the world DirectionalLight
	float sd = max(dot(dir, normalize(sun_dir)), 0.0);
	col += sun_color * (pow(sd, 1400.0) * 8.0 + pow(sd, 60.0) * 0.35);

	// stars: faint, and only up high (a bright sky washes them out near the horizon)
	float star_fade = smoothstep(0.15, 0.6, dir.y);
	float s = star_layer(dir, 250.0, star_threshold)
			+ star_layer(dir, 430.0, star_threshold + 0.004) * 0.8
			+ star_layer(dir, 150.0, star_threshold + 0.003) * 1.3;
	col += vec3(s) * star_fade * 0.7;

	// planet
	vec3 pd = normalize(planet_dir);
	float dd = dot(dir, pd);
	float cr = cos(planet_size);
	if (dd > cr) {
		vec3 offset = dir - pd * dd;                 // tangential component
		float r = clamp(length(offset) / sin(planet_size), 0.0, 1.0);
		float z = sqrt(max(0.0, 1.0 - r * r));
		vec3 nrm = normalize(offset) * r + pd * z;   // approx surface normal
		float ndl = clamp(dot(nrm, normalize(planet_light_dir)), 0.0, 1.0);
		float cont = fbm3(nrm * 2.5 + 3.0);
		vec3 surf = mix(planet_ocean, planet_land, smoothstep(0.48, 0.55, cont));
		float clouds = smoothstep(0.60, 0.75, fbm3(nrm * 3.5 + 20.0));
		surf = mix(surf, vec3(1.0), clouds * 0.6);
		// keep the whole disc luminous — a big ambient floor, gentle day-night shading
		surf *= (0.55 + 0.45 * ndl) * 1.2;
		float rim = smoothstep(0.72, 1.0, r);
		surf += vec3(0.45, 0.75, 1.0) * rim * 0.6;
		float edge = smoothstep(cr, mix(cr, 1.0, 0.02), dd);
		col = mix(col, surf, edge);
	}

	COLOR = col;
}
