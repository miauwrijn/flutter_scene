// The camera depth prepass with surfaces (RenderInput.surfaces): what
// LinearDepthNormalFragment writes (planar depth, view normal, roughness),
// and in two more targets what the object masks MaskAlbedoFragment and
// MaskNormalFragment would draw — the receiver albedo (times the per-item
// color, its alpha) and the shading normal (normal-mapped, n * 0.5 + 0.5,
// the per-item alpha) — in the same pass, so a consumer needs no redraw.
#define FLUTTER_SCENE_NO_VIEW_INFO
#define FLUTTER_SCENE_SURFACE_TARGETS
#include <material_varyings.glsl>
#include <material_inputs.glsl>
#include <normals.glsl>
#define MASK_SURFACE_NORMAL
#include <mask_surface.glsl>

uniform DepthNormalInfo {
  vec4 camera_forward;
  vec4 camera_right;
  vec4 camera_up;
  vec4 roughness_uv_transform;
  vec4 roughness_uv_rotation;
}
info;

// The per-item colors: the albedo target's (rgb multiplied in, a), the
// normal target's alpha.
uniform PrepassSurfaceInfo {
  vec4 albedo_color;
  vec4 normal_color;
}
prepass_surface;

uniform sampler2D metallic_roughness_texture;

vec2 OctEncode(vec3 n) {
  n /= (abs(n.x) + abs(n.y) + abs(n.z));
  vec2 e = n.z >= 0.0
      ? n.xy
      : (1.0 - abs(n.yx)) *
            vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
  return e;
}

void main() {
  MaskSurfaceAlphaTest();
  float view_depth = -dot(v_viewvector, info.camera_forward.xyz);
  vec3 n = GetWorldNormal();
  vec3 view_normal = normalize(vec3(dot(n, info.camera_right.xyz),
                                    dot(n, info.camera_up.xyz),
                                    dot(n, info.camera_forward.xyz)));
  vec2 roughness_uv = MaterialTextureUv(info.roughness_uv_transform,
                                        info.roughness_uv_rotation);
  float roughness = clamp(
      texture(metallic_roughness_texture, roughness_uv).g *
          info.camera_forward.w,
      0.0, 1.0);
  vec2 oct = OctEncode(view_normal);
  frag_color = vec4(view_depth, oct.x, oct.y, roughness);
  frag_albedo = vec4(prepass_surface.albedo_color.rgb * MaskSurfaceAlbedo(),
                     prepass_surface.albedo_color.a);
  vec3 shading = n;
  if (mask_surface.normal_params.x > 0.5) {
    vec2 uv = MaterialTextureUv(mask_surface.normal_uv_transform,
                                mask_surface.normal_uv_rotation);
    shading = PerturbNormal(normal_texture, n, v_viewvector, uv,
                            mask_surface.normal_params.y);
  }
  frag_normal = vec4(shading * 0.5 + 0.5, prepass_surface.normal_color.a);
}
