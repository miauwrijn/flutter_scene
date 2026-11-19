// Covers what RenderPassContext.drawObjects draws of an instanced batch: the
// instances the color pass draws (those in view, cut to the mesh's draw
// selector), not every instance of a batch whose bounds reach the view.

@TestOn('vm')
library;

import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/render_stats.dart'
    show activeRenderCounters;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

// Draws one flat object mask and records the instances it drew.
class _MaskProbe extends CustomRenderPass {
  int instances = -1;

  @override
  String get name => 'mask_probe';

  @override
  RenderStage get stage => RenderStage.afterScene;

  @override
  void execute(RenderPassContext context) {
    final before = activeRenderCounters.instances;
    context.drawObjects();
    instances = activeRenderCounters.instances - before;
  }
}

// Ten unit cubes along x, five in view of a camera looking down -z from the
// origin (x in -2..2) and five far to the side (x 1000..1004).
InstancedMesh _batch({required bool cullInstances}) {
  final mesh = InstancedMesh(
    geometry: CuboidGeometry(Vector3.all(0.5)),
    material: UnlitMaterial(),
    cullInstances: cullInstances,
  );
  for (var i = 0; i < 5; i++) {
    mesh.addInstance(Matrix4.translation(Vector3(i - 2.0, 0, -6)));
  }
  for (var i = 0; i < 5; i++) {
    mesh.addInstance(Matrix4.translation(Vector3(1000.0 + i, 0, -6)));
  }
  return mesh;
}

int _render(InstancedMesh mesh) {
  final scene = Scene()
    ..add(Node()..addComponent(InstancedMeshComponent(mesh)));
  final probe = _MaskProbe();
  scene.addRenderPass(probe);
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
  recorder.endRecording().dispose();
  scene.dispose();
  return probe.instances;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final noGpu = gpuAvailable()
      ? null
      : 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.';

  setUpAll(() async {
    if (noGpu == null) await Scene.initializeStaticResources();
  });

  test('a culling batch draws only the instances in view', () {
    expect(_render(_batch(cullInstances: true)), 5);
  }, skip: noGpu);

  test('a batch that does not cull draws every instance, as the color '
      'pass does', () {
    expect(_render(_batch(cullInstances: false)), 10);
  }, skip: noGpu);

  test('the mesh draw selector cuts the instances', () {
    final mesh = _batch(cullInstances: false)
      ..drawSelector = (context) => context.pass == MeshDrawPass.color
          ? const MeshDrawSelection(instanceCount: 3)
          : MeshDrawSelection.all;
    expect(_render(mesh), 3);
  }, skip: noGpu);

  test('culling and the selector combine', () {
    // The first three instances (all in view) under the selector.
    final mesh = _batch(cullInstances: true)
      ..drawSelector = (_) => const MeshDrawSelection(instanceCount: 3);
    expect(_render(mesh), 3);
  }, skip: noGpu);
}
