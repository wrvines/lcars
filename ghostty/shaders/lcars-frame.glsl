// ============================================================================
// LCARS frame for Ghostty — a size-aware border drawn over the terminal
// ============================================================================
// The generated PNG frame is stretched to the window, so it lines up with the
// text only at the canvas size it was authored for. This shader draws the
// frame instead: it always hugs the window edge, at any window size, aspect
// or DPI. And because custom shaders run as a post-process pass, the frame
// stays visible over full-screen apps (tmux, editors, ...) whose backgrounds
// would otherwise cover the background image.
//
// The band thickness scales with the window height (clamped), so the
// clearance text needs depends only on the band thickness. window-padding-x/y
// in ghostty.conf are sized to clear it.
//
// Colors mirror palette/lcars.json:
//   #FF9900 sunset    #FF9966 salmon    #CC99CC lavender
//   #996699 mauve     #99CCFF ice
//
// The design is identical top and bottom on purpose: Ghostty's Metal and
// OpenGL backends disagree on the fragment coordinate origin, and a shader
// cannot detect which one is in use.
//
// Tune with the defines below, or disable the whole pass by commenting the
// lcars-frame.glsl `custom-shader` line in ghostty.conf.
//
//   BAND_FRACTION   band thickness as a fraction of window height
//   BAND_MIN/MAX    clamps for the band thickness, in pixels
//   CORNER_FRACTION inner corner radius relative to the band thickness
// ============================================================================

#define BAND_FRACTION 0.028
#define BAND_MIN 10.0
#define BAND_MAX 32.0
#define CORNER_FRACTION 0.6

const vec3 LCARS_SUNSET = vec3(1.000, 0.600, 0.000);   // #FF9900
const vec3 LCARS_SALMON = vec3(1.000, 0.600, 0.400);   // #FF9966
const vec3 LCARS_LAVENDER = vec3(0.800, 0.600, 0.800); // #CC99CC
const vec3 LCARS_MAUVE = vec3(0.600, 0.400, 0.600);    // #996699
const vec3 LCARS_ICE = vec3(0.600, 0.800, 1.000);      // #99CCFF

// Signed distance to a rounded box centered on the origin.
float sdRoundedBox(vec2 p, vec2 half_size, float radius) {
    vec2 q = abs(p) - half_size + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 res = iResolution.xy;
    vec4 base = texture(iChannel0, fragCoord / res);

    float band = clamp(res.y * BAND_FRACTION, BAND_MIN, BAND_MAX);
    band = min(band, min(res.x, res.y) * 0.08);
    float radius = band * CORNER_FRACTION;
    float outer = radius + band;
    vec2 mid = res * 0.5;

    // Border = outer rounded box minus inner rounded box.
    float d_out = sdRoundedBox(fragCoord - mid, mid, outer);
    float d_in = sdRoundedBox(fragCoord - mid, mid - band, radius);
    float d = max(d_out, -d_in);

    float aa = max(fwidth(d), 0.5);
    float mask = 1.0 - smoothstep(-aa, aa, d);

    float near_x = min(fragCoord.x, res.x - fragCoord.x);
    float near_y = min(fragCoord.y, res.y - fragCoord.y);
    float x = fragCoord.x / res.x;

    vec3 color;
    if (near_y < outer && near_x >= outer) {
        // Top and bottom bars: lavender with mirrored LCARS segments.
        color = (x > 0.10 && x < 0.34) ? LCARS_SALMON
              : (x > 0.66 && x < 0.90) ? LCARS_ICE
              : LCARS_LAVENDER;
    } else {
        // Side rails and the corner arcs: left sunset, right mauve.
        color = (fragCoord.x < mid.x) ? LCARS_SUNSET : LCARS_MAUVE;
    }

    fragColor = vec4(mix(base.rgb, color, mask), base.a);
}
