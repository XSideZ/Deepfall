shader_type canvas_item;

// 2D mirror of block.gdshader so hotbar swatches match the in-world blocks.
// block_color = base tint, block_id selects the motif (ids match Blocks.gd).

uniform vec3 block_color : source_color = vec3(1.0);
uniform int block_id = 0;

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
	int id = block_id;
	vec3 base = block_color;
	float p = 1.0;

	float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	float outline = smoothstep(0.0, 0.05, edge);
	p *= mix(0.5, 1.0, outline);
	p *= mix(1.08, 0.92, clamp((uv.x + uv.y) * 0.5, 0.0, 1.0));

	if (id == 1) {
		float s = hash(floor(uv * 10.0));
		p *= mix(0.86, 1.14, step(0.5, s));
	} else if (id == 2) {
		float n = vnoise(uv * 6.0);
		p *= mix(0.80, 1.10, n);
	} else if (id == 3) {
		float n = vnoise(uv * 5.0);
		float crack = smoothstep(0.02, 0.0, abs(uv.y - 0.5 - 0.12 * sin(uv.x * 9.0)));
		p *= mix(0.86, 1.08, n) * mix(0.7, 1.0, 1.0 - crack);
	} else if (id == 4) {
		float s = hash(floor(uv * 15.0));
		p *= mix(0.93, 1.07, s);
	} else if (id == 5) {
		float g = sin(uv.x * 40.0) * 0.5 + 0.5;
		float rings = sin(uv.x * 7.0 + sin(uv.y * 3.0)) * 0.5 + 0.5;
		p *= mix(0.80, 1.06, g) * mix(0.92, 1.0, rings);
	} else if (id == 6) {
		float n = vnoise(uv * 7.0);
		p *= mix(0.66, 1.16, step(0.42, n));
	} else if (id == 7) {
		float row = floor(uv.y * 4.0);
		float bx = fract(uv.x * 4.0 + mod(row, 2.0) * 0.5);
		float by = fract(uv.y * 4.0);
		float lineX = smoothstep(0.0, 0.08, min(bx, 1.0 - bx));
		float lineY = smoothstep(0.0, 0.08, min(by, 1.0 - by));
		p *= mix(0.5, 1.05, min(lineX, lineY));
	} else if (id == 8) {
		float s = hash(floor(uv * 16.0));
		p *= mix(0.97, 1.06, s);
	} else if (id == 9) {
		vec2 g = uv * 4.0;
		float n = hash(floor(g));
		vec2 gf = fract(g) - 0.5;
		float stone = smoothstep(0.5, 0.30, length(gf));
		p *= mix(0.6, 1.06, stone) * mix(0.9, 1.1, n);
	} else if (id == 10) {
		float b = smoothstep(0.0, 0.06, min(fract(uv.y * 4.0), 1.0 - fract(uv.y * 4.0)));
		float grain = sin(uv.x * 30.0) * 0.5 + 0.5;
		p *= mix(0.6, 1.0, b) * mix(0.94, 1.0, grain);
	}

	COLOR = vec4(clamp(base * p, vec3(0.0), vec3(1.0)), 1.0);
}
