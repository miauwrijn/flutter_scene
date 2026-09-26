// The depth row a material writing its own gl_FragDepth is handed: it has to
// reproduce the clip-space divide the vertex stage already performed, or the
// relief it writes sits at a depth nothing else in the scene agrees with.
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  test('window depth from the projection row matches the clip divide', () {
    final projection = PerspectiveProjection(
      fovRadiansY: 50 * degrees2Radians,
      near: 0.1,
      far: 900.0,
    );
    final m = projection.getProjectionMatrix(16 / 9);
    // What `ScenePass` publishes as FragInfo.depth_projection.
    final row = Vector4(
      m.entry(2, 2),
      m.entry(2, 3),
      m.entry(3, 2),
      m.entry(3, 3),
    );
    for (final viewZ in [0.2, 1.0, 5.0, 42.0, 400.0, 899.0]) {
      // The vertex stage's own answer: a view-space point at planar depth
      // viewZ (the engine's view space looks down +Z), divided through.
      final clip = m.transform(Vector4(0, 0, viewZ, 1));
      final expected = clip.z / clip.w;
      // WindowDepthAlongView's answer, in Dart.
      final actual = (row.x * viewZ + row.y) / (row.z * viewZ + row.w);
      expect(actual, closeTo(expected, 1e-6), reason: 'at view depth $viewZ');
    }
  });

  test('the row maps the near and far planes to the depth range', () {
    final projection = PerspectiveProjection(near: 0.25, far: 500);
    final m = projection.getProjectionMatrix(1.5);
    double depth(double z) =>
        (m.entry(2, 2) * z + m.entry(2, 3)) /
        (m.entry(3, 2) * z + m.entry(3, 3));
    expect(depth(0.25), closeTo(0.0, 1e-6));
    expect(depth(500), closeTo(1.0, 1e-6));
    // And it is monotonic: further is deeper, which is the whole contract.
    expect(depth(10), greaterThan(depth(5)));
  });
}
