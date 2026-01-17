//! Embedded assets
//!
//! Contains fonts and other resources embedded at compile time.

/// DejaVu Sans font (OFL licensed)
pub const dejavu_sans = @embedFile("fonts/DejaVuSans.ttf");

/// SF Mono font (Apple San Francisco Mono)
pub const sf_mono = @embedFile("fonts/SFNSMono.ttf");
