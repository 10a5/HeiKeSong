shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled;

// Both depth zones share this opaque surface; depth only changes gameplay.
uniform vec4 water_color : source_color = vec4(0.22, 0.30, 0.34, 1.0);
uniform float wave_time = 0.0;
// World X/Z, age in seconds, strength. A zero strength disables the entry.
uniform vec4 ripple_data[16];

varying vec3 world_position;

float water_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float water_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 blend = fract(p);
	blend = blend * blend * (3.0 - 2.0 * blend);
	return mix(mix(water_hash(cell), water_hash(cell + vec2(1.0, 0.0)), blend.x),
		mix(water_hash(cell + vec2(0.0, 1.0)), water_hash(cell + vec2(1.0, 1.0)), blend.x), blend.y);
}

void vertex() {
	// World projection keeps adjacent surface strips seamless as waves travel.
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_position.xz;
	float surface_pixel = max(length(fwidth(p)), 0.001);
	float drift = water_noise(p * 0.27 + vec2(wave_time * 0.035, -wave_time * 0.018));
	vec2 direction_a = normalize(vec2(1.0, 0.48));
	vec2 direction_b = normalize(vec2(-0.42, 1.0));
	vec2 direction_c = normalize(vec2(0.83, -0.55));
	float phase_a = dot(p, direction_a) * 2.10 + wave_time * 1.05 + drift * 1.8;
	float phase_b = dot(p, direction_b) * 3.85 - wave_time * 1.38 + drift * 1.1;
	float phase_c = dot(p, direction_c) * 8.40 + wave_time * 1.70;
	// Suppress waves smaller than a few pixels to keep distant water stable.
	float visible_a = 1.0 - smoothstep(0.7, 2.5, fwidth(phase_a));
	float visible_b = 1.0 - smoothstep(0.7, 2.5, fwidth(phase_b));
	float visible_c = 1.0 - smoothstep(0.7, 2.5, fwidth(phase_c));
	vec2 slope = direction_a * cos(phase_a) * 0.060 * visible_a
		+ direction_b * cos(phase_b) * 0.032 * visible_b
		+ direction_c * cos(phase_c) * 0.012 * visible_c;
	float wave_shade = sin(phase_a) * 0.022 * visible_a
		+ sin(phase_b) * 0.012 * visible_b;
	float ripple_shade = 0.0;

	for (int i = 0; i < 16; i++) {
		vec4 ripple = ripple_data[i];
		if (ripple.w > 0.0 && ripple.z >= 0.0 && ripple.z < 2.2) {
			vec2 delta = p - ripple.xy;
			float distance_to_center = length(delta);
			vec2 radial_direction = delta / max(distance_to_center, 0.001);
			float age = ripple.z;
			float radius = 0.15 + age * 2.0;
			float strength = min(ripple.w, 2.5);
			float fade = smoothstep(0.0, 0.07, age)
				* pow(max(1.0 - age / 2.2, 0.0), 1.35) / (1.0 + radius * 0.16);
			float physical_width = 0.15 + age * 0.065 + strength * 0.015;
			float width = max(physical_width, surface_pixel * 0.85);
			float coverage = physical_width / width;
			float offset = distance_to_center - radius;
			float crest = exp(-offset * offset / (width * width));
			float trailing_offset = offset + 0.32 + age * 0.07;
			float trough = exp(-trailing_offset * trailing_offset / (width * width * 1.7));
			// A broad crest followed by a softer trough produces light and shadow,
			// with the scene's sky/lights supplying the moving specular highlight.
			float height_derivative = (-2.0 * offset / (width * width)) * crest
				+ 0.38 * (2.0 * trailing_offset / (width * width * 1.7)) * trough;
			slope += radial_direction * height_derivative * 0.045 * strength * fade * coverage;
			ripple_shade += (crest * 0.13 - trough * 0.075) * strength * fade * coverage;
		}
	}

	vec3 surface_normal = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(surface_normal, 0.0)).xyz);
	ALBEDO = water_color.rgb * (0.97 + drift * 0.08 + wave_shade + clamp(ripple_shade, -0.12, 0.24));
	ROUGHNESS = clamp(0.25 + (drift - 0.5) * 0.09 - ripple_shade * 0.12, 0.18, 0.32);
	METALLIC = 0.0;
	SPECULAR = 0.72;
}
