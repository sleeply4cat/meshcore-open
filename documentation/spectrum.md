# Spectrum

The spectrum screen shows the radio band around your companion as a live spectrum and waterfall, measured by the companion's own radio. Use it to see channel activity, interference, and where other transmitters sit.

## Requirements

The companion must run firmware with the spectrum stream: an nRF52 board with an SX1262 radio, built with `SPECTRUM_STREAM`. Other firmware shows an explanatory message instead of the plot. Review mode simulates it.

**The mesh is paused while the spectrum runs**: the companion neither receives nor sends packets. It resumes when you leave the screen, stop the spectrum, send the app to the background, or lose the connection (the companion stops by itself after 15 s without the app).

## Open the screen

Use Settings → Spectrum. The stream starts when the screen opens; the stop/start action in the app bar pauses it.

## Controls

| Control | Effect |
|---|---|
| Span (0.5 / 2 / 8 / 16 MHz) | Width of the swept band, 250 points across it. Wider spans sweep faster but resolve less |
| Centre, ◀ ▶ | Centre frequency; the arrows move by a quarter span, tapping the frequency edits it |
| Node channel | Centre on the companion's own frequency and follow it |
| Tap or drag on a plot | Cursor with the frequency and level under it |
| Double tap on a plot | Centre there |
| Settings → frames from the node | How often the companion sends a frame (5–50/s, or every sweep). More than the link carries are skipped |
| Settings → a frame holds | Of the sweeps between two frames: the strongest level (shows short packets), the mean power, or the latest sweep |
| Settings → averaging, peak hold, range | Display only: trace averaging, a held maximum (decaying or kept), and the vertical scale |

The footer shows the strongest point (when it stands 10 dB above the noise), the noise level, received frames per second with the share skipped, sweeps per second, the resolution bandwidth and the step between points. The node's channel is shaded on the spectrum.

Levels are the radio's RSSI readings through its receive filter: useful for comparing signals and seeing activity, not a calibrated measurement.
