// Covers `mask_surface: true`: the `<Name>MaskAlbedo` and `<Name>MaskNormal`
// entries built from the material's own Surface(), their sidecar map, the
// parser's rules, and that the entries compile on every backend.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_gpu_shaders/environment.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat_emitter.dart'
    show kMaskSurfaceDefine, materialHasMaskSurface;
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/runtime_compile.dart';
import 'package:flutter_test/flutter_test.dart';

const _ground = '''
material {
  name: "Ground",
  shading_model: lit,
  blending: opaque,
  mask_surface: true,
  parameters: [
    { type: sampler2d, name: grain },
    { type: float, name: relief, default: 1.0 },
  ],
}

fragment {
  void Surface(inout MaterialInputs material) {
    vec3 c = texture(grain, GetUV0()).rgb;
#ifndef FLUTTER_SCENE_MASK_SURFACE
    c *= material_params.relief;
#endif
    material.base_color = vec4(c, 1.0);
  }
}
''';

void main() async {
  test('mask_surface ships albedo and normal mask fragments', () {
    final material = compileFmat(_ground, fileName: 'ground.fmat').material;
    expect(material.maskSurface, isTrue);
    expect(materialHasMaskSurface(material), isTrue);
    expect(buildSidecar(material)['mask_surface'], {
      'albedo': 'GroundMaskAlbedo',
      'normal': 'GroundMaskNormal',
    });
    for (final kind in MaskSurfaceKind.values) {
      final source = emitFragmentGlsl(material, maskSurface: kind);
      expect(source, contains('#define $kMaskSurfaceDefine'));
      expect(source, contains('#define ${kind.define}'));
      expect(source, contains('Surface(material);'));
      expect(source, contains('uniform MaskInfo'));
      // Only its own kind's define.
      for (final other in MaskSurfaceKind.values) {
        if (other != kind) expect(source, isNot(contains(other.define)));
      }
    }
    expect(
      emitFragmentGlsl(material, maskSurface: MaskSurfaceKind.albedo),
      contains('mask_info.color.rgb * material.base_color.rgb'),
    );
    expect(
      emitFragmentGlsl(material, maskSurface: MaskSurfaceKind.normal),
      contains('normalize(material.normal) * 0.5 + 0.5'),
    );
    // The shaded entry is not the mask's.
    expect(
      emitFragmentGlsl(material),
      isNot(contains('#define $kMaskSurfaceDefine')),
    );
  });

  test('without mask_surface there is no mask fragment', () {
    final material = compileFmat(
      _ground.replaceFirst('  mask_surface: true,\n', ''),
      fileName: 'plain.fmat',
    ).material;
    expect(material.maskSurface, isFalse);
    expect(buildSidecar(material).containsKey('mask_surface'), isFalse);
  });

  test('a material with engine inputs gets no mask fragment', () {
    final material = compileFmat(
      _ground.replaceFirst(
        '  mask_surface: true,\n',
        '  mask_surface: true,\n  engine_inputs: [scene_depth],\n',
      ),
      fileName: 'inputs.fmat',
    ).material;
    expect(material.maskSurface, isTrue);
    expect(materialHasMaskSurface(material), isFalse);
    expect(buildSidecar(material).containsKey('mask_surface'), isFalse);
  });

  test('mask_surface must be a boolean', () {
    expect(
      () => compileFmat(
        _ground.replaceFirst('mask_surface: true', 'mask_surface: 1'),
        fileName: 'bad.fmat',
      ),
      throwsA(
        isA<FmatException>().having(
          (e) => e.message,
          'message',
          contains('`mask_surface` must be a boolean'),
        ),
      ),
    );
  });

  test('mask_surface is rejected on a sky', () {
    expect(
      () => compileFmat('''
material { name: "Dome", mask_surface: true }
sky {
  vec3 Sky(vec3 direction) {
    return vec3(0.5);
  }
}
''', fileName: 'dome.fmat'),
      throwsA(isA<FmatException>()),
    );
  });

  Uri? impellerc;
  try {
    impellerc = await findImpellerC();
  } catch (_) {
    impellerc = null;
  }

  test('the mask entries compile on every backend', () async {
    final cacheDir = Directory.systemTemp.createTempSync('fmat_mask_surface_');
    try {
      final result = await FmatRuntimeCompiler(
        impellerc: impellerc!,
        includeDirectories: [Directory('shaders').absolute.uri],
        cacheDirectory: cacheDir,
      ).compile(_ground, fileName: 'ground.fmat');
      final metadata = (result.sidecar[result.entryName] as Map)
          .cast<String, Object?>();
      expect(metadata['mask_surface'], {
        'albedo': 'GroundMaskAlbedo',
        'normal': 'GroundMaskNormal',
      });
    } finally {
      cacheDir.deleteSync(recursive: true);
    }
  }, skip: impellerc == null ? 'impellerc not found in the SDK cache' : false);
}
