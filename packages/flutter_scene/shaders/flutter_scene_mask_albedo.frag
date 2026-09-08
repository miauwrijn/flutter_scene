// Object mask fragment shader, albedo content (MaskContent.albedo): the
// per-item color times the material's textured base color, so a custom
// pass can shade with the surface's own albedo at full resolution. Pairs
// with the engine's full vertex shaders (the UVs and vertex color come from
// the varyings); MaskInfo matches flutter_scene_mask.frag.

#include <material_varyings.glsl>
#include <material_inputs.glsl>
#include <mask_surface.glsl>

uniform MaskInfo {
  // rgb: the per-item color (linear), multiplied in; a: coverage/weight.
  vec4 color;
}
mask_info;

void main() {
  frag_color = vec4(mask_info.color.rgb * MaskSurfaceAlbedo(),
                    mask_info.color.a);
}
