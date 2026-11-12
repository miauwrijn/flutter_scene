// The lit extension: an application's own code inside every lit material.
//
// This is the engine's copy and defines nothing. An application supplies its
// own file of this name in a directory of its own and names that directory:
//
//   * to flutter_scene's hook, which compiles the built-in physical
//     materials, with the `lit_extension` user-define in the root pubspec:
//
//       hooks:
//         user_defines:
//           flutter_scene:
//             lit_extension: path/to/the/directory
//
//   * to its own hooks, which compile its `.fmat` materials, with
//     `buildMaterials(litExtension: ...)` (or the
//     `flutter_scene_lit_extension` user-define of the package whose hook
//     it is).
//
// The directory goes on the include path ahead of the engine's, so the
// application's file is the one found, and it may include others beside it. Every lit material is rebuilt when a `.glsl` file in it changes.
//
// The file is included by `material_lighting.glsl` after the engine's own
// declarations, so it may use `frag_info`, MaterialInputs, the varyings'
// accessors (GetWorldNormal(), GetTime(), ...) and the engine's samplers. It
// opts into each hook by defining the hook's macro and its function:
//
//   #define FLUTTER_SCENE_EXT_SURFACE
//   void ExtSurface(inout MaterialInputs material, vec3 world_position);
//     Runs first in EvaluateLighting: everything is lit as it leaves the
//     surface. Not in the lean lit tier.
//
//   #define FLUTTER_SCENE_EXT_SUN_VISIBILITY
//   float ExtSunVisibility(vec3 world_position);
//     Multiplies the directional light's visibility (1 lit .. 0 blocked),
//     direct light only. Not in the lean lit tier.
//
//   #define FLUTTER_SCENE_EXT_TRANSMISSION
//   ExtTransmissionResult ExtTransmission(inout MaterialInputs material);
//     Called by the built-in transmissive material before it refracts; see
//     ExtTransmissionResult in material_lighting.glsl.
//
// Its inputs, none of which the engine interprets:
//
//   frag_info.ext_params[0..8]  `Scene.litExtension.params`, per frame.
//   frag_info.ext_material      `Material.extensionInput`, per material.
//   material.ext                what a material's own Surface() hands over.
//   ext_texture                 `Scene.litExtension.texture`; declared only
//                               where FLUTTER_SCENE_EXT_TEXTURE is defined.
//
// `Scene.litExtension.active` says whether the hooks have anything to do
// this frame: while it is true every lit draw uses the full lit tier.
