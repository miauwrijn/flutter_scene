// The directional light's cookie: a texture projected along the light that
// scales its direct visibility (see DirectionalLight.cookie). It rides the
// shadow atlas as one extra tile after every shadow tile, so it costs no
// texture unit; the shadow pass copies the cookie into that tile each frame.
//
// Projection, orthographic along the light's travel direction L (unit):
//   right = normalize(cross(vec3(0, 0, 1), L))   (+X for a sun straight down)
//   up    = cross(L, right)                      (+Z for a sun straight down)
//   uv    = (vec2(dot(p, right), dot(p, up)) + offset) / size
// for a world point p. With repeat the texture tiles; without it a point
// outside [0, 1] is unaffected. Keep in sync with DirectionalLight.cookieUv.

#ifndef SHADOW_COOKIE_GLSL_
#define SHADOW_COOKIE_GLSL_

// The cookie-space basis for travel direction [light_dir] (need not be unit).
// A light travelling along the world Z axis has no basis from +Z and falls
// back to +X; that is a light at the horizon, which a cookie rarely serves.
void ShadowCookieBasis(highp vec3 light_dir, out highp vec3 right,
                       out highp vec3 up) {
  highp vec3 l = normalize(light_dir);
  highp vec3 reference =
      abs(l.z) > 0.999 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0);
  right = normalize(cross(reference, l));
  up = cross(l, right);
}

// The cookie tile's value at tile texel [texel] (wrapped or clamped).
highp float ShadowCookieTexel(highp sampler2D atlas, ivec2 texel, int res,
                              highp float tile, highp float total,
                              bool repeat) {
  ivec2 t = repeat ? ((texel % res) + res) % res
                   : clamp(texel, ivec2(0), ivec2(res - 1));
  highp float fres = float(res);
  highp vec2 uv = vec2((tile * fres + float(t.x) + 0.5) / (total * fres),
                       (float(t.y) + 0.5) / fres);
  return textureLod(atlas, uv, 0.0).r;
}

// The cookie's visibility factor at world point [p] (1 = unaffected).
// [params]: x enabled (> 0.5), y repeat (> 0.5). [transform]: xy 1 / size,
// zw offset. [tile] is the cookie's atlas tile, [total] the atlas tile count,
// [res] the tile edge in texels. The tile is fp32 and sampled nearest (fp32
// filtering is optional on OpenGL ES), so it is filtered here by hand.
highp float SampleShadowCookie(highp sampler2D atlas, highp vec3 p,
                               highp vec3 light_dir, highp vec4 params,
                               highp vec4 transform, highp float tile,
                               highp float total, highp float res) {
  if (params.x < 0.5) {
    return 1.0;
  }
  highp vec3 right;
  highp vec3 up;
  ShadowCookieBasis(light_dir, right, up);
  highp vec2 uv = (vec2(dot(p, right), dot(p, up)) + transform.zw) *
                  transform.xy;
  bool repeat = params.y > 0.5;
  if (!repeat && (any(lessThan(uv, vec2(0.0))) ||
                  any(greaterThan(uv, vec2(1.0))))) {
    return 1.0;
  }
  if (repeat) {
    uv = fract(uv);
  }
  int ires = int(res + 0.5);
  highp vec2 t = uv * res - 0.5;
  highp vec2 base = floor(t);
  highp vec2 f = t - base;
  ivec2 i = ivec2(base);
  highp float a = ShadowCookieTexel(atlas, i, ires, tile, total, repeat);
  highp float b =
      ShadowCookieTexel(atlas, i + ivec2(1, 0), ires, tile, total, repeat);
  highp float c =
      ShadowCookieTexel(atlas, i + ivec2(0, 1), ires, tile, total, repeat);
  highp float d =
      ShadowCookieTexel(atlas, i + ivec2(1, 1), ires, tile, total, repeat);
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

#endif  // SHADOW_COOKIE_GLSL_
