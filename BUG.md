# MSDF Rendering Bug: Artifacts on Curved Glyphs (S, D)

## Summary

Curved glyphs like "S" and "D" display jagged/rough artifacts at their inner curves when rendered at high zoom levels. The artifacts appear as irregular edges inside the smooth curved portions of the letters.

## Reproduction

1. Run `zig build run-gpu`
2. Press SPACE to enter interactive zoom mode
3. Zoom to 8x scale using mouse wheel or UP arrow
4. Observe the "S" and "D" characters - they have visible artifacts at curve transitions

## Root Cause: Confirmed

**The issue is in zig-msdf's atlas generation, NOT the rendering code.**

This was definitively proven by:
1. Building an atlas comparison tool (`zig build run-compare`)
2. Generating identical glyphs with both zig-msdf and reference msdfgen
3. Rendering both atlases with the same shader/rendering code
4. msdfgen atlas renders perfectly; zig-msdf atlas shows artifacts

### Visual Evidence

Side-by-side atlas comparison:
- `zig-msdf-atlas/atlas.png` - shows problematic color transitions
- `msdfgen-atlas/atlas_converted.png` - shows correct MSDF color boundaries

The atlases look visibly different, particularly in edge coloring at curve inflection points.

## Investigation Findings

### Rendering Code: Verified Correct

The examples rendering pipeline was thoroughly reviewed and confirmed correct:
- UV coordinate mapping properly accounts for padding and aspect ratios
- Shader implementation uses standard MSDF median calculation
- Texture sampling uses appropriate linear filtering
- Both SPIR-V and Metal shader implementations are functionally identical

### Atlas Generation: Confirmed Problematic

| Metric | zig-msdf | msdfgen |
|--------|----------|---------|
| Atlas size | 480x480 | 332x332 |
| Glyph count | 94 | 95 |
| Visual quality | Artifacts on curves | Clean |

### Font Type

- DejaVu Sans uses **TrueType (quadratic beziers)**, not cubic beziers
- The curvature detection code path for quadratic beziers is the likely issue

## Technical Analysis

The issue is in **zig-msdf's edge coloring algorithm** for MSDF generation. For proper MSDF rendering, edges must be colored (RGB channels) such that adjacent edges at "corners" have different colors. When this isn't done correctly, the median calculation in the shader produces artifacts.

For the "S" shape:
- The curve has an **inflection point** where curvature direction reverses
- TrueType fonts represent this as multiple quadratic beziers
- The coloring algorithm should detect where curvature sign changes and treat those points as color boundaries

### Relevant Code in zig-msdf

`src/generator/coloring.zig` (lines 96-122):
```zig
// Curvature sign reversal detection
const prev_curv = findPreviousCurvature(contour.edges, i);
const curr_curv = findCurrentCurvature(contour.edges, i);

const has_meaningful_curvature = max_curv > 0 and min_curv > max_curv * 0.01;
const opposite_signs = (prev_curv > 0 and curr_curv < 0) or (prev_curv < 0 and curr_curv > 0);

if (has_meaningful_curvature and opposite_signs) {
    // Mark as color boundary
}
```

`src/generator/edge.zig` (lines 202-208):
```zig
pub fn curvatureSign(self: QuadraticSegment) f64 {
    const leg1 = self.p1.sub(self.p0);
    const leg2 = self.p2.sub(self.p1);
    return leg1.cross(leg2);
}
```

### Possible Issues

1. **Threshold too high** - The curvature threshold `@abs(curv) > 1.0` may filter out valid curved edges
2. **Detection not triggering** - Curvature sign reversal detection may not find inflection points
3. **Wrong edges being compared** - `findPreviousCurvature` searches up to 5 edges back
4. **Resolution independent** - Increasing glyph_size/px_range didn't help (algorithmic issue)

## Comparison Tool

A comparison tool was built to aid debugging:

```bash
zig build run-compare
```

Controls:
- SPACE - Toggle between zig-msdf and msdfgen atlas
- T - Toggle atlas view / text view
- E - Export zig-msdf atlas to `zig-msdf-atlas/` directory
- UP/DOWN or Mouse wheel - Adjust scale
- ESC - Exit

## Environment

- zig-msdf: latest from main branch (local path `../zig-msdf`)
- Font: DejaVu Sans (TrueType, quadratic beziers)
- Glyph size: 48px
- px_range: 4.0
- Platform: macOS (Metal shaders)

## Related Issue

https://github.com/PhilipLudington/zig-msdf/issues/1
