// Object mask fragment shader, normal content (MaskContent.normal): the
// material's shading normal — the geometric normal perturbed by its normal
// map exactly as the color pass does (PerturbNormal) — in world space,
// encoded n * 0.5 + 0.5. Alpha is the per-item color's alpha. Pairs with
// the engine's full vertex shaders; MaskInfo matches flutter_scene_mask.frag.

#include <material_varyings.glsl>
#include <material_inputs.glsl>
#include <normals.glsl>
#include <mask_surface.glsl>

uniform MaskInfo {
  vec4 color;
}
mask_info;

void main() {
  vec3 normal = GetWorldNormal();
  if (mask_surface.normal_params.x > 0.5) {
    vec2 uv = MaterialTextureUv(mask_surface.normal_uv_transform,
                                mask_surface.normal_uv_rotation);
    normal = PerturbNormal(normal_texture, normal, v_viewvector, uv,
                           mask_surface.normal_params.y);
  }
  frag_color = vec4(normal * 0.5 + 0.5, mask_info.color.a);
}
