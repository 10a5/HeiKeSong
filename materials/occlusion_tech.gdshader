shader_type spatial;
// The project uses GL Compatibility, so keep this effect to GLES-friendly
// arithmetic and the built-in TIME clock. Buildings remain in the depthless
// translucent pass while their silhouette is replaced by a blue hologram.
render_mode blend_mix, cull_disabled, depth_draw_never, unshaded;

uniform vec4 base_color : source_color = vec4(0.08, 0.32, 0.48, 1.0);
uniform vec4 highlight_color : source_color = vec4(0.20, 0.84, 1.0, 1.0);
uniform vec4 line_color : source_color = vec4(0.40, 0.94, 1.0, 1.0);
uniform float opacity : hint_range(0.02, 0.80) = 0.32;
uniform float line_speed : hint_range(-4.0, 4.0) = 0.75;
uniform float line_density : hint_range(0.1, 10.0) = 2.8;
uniform float grid_density : hint_range(0.01, 2.0) = 0.16;
uniform float line_strength : hint_range(0.0, 2.0) = 0.72;
uniform float fade : hint_range(0.0, 1.0) = 0.0;

varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

float narrow_line(float value, float width) {
	float distance_to_line = abs(fract(value) - 0.5);
	return 1.0 - smoothstep(width, width + 0.035, distance_to_line);
}

void fragment() {
	float transition = clamp(fade, 0.0, 1.0);
	vec3 normal = normalize(world_normal);
	vec3 view_direction = normalize(VIEW);
	float rim = pow(1.0 - abs(dot(normal, view_direction)), 2.0);

	// A vertical cyan gradient gives the ghost a readable depth cue while the
	// rim keeps corners bright even when the source GLB is very dark.
	float gradient = smoothstep(-0.6, 22.0, world_position.y);
	vec3 hologram = mix(base_color.rgb, highlight_color.rgb, gradient * 0.78);
	hologram += highlight_color.rgb * rim * 0.52;

	// Fine facade grid. The two projections work for both X-facing and
	// Z-facing walls, and the Y line remains visible on roofs and terraces.
	float vertical_grid = max(
		narrow_line(world_position.x * grid_density, 0.026),
		narrow_line(world_position.z * grid_density, 0.026)
	);
	float horizontal_grid = narrow_line(world_position.y * grid_density, 0.021);
	float grid = max(vertical_grid, horizontal_grid) * 0.23;

	// A narrow travelling scan band plus a slower secondary band prevent the
	// effect from reading like a static blue tint. TIME is available in both
	// Forward+ and GL Compatibility renderers.
	float scan_phase = world_position.y * line_density - TIME * line_speed;
	float scan = narrow_line(scan_phase, 0.040);
	float scan_wash = smoothstep(0.05, 0.34, fract(scan_phase + 0.28));
	float signal = scan * 0.95 + scan_wash * 0.10;

	hologram = mix(hologram, line_color.rgb, clamp(grid + signal * line_strength, 0.0, 0.92));
	ALBEDO = hologram;
	EMISSION = hologram * transition * (0.32 + rim * 0.38 + signal * 0.48);
	ROUGHNESS = 0.24;
	SPECULAR = 0.65;
	ALPHA = clamp((opacity + rim * 0.08 + signal * 0.12 + grid * 0.06) * transition, 0.0, 0.72);
}
