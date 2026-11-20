// Covers `stage: vertex` sampler parameters: declared and kept alive in the
// vertex stage only, recorded in the sidecar, bound on the vertex shader by
// the runtime, and rejected where they cannot work.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu_shaders/environment.dart';
import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat_bytes_library.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/runtime_compile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

// A lit material whose Vertex() displaces by a height map that Surface()
// never reads, next to an ordinary fragment texture.
const _displaced = '''
material {
  name: "Displaced",
  shading_model: lit,
  parameters: [
    { type: sampler2d, name: albedo },
    { type: sampler2d, name: height_map, hint: default_black, stage: vertex },
    { type: float, name: amount, default: 1.0 },
  ],
}

vertex {
  void Vertex(inout VertexInputs vertex) {
    vertex.world_position += vertex.world_normal *
        material_params.amount * textureLod(height_map, vertex.uv, 0.0).r;
  }
}

fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = texture(albedo, GetUV0());
  }
}
''';

// Only a vertex sampler: no uniform block, so the vertex keep-alive is the
// sampler read alone, and the fragment declares no parameter at all.
const _vertexOnly = '''
material {
  name: "VertexOnly",
  shading_model: unlit,
  parameters: [
    { type: sampler2d, name: wind, stage: vertex },
  ],
}

vertex {
  void Vertex(inout VertexInputs vertex) {
    vertex.world_position.x += textureLod(wind, vertex.uv, 0.0).r;
  }
}

fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = vec4(1.0);
    PrepareMaterial(material);
  }
}
''';

// The vertex stage reads a texture and hands the value to the fragment, so
// the pixel shows whether the texture bound to the vertex shader arrived.
const _passThrough = '''
material {
  name: "VertexSamplerPassThrough",
  shading_model: unlit,
  culling: none,
  parameters: [
    { type: sampler2d, name: level_map, hint: default_black, stage: vertex },
  ],
  varyings: [
    { type: float, name: level },
  ],
}

vertex {
  void Vertex(inout VertexInputs vertex) {
    level = textureLod(level_map, vec2(0.5), 0.0).r;
  }
}

fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = vec4(vec3(level), 1.0);
    PrepareMaterial(material);
  }
}
''';

// The red channel at the centre of a 32x32 render of [material] on a quad
// filling the view (a thin box facing the camera).
Future<int> _centreRed(Material material) async {
  final scene = Scene()
    ..add(
      Node(mesh: Mesh(CuboidGeometry(Vector3(4, 4, 0.01)), material))
        ..position = Vector3(0, 0, -1),
    );
  const size = ui.Size(32, 32);
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(
      position: Vector3.zero(),
      target: Vector3(0, 0, -1),
      up: Vector3(0, 1, 0),
    ),
    ui.Canvas(recorder),
    viewport: ui.Offset.zero & size,
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(32, 32);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  scene.dispose();
  return bytes.getUint8((16 * 32 + 16) * 4);
}

String _material(String parameter, {bool withVertex = true}) =>
    '''
material {
  name: "Bad",
  shading_model: unlit,
  parameters: [ $parameter ],
}
${withVertex ? 'vertex { void Vertex(inout VertexInputs vertex) {} }' : ''}
fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = vec4(1.0);
    PrepareMaterial(material);
  }
}
''';

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('emitter', () {
    test('a vertex sampler is declared in the vertex stage only', () {
      final material = compileFmat(_displaced, fileName: 'd.fmat').material;
      expect(material.fragmentSamplerParameters.map((p) => p.name), ['albedo']);
      expect(material.vertexSamplerParameters.map((p) => p.name), [
        'height_map',
      ]);

      final fragment = emitFragmentGlsl(material);
      expect(fragment, contains('uniform sampler2D albedo;'));
      expect(fragment, isNot(contains('height_map')));

      final vertex = emitVertexGlsl(material);
      expect(vertex, isNotEmpty);
      for (final source in vertex.values) {
        expect(source, contains('uniform sampler2D height_map;'));
        expect(source, isNot(contains('albedo')));
        // Kept alive next to the uniform block, with an explicit LOD.
        expect(source, contains('textureLod(height_map, vec2(0.0), 0.0).x'));
      }
    });

    test('a vertex sampler alone still gets a vertex keep-alive', () {
      final material = compileFmat(_vertexOnly, fileName: 'v.fmat').material;
      for (final source in emitVertexGlsl(material).values) {
        expect(
          source,
          contains(
            '#define MATERIAL_PARAMS_KEEP_ALIVE '
            '(textureLod(wind, vec2(0.0), 0.0).x)',
          ),
        );
      }
      // The fragment declares no parameter, so no fragment keep-alive block
      // (which the runtime mirrors with hasAnyParameters).
      expect(emitFragmentGlsl(material), isNot(contains('FragmentKeepAlive')));
    });

    test('a vertex sampler2DArray is kept alive with a layer coordinate', () {
      final material = compileFmat(
        _vertexOnly
            .replaceFirst(
              '{ type: sampler2d, name: wind, stage: vertex }',
              '{ type: sampler2DArray, name: wind, stage: vertex }',
            )
            .replaceFirst('vertex.uv, 0.0', 'vec3(vertex.uv, 0.0), 0.0'),
        fileName: 'a.fmat',
      ).material;
      for (final source in emitVertexGlsl(material).values) {
        expect(source, contains('uniform sampler2DArray wind;'));
        expect(source, contains('textureLod(wind, vec3(0.0), 0.0).x'));
      }
    });

    test('the sidecar marks vertex samplers', () {
      final material = compileFmat(_displaced, fileName: 'd.fmat').material;
      final samplers = (buildSidecar(material)['samplers']! as List)
          .cast<Map<String, Object?>>();
      expect(samplers.firstWhere((s) => s['name'] == 'albedo'), {
        'name': 'albedo',
        'type': 'sampler2D',
      });
      expect(
        samplers.firstWhere((s) => s['name'] == 'height_map')['stage'],
        'vertex',
      );
    });
  });

  group('parser', () {
    void expectRejected(String source, String message) => expect(
      () => compileFmat(source, fileName: 'bad.fmat'),
      throwsA(
        isA<FmatException>().having(
          (e) => e.message,
          'message',
          contains(message),
        ),
      ),
    );

    test('stage: fragment is the default and may be spelled out', () {
      final material = compileFmat(
        _material('{ type: sampler2d, name: t, stage: fragment }'),
        fileName: 'f.fmat',
      ).material;
      expect(material.fragmentSamplerParameters.map((p) => p.name), ['t']);
    });

    test('stage is rejected on a uniform parameter', () {
      expectRejected(
        _material('{ type: float, name: f, stage: vertex }'),
        'only sampler parameters take a `stage`',
      );
    });

    test('stage must be fragment or vertex', () {
      expectRejected(
        _material('{ type: sampler2d, name: t, stage: geometry }'),
        '`stage` must be `fragment` or `vertex`',
      );
    });

    test('a vertex sampler needs a vertex block', () {
      expectRejected(
        _material(
          '{ type: sampler2d, name: t, stage: vertex }',
          withVertex: false,
        ),
        'must declare a `vertex { }` block',
      );
    });
  });

  group('runtime parameters', () {
    test('vertex samplers are told apart from fragment samplers', () {
      final params = MaterialParameters.withLayout(
        blockName: 'MaterialParams',
        blockSizeBytes: 0,
        parameters: const {},
        samplers: const {'albedo': null, 'height_map': null},
        vertexSamplers: const {'height_map'},
      );
      expect(params.isVertexSampler('height_map'), isTrue);
      expect(params.isVertexSampler('albedo'), isFalse);
      expect(params.isVertexSampler('missing'), isFalse);
      expect(params.hasAnyParameters, isTrue);
    });

    test('vertex samplers alone do not count as fragment parameters', () {
      final params = MaterialParameters.withLayout(
        blockName: 'MaterialParams',
        blockSizeBytes: 0,
        parameters: const {},
        samplers: const {'wind': null},
        vertexSamplers: const {'wind'},
      );
      expect(params.hasAnyParameters, isFalse);
    });

    test('a refresh keeps the stage the new metadata gives', () {
      final params = MaterialParameters.withLayout(
        blockName: 'MaterialParams',
        blockSizeBytes: 0,
        parameters: const {},
        samplers: const {'t': null},
      );
      expect(params.isVertexSampler('t'), isFalse);
      params.updateFromLayout(
        blockName: 'MaterialParams',
        blockSizeBytes: 0,
        parameters: const {},
        samplers: const {'t': null},
        vertexSamplers: const {'t'},
      );
      expect(params.isVertexSampler('t'), isTrue);
    });
  });

  // The generated GLSL through impellerc, for every backend in the bundle.
  Uri? impellerc;
  try {
    impellerc = await findImpellerC();
  } catch (_) {
    impellerc = null;
  }
  final skip = impellerc == null
      ? 'impellerc not found in the SDK cache'
      : false;

  group('compiles', () {
    late Directory cacheDir;
    late FmatRuntimeCompiler compiler;

    setUp(() {
      cacheDir = Directory.systemTemp.createTempSync('fmat_vertex_samplers_');
      compiler = FmatRuntimeCompiler(
        impellerc: impellerc ?? Uri.file('/nonexistent'),
        includeDirectories: [Directory('shaders').absolute.uri],
        cacheDirectory: cacheDir,
      );
    });

    tearDown(() => cacheDir.deleteSync(recursive: true));

    for (final (name, source) in [
      ('displaced.fmat', _displaced),
      ('vertex_only.fmat', _vertexOnly),
    ]) {
      test(name, () async {
        final result = await compiler.compile(source, fileName: name);
        // The flatbuffer file identifier sits after the root offset.
        expect(
          utf8.decode(Uint8List.sublistView(result.shaderBundle, 4, 8)),
          'IPSB',
        );
        final metadata = (result.sidecar[result.entryName] as Map)
            .cast<String, Object?>();
        expect(
          (metadata['samplers']! as List).any(
            (s) => (s as Map)['stage'] == 'vertex',
          ),
          isTrue,
        );
      }, skip: skip);
    }
  });

  final noGpu = !gpuAvailable()
      ? 'no GPU context in this environment'
      : impellerc == null
      ? 'impellerc not found in the SDK cache'
      : null;

  group('renders', () {
    late Directory cacheDir;

    setUpAll(() async {
      if (noGpu == null) await Scene.initializeStaticResources();
    });
    setUp(
      () => cacheDir = Directory.systemTemp.createTempSync('fmat_vs_render_'),
    );
    tearDown(() => cacheDir.deleteSync(recursive: true));

    test('a texture bound to a vertex sampler reaches Vertex()', () async {
      final compiler = FmatRuntimeCompiler(
        impellerc: impellerc!,
        includeDirectories: [Directory('shaders').absolute.uri],
        cacheDirectory: cacheDir,
      );
      final compiled = await compiler.compile(
        _passThrough,
        fileName: 'pass_through.fmat',
      );
      final library = await FmatBytesLibrary.load(
        compiled.shaderBundle,
        compiled.sidecar,
      );

      // Unbound: the default_black placeholder.
      final unbound = library.createMaterial(compiled.entryName);
      expect(await _centreRed(unbound), lessThan(16));

      // Bound to white: only a vertex-stage bind can make the quad bright.
      final white = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        1,
        1,
      );
      white.overwrite(
        ByteData.sublistView(Uint8List.fromList([255, 255, 255, 255])),
      );
      final bound = library.createMaterial(compiled.entryName);
      bound.parameters.setTexture('level_map', white);
      expect(await _centreRed(bound), greaterThan(200));
    }, skip: noGpu);
  });
}
