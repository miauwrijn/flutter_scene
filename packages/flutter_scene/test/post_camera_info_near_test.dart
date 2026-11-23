// PostCameraInfo's near is the plane the frame clips geometry at. A view
// fits its near plane to the visible content, so a custom pass that
// reconstructed points on the camera's own near plane put them somewhere
// the geometry was not clipped (a waterline drawn in the wrong place).

@TestOn('vm')
library;

import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/viewport_camera.dart'
    show depthRasterOf;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

class _NearProbe extends CustomRenderPass {
  double? packedNear;
  double? rasterNear;

  @override
  String get name => 'near_probe';

  @override
  RenderStage get stage => RenderStage.afterScene;

  @override
  void execute(RenderPassContext context) {
    final info = context.cameraInfo;
    packedNear = info.buffer.asFloat32List(info.offsetInBytes, 20)[2];
    rasterNear = depthRasterOf(context.camera).near;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final noGpu = gpuAvailable()
      ? null
      : 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.';

  setUpAll(() async {
    if (noGpu == null) await Scene.initializeStaticResources();
  });

  test('cameraInfo carries the fitted near the frame rasterizes with', () {
    // Everything visible is far away, so the view raises its near plane well
    // past the camera's own.
    final scene = Scene()
      ..add(
        Node(mesh: Mesh(CuboidGeometry(Vector3.all(1)), UnlitMaterial()))
          ..position = Vector3(0, 0, -20),
      );
    final probe = _NearProbe();
    scene.addRenderPass(probe);
    final camera = PerspectiveCamera(
      position: Vector3.zero(),
      target: Vector3(0, 0, -1),
      up: Vector3(0, 1, 0),
    );
    final ownNear = (camera.projection as PerspectiveProjection).near;
    final recorder = ui.PictureRecorder();
    scene.render(
      camera,
      ui.Canvas(recorder),
      viewport: const ui.Rect.fromLTWH(0, 0, 32, 32),
      pixelRatio: 1.0,
    );
    recorder.endRecording().dispose();
    scene.dispose();

    final rasterNear = probe.rasterNear;
    expect(rasterNear, isNotNull, reason: 'the view fitted no near plane');
    expect(rasterNear, greaterThan(ownNear));
    expect(probe.packedNear, closeTo(rasterNear!, rasterNear * 1e-6));
  }, skip: noGpu);
}
