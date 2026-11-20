// Copies a directional light's cookie into its tile of the shadow atlas (see
// shadow_cookie.glsl), its strength applied: the lit shader reads the tile
// as a visibility factor, 1 where the cookie lets all the light through.

precision highp float;

uniform sampler2D cookie_texture;

uniform CookieInfo {
  // x: strength (0 leaves the light unaffected, 1 applies the cookie fully).
  vec4 params;
}
cookie_info;

in vec2 v_uv;

out vec4 frag_color;

void main() {
  float cookie = texture(cookie_texture, v_uv).r;
  frag_color = vec4(mix(1.0, cookie, cookie_info.params.x), 0.0, 0.0, 1.0);
}
