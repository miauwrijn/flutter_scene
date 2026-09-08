// The material inputs the surface-content object masks sample (see
// MaskContent in object_filter.dart and Material.bindMaskSurface): the
// base color as the standard material shades with it, and the normal map.
// Requires the full-vertex varyings (material_varyings.glsl) and
// MaterialTextureUv (material_inputs.glsl).

uniform MaskSurfaceInfo {
  // rgb: base color factor (linear); w: vertex-color weight.
  vec4 color;
  // Base color UV: xy offset, zw scale; then xy cos/sin, z UV channel.
  vec4 base_uv_transform;
  vec4 base_uv_rotation;
  // Normal map UV, likewise.
  vec4 normal_uv_transform;
  vec4 normal_uv_rotation;
  // x: whether the material has a normal map; y: its scale.
  vec4 normal_params;
}
mask_surface;

uniform sampler2D base_color_texture;
uniform sampler2D normal_texture;

// The linear base color at this fragment, as Surface() computes it.
vec3 MaskSurfaceAlbedo() {
  vec2 uv = MaterialTextureUv(mask_surface.base_uv_transform,
                              mask_surface.base_uv_rotation);
  vec3 srgb = texture(base_color_texture, uv).rgb;
  vec3 linear = mix(srgb / 12.92,
                    pow((srgb + 0.055) / 1.055, vec3(2.4)),
                    step(0.04045, srgb));
  vec3 vertex = mix(vec3(1.0), v_color.rgb, mask_surface.color.w);
  return linear * vertex * mask_surface.color.rgb;
}
