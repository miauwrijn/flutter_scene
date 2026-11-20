// The material inputs the surface-content object masks sample (see
// MaskContent in object_filter.dart and Material.bindMaskSurface): the base
// color as the standard material shades with it, and its normal map.
// Requires the full-vertex varyings (material_varyings.glsl) and
// MaterialTextureUv (material_inputs.glsl).

uniform MaskSurfaceInfo {
  // rgb: base color factor (linear); w: vertex-color weight.
  vec4 color;
  // Base color UV: xy offset, zw scale; then xy cos/sin, z UV channel,
  // w unused.
  vec4 base_uv_transform;
  vec4 base_uv_rotation;
  // Normal map UV, likewise.
  vec4 normal_uv_transform;
  vec4 normal_uv_rotation;
  // x: whether the material has a normal map; y: its scale; z: the alpha
  // cutoff of a cut-out material (0: no test); w: the vertex-color alpha
  // weight its coverage multiplies in.
  vec4 normal_params;
}
mask_surface;

uniform sampler2D base_color_texture;
// Declared only by the shader that reads it (the normal content defines
// MASK_SURFACE_NORMAL): an unread sampler is compiled out, and binding a slot
// the compiled shader does not have fails.
#ifdef MASK_SURFACE_NORMAL
uniform sampler2D normal_texture;
#endif

// Discards the fragment where a cut-out material's coverage falls below its
// cutoff, so the mask of a leaf card is the leaf and not its quad, and what
// lies behind the cut-out keeps its own content. Mirrors the depth passes'
// alpha mask.
void MaskSurfaceAlphaTest() {
  float cutoff = mask_surface.normal_params.z;
  if (cutoff <= 0.0) {
    return;
  }
  vec2 uv = MaterialTextureUv(mask_surface.base_uv_transform,
                              mask_surface.base_uv_rotation);
  float alpha = texture(base_color_texture, uv).a *
                mix(1.0, v_color.a, mask_surface.normal_params.w);
  if (alpha < cutoff) {
    discard;
  }
}

// The linear base color at this fragment, as the standard material shades
// with it: the (sRGB) texture times the factor and the weighted vertex color.
vec3 MaskSurfaceAlbedo() {
  vec2 uv = MaterialTextureUv(mask_surface.base_uv_transform,
                              mask_surface.base_uv_rotation);
  vec3 srgb = texture(base_color_texture, uv).rgb;
  vec3 linear = mix(srgb / 12.92, pow((srgb + 0.055) / 1.055, vec3(2.4)),
                    step(0.04045, srgb));
  vec3 vertex = mix(vec3(1.0), v_color.rgb, mask_surface.color.w);
  return linear * vertex * mask_surface.color.rgb;
}
