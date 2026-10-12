# LoRa Scan

The LoRa scan looks for LoRa networks around the companion with its own radio, tells which settings they use and whether they are MeshCore, and can switch the radio to a network it found.

## Requirements

Companion firmware with the LoRa scan: an nRF52 board with an SX1262, built with `LORA_SCAN`. Other firmware shows an explanatory message.

**The mesh is paused while the scan or a listen runs**; the radio returns to its settings when it ends, is stopped, or the connection drops.

## How it works

1. **Scan.** The companion checks each point of the band for LoRa chirps of each chosen bandwidth and spreading factor (channel activity detection, CAD). CAD finds LoRa below the noise floor, where a spectrum view shows nothing. The heat map shows, per bandwidth and SF, how often each point fires above that row's false-alarm level.
2. **Candidates.** Points that fire clearly more than the rest of their row become candidates; settings that fire at the same place less often are kept as alternatives.
3. **Hot points.** After each pass the companion spends a while on the best candidates not heard yet (their place and an eighth of their bandwidth either side) and receives after each detection there: their packets often come during the scan, with the exact frequency, and the candidate is answered.
4. **Listen.** For candidates not heard during the scan, the companion receives on a candidate (and its alternatives, while nothing is decoded) with MeshCore's sync word, until the first good packet or the time is up. Each good packet gives the signal level, the coding rate and the sender's exact frequency from the radio's frequency error; MeshCore packets are recognised by their header, adverts by name.
5. **Use.** For a MeshCore network heard, "Use these radio settings" stops the scan and sets the companion to the frequency, bandwidth, SF and coding rate heard. Other LoRa networks are only shown.

## Settings

| Setting | Effect |
|---|---|
| Band | The range scanned; presets around the node and for the RU, EU and US bands (the whole EU 863–870 or US band is slow) |
| Bandwidths, spreading factors | Which LoRa settings to look for; each adds a row and time to every pass |
| Step | Between points; Auto is half of each bandwidth (CAD hears up to about that far off); = BW is twice as fast, coarser |
| CAD length, threshold | Longer CAD and a higher threshold: fewer false alarms, slower and less sensitive |
| Scan time | How long to scan; most networks send only a few packets a minute, so give it several minutes (10 by default) |
| Hot points | Time on the hot points after each pass; Off: counting only, then listening |
| Listen on each candidate | How long to wait for packets on a candidate |

A pass takes roughly points × (CAD symbols + 1) × symbol time, summed over the settings: over 1 MHz at BW 62.5 kHz about 0.35 s at SF7 and 1.6 s at SF10. High spreading factors and narrow bandwidths are slow; leave them out unless needed. Detection depends on traffic: a network that sends rarely needs a longer scan.
