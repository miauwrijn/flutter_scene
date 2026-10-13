// Weather on lit surfaces: a procedural cloud deck that shadows the
// directional light, and surfaces made wet (darker, glossier, puddled, rain
// rings in the puddles) and snowed on where they are open to the sky. Driven
// by SceneWeather through the weather_* fields of FragInfo and the
// weather_occlusion sampler; every field zero is a clear, dry day and costs a
// uniform branch.
//
// The cloud deck is the same function the application draws its sky with:
// the block between BEGIN and END CloudDensity is a copy, kept in step with
// the application's own (Spatium checks the two against each other).
//
// Requires, declared before this file is included: FragInfo (`frag_info`),
// the `weather_occlusion` sampler, MaterialInputs and GetWorldNormal().

// BEGIN CloudDensity
float CloudHash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float CloudNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = CloudHash(i);
  float b = CloudHash(i + vec2(1.0, 0.0));
  float c = CloudHash(i + vec2(0.0, 1.0));
  float d = CloudHash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float CloudFbm(vec2 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 5; i++) {
    sum += CloudNoise(p) * amp;
    p = mat2(1.6, 1.2, -1.2, 1.6) * p + vec2(3.1, 1.7);
    amp *= 0.5;
  }
  return sum / 0.96875;
}

// Density of the cloud deck at `xy`, 0 clear sky .. 1 solid cloud.
float CloudDensity(vec2 xy, vec2 drift, float cover, float scale, float seed) {
  vec2 p = (xy - drift) / max(scale, 1.0) + vec2(seed * 17.13, seed * 7.31);
  float n = CloudFbm(p);
  float edge = 1.0 - clamp(cover, 0.0, 1.0);
  return smoothstep(edge - 0.06, edge + 0.22, n) *
         step(0.001, cover);
}

// Where a ray from `origin` (model space) toward the light `toLight` (unit,
// up is +Z) crosses the deck at `deckHeight`; `origin.xy` when it cannot.
vec2 CloudDeckPoint(vec3 origin, vec3 toLight, float deckHeight) {
  if (toLight.z <= 0.02) return origin.xy;
  return origin.xy + toLight.xy * ((deckHeight - origin.z) / toLight.z);
}
// END CloudDensity

// The top of whatever stands over [p] (nearest texel: the channels are packed
// data), or -1e9 where nothing does.
float WeatherTopAt(vec3 p) {
  vec2 st = vec2(dot(p, frag_info.weather_occ_s.xyz) + frag_info.weather_occ_s.w,
                 dot(p, frag_info.weather_occ_t.xyz) + frag_info.weather_occ_t.w);
  if (st.x < 0.0 || st.y < 0.0 || st.x > 1.0 || st.y > 1.0) return -1e9;
  vec4 e = texture(weather_occlusion, st);
  if (e.b < 0.5) return -1e9;
  return frag_info.weather_occ_range.x +
      (floor(e.r * 255.0 + 0.5) * 256.0 + floor(e.g * 255.0 + 0.5)) / 65535.0 *
          frag_info.weather_occ_range.y;
}

// How open [p] is to the falling rain and snow, 0 under a roof .. 1 open.
//
// The drop is followed back up its slanted path (weather_rain: wind pushes
// the rain in under a windward eave), then the cover is tested at five
// points around there, jittered by noise, so the wet/dry edge is soft and
// ragged rather than a staircase along the map's cells. [ax]/[ay] are two
// horizontal axes, [plane] the point in them.
float WeatherSkyOpen(vec3 p, vec3 ax, vec3 ay, vec2 plane) {
  if (frag_info.weather_occ_range.z < 0.5) return 1.0;
  vec3 up = frag_info.weather_cloud_up.xyz;
  float h = dot(p, up);
  float top = WeatherTopAt(p);
  vec3 q = p;
  if (top > h) q += frag_info.weather_rain.xyz * (top - h);
  vec2 j = (vec2(CloudNoise(plane * 1.7), CloudNoise(plane * 1.7 + 9.1)) - 0.5) * 0.45;
  q += ax * j.x + ay * j.y;
  float open = 0.0;
  for (int k = 0; k < 5; k++) {
    vec2 o = k == 0 ? vec2(0.0)
        : vec2(k == 1 ? 1.0 : (k == 2 ? -1.0 : 0.0),
               k == 3 ? 1.0 : (k == 4 ? -1.0 : 0.0)) * 0.22;
    float t = WeatherTopAt(q + ax * o.x + ay * o.y);
    open += smoothstep(-0.06, 0.06, h - t + frag_info.weather_occ_range.w);
  }
  return open * 0.2;
}

// How much of the directional light the cloud deck lets through at [p].
float WeatherCloudShadow(vec3 p) {
  float strength = frag_info.weather_cloud_params.x;
  if (strength <= 0.0 || frag_info.has_directional_light < 0.5) return 1.0;
  vec3 up = frag_info.weather_cloud_up.xyz;
  vec3 l = -normalize(frag_info.directional_light_direction.xyz);
  float lu = dot(l, up);
  if (lu <= 0.02) return 1.0;
  vec3 deck = p + l * ((frag_info.weather_cloud_up.w - dot(p, up)) / lu);
  vec2 xy = vec2(dot(deck, frag_info.weather_cloud_u.xyz) + frag_info.weather_cloud_u.w,
                 dot(deck, frag_info.weather_cloud_v.xyz) + frag_info.weather_cloud_v.w);
  float d = CloudDensity(xy, vec2(0.0), frag_info.weather_cloud_params.y, 1.0,
                         frag_info.weather_cloud_params.z);
  return 1.0 - strength * d;
}

// Raindrops' rings on a wet, hard surface: the gradient of expanding
// ripples from drops landing on a jittered grid (one cell = [p] unit), each
// its own size and on its own clock, a crisp crest with a trough behind it,
// fading as it spreads. The same rings the clear water draws.
vec2 WeatherRipples(vec2 p, float t) {
  vec2 g = vec2(0.0);
  vec2 cell = floor(p);
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 c = cell + vec2(float(i), float(j));
      float h = CloudHash(c);
      float size = 0.55 + 0.45 * CloudHash(c + 5.3);
      vec2 centre = c + vec2(CloudHash(c + 3.1), CloudHash(c + 7.7));
      float age = fract(t * (0.7 + 0.5 * CloudHash(c + 1.9)) + h);
      vec2 d = p - centre;
      float r = length(d);
      float x = (r - age * size) * 30.0 / size;
      // One crest and its trough, not a comb of rings.
      float wave = -x * exp(-x * x * 0.5) * (1.0 - age) * (1.0 - age);
      g += d / max(r, 1e-3) * wave;
    }
  }
  return g;
}

// Gradient noise, -1..1-ish, quintic: round contours with no lattice in
// them — what puddle outlines are cut from.
vec2 WeatherGrad(vec2 c) {
  float a = CloudHash(c) * 6.2831853;
  return vec2(cos(a), sin(a));
}

float WeatherGradNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  float a = dot(WeatherGrad(i), f);
  float b = dot(WeatherGrad(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0));
  float c = dot(WeatherGrad(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0));
  float d = dot(WeatherGrad(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.4;
}

// Wets and snows [material] at world point [p] by the scene's weather.
void ApplyWeathering(inout MaterialInputs material, vec3 p) {
  vec4 w = frag_info.weather_surface;
  if (w.w < 0.5 || (w.x < 0.002 && w.y < 0.002)) return;
  vec3 up = frag_info.weather_cloud_up.xyz;
  vec3 ng = normalize(GetWorldNormal());
  float facing = dot(ng, up);
  // Two horizontal axes for the patterns, whatever the world's up is.
  vec3 ax = normalize(abs(up.x) < 0.9 ? cross(up, vec3(1.0, 0.0, 0.0))
                                      : cross(up, vec3(0.0, 0.0, 1.0)));
  vec3 ay = cross(up, ax);
  vec2 plane = vec2(dot(p, ax), dot(p, ay));
  float height = dot(p, up);
  // A wall is asked about the air just outside it, not its own footprint
  // (whose top is the wall itself): an exposed wall gets rain, one under a
  // deep eave stays dry.
  vec3 out_ = ng - up * facing;
  float side = length(out_);
  vec3 probe = side > 0.3 ? p + out_ / side * 0.4 : p;
  float open = WeatherSkyOpen(probe, ax, ay, plane);
  if (open <= 0.001) return;

  // --- Wet ---
  float wet = w.x * open;
  if (wet > 0.002) {
    // Up-facing surfaces soak through; walls wet in streaks running down.
    float streak = CloudNoise(vec2(dot(p, ax + ay) * 3.0, height * 0.35));
    float wall = mix(0.35, 0.8, streak);
    float amount = wet * mix(wall, 1.0, clamp(facing, 0.0, 1.0));
    // Damp: porous, rough dielectrics darken — clearly darker than dry,
    // since water fills the pores and stops the scattering — and gloss only
    // a little. Never a mirror: that is the puddles'.
    float porous = (1.0 - material.metallic) * smoothstep(0.25, 0.75, material.roughness);
    material.base_color.rgb *= 1.0 - amount * 0.6 * porous;
    material.roughness = mix(material.roughness, material.roughness * 0.75, amount);
    // Puddles, on the level only. The field is gradient noise (smooth,
    // round contours — value noise's lattice showed as square, stepped
    // outlines), domain-warped, deepened where the surface itself is low:
    // a joint or a hollow in the texture (its baked occlusion) pools first.
    // How far it fills goes with how hard it has rained: a drizzle leaves a
    // few small puddles, a downpour joins them.
    float level = smoothstep(0.965, 0.995, facing);
    // Hard: everything but the ground — a terrain passes its pooling field
    // and is soft (grass, beds, sand soak the drops up) outside its puddles.
    bool hard = material.pooling < 0.0;
    if (level > 0.0 && hard && w.z > 0.01) {
      // A thin film on flat paving and roofs: faint rings everywhere.
      vec2 g = WeatherRipples(plane * 2.5, GetTime()) * w.z * 0.06 * level * wet;
      material.normal = normalize(material.normal + ax * g.x + ay * g.y);
    }
    if (level > 0.0) {
      vec2 q = plane * 0.35;
      q += vec2(WeatherGradNoise(q * 0.5 + 3.1), WeatherGradNoise(q * 0.5 + 7.3)) * 0.8;
      float low = WeatherGradNoise(q) * 0.7 + WeatherGradNoise(q * 2.3 + 11.0) * 0.3;
      low += (1.0 - material.occlusion) * 0.1;
      // Where the surface says water gathers (a terrain's hollows and
      // slope feet), that decides it and the noise only breaks the outline;
      // where it sheds, nothing pools.
      if (material.pooling >= 0.0) {
        low = low * 0.25 + (material.pooling - 0.55) * 1.6;
      }
      float fill = wet * clamp(0.15 + 0.85 * w.z * 1.2, 0.0, 1.0);
      // The field is about ±0.6; a moderate rain fills its lowest tenth to
      // fifth, a downpour its lowest third.
      float edge = 0.78 - 0.6 * fill;
      float puddle = level * smoothstep(edge, edge + 0.07, low) *
                     smoothstep(0.05, 0.25, fill);
      // A soaked rim round each puddle, a few centimetres wide.
      float rim = level * smoothstep(edge - 0.12, edge, low) * wet;
      material.base_color.rgb *= 1.0 - 0.25 * rim * porous;
      if (puddle > 0.001) {
        vec3 n = mix(material.normal, ng, puddle);
        float rain = w.z;
        if (rain > 0.01) {
          vec2 g = WeatherRipples(plane * 2.5, GetTime()) * rain * 0.3 * puddle;
          n += ax * g.x + ay * g.y;
        }
        material.normal = normalize(n);
        // Water over the ground: a dark, still mirror — the sky and the
        // facade in it by Fresnel, the ground showing faintly through.
        material.roughness = mix(material.roughness, 0.03, puddle);
        material.base_color.rgb *= mix(1.0, 0.25, puddle);
        material.metallic *= 1.0 - puddle;
        material.occlusion = mix(material.occlusion, 1.0, puddle);
      }
    }
  }

  // --- Snow ---
  float snow = w.y * open;
  if (snow > 0.002) {
    float drift = CloudFbm(plane * 0.8 + 5.0);
    // Settles on what faces up, thinning up a slope, broken at its edge.
    float lie = smoothstep(0.3, 0.75, facing + (drift - 0.5) * 0.35);
    float cover = clamp(lie * smoothstep(0.0, 0.6, snow + (drift - 0.5) * 0.4) *
                            (0.6 + 0.4 * snow) * 1.4, 0.0, 1.0);
    material.base_color.rgb = mix(material.base_color.rgb, vec3(0.86, 0.89, 0.93), cover);
    material.roughness = mix(material.roughness, 0.7, cover);
    material.metallic *= 1.0 - cover;
    material.normal = normalize(mix(material.normal, ng, cover * 0.85));
    material.occlusion = mix(material.occlusion, 1.0, cover * 0.5);
  }
}
