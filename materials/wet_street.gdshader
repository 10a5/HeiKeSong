shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.25, 0.31, 0.35, 1.0);
uniform bool paving = false;
uniform bool road_paint = false;
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
	return mix(mix(hash21(cell), hash21(cell + vec2(1, 0)), f.x),
		mix(hash21(cell + vec2(0, 1)), hash21(cell + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_position.xz;
	float patches = noise2(p * 0.31) * 0.65 + noise2(p * 0.87) * 0.35;
	float grit = noise2(p * 19.0);
	float speckle = noise2(p * 11.0);
	float puddle = smoothstep(0.50, 0.67, patches);
	float detail = 1.0 - smoothstep(0.15, 0.8, length(fwidth(p * 19.0)));
	vec3 dry = base_color.rgb * mix(1.0, mix(0.91, 1.09, grit), detail);
	float seams = 0.0;
	if (paving) {
		// Staggered, worn stone slabs; texture size stays constant on every mesh.
		vec2 tile = p / vec2(0.95, 0.54);
		tile.x += mod(floor(tile.y), 2.0) * 0.5;
		vec2 edge = min(fract(tile), 1.0 - fract(tile));
		vec2 edge_width = max(fwidth(tile) * 0.7, vec2(0.018));
		seams = 1.0 - smoothstep(0.006, edge_width.x, edge.x)
			* smoothstep(0.006, edge_width.y, edge.y);
		dry *= mix(0.82, 1.14, hash21(floor(tile)));
		dry = mix(dry, dry * 0.26, seams * 0.8);
		puddle *= 0.62;
	} else {
		// Asphalt aggregate, repaired patches and fine branching cracks.
		float vein = abs(noise2(p * 1.25) - 0.5);
		float crack = 1.0 - smoothstep(0.002, 0.016, vein);
		crack *= smoothstep(0.42, 0.65, noise2(p * 0.69 + 31.0));
		dry *= 1.0 - crack * 0.42;
		dry += vec3(0.003, 0.004, 0.004) * smoothstep(0.70, 0.9, speckle) * detail;
	}
	if (road_paint) {
		float wear = smoothstep(0.32, 0.56, noise2(p * 12.0));
		dry = mix(vec3(0.045, 0.067, 0.080), base_color.rgb, wear * 0.75);
	}
	// Cloud reflections are supplied by the sky environment, not baked white.
	vec3 wet = dry * vec3(0.50, 0.61, 0.68);
	ALBEDO = mix(dry, wet, puddle * 0.85);
	ROUGHNESS = mix(0.78, 0.23, puddle);
	METALLIC = 0.0;
	SPECULAR = 0.60;
	// Subtle normal ripples break up the specular highlight without geometry.
	vec2 ripple = vec2(noise2(p * 5.3), noise2(p * 5.3 + 17.0)) - 0.5;
	vec3 ripple_normal = normalize(vec3(ripple.x * 0.22, 1.0, ripple.y * 0.22));
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 perturbed = normalize(mix(world_normal, ripple_normal, 0.32 * max(world_normal.y, 0.0)));
	NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
}
