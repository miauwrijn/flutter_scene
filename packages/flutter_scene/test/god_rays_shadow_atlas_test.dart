// God rays sample the directional light's cascades from the shared shadow
// atlas, a strip whose tiles spot and point shadows add to. They divided the
// strip by the cascade count alone, so a shadowed spot light anywhere in the
// scene moved every cascade lookup and changed the sun's shafts.

@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/custom_render_pass.dart'
    show packPostShadowInfo;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

const _size = 48;

Future<Uint8List> _render({required bool withSpotShadow}) async {
  final scene = Scene()
    ..directionalLight = DirectionalLight(
      direction: Vector3(0.15, -1.0, 0.05),
      intensity: 4.0,
      castsShadow: true,
      shadowCascadeCount: 2,
      shadowMaxDistance: 40,
    );
  scene.godRays
    ..enabled = true
    ..intensity = 3.0
    ..density = 1.0;
  // A floor, and a roof over the left half of the view: the air below the
  // roof is in its shadow, so half the shafts depend on the cascade lookup.
  scene
    ..add(
      Node(
        mesh: Mesh(
          CuboidGeometry(Vector3(40, 0.2, 40)),
          PhysicallyBasedMaterial(),
        ),
      )..position = Vector3(0, -1, -10),
    )
    ..add(
      Node(
        mesh: Mesh(
          CuboidGeometry(Vector3(10, 0.2, 30)),
          PhysicallyBasedMaterial(),
        ),
      )..position = Vector3(-5, 6, -10),
    );
  if (withSpotShadow) {
    // In view, so it gets a shadow tile, but pointing up into empty sky
    // with a short range: it lights nothing the camera sees and only adds a
    // tile to the shadow atlas.
    scene.add(
      Node(localTransform: Matrix4.translation(Vector3(6, 0.5, -14)))
        ..addComponent(
          SpotLightComponent(
            SpotLight(
              range: 3.0,
              castsShadow: true,
              intensity: 0.001,
              direction: Vector3(0, -1, 0),
            ),
          ),
        ),
    );
  }
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(
      position: Vector3(0, 1, 0),
      target: Vector3(0, 1, -10),
      up: Vector3(0, 1, 0),
    ),
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, _size + 0.0, _size + 0.0),
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(_size, _size);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  scene.dispose();
  return bytes.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final noGpu = gpuAvailable()
      ? null
      : 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.';

  setUpAll(() async {
    if (noGpu == null) await Scene.initializeStaticResources();
  });

  test('packPostShadowInfo carries the atlas tile count in light_color.w', () {
    final cascade = ShadowCascade(
      lightSpaceMatrix: Matrix4.identity(),
      splitDistance: 10.0,
      boxSize: 5.0,
    );
    Float32List pack({int? totalTiles}) {
      final bytes = packPostShadowInfo(
        [cascade, cascade],
        Vector3(0, -1, 0),
        Vector3.all(1),
        totalTiles: totalTiles,
      );
      return bytes.buffer.asFloat32List(bytes.offsetInBytes, 76);
    }

    // The cascades alone when no other tile shares the atlas.
    expect(pack()[75], 2.0);
    expect(pack(totalTiles: 5)[75], 5.0);
  });

  test('a shadowed spot light leaves the sun\'s shafts alone', () async {
    final without = await _render(withSpotShadow: false);
    final withSpot = await _render(withSpotShadow: true);
    var maxDelta = 0;
    for (var i = 0; i < without.length; i++) {
      final d = (without[i] - withSpot[i]).abs();
      if (d > maxDelta) maxDelta = d;
    }
    // A few levels of noise from the extra light and the wider atlas; the
    // old divide-by-cascade-count misplaced the lookups by about 20.
    expect(maxDelta, lessThanOrEqualTo(6));
  }, skip: noGpu);
}
