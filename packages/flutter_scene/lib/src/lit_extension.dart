import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

/// The per-frame inputs of the application's lit extension: shader code of
/// the application's own that runs inside every lit material (see
/// `shaders/flutter_scene_lit_extension.glsl` for how to supply
/// it and what it may hook).
///
/// The engine gives none of this a meaning. It carries [params] to
/// `frag_info.ext_params` and [texture] to the `ext_texture` sampler, and
/// draws the full lit tier while [active] is set, since the lean lit entries
/// compile the extension's hooks out.
///
/// {@category Materials}
class LitExtension {
  /// The number of floats in [params]: nine vec4s.
  static const int paramCount = 36;

  /// Whether the extension has anything to do this frame. False (the
  /// default) packs [params] as zeros, whatever they hold, and leaves the
  /// lit tier to the frame's other features.
  bool active = false;

  /// What `frag_info.ext_params[0..8]` reads while [active], four floats a
  /// vec4.
  final Float32List params = Float32List(paramCount);

  /// What the `ext_texture` sampler reads; a white placeholder when null.
  gpu.Texture? texture;

  /// How [texture] is sampled. Nearest and clamped by default, which is what
  /// packed data wants.
  gpu.SamplerOptions sampler = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.nearest,
    magFilter: gpu.MinMagFilter.nearest,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );
}
