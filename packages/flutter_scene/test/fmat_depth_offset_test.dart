// Covers `depth_offset: true`: the emitted field and gl_FragDepth write, the
// parser's rules, and on a GPU that a surface pushed back along the view ray
// really is occluded by what stands between it and its polygon.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_gpu_shaders/environment.dart';
import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat_bytes_library.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat_emitter.dart'
    show kMaterialDepthOffsetDefine;
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/runtime_compile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

// Unlit on purpose: an unlit material only carries FragInfo (where the
// projection row rides) because it writes depth.
const _relief = '''
material {
  name: "Relief",
  shading_model: unlit,
  depth_offset: true,
  parameters: [
    { type: float, name: offset, default: 0.0 },
  ],
}

fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = vec4(1.0, 0.0, 0.0, 1.0);
    material.depth_offset = material_params.offset;
    PrepareMaterial(material);
  }
}
''';

const _plain = '''
material {
  name: "Plain",
  shading_model: lit,
}

fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = vec4(1.0);
  }
}
''';

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('emitter', () {
    test('depth_offset compiles the field and the gl_FragDepth write', () {
      final material = compileFmat(_relief, fileName: 'r.fmat').material;
      expect(material.depthOffset, isTrue);
      expect(buildSidecar(material)['depth_offset'], isTrue);
      final glsl = emitFragmentGlsl(material);
      expect(glsl, contains('#define $kMaterialDepthOffsetDefine'));
      expect(
        glsl,
        contains('gl_FragDepth = WindowDepthAlongView(material.depth_offset)'),
      );
      // Unlit, so FragInfo comes only through depth_offset.
      expect(glsl, contains('#include <material_scene_inputs.glsl>'));
    });

    test('a material without depth_offset writes no depth', () {
      final material = compileFmat(_plain, fileName: 'p.fmat').material;
      expect(material.depthOffset, isFalse);
      expect(buildSidecar(material).containsKey('depth_offset'), isFalse);
      final glsl = emitFragmentGlsl(material);
      expect(glsl, isNot(contains('gl_FragDepth')));
      expect(glsl, isNot(contains(kMaterialDepthOffsetDefine)));
    });
  });

  group('parser', () {
    test('depth_offset must be a boolean', () {
      expect(
        () => compileFmat('''
material { name: "Bad", depth_offset: 1 }
fragment { void Surface(inout MaterialInputs material) {} }
''', fileName: 'bad.fmat'),
        throwsA(
          isA<FmatException>().having(
            (e) => e.message,
            'message',
            contains('`depth_offset` must be a boolean'),
          ),
        ),
      );
    });

    test('depth_offset is rejected on a sky', () {
      expect(
        () => compileFmat('''
material { name: "Dome", depth_offset: true }
sky {
  vec3 Sky(vec3 direction) {
    return vec3(0.5);
  }
}
''', fileName: 'dome.fmat'),
        throwsA(
          isA<FmatException>().having(
            (e) => e.message,
            'message',
            contains('a sky writes no depth'),
          ),
        ),
      );
    });
  });

  Uri? impellerc;
  try {
    impellerc = await findImpellerC();
  } catch (_) {
    impellerc = null;
  }
  final skip = !gpuAvailable()
      ? 'no GPU context in this environment'
      : impellerc == null
      ? 'impellerc not found in the SDK cache'
      : null;

  group('renders', () {
    late Directory cacheDir;
    late FmatBytesLibrary library;
    late String entry;

    setUpAll(() async {
      if (skip != null) return;
      await Scene.initializeStaticResources();
      cacheDir = Directory.systemTemp.createTempSync('fmat_depth_offset_');
      final compiled = await FmatRuntimeCompiler(
        impellerc: impellerc!,
        includeDirectories: [Directory('shaders').absolute.uri],
        cacheDirectory: cacheDir,
      ).compile(_relief, fileName: 'relief.fmat');
      library = await FmatBytesLibrary.load(
        compiled.shaderBundle,
        compiled.sidecar,
      );
      entry = compiled.entryName;
    });
    tearDownAll(() {
      if (skip == null) cacheDir.deleteSync(recursive: true);
    });

    // The centre pixel's red and blue of the red relief quad at 1 m, written
    // [offset] m further back, in front of a blue quad at 1.25 m. (Tone
    // mapping lifts the off channels of a pure color to about 33.)
    Future<List<int>> centre(double offset) async {
      final relief = library.createMaterial(entry)
        ..parameters.setFloat('offset', offset);
      final blue = UnlitMaterial()..baseColorFactor = Vector4(0, 0, 1, 1);
      final scene = Scene()
        ..add(
          Node(mesh: Mesh(CuboidGeometry(Vector3(4, 4, 0.001)), relief))
            ..position = Vector3(0, 0, -1),
        )
        ..add(
          Node(mesh: Mesh(CuboidGeometry(Vector3(4, 4, 0.001)), blue))
            ..position = Vector3(0, 0, -1.25),
        );
      final recorder = ui.PictureRecorder();
      scene.render(
        PerspectiveCamera(
          position: Vector3.zero(),
          target: Vector3(0, 0, -1),
          up: Vector3(0, 1, 0),
        ),
        ui.Canvas(recorder),
        viewport: const ui.Rect.fromLTWH(0, 0, 32, 32),
        pixelRatio: 1.0,
      );
      final image = await recorder.endRecording().toImage(32, 32);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      image.dispose();
      scene.dispose();
      final i = (16 * 32 + 16) * 4;
      return [bytes.getUint8(i), bytes.getUint8(i + 2)];
    }

    test('no offset keeps the polygon depth: the relief is in front', () async {
      final [red, blue] = await centre(0.0);
      expect(red, greaterThan(200));
      expect(blue, lessThan(64));
    }, skip: skip);

    test('an offset past the blue quad puts the relief behind it', () async {
      final [red, blue] = await centre(0.5);
      expect(red, lessThan(64));
      expect(blue, greaterThan(200));
    }, skip: skip);

    test(
      'an offset short of the blue quad keeps the relief in front',
      () async {
        final [red, blue] = await centre(0.1);
        expect(red, greaterThan(200));
        expect(blue, lessThan(64));
      },
      skip: skip,
    );
  });
}
