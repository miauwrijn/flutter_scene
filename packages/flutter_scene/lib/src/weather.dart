import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

/// Weather on every lit surface of a [Scene]: a procedural cloud deck that
/// shadows the directional light, and surfaces made wet (darker, glossier,
/// with puddles and rain rings) and snowed on where they are open to the
/// sky. See `shaders/weather.glsl`.
///
/// Off by default ([enabled]); with every amount at zero it costs a uniform
/// branch per fragment. A material opts out with `Material.receivesWeather`
/// (water, glass).
class SceneWeather {
  /// Whether any of this is applied.
  bool enabled = false;

  // --- The cloud deck ---------------------------------------------------------

  /// How much of the directional light a solid cloud stops, 0..1. Zero turns
  /// the cloud shadows off.
  double cloudShadowStrength = 0;

  /// How much of the sky is cloud, 0..1.
  double cloudCover = 0;

  /// The clouds' seed.
  double cloudSeed = 0;

  /// The world's up axis. Unit length.
  final Vector3 up = Vector3(0, 1, 0);

  /// The deck's height along [up], world units.
  double cloudDeckHeight = 1500;

  /// The deck coordinates of a world point on the deck: `u = dot(p, xyz) +
  /// w`, `v` likewise. Scale, wind drift and any axis flip go in here; the
  /// shader's noise takes these as they are.
  final Vector4 cloudU = Vector4(1 / 1000, 0, 0, 0);
  final Vector4 cloudV = Vector4(0, 0, 1 / 1000, 0);

  // --- Surfaces ---------------------------------------------------------------

  /// How wet open surfaces are, 0..1.
  double wetness = 0;

  /// How much snow lies on open, up-facing surfaces, 0..1.
  double snowCover = 0;

  /// How hard it is raining, 0..1: the rings in the puddles, and how big
  /// the puddles grow.
  double rainfall = 0;

  /// The rain's slant: the horizontal offset, per unit of height fallen,
  /// from where a drop lands back toward where it came from (upwind) —
  /// `upwind * tan(slant)`. Zero is rain falling straight down. Lets the
  /// rain reach under an eave on the windward side.
  final Vector3 rainSlant = Vector3.zero();

  // --- What is overhead -------------------------------------------------------

  /// The sky-occlusion height map: per texel the top of whatever stands
  /// overhead, r*256+g a 16-bit height over [occlusionMinHeight] ..
  /// + [occlusionHeightSpan], b 1 where something stands. Null treats
  /// everything as open to the sky. Sampled nearest.
  gpu.Texture? occlusionMap;

  /// Map coordinates of a world point: `s = dot(p, xyz) + w`, `t` likewise,
  /// 0..1 across the map.
  final Vector4 occlusionS = Vector4.zero();
  final Vector4 occlusionT = Vector4.zero();
  double occlusionMinHeight = 0;
  double occlusionHeightSpan = 1;

  /// How far under the stored top a surface may be and still count as open
  /// (the roof's own upper face).
  double occlusionClearance = 0.05;

  /// Whether anything reaches a fragment at all.
  bool get active =>
      enabled &&
      (cloudShadowStrength > 0 || wetness > 0 || snowCover > 0);
}
