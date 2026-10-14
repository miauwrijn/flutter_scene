// Compact roughness-filtered scene-color atlas.
uniform sampler2D scene_filtered_color;

float TransmissionWeight0(float x) {
  return (x * (x * (-x + 3.0) - 3.0) + 1.0) / 6.0;
}

float TransmissionWeight1(float x) {
  return (x * x * (3.0 * x - 6.0) + 4.0) / 6.0;
}

float TransmissionWeight2(float x) {
  return (x * (-3.0 * x * x + 3.0 * x + 3.0) + 1.0) / 6.0;
}

float TransmissionWeight3(float x) { return x * x * x / 6.0; }

vec3 SampleTransmissionBand(highp vec2 uv, float level, highp vec2 scene_size,
                            highp vec2 atlas_size) {
  highp vec2 band_size = max(floor(scene_size / exp2(level)), vec2(1.0));
  highp float offset_x = scene_size.x - ceil(scene_size.x / exp2(level - 1.0));
  highp vec2 coord = uv * band_size + 0.5;
  highp vec2 base = floor(coord);
  highp vec2 f = fract(coord);
  vec2 g0 = vec2(TransmissionWeight0(f.x) + TransmissionWeight1(f.x),
                 TransmissionWeight0(f.y) + TransmissionWeight1(f.y));
  vec2 g1 = vec2(TransmissionWeight2(f.x) + TransmissionWeight3(f.x),
                 TransmissionWeight2(f.y) + TransmissionWeight3(f.y));
  highp vec2 h0 = -vec2(1.0) +
            vec2(TransmissionWeight1(f.x), TransmissionWeight1(f.y)) / g0;
  highp vec2 h1 = vec2(1.0) +
            vec2(TransmissionWeight3(f.x), TransmissionWeight3(f.y)) / g1;
  highp vec2 origin = vec2(offset_x, 0.0);
  highp vec2 minimum = origin + vec2(0.5);
  highp vec2 maximum = origin + band_size - vec2(0.5);
  highp vec2 p0 = clamp(origin + base + vec2(h0.x, h0.y) - 0.5,
                  minimum, maximum) / atlas_size;
  highp vec2 p1 = clamp(origin + base + vec2(h1.x, h0.y) - 0.5,
                  minimum, maximum) / atlas_size;
  highp vec2 p2 = clamp(origin + base + vec2(h0.x, h1.y) - 0.5,
                  minimum, maximum) / atlas_size;
  highp vec2 p3 = clamp(origin + base + vec2(h1.x, h1.y) - 0.5,
                  minimum, maximum) / atlas_size;
  // Level-0 reads: the bands are laid out by hand in one single-level
  // texture, so this is what texture() returns -- and an implicit-derivative
  // read inside the band loop is one fxc (ANGLE on Windows) unrolls again.
  return g0.y * (g0.x * textureLod(scene_filtered_color, p0, 0.0).rgb +
                 g1.x * textureLod(scene_filtered_color, p1, 0.0).rgb) +
         g1.y * (g0.x * textureLod(scene_filtered_color, p2, 0.0).rgb +
                 g1.x * textureLod(scene_filtered_color, p3, 0.0).rgb);
}

// Samples the accumulated scene color with perceptual roughness and
// IOR-dependent blur.
vec3 GetSceneColorFiltered(highp vec2 uv_offset, float roughness, float ior) {
  if (frag_info.scene_inputs.x < 0.5) return vec3(0.0);
  highp vec2 uv = clamp(GetScreenUv() + uv_offset, vec2(0.001), vec2(0.999));
  vec3 sharp = texture(scene_opaque_color, uv).rgb;
  float bands = frag_info.transmission_info.y;
  if (frag_info.transmission_info.x < 0.5 || bands < 1.0) return sharp;
  float adjusted = roughness * clamp(ior * 2.0 - 2.0, 0.0, 1.0);
  highp vec2 scene_size = 1.0 / max(frag_info.ssao_params.zw, vec2(1e-6));
  highp float lod = clamp(log2(max(scene_size.x, scene_size.y)) * adjusted,
                    0.0, bands);
  if (lod <= 0.0) return sharp;
  highp vec2 atlas_size = 1.0 / frag_info.transmission_info.zw;
  highp float lo = max(floor(lod), 1.0);
  highp float hi = min(lo + 1.0, bands);
  // The two bands the level falls between, through ONE SampleTransmissionBand
  // call: each is four bicubic taps, and fxc (ANGLE on Windows) inlines every
  // call site -- with a dispersive material calling this once per channel,
  // that was six copies. Always two here, but not a count fxc can fold.
  vec3 lo_color = vec3(0.0);
  vec3 hi_color = vec3(0.0);
  int band_taps = bands >= 1.0 ? 2 : 0;
  for (int b = 0; b < band_taps; b++) {
    vec3 band = SampleTransmissionBand(uv, b == 0 ? lo : hi, scene_size,
                                       atlas_size);
    if (b == 0) {
      lo_color = band;
    } else {
      hi_color = band;
    }
  }
  vec3 filtered = mix(lo_color, hi_color, fract(lod));
  return mix(sharp, filtered, min(lod, 1.0));
}
