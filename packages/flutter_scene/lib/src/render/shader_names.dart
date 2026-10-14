import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/shared/shader_library_sources.dart'
    show knownShaderLibraries;

/// [shader]'s entry name in whichever loaded shader library holds it, for a
/// progress label or a profiler event; null when no library knows it.
String? shaderEntryName(gpu.Shader shader) {
  for (final library in knownShaderLibraries()) {
    try {
      final shaders = (library as dynamic).shaders_ as Map;
      for (final entry in shaders.entries) {
        if (identical(entry.value, shader)) return '${entry.key}';
      }
    } on Object {
      // A backend whose library keeps its shaders otherwise: no name.
    }
  }
  return null;
}
