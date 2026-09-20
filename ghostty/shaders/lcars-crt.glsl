// ============================================================================
// LCARS CRT pass for Ghostty
// ============================================================================
// A very gentle scanline + vignette effect. Ghostty custom shaders are
// Shadertoy-compatible: iChannel0 holds the rendered terminal screen.
//
// Tune with the defines below, or disable the effect entirely by commenting
// the `custom-shader` line in lcars/ghostty/ghostty.conf.
//
//   SCANLINE      strength of the horizontal scanlines (0.0 = off)
//   VIGNETTE_*    corner darkening
// ============================================================================

#define SCANLINE 0.04
#define VIGNETTE_MIN 0.88
#define VIGNETTE_INNER 0.45
#define VIGNETTE_OUTER 0.85

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = fragCoord / iResolution.xy;
    vec4 col = texture(iChannel0, uv);

    // Scanlines: one attenuation cycle every two physical pixels.
    float scan = 0.5 + 0.5 * sin(fragCoord.y * 3.14159265);
    col.rgb *= 1.0 - SCANLINE * scan;

    // Vignette: subtle darkening toward the corners.
    float vig = smoothstep(VIGNETTE_OUTER, VIGNETTE_INNER, length(uv - 0.5));
    col.rgb *= mix(VIGNETTE_MIN, 1.0, vig);

    fragColor = col;
}
