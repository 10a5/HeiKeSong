shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 water_color : source_color = vec4(0.16, 0.42, 0.48, 1.0);
uniform float water_alpha : hint_range(0.05, 0.65) = 0.28;
uniform float wave_time = 0.0;
// Wave amplitude and ripple brightness are scaled per surface: the arena's
// ankle-deep sheet keeps 1.0, while the ending's deep basin raises both so the
// water still reads as a surface when it is seen from straight above.
uniform float wave_scale : hint_range(0.0, 4.0) = 1.0;
uniform float ripple_scale : hint_range(0.0, 4.0) = 1.0;
// World X/Z, age in seconds, strength. A zero strength disables the entry.
uniform vec4 ripple_data[16];

varying vec3 world_position;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise2(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(cell), hash21(cell + vec2(1.0, 0.0)), f.x),
		mix(hash21(cell + vec2(0.0, 1.0)), hash21(cell + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_position.xz;
	float drift = noise2(p * 0.24 + vec2(wave_time * 0.035, -wave_time * 0.02));
	vec2 flow_a = normalize(vec2(1.0, 0.42));
	vec2 flow_b = normalize(vec2(-0.35, 1.0));
	float phase_a = dot(p, flow_a) * 2.2 + wave_time * 0.9 + drift * 1.4;
	float phase_b = dot(p, flow_b) * 4.1 - wave_time * 1.25 + drift;
	float wave = (sin(phase_a) * 0.045 + sin(phase_b) * 0.022) * wave_scale;
	vec2 slope = (flow_a * cos(phase_a) * 0.045 + flow_b * cos(phase_b) * 0.018) * wave_scale;
	float ripple_light = 0.0;
	for (int i = 0; i < 16; i++) {
		vec4 ripple = ripple_data[i];
		if (ripple.w > 0.0 && ripple.z >= 0.0 && ripple.z < 2.2) {
			vec2 delta = p - ripple.xy;
			float distance_to_center = length(delta);
			float age = ripple.z;
			float radius = 0.18 + age * 1.7;
			float width = 0.12 + age * 0.055;
			float ring = exp(-pow((distance_to_center - radius) / max(width, 0.02), 2.0));
			float fade = pow(max(1.0 - age / 2.2, 0.0), 1.25);
			ripple_light += ring * min(ripple.w, 1.8) * fade * 0.24 * ripple_scale;
		}
	}
	vec3 surface_normal = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(surface_normal, 0.0)).xyz);
	float fresnel_hint = 0.82 + 0.18 * clamp(dot(surface_normal, vec3(0.0, 1.0, 0.0)), 0.0, 1.0);
	ALBEDO = water_color.rgb * (0.92 + drift * 0.10 + wave + ripple_light);
	ROUGHNESS = 0.18;
	METALLIC = 0.05;
	SPECULAR = 0.82;
	ALPHA = clamp(water_alpha * fresnel_hint + ripple_light * 0.20, 0.05, 0.92);
}
