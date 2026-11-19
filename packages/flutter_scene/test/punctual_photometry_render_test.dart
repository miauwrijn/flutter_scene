// Renders a white floor under a point light and a spot light to check that a
// photometric profile actually shapes the light: a profile that is dark along
// its axis darkens the floor straight under the light, and a spot with a
// profile drops its cone.
@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

const int _size = 32;

// The red channel at the centre of a top-down view of a white floor, lit only
// by [light] on a node 1 m above the floor's centre.
Future<int> _floorUnder(Component light) async {
  final scene = Scene()
    ..environment = EnvironmentMap.empty()
    ..add(
      Node(
        mesh: Mesh(
          PlaneGeometry(width: 6, depth: 6),
          PhysicallyBasedMaterial()
            ..baseColorFactor = Vector4(1, 1, 1, 1)
            ..roughnessFactor = 1.0
            ..metallicFactor = 0.0,
        ),
      ),
    )
    ..add(
      Node(localTransform: Matrix4.translationValues(0, 1, 0))
        ..addComponent(light),
    );
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(
      position: Vector3(0, 3, 0),
      target: Vector3.zero(),
      up: Vector3(0, 0, -1),
    ),
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, _size + 0.0, _size + 0.0),
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(_size, _size);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  scene.dispose();
  return bytes.getUint8(((_size ~/ 2) * _size + _size ~/ 2) * 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final noGpu = gpuAvailable()
      ? null
      : 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.';

  setUpAll(() async {
    if (noGpu == null) await Scene.initializeStaticResources();
  });

  test(
    'a profile dark along its axis darkens the floor under a point light',
    () async {
      final uniform = await _floorUnder(
        PointLightComponent(PointLight(intensity: 2.0)),
      );
      // Black straight down (the default axis), full strength sideways and up.
      final shaped = await _floorUnder(
        PointLightComponent(
          PointLight(
            intensity: 2.0,
            photometry: Float32List.fromList([0, 1, 1]),
          ),
        ),
      );
      expect(uniform, greaterThan(120));
      expect(shaped, lessThan(uniform ~/ 3));
    },
    skip: noGpu,
  );

  test('the profile axis decides the dark direction', () async {
    // The same profile pointed up leaves the floor below at full strength.
    final pointedUp = await _floorUnder(
      PointLightComponent(
        PointLight(
          intensity: 2.0,
          photometry: Float32List.fromList([0, 1, 1]),
          photometryAxis: Vector3(0, 1, 0),
        ),
      ),
    );
    final uniform = await _floorUnder(
      PointLightComponent(PointLight(intensity: 2.0)),
    );
    expect(pointedUp, closeTo(uniform, 8));
  }, skip: noGpu);

  test('a profiled spot is lit by its profile, not its cone', () async {
    // A narrow cone that would light the floor's centre fully...
    SpotLight spot({Float32List? photometry}) => SpotLight(
      intensity: 2.0,
      innerConeAngle: 0.2,
      outerConeAngle: 0.4,
      photometry: photometry,
    );
    final cone = await _floorUnder(SpotLightComponent(spot()));
    // ...and a profile that is dark on the axis, which replaces the cone.
    final profiled = await _floorUnder(
      SpotLightComponent(spot(photometry: Float32List.fromList([0, 1]))),
    );
    expect(cone, greaterThan(120));
    expect(profiled, lessThan(cone ~/ 3));
  }, skip: noGpu);
}
