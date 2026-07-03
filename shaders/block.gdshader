shader_type spatial;
render_mode diffuse_burley;

// Procedural, asset-free cartoony block textures. Base tint comes from the vertex
// COLOR (set per block in Blocks.gd); the block id arrives in UV2.x and selects a
// per-type motif. Every face also gets a dark outline for a clean blocky/toon look.
// Block ids must match Blocks.gd.

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	vec2 uv = UV;
	int id = int(round(UV2.x));
	vec3 base = COLOR.rgb;
	float p = 1.0;  // brightness multiplier the patterns push around

	// Cartoony dark outline around every block face.
	float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	float outline = smoothstep(0.0, 0.05, edge);
	p *= mix(0.5, 1.0, outline);

	// Soft top-left highlight / bottom-right shade for a faux-bevel.
	p *= mix(1.08, 0.92, clamp((uv.x + uv.y) * 0.5, 0.0, 1.0));

	if (id == 1) {            // GRASS — speckled blades
		float s = hash(floor(uv * 10.0));
		p *= mix(0.86, 1.14, step(0.5, s));
	} else if (id == 2) {     // DIRT — soft clumps
		float n = vnoise(uv * 6.0);
		p *= mix(0.80, 1.10, n);
	} else if (id == 3) {     // STONE — mottled with a faint crack
		float n = vnoise(uv * 5.0);
		float crack = smoothstep(0.02, 0.0, abs(uv.y - 0.5 - 0.12 * sin(uv.x * 9.0)));
		p *= mix(0.86, 1.08, n) * mix(0.7, 1.0, 1.0 - crack);
	} else if (id == 4) {     // SAND — fine soft speckle
		float s = hash(floor(uv * 15.0));
		p *= mix(0.93, 1.07, s);
	} else if (id == 5) {     // WOOD — vertical grain + rings
		float g = sin(uv.x * 40.0) * 0.5 + 0.5;
		float rings = sin(uv.x * 7.0 + sin(uv.y * 3.0)) * 0.5 + 0.5;
		p *= mix(0.80, 1.06, g) * mix(0.92, 1.0, rings);
	} else if (id == 6) {     // LEAVES — clumpy with darker gaps
		float n = vnoise(uv * 7.0);
		p *= mix(0.66, 1.16, step(0.42, n));
	} else if (id == 7) {     // BRICK — mortar grid, offset rows
		float row = floor(uv.y * 4.0);
		float bx = fract(uv.x * 4.0 + mod(row, 2.0) * 0.5);
		float by = fract(uv.y * 4.0);
		float lineX = smoothstep(0.0, 0.08, min(bx, 1.0 - bx));
		float lineY = smoothstep(0.0, 0.08, min(by, 1.0 - by));
		p *= mix(0.5, 1.05, min(lineX, lineY));
	} else if (id == 8) {     // SNOW — very soft sparkle
		float s = hash(floor(uv * 16.0));
		p *= mix(0.97, 1.06, s);
	} else if (id == 9) {     // COBBLE — rounded stones
		vec2 g = uv * 4.0;
		float n = hash(floor(g));
		vec2 gf = fract(g) - 0.5;
		float stone = smoothstep(0.5, 0.30, length(gf));
		p *= mix(0.6, 1.06, stone) * mix(0.9, 1.1, n);
	} else if (id == 10) {    // PLANK — horizontal boards
		float b = smoothstep(0.0, 0.06, min(fract(uv.y * 4.0), 1.0 - fract(uv.y * 4.0)));
		float grain = sin(uv.x * 30.0) * 0.5 + 0.5;
		p *= mix(0.6, 1.0, b) * mix(0.94, 1.0, grain);
	}

	ALBEDO = clamp(base * p, vec3(0.0), vec3(1.0));
	ROUGHNESS = 1.0;
	SPECULAR = 0.1;
}
