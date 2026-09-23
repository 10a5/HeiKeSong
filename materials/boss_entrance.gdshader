shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_opaque;

uniform float elapsed = 0.0;
uniform float visibility : hint_range(0.0, 1.0) = 1.0;
varying float shell_height;

void vertex() {
	shell_height = VERTEX.y;
}

void fragment() {
	float rim = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.4);
	float stripe = pow(0.5 + 0.5 * sin(shell_height * 38.0 - elapsed * 8.0), 14.0);
	float sweep = pow(0.5 + 0.5 * sin(shell_height * 3.0 - elapsed * 5.0), 20.0);
	vec3 color = mix(vec3(0.25, 0.72, 1.0), vec3(1.0, 0.9, 0.62), sweep);
	ALBEDO = color;
	EMISSION = color * (0.4 + rim + sweep * 0.6);
	ALPHA = visibility * clamp(0.06 + rim * 0.5 + stripe * 0.14 + sweep * 0.22, 0.0, 0.85);
}
