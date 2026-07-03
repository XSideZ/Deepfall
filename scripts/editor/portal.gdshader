shader_type spatial;
render_mode unshaded, cull_disabled;

// Portal surface: samples the portal camera's render in SCREEN space so the view
// through the opening lines up with the world exactly (correct parallax).
// Clipped to a circle so it fills the round arch, not a rectangle.
uniform sampler2D view_tex : source_color, filter_linear;

void fragment() {
	if (length(UV - vec2(0.5)) > 0.5) {
		discard;
	}
	ALBEDO = texture(view_tex, SCREEN_UV).rgb;
}
