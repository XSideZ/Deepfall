shader_type spatial;
render_mode cull_disabled;

// Stylised (Subnautica / Planet Crafter style): the LOOK comes from vibrant flat colours
// blended by height + slope. The photo textures are used only as faint luminance detail so
// the surface isn't dead-flat, but never as the main look. Triplanar so cliffs don't stretch.
uniform sampler2D tex_grass : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_rock : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_sand : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_snow : source_color, filter_linear_mipmap, repeat_enable;

uniform vec3 col_grass : source_color = vec3(0.63, 0.87, 0.13);   // luminous chartreuse (PC ref)
uniform vec3 col_grass2 : source_color = vec3(0.49, 0.71, 0.09);  // warmer patch green
uniform vec3 col_sand : source_color = vec3(0.96, 0.94, 0.86);    // near-white beach
uniform vec3 col_rock : source_color = vec3(0.52, 0.33, 0.27);    // reddish-maroon mesa
uniform vec3 col_rock2 : source_color = vec3(0.74, 0.66, 0.54);   // pale weathered bands
uniform vec3 col_snow : source_color = vec3(0.93, 0.95, 0.99);

// BIOMES: a low-freq field (0 desert .. 0.5 plains .. 1 jungle) tints the lush ground
// and rock. Snow is OFF by default (Jay: no snow without a cold/water climate).
uniform sampler2D biome_map : filter_linear;
uniform float terrain_span = 512.0;
uniform float snow_amount = 0.0;
uniform vec3 col_grass_desert : source_color = vec3(0.96, 0.94, 0.86);  // proper sand — same as the beach, dunes flow into shore
uniform vec3 col_grass_jungle : source_color = vec3(0.19, 0.53, 0.13);  // deep saturated jungle
uniform vec3 col_rock_grey : source_color = vec3(0.50, 0.50, 0.54);     // grey cliff stone

// BLOOM: life spreads OUTWARD from a seed origin as a patchy blob, not all at once.
// bloom (global cap) is 1 in the editor with a huge radius = lush everywhere; in game
// the radius grows per bloom-stage and a noisy edge makes the green creep in patches.
uniform float bloom = 1.0;
uniform vec2 bloom_origin = vec2(0.0, 0.0);   // world xz of the seed
uniform float bloom_radius = 99999.0;         // how far life has spread
uniform float bloom_edge = 22.0;              // soft transition width
uniform float bloom_patch = 26.0;             // noisy edge ragged-ness
uniform vec3 col_dead : source_color = vec3(0.50, 0.44, 0.30);    // dry ochre dead ground
uniform vec3 col_dead2 : source_color = vec3(0.40, 0.34, 0.25);   // brown cracked dirt
uniform vec3 col_dead3 : source_color = vec3(0.44, 0.42, 0.40);   // pale grey dust
uniform vec3 col_dead4 : source_color = vec3(0.29, 0.27, 0.24);   // dark charred soil
uniform vec3 col_dead_rock : source_color = vec3(0.36, 0.33, 0.31); // grey lifeless stone
uniform vec3 col_dead_sand : source_color = vec3(0.72, 0.66, 0.55); // dull grey sand

uniform float tile_scale = 0.08;
uniform float macro_scale = 0.004;    // large-scale colour patches so grass isn't flat/barren
uniform float detail_amount = 0.42;   // 0 = pure flat colour, 1 = strong texture modulation
uniform float grass_texture = 1.0;    // cartoony medium-scale light/dark clumps on the grass ground
uniform float water_level = -5.0;     // sand forms at/under this height (set from the water slider)
uniform float beach_height = 1.6;     // how far above the water line the beach reaches
uniform float beach_blend = 2.5;      // sand -> grass transition width
uniform float snow_level = 52.0;
uniform float snow_blend = 10.0;
uniform float slope_rock = 0.55;
uniform float slope_blend = 0.15;

varying vec3 v_wpos;
varying vec3 v_wnrm;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// triplanar luminance of a texture (for subtle detail only)
float tri_luma(sampler2D t, vec3 wpos, vec3 wnrm, float scale) {
	vec3 bw = pow(abs(wnrm), vec3(4.0));
	bw /= (bw.x + bw.y + bw.z);
	float cx = dot(texture(t, wpos.zy * scale).rgb, vec3(0.333));
	float cy = dot(texture(t, wpos.xz * scale).rgb, vec3(0.333));
	float cz = dot(texture(t, wpos.xy * scale).rgb, vec3(0.333));
	return cx * bw.x + cy * bw.y + cz * bw.z;
}

void fragment() {
	vec3 wnrm = normalize(v_wnrm);
	float slope = 1.0 - clamp(wnrm.y, 0.0, 1.0);
	float h = v_wpos.y;

	float m_rock = smoothstep(slope_rock, slope_rock + slope_blend, slope);
	float m_snow = smoothstep(snow_level - snow_blend, snow_level + snow_blend, h) * (1.0 - smoothstep(0.7, 0.85, slope)) * snow_amount;
	// sand covers the beach band + everything at/under the water line (applied last so it wins)
	float m_sand = smoothstep(water_level + beach_height + beach_blend, water_level + beach_height, h);

	// grass ground: large patches (anti-barren) + medium clumps + FINE blade noise (PC-style)
	float macro = tri_luma(tex_grass, v_wpos, wnrm, macro_scale);
	float clump = tri_luma(tex_grass, v_wpos, wnrm, tile_scale);
	float fine = tri_luma(tex_grass, v_wpos, wnrm, 0.55);
	float bmacro = tri_luma(tex_rock, v_wpos, wnrm, macro_scale * 1.6);
	vec3 grass_col = mix(col_grass2, col_grass, smoothstep(0.30, 0.70, macro));
	// biome tint: golden desert <- chartreuse plains -> deep jungle green.
	// bio_d = biome value DITHERED by two noise scales, so boundaries interleave in
	// organic patches (sand tongues into grass, grass tufts into sand) instead of a line
	float bio = texture(biome_map, (v_wpos.xz + terrain_span * 0.5) / terrain_span).r;
	float bio_d = bio + (bmacro - 0.5) * 0.28 + (clump - 0.5) * 0.10;
	grass_col = mix(col_grass_desert, grass_col, smoothstep(0.18, 0.50, bio_d));
	grass_col = mix(grass_col, col_grass_jungle, smoothstep(0.56, 0.84, bio_d));
	// detail centred on 1.0 so texture variation never darkens the palette overall
	float clump_d = 1.0 + (smoothstep(0.28, 0.72, clump) - 0.5) * 0.34;
	float fine_d = 1.0 + (smoothstep(0.35, 0.65, fine) - 0.5) * 0.58;
	grass_col *= mix(1.0, clump_d * fine_d, grass_texture);

	// spatial bloom: distance from the seed, pushed around by noise so life creeps in
	// ragged patches rather than a clean circle
	float d_seed = distance(v_wpos.xz, bloom_origin) + (bmacro - 0.5) * 2.0 * bloom_patch;
	float b = bloom * (1.0 - smoothstep(bloom_radius - bloom_edge, bloom_radius, d_seed));

	// barren ground: mix ochre / brown / grey / charred by two noise fields for variety
	vec3 dead_col = mix(col_dead2, col_dead, smoothstep(0.35, 0.70, macro));
	dead_col = mix(dead_col, col_dead3, smoothstep(0.45, 0.85, bmacro));
	dead_col = mix(dead_col, col_dead4, smoothstep(0.72, 0.95, 1.0 - macro) * 0.7);
	dead_col *= mix(1.0, clump_d * fine_d, grass_texture * 0.35);
	grass_col = mix(dead_col, grass_col, b);

	// rock: red canyon in deserts, grey cliffs elsewhere; pale weathered banding
	float rock_band = tri_luma(tex_rock, v_wpos, wnrm, 0.02);
	vec3 rock_col = mix(col_rock, col_rock2, smoothstep(0.40, 0.62, rock_band));
	rock_col = mix(rock_col, col_rock_grey, smoothstep(0.20, 0.56, bio_d));   // deserts stay red
	rock_col = mix(col_dead_rock, rock_col, b);

	vec3 sand_col = mix(col_dead_sand, col_sand, b);
	vec3 base = grass_col;
	base = mix(base, rock_col, m_rock);
	base = mix(base, col_snow, m_snow);
	base = mix(base, sand_col, m_sand);

	// ICE BIOME (bio ~1.7): snow blankets everything; steep rock shows through the
	// drifts a little so cliffs still read as stone. Dithered edge = ragged drift
	// fingers, and a FROST band dusts the approach before the full blanket.
	float w_ice = smoothstep(1.22, 1.58, bio_d);
	// frost gate uses the raw bio (only ice pushes it past 1.0) with light dither,
	// so jungle at bio~1.0 never catches frost
	float frost = smoothstep(1.04, 1.35, bio + (bmacro - 0.5) * 0.12) * (1.0 - w_ice);
	float snow_grain = tri_luma(tex_snow, v_wpos, wnrm, tile_scale);
	vec3 ice_col = col_snow * (0.88 + snow_grain * 0.24);
	ice_col = mix(ice_col, vec3(0.72, 0.82, 0.94), smoothstep(0.5, 0.9, bmacro) * 0.35);  // icy blue patches
	base = mix(base, col_snow * 0.94, frost * 0.45 * smoothstep(0.45, 0.65, clump));  // patchy frost dust
	base = mix(base, ice_col, w_ice * (1.0 - m_rock * 0.45));

	// faint texture detail (same masks) modulating brightness only
	float dl = tri_luma(tex_grass, v_wpos, wnrm, tile_scale);
	dl = mix(dl, tri_luma(tex_rock, v_wpos, wnrm, tile_scale), m_rock);
	dl = mix(dl, tri_luma(tex_snow, v_wpos, wnrm, tile_scale), m_snow);
	dl = mix(dl, tri_luma(tex_sand, v_wpos, wnrm, tile_scale), m_sand);
	// centred on 1.0 — this was darkening beaches/rock to gray before
	float detail = 1.0 + (dl - 0.45) * detail_amount * 1.4;

	// close-range micro detail: crisp fine grain fades in within ~15 m of the camera
	// so the ground right underfoot reads sharp instead of blurry ("touching the ground")
	float cam_d = distance(v_wpos, CAMERA_POSITION_WORLD);
	float close_f = 1.0 - smoothstep(4.0, 16.0, cam_d);
	if (close_f > 0.002) {
		float micro = tri_luma(tex_grass, v_wpos, wnrm, 1.7);
		detail *= 1.0 + (smoothstep(0.35, 0.65, micro) - 0.5) * 0.38 * close_f;
	}

	ALBEDO = base * detail;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
}
