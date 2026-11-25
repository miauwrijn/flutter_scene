import 'package:flutter_scene/src/fmat/fmat_ast.dart';
import 'package:flutter_scene/src/fmat/fmat_emitter.dart';
import 'package:flutter_scene/src/fmat/fmat_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _cutout = '''
material {
  name: "Leaf",
  shading_model: lit,
  blending: opaque,
  cutout: true,
}
fragment {
  void Surface(inout MaterialInputs material) {
    if (GetUV0().x > 0.5) {
      discard;
    }
    material.base_color = vec4(1.0);
  }
}
''';

void main() {
  test('a cutout ships a coverage fragment that keeps its discard', () {
    final m = parseFmat(_cutout, fileName: 'leaf.fmat');
    expect(materialHasCoverageSurface(m), isTrue);
    expect(depthSurfaceKindsOf(m), contains(DepthSurfaceKind.coverage));
    final coverage = emitFragmentGlsl(
      m,
      depthSurface: DepthSurfaceKind.coverage,
    );
    expect(coverage, contains('discard;'));
  });

  test("a cutout's lit fragment has no discard (the pre-draw cut it)", () {
    final m = parseFmat(_cutout, fileName: 'leaf.fmat');
    expect(RegExp(r'\bdiscard\s*;').hasMatch(emitFragmentGlsl(m)), isFalse);
  });

  test('a shadow_cutout material ships its shadow fragment only', () {
    final m = parseFmat(
      _cutout.replaceFirst('  cutout: true,', '  shadow_cutout: true,'),
      fileName: 'leaf.fmat',
    );
    expect(depthSurfaceKindsOf(m).toList(), [DepthSurfaceKind.shadow]);
    expect(
      emitFragmentGlsl(m, depthSurface: DepthSurfaceKind.shadow),
      contains('discard;'),
    );
    // Its lit fragment keeps its discards (no coverage pre-draw).
    expect(emitFragmentGlsl(m), contains('discard;'));
  });

  test('a material without cutout keeps its discards and no coverage', () {
    final m = parseFmat(
      _cutout.replaceFirst('  cutout: true,\n', ''),
      fileName: 'leaf.fmat',
    );
    expect(materialHasCoverageSurface(m), isFalse);
    expect(emitFragmentGlsl(m), contains('discard;'));
  });
}
