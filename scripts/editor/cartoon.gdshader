shader_type canvas_item;

// Full-screen cartoon post-process: boosts saturation, posterises colour into cel bands,
// and adds a subtle luminance outline. Applied over the whole rendered frame.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float levels = 6.0;
uniform float saturation = 1.35;
uniform float outline = 0.14;

const vec3 LUMA = vec3(0.299, 0.587, 0.114);

void fragment() {
	vec2 ts = 1.0 / vec2(textureSize(screen_tex, 0));
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;

	float l = dot(c, LUMA);
	c = mix(vec3(l), c, saturation);          // punchier colours
	c = floor(c * levels) / levels;            // posterise into bands

	// subtle outline from luminance gradient
	float lx = dot(texture(screen_tex, SCREEN_UV + vec2(ts.x, 0.0)).rgb, LUMA);
	float ly = dot(texture(screen_tex, SCREEN_UV + vec2(0.0, ts.y)).rgb, LUMA);
	float e = clamp((abs(l - lx) + abs(l - ly)) * outline * 24.0, 0.0, 1.0);
	c = mix(c, vec3(0.04), e);

	COLOR = vec4(c, 1.0);
}
