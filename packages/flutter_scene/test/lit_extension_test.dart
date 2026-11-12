// The lit extension is a contract between three places that cannot see each
// other: the FragInfo block in GLSL, the indices the Dart side packs it at,
// and the engine's own (empty) extension file an application's replaces.
import 'dart:io';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/light.dart' show leanLightingAllowed;
import 'package:flutter_scene/src/material/engine_lighting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the extension fields close the FragInfo block where Dart packs them',
    () {
      final inputs = File(
        'shaders/material_scene_inputs.glsl',
      ).readAsStringSync();
      final block = inputs.substring(
        inputs.indexOf('uniform FragInfo {'),
        inputs.indexOf('frag_info;'),
      );
      final fields = RegExp(
        r'^\s*(?:highp\s+)?(?:vec4|mat4|float)\s+(\w+)(?:\[(\d+)\])?;',
        multiLine: true,
      ).allMatches(block).toList();
      expect(fields[fields.length - 2].group(1), 'ext_params');
      expect(fields[fields.length - 2].group(2), '9');
      expect(fields.last.group(1), 'ext_material');
      expect(LitExtension.paramCount, 9 * 4);
      expect(
        EngineLightingUniforms.extensionMaterialIndex,
        EngineLightingUniforms.extensionParamsIndex + LitExtension.paramCount,
      );
      expect(
        EngineLightingUniforms.fragInfoFloatCount,
        EngineLightingUniforms.extensionMaterialIndex + 4,
      );
    },
  );

  test('an active extension keeps a frame off the lean lit tier', () {
    bool allowed({required bool extension}) => leanLightingAllowed(
      irradianceField: false,
      rectAreaLightCount: 0,
      environmentBlending: false,
      ambientOcclusion: false,
      pointShadowTileCount: 0,
      litExtension: extension,
    );
    expect(allowed(extension: false), isTrue);
    expect(allowed(extension: true), isFalse);
  });

  test("the engine's own extension file hooks nothing", () {
    final lines = File(
      'shaders/flutter_scene_lit_extension.glsl',
    ).readAsLinesSync();
    expect(
      lines.where((line) => line.trim().isNotEmpty && !line.startsWith('//')),
      isEmpty,
    );
  });

  test('the lit shader calls each hook only when the extension defines it', () {
    final lighting = File('shaders/material_lighting.glsl').readAsStringSync();
    expect(lighting, contains('#include <flutter_scene_lit_extension.glsl>'));
    expect(lighting, contains('defined(FLUTTER_SCENE_EXT_SURFACE)'));
    expect(lighting, contains('defined(FLUTTER_SCENE_EXT_SUN_VISIBILITY)'));
    expect(lighting, contains('#ifndef FLUTTER_SCENE_EXT_TRANSMISSION'));
  });
}
