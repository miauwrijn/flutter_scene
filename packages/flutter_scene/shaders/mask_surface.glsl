// The material inputs the surface-content object masks sample (see
// MaskContent in object_filter.dart and Material.bindMaskSurface): the
// base color as the standard material shades with it, and the normal map.
// Requires the full-vertex varyings (material_varyings.glsl) and
// MaterialTextureUv (material_inputs.glsl).

uniform MaskSurfaceInfo {
  // rgb: base color factor (linear); w: vertex-color weight.
  vec4 color;
  // Base color UV: xy offset, zw scale; then xy cos/sin, z UV channel,
  // w the triplanar repeat per world unit for a surface that has no UVs
  // (its vertices carry u < -0.5), or 0 for none.
  vec4 base_uv_transform;
  vec4 base_uv_rotation;
  // Normal map UV, likewise.
  vec4 normal_uv_transform;
  vec4 normal_uv_rotation;
  // x: whether the material has a normal map; y: its scale; z: the alpha
  // cutoff of a cut-out material (0: no test); w: the vertex-color alpha
  // weight the cut-out's coverage multiplies in.
  vec4 normal_params;
}
mask_surface;

uniform sampler2D base_color_texture;
uniform sampler2D normal_texture;

// Discards the fragment where a cut-out material's coverage falls below
// its cutoff, so a mask of a leaf card is the leaf and not its quad: the
// surface behind the cut-out keeps its own albedo and normal in the mask,
// which is what a pass shading with them (a bounce composite, say) needs
// — without this the ground under every card read as a black square.
// Mirrors the depth passes' ApplyDepthAlphaMask.
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

// The base color texture sampled by world position on three planes,
// blended by the normal: for a surface with no UVs (a mesh grown as one
// manifold marks its vertices with u < -0.5), so its mask carries the
// texture the color pass draws with instead of one texel.
vec3 MaskSurfaceTriplanar(float repeat) {
  vec3 p = v_position * repeat;
  vec3 n = normalize(v_normal);
  vec3 w = pow(abs(n), vec3(4.0));
  w /= (w.x + w.y + w.z);
  return texture(base_color_texture, p.yz).rgb * w.x +
         texture(base_color_texture, p.xz).rgb * w.y +
         texture(base_color_texture, p.xy).rgb * w.z;
}

// The linear base color at this fragment, as Surface() computes it.
vec3 MaskSurfaceAlbedo() {
  vec2 uv = MaterialTextureUv(mask_surface.base_uv_transform,
                              mask_surface.base_uv_rotation);
  float repeat = mask_surface.base_uv_rotation.w;
  vec3 srgb = repeat > 0.0 && v_texture_coords.x < -0.5
      ? MaskSurfaceTriplanar(repeat)
      : texture(base_color_texture, uv).rgb;
  vec3 linear = mix(srgb / 12.92,
                    pow((srgb + 0.055) / 1.055, vec3(2.4)),
                    step(0.04045, srgb));
  vec3 vertex = mix(vec3(1.0), v_color.rgb, mask_surface.color.w);
  return linear * vertex * mask_surface.color.rgb;
}
