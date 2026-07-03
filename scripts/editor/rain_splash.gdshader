shader_type particles;

// Rain impact rings: each particle picks a random spot around the emitter and snaps
// itself to the TERRAIN surface there (heightmap lookup) — or the water surface if
// that's higher. Rings grow and fade over their lifetime.
uniform sampler2D heightmap : filter_linear;
uniform float span = 512.0;     // world size in metres (uv = (xz + span/2) / span)
uniform float water_y = -1.0;
uniform float radius = 13.0;

float rand_from_seed(inout uint seed) {
	int k;
	int s = int(seed);
	if (s == 0) {
		s = 305420679;
	}
	k = s / 127773;
	s = 16807 * (s - k * 127773) - 2836 * k;
	if (s < 0) {
		s += 2147483647;
	}
	seed = uint(s);
	return float(seed % uint(65536)) / 65535.0;
}

uint hash(uint x) {
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = (x >> uint(16)) ^ x;
	return x;
}

void start() {
	uint seed = hash(NUMBER + uint(1) + RANDOM_SEED);
	float a = rand_from_seed(seed) * 6.2831853;
	float d = radius * sqrt(rand_from_seed(seed));
	vec2 xz = EMISSION_TRANSFORM[3].xz + vec2(cos(a), sin(a)) * d;
	vec2 uv = (xz + span * 0.5) / span;
	float h = texture(heightmap, uv).r;
	float y = max(h, water_y) + 0.06;
	TRANSFORM = mat4(vec4(1, 0, 0, 0), vec4(0, 1, 0, 0), vec4(0, 0, 1, 0), vec4(xz.x, y, xz.y, 1));
	VELOCITY = vec3(0.0);
	CUSTOM = vec4(0.7 + rand_from_seed(seed) * 0.6, 0.0, 0.0, 0.0);   // x = size, y = age
	COLOR = vec4(1.0);
}

void process() {
	CUSTOM.y += DELTA / LIFETIME;
	float t = clamp(CUSTOM.y, 0.0, 1.0);
	float s = CUSTOM.x * mix(0.25, 1.5, t);
	TRANSFORM[0][0] = s;
	TRANSFORM[1][1] = s;
	TRANSFORM[2][2] = s;
	COLOR.a = (1.0 - t) * 0.6;
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
}
