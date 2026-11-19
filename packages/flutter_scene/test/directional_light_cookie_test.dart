// Covers DirectionalLight.cookie: the projection an app renders a matching
// cookie with, the uniforms it packs, and on a GPU that the cookie darkens
// exactly the part of a sun-lit floor its black half covers, moves with its
// offset, and tiles or clamps as asked.
@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
// ignore: implementation_imports
import 'package:flutter_scene/src/light.dart' show hasShadowCookieTile;
// ignore: implementation_imports
import 'package:flutter_scene/src/render/custom_render_pass.dart'
    show packPostShadowInfo;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

const int _size = 64;

// A 64 x 64 cookie, black where u < 0.5 (or, with [alongV], v < 0.5: the
// first 32 rows) and white elsewhere.
gpu.Texture _halfBlackCookie({bool alongV = false}) {
  const n = 64;
  final texture = gpu.gpuContext.createTexture(
    gpu.StorageMode.hostVisible,
    n,
    n,
  );
  final texels = Uint8List(n * n * 4);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final v = (alongV ? y : x) < n ~/ 2 ? 0 : 255;
      final i = (y * n + x) * 4;
      texels
        ..[i] = v
        ..[i + 1] = v
        ..[i + 2] = v
        ..[i + 3] = 255;
    }
  }
  texture.overwrite(ByteData.sublistView(texels));
  return texture;
}

// The red channel at world x = -1 and x = +1 (z = 0) of a top-down view of a
// white floor lit straight down by [light], or with [alongZ] at z = -1 and
// z = +1 (x = 0).
Future<(int, int)> _floor(DirectionalLight light, {bool alongZ = false}) async {
  final scene = Scene()
    ..environment = EnvironmentMap.empty()
    ..directionalLight = light
    ..add(
      Node(
        mesh: Mesh(
          PlaneGeometry(width: 8, depth: 8),
          PhysicallyBasedMaterial()
            ..baseColorFactor = Vector4(1, 1, 1, 1)
            ..roughnessFactor = 1.0
            ..metallicFactor = 0.0,
        ),
      ),
    );
  final camera = OrthographicCamera(
    position: Vector3(0, 5, 0),
    target: Vector3.zero(),
    up: Vector3(0, 0, -1),
    projection: OrthographicProjection(
      size: OrthographicSize.contain(4, 4),
      far: 10,
    ),
  );
  final recorder = ui.PictureRecorder();
  scene.render(
    camera,
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, _size + 0.0, _size + 0.0),
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(_size, _size);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  scene.dispose();
  // The view spans x in [-2, 2]; x = -1 and +1 sit a quarter in from each
  // edge. Which screen side is world -x is the camera's business, so the
  // two are returned by world side.
  int at(int column, int row) => bytes.getUint8((row * _size + column) * 4);
  if (alongZ) {
    // Screen up is the camera's up; image row 0 is the top.
    final zUp = Vector3(0, 0, 1).dot(camera.up) > 0;
    final top = at(_size ~/ 2, _size ~/ 4);
    final bottom = at(_size ~/ 2, 3 * _size ~/ 4);
    return zUp ? (bottom, top) : (top, bottom);
  }
  final screenX = Vector3(1, 0, 0).dot(_screenRight(camera)) > 0;
  final left = at(_size ~/ 4, _size ~/ 2);
  final right = at(3 * _size ~/ 4, _size ~/ 2);
  return screenX ? (left, right) : (right, left);
}

// The world direction that points to screen right for [camera]: `up x
// forward` in the engine's camera convention.
Vector3 _screenRight(OrthographicCamera camera) {
  final forward = (camera.target - camera.position)..normalize();
  return camera.up.cross(forward)..normalize();
}

DirectionalLight _sun({gpu.Texture? cookie}) => DirectionalLight(
  direction: Vector3(0, -1, 0),
  intensity: 3.0,
  castsShadow: true,
  cookie: cookie,
  cookieSize: Vector2(4, 4),
  cookieOffset: Vector2(2, 2),
  cookieRepeat: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('projection', () {
    test('a light straight down maps world x and z to u and v', () {
      final light = DirectionalLight(
        cookieSize: Vector2(4, 8),
        cookieOffset: Vector2(1, 2),
      );
      final uv = light.cookieUv(Vector3(3, 7, -2), Vector3(0, -1, 0));
      expect(uv.x, closeTo((3 + 1) / 4, 1e-6));
      expect(uv.y, closeTo((-2 + 2) / 8, 1e-6));
    });

    test('the basis is orthonormal and stable as the light tilts', () {
      final light = DirectionalLight(
        cookieSize: Vector2(1, 1),
        cookieOffset: Vector2.zero(),
      );
      // Moving along the light's own direction never changes the coordinate:
      // the projection is along the light.
      for (final dir in [
        Vector3(0, -1, 0),
        Vector3(0.3, -1, 0.2),
        Vector3(-0.7, -0.5, 0.1),
      ]) {
        final p = Vector3(1.5, 0.25, -3);
        final a = light.cookieUv(p, dir);
        final b = light.cookieUv(p + dir.normalized() * 10, dir);
        expect(a.x, closeTo(b.x, 1e-5));
        expect(a.y, closeTo(b.y, 1e-5));
      }
      // A slight tilt from straight down keeps u along +x (no basis flip).
      final tilted = light.cookieUv(Vector3(1, 0, 0), Vector3(0.01, -1, 0.01));
      expect(tilted.x, greaterThan(0.99));
    });
  });

  group('packing', () {
    test('the tile exists only with a cookie and cascades', () {
      final light = DirectionalLight();
      expect(hasShadowCookieTile(light, hasCascades: true), isFalse);
      expect(hasShadowCookieTile(null, hasCascades: true), isFalse);
    });

    test('PostShadowInfo carries the tile count and an absent cookie', () {
      final info = Float32List.sublistView(
        packPostShadowInfo(
          const [],
          Vector3(0, -1, 0),
          Vector3(1, 1, 1),
          totalTiles: 7,
        ),
      );
      expect(info.length, 84);
      expect(info[75], 7);
      expect(info.sublist(76), everyElement(0));
    });
  });

  final noGpu = gpuAvailable()
      ? null
      : 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.';

  group('renders', () {
    setUpAll(() async {
      if (noGpu == null) await Scene.initializeStaticResources();
    });

    test('the tile exists with a cookie on a shadow-casting light', () {
      final light = _sun(cookie: _halfBlackCookie());
      expect(hasShadowCookieTile(light, hasCascades: true), isTrue);
      expect(hasShadowCookieTile(light, hasCascades: false), isFalse);
    }, skip: noGpu);

    test('a half-black cookie darkens exactly the covered side', () async {
      final (plainMinus, plainPlus) = await _floor(_sun());
      expect(plainMinus, greaterThan(150));
      expect(plainPlus, closeTo(plainMinus, 6));

      // uv.u = (x + 2) / 4: the black half covers x < 0.
      final (minus, plus) = await _floor(_sun(cookie: _halfBlackCookie()));
      expect(minus, lessThan(plainMinus ~/ 4));
      expect(plus, closeTo(plainPlus, 6));
    }, skip: noGpu);

    test('v follows the texture rows: row 0 is v = 0', () async {
      final (plainMinus, plainPlus) = await _floor(_sun(), alongZ: true);
      // uv.v = (z + 2) / 4: the black first rows cover z < 0.
      final (minus, plus) = await _floor(
        _sun(cookie: _halfBlackCookie(alongV: true)),
        alongZ: true,
      );
      expect(minus, lessThan(plainMinus ~/ 4));
      expect(plus, closeTo(plainPlus, 6));
    }, skip: noGpu);

    test(
      'the offset moves it; without repeat the rest is unaffected',
      () async {
        final (plainMinus, plainPlus) = await _floor(_sun());
        // uv.u = (x + 4) / 4: x in [-2, 0] reads the white half and x > 0
        // falls outside the cookie, which clamping leaves lit.
        final light = _sun(cookie: _halfBlackCookie())
          ..cookieOffset = Vector2(4, 2);
        final (minus, plus) = await _floor(light);
        expect(minus, closeTo(plainMinus, 6));
        expect(plus, closeTo(plainPlus, 6));
      },
      skip: noGpu,
    );

    test('with repeat the cookie tiles past its size', () async {
      final (plainMinus, _) = await _floor(_sun());
      // The same offset, tiled: x in (0, 2] wraps to u in (0, 0.5], black.
      final light = _sun(cookie: _halfBlackCookie())
        ..cookieOffset = Vector2(4, 2)
        ..cookieRepeat = true;
      final (minus, plus) = await _floor(light);
      expect(minus, closeTo(plainMinus, 6));
      expect(plus, lessThan(plainMinus ~/ 4));
    }, skip: noGpu);

    test('strength 0 leaves the light unaffected', () async {
      final (plainMinus, _) = await _floor(_sun());
      final light = _sun(cookie: _halfBlackCookie())..cookieStrength = 0;
      final (minus, _) = await _floor(light);
      expect(minus, closeTo(plainMinus, 6));
    }, skip: noGpu);
  });
}
