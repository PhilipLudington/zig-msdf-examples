//! Embedded assets
//!
//! Contains fonts and other resources embedded at compile time.

/// DejaVu Sans font (OFL licensed)
pub const dejavu_sans = @embedFile("fonts/DejaVuSans.ttf");
