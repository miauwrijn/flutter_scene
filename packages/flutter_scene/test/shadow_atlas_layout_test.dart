import 'dart:typed_data';

import 'package:flutter_scene/src/render/custom_render_pass.dart';
import 'package:flutter_scene/src/render/shadow_pass.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  test('lamp tiles wrap under the cascades instead of widening the atlas', () {
    // The reported crash: 4 cascades + 6 lamp tiles at 2048 asked for a
    // 20480 x 2048 texture, past the 16384 limit.
    const layout = ShadowAtlasLayout(10, 2048);
    expect(layout.width, 8192);
    expect(layout.height, 3 * 2048);
    expect([for (var i = 0; i < 4; i++) layout.y(i)], everyElement(0));
    expect((layout.x(4), layout.y(4)), (0, 2048));
    expect((layout.x(9), layout.y(9)), (2048, 4096));
  });

  test('the lamp budget fits every GPU', () {
    // 4 cascades + 4 spots + 4 point lights at 2 tiles each.
    const layout = ShadowAtlasLayout(16, 2048);
    expect(layout.width, lessThanOrEqualTo(8192));
    expect(layout.height, lessThanOrEqualTo(8192));
  });

  test('a lone tile is one tile', () {
    const layout = ShadowAtlasLayout(1, 1024);
    expect((layout.width, layout.height), (1024, 1024));
  });

  test('the post passes get the tile count', () {
    final info = packPostShadowInfo(
      const [],
      Vector3(0, -1, 0),
      Vector3(1, 1, 1),
      totalTiles: 10,
    );
    expect(info.getFloat32(75 * 4, Endian.little), 10);
  });
}
