// Covers RenderPassContext.drawObjects(content:): the albedo mask carries a
// material's textured base color, the normal mask its normal-mapped normal,
// a cut-out is cut out of both, and a `mask_surface: true` .fmat fills the
// albedo and normal masks with its own Surface().
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu_shaders/environment.dart';
import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat_bytes_library.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/runtime_compile.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/frame_transients.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

const int _size = 32;

// Draws the scene's objects as a [content] mask and copies it into an 8-bit
// texture for readback.
class _MaskProbe extends CustomRenderPass {
  _MaskProbe(this.content);

  final MaskContent content;
  gpu.Texture? copy;

  @override
  String get name => 'mask_probe';

  @override
  RenderStage get stage => RenderStage.afterScene;

  static final gpu.Shader _vertex = baseShaderLibrary['FullscreenVertex']!;
  static final gpu.Shader _copyFragment = baseShaderLibrary['CopyFragment']!;

  @override
  void execute(RenderPassContext context) {
    final mask = context.drawObjects(content: content);
    final target = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      mask.width,
      mask.height,
      format: gpu.PixelFormat.r8g8b8a8UNormInt,
      enableRenderTargetUsage: true,
      enableShaderReadUsage: true,
    );
    final quad = gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList(<double>[
          -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, //
          -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, //
        ]),
      ),
    );
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final renderPass = commandBuffer.createRenderPass(
      gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: target)),
    );
    renderPass.bindPipeline(resolvePipeline(_vertex, _copyFragment));
    renderPass.setDepthWriteEnable(false);
    renderPass.setDepthCompareOperation(gpu.CompareFunction.always);
    renderPass.setColorBlendEnable(false);
    renderPass.setCullMode(gpu.CullMode.none);
    bindVertexBufferCompat(
      renderPass,
      gpu.BufferView(quad, offsetInBytes: 0, lengthInBytes: 6 * 2 * 4),
      6,
    );
    renderPass.bindTexture(
      _copyFragment.getUniformSlot('source_texture'),
      mask,
      sampler: gpu.SamplerOptions(
        minFilter: gpu.MinMagFilter.nearest,
        magFilter: gpu.MinMagFilter.nearest,
      ),
    );
    drawCompat(renderPass, 6);
    rendererSubmissions.submit(commandBuffer);
    copy = target;
  }
}

// A 1x1 RGBA8 texture of [rgba].
gpu.Texture _texel(List<int> rgba) {
  final texture = gpu.gpuContext.createTexture(
    gpu.StorageMode.hostVisible,
    1,
    1,
  );
  texture.overwrite(ByteData.sublistView(Uint8List.fromList(rgba)));
  return texture;
}

// The centre RGBA of the [content] mask of [material] on a card filling the
// view, facing the camera.
Future<List<int>> _centre(Material material, MaskContent content) async {
  final scene = Scene()
    ..add(
      Node(mesh: Mesh(CuboidGeometry(Vector3(4, 4, 0.01)), material))
        ..position = Vector3(0, 0, -1),
    );
  final probe = _MaskProbe(content);
  scene.addRenderPass(probe);
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(
      position: Vector3.zero(),
      target: Vector3(0, 0, -1),
      up: Vector3(0, 1, 0),
    ),
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, _size + 0.0, _size + 0.0),
    pixelRatio: 1.0,
  );
  recorder.endRecording().dispose();
  final bytes = (await probe.copy!.asImage().toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!;
  scene.dispose();
  final i = ((_size ~/ 2) * _size + _size ~/ 2) * 4;
  return [for (var c = 0; c < 4; c++) bytes.getUint8(i + c)];
}

// Tilts its normal to +X in Surface(), which no geometry or normal map of
// the card would give: the normal mask must show it.
const _ownNormal = '''
material {
  name: "OwnNormal",
  shading_model: lit,
  mask_surface: true,
}

fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = vec4(1.0);
#ifdef FLUTTER_SCENE_MASK_SURFACE_NORMAL
    material.normal = vec3(1.0, 0.0, 0.0);
#endif
  }
}
''';

const _ownAlbedo = '''
material {
  name: "OwnAlbedo",
  shading_model: unlit,
  mask_surface: true,
}

fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = vec4(0.0, 1.0, 0.0, 1.0);
    PrepareMaterial(material);
  }
}
''';

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  Uri? impellerc;
  try {
    impellerc = await findImpellerC();
  } catch (_) {
    impellerc = null;
  }
  final noGpu = gpuAvailable()
      ? null
      : 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.';

  setUpAll(() async {
    if (noGpu == null) await Scene.initializeStaticResources();
  });

  test('the albedo mask carries the base color texture', () async {
    final textured = PhysicallyBasedMaterial()
      ..baseColorTexture = GpuTextureSource(_texel([255, 0, 0, 255]));
    final [r, g, b, a] = await _centre(textured, MaskContent.albedo);
    expect(r, greaterThan(240));
    expect(g, lessThan(16));
    expect(b, lessThan(16));
    expect(a, greaterThan(240));
    // A flat mask of the same material is the plain per-item white.
    final [fr, fg, fb, _] = await _centre(textured, MaskContent.flat);
    expect([fr, fg, fb], everyElement(greaterThan(240)));
  }, skip: noGpu);

  test('the albedo mask multiplies the base color factor', () async {
    final tinted = PhysicallyBasedMaterial()
      ..baseColorFactor = Vector4(0, 0, 1, 1);
    final [r, g, b, _] = await _centre(tinted, MaskContent.albedo);
    expect(r, lessThan(16));
    expect(g, lessThan(16));
    expect(b, greaterThan(240));
  }, skip: noGpu);

  test('the normal mask follows the normal map', () async {
    final flat = await _centre(PhysicallyBasedMaterial(), MaskContent.normal);
    // A tangent-space normal tilted hard along +X.
    final mapped = await _centre(
      PhysicallyBasedMaterial()
        ..normalTexture = GpuTextureSource(_texel([255, 128, 30, 255])),
      MaskContent.normal,
    );
    // The card faces the camera: the geometric normal encodes to about
    // (0.5, 0.5, 1.0) in whichever world axis points at the eye.
    final flatDelta = [for (var c = 0; c < 3; c++) (flat[c] - 128).abs()];
    expect(flatDelta.where((d) => d > 100).length, 1);
    var difference = 0;
    for (var c = 0; c < 3; c++) {
      difference += (mapped[c] - flat[c]).abs();
    }
    expect(difference, greaterThan(60));
  }, skip: noGpu);

  test('a cut-out is cut out of the surface masks', () async {
    PhysicallyBasedMaterial cutOut(int alpha) => PhysicallyBasedMaterial()
      ..alphaMode = AlphaMode.mask
      ..alphaCutoff = 0.5
      ..baseColorTexture = GpuTextureSource(_texel([255, 255, 255, alpha]));
    for (final content in [MaskContent.albedo, MaskContent.normal]) {
      final covered = await _centre(cutOut(255), content);
      final uncovered = await _centre(cutOut(40), content);
      expect(covered[3], greaterThan(240), reason: '$content covered');
      expect(uncovered[3], lessThan(16), reason: '$content uncovered');
    }
  }, skip: noGpu);

  test('a mask_surface .fmat fills the albedo mask by its Surface()', () async {
    final cacheDir = Directory.systemTemp.createTempSync('mask_content_');
    try {
      final compiled = await FmatRuntimeCompiler(
        impellerc: impellerc!,
        includeDirectories: [Directory('shaders').absolute.uri],
        cacheDirectory: cacheDir,
      ).compile(_ownAlbedo, fileName: 'own_albedo.fmat');
      final library = await FmatBytesLibrary.load(
        compiled.shaderBundle,
        compiled.sidecar,
      );
      final material = library.createMaterial(compiled.entryName);
      final [r, g, b, _] = await _centre(material, MaskContent.albedo);
      expect(r, lessThan(16));
      expect(g, greaterThan(240));
      expect(b, lessThan(16));
    } finally {
      cacheDir.deleteSync(recursive: true);
    }
  }, skip: noGpu ?? (impellerc == null ? 'impellerc not found' : null));

  test('a mask_surface .fmat fills the normal mask by its Surface()', () async {
    final cacheDir = Directory.systemTemp.createTempSync('mask_content_');
    try {
      final compiled = await FmatRuntimeCompiler(
        impellerc: impellerc!,
        includeDirectories: [Directory('shaders').absolute.uri],
        cacheDirectory: cacheDir,
      ).compile(_ownNormal, fileName: 'own_normal.fmat');
      final library = await FmatBytesLibrary.load(
        compiled.shaderBundle,
        compiled.sidecar,
      );
      final material = library.createMaterial(compiled.entryName);
      // +X encodes to (255, 128, 128); the card's geometric normal faces the
      // camera along Z instead.
      final [r, g, b, a] = await _centre(material, MaskContent.normal);
      expect(r, greaterThan(240));
      expect((g - 128).abs(), lessThan(8));
      expect((b - 128).abs(), lessThan(8));
      expect(a, greaterThan(240));
    } finally {
      cacheDir.deleteSync(recursive: true);
    }
  }, skip: noGpu ?? (impellerc == null ? 'impellerc not found' : null));
}
