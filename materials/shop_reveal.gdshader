shader_type canvas_item;
render_mode unshaded;

// Blur the product's own SubViewport texture. Works in GL Compatibility,
// without a screen texture or a renderer-specific post-processing pass.
uniform float blur_radius : hint_range(0.0, 24.0) = 16.0;
uniform float reveal : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 step_uv = TEXTURE_PIXEL_SIZE * blur_radius;
	vec4 blurred = texture(TEXTURE, UV) * 0.20;
	blurred += texture(TEXTURE, UV + vec2(step_uv.x, 0.0)) * 0.10;
	blurred += texture(TEXTURE, UV - vec2(step_uv.x, 0.0)) * 0.10;
	blurred += texture(TEXTURE, UV + vec2(0.0, step_uv.y)) * 0.10;
	blurred += texture(TEXTURE, UV - vec2(0.0, step_uv.y)) * 0.10;
	blurred += texture(TEXTURE, UV + step_uv) * 0.06;
	blurred += texture(TEXTURE, UV - step_uv) * 0.06;
	blurred += texture(TEXTURE, UV + vec2(step_uv.x, -step_uv.y)) * 0.06;
	blurred += texture(TEXTURE, UV + vec2(-step_uv.x, step_uv.y)) * 0.06;
	blurred += texture(TEXTURE, UV + vec2(step_uv.x * 2.0, 0.0)) * 0.04;
	blurred += texture(TEXTURE, UV - vec2(step_uv.x * 2.0, 0.0)) * 0.04;
	blurred += texture(TEXTURE, UV + vec2(0.0, step_uv.y * 2.0)) * 0.04;
	blurred += texture(TEXTURE, UV - vec2(0.0, step_uv.y * 2.0)) * 0.04;
	blurred.rgb += vec3(0.015, 0.11, 0.075) * (1.0 - reveal);
	COLOR = vec4(blurred.rgb, blurred.a * smoothstep(0.0, 0.65, reveal));
}
