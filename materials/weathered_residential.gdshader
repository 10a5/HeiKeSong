shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

varying vec3 world_position;
varying vec3 world_normal;

float hash21(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 19.19);
	return fract(p.x * p.y);
}

float noise2(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(cell), hash21(cell + vec2(1, 0)), f.x),
		mix(hash21(cell + vec2(0, 1)), hash21(cell + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 n = abs(normalize(world_normal));
	// Project onto each actual facade, including walls parallel to the X axis.
	vec2 p = n.x > n.z ? world_position.zy : world_position.xy;
	if (n.y > max(n.x, n.z)) { p = world_position.xz; }
	float original_value = dot(COLOR.rgb, vec3(0.2126, 0.7152, 0.0722));
	float plaster = smoothstep(0.006, 0.045, original_value);
	// Retain the GLB's darker rails, timber and pipes while lifting grey plaster.
	float value = pow(max(original_value, 0.0001), 0.46) * 1.15;
	vec3 painted = value * mix(vec3(0.48, 0.65, 0.72), vec3(1.14, 1.23, 1.27), plaster);
	painted = mix(painted, COLOR.rgb * 1.8, 0.04);
	float patches = noise2(p * 1.4) * 0.7 + noise2(p * 4.1) * 0.3;
	float chips = smoothstep(0.56, 0.78, patches);
	float rain = smoothstep(0.48, 0.75, noise2(p * vec2(3.4, 0.15)));
	float fine = noise2(p * 7.0);
	float moss = (1.0 - smoothstep(0.0, 3.2, world_position.y)) * noise2(p * 1.7);
	vec3 surface = painted * mix(0.95, 1.05, fine);
	surface = mix(surface, painted * vec3(0.42, 0.46, 0.44), chips * plaster * 0.72);
	surface *= 1.0 - rain * plaster * 0.23;
	surface = mix(surface, surface * vec3(0.59, 0.72, 0.57), moss * 0.34);
	ALBEDO = surface;
	ROUGHNESS = mix(0.82, 0.54, rain * plaster);
	METALLIC = 0.03 * (1.0 - plaster);
	SPECULAR = 0.38;
}
