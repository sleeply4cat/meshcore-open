import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../l10n/l10n.dart';
import '../services/lora_scan.dart';
import '../theme/mesh_theme.dart';
import '../utils/disconnect_navigation_mixin.dart';

void pushLoraScanScreen(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (context) => const LoraScanScreen()),
  );
}

const List<int> _stepsHz = [0, stepBandwidth, 10000, 25000, 50000, 100000];
const List<int> _hotsS = [0, 5, 10, 20, 30];
const List<int> _durationsS = [120, 300, 600, 1200, 1800, 3600];
const List<int> _listensS = [30, 60, 120, 300, 600];
const List<int> _cadSymbols = [1, 2, 4, 8];

/// Finds LoRa traffic around the node with its CAD scan, and listens on the
/// candidates to tell whether they are MeshCore and on which exact frequency.
class LoraScanScreen extends StatefulWidget {
  const LoraScanScreen({super.key});

  @override
  State<LoraScanScreen> createState() => _LoraScanScreenState();
}

class _LoraScanScreenState extends State<LoraScanScreen>
    with DisconnectNavigationMixin {
  // kept for the next time the screen opens
  static LoraScanSettings? _lastSettings;

  late final LoraScanController _scan;
  late final TextEditingController _from;
  late final TextEditingController _to;
  final ExpansibleController _settingsTile = ExpansibleController();

  @override
  void initState() {
    super.initState();
    final connector = context.read<MeshCoreConnector>();
    // the node reports its frequency in kHz
    final nodeHz = (connector.currentFreqHz ?? 869525) * 1000;
    final settings =
        _lastSettings ??
        LoraScanSettings(fromHz: nodeHz - 500000, toHz: nodeHz + 500000);
    _scan = LoraScanController(connector, settings);
    _from = TextEditingController(text: _mhz(settings.fromHz));
    _to = TextEditingController(text: _mhz(settings.toHz));
  }

  @override
  void dispose() {
    _lastSettings = _scan.settings;
    _scan.dispose();
    _from.dispose();
    _to.dispose();
    _settingsTile.dispose();
    super.dispose();
  }

  void _update(LoraScanSettings s) {
    _scan.settings = s;
  }

  void _setBand(int fromHz, int toHz) {
    _from.text = _mhz(fromHz);
    _to.text = _mhz(toHz);
    _update(_scan.settings.copyWith(fromHz: fromHz, toHz: toHz));
  }

  void _readBand() {
    final f = double.tryParse(_from.text.replaceAll(',', '.'));
    final t = double.tryParse(_to.text.replaceAll(',', '.'));
    if (f == null || t == null) return;
    _update(
      _scan.settings.copyWith(
        fromHz: (f * 1e6).round(),
        toHz: (t * 1e6).round(),
      ),
    );
  }

  Future<void> _start() async {
    _readBand();
    if (!_scan.settings.isValid) return;
    _settingsTile.collapse();
    await _scan.startScan();
  }

  Future<void> _apply(LoraCandidate c, LoraListenResult r) async {
    final l10n = context.l10n;
    final connector = context.read<MeshCoreConnector>();
    final hz = r.senderHz ?? r.freqHz;
    final cr = r.codingRate ?? 5;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.loraScan_applyTitle),
        content: Text(
          l10n.loraScan_applyBody(
            _mhz(hz),
            loraBandwidthsKhz[r.bandwidth].toString(),
            r.sf,
            cr,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.loraScan_apply),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // the radio must be the mesh's again before it takes new settings
    await _scan.stopAndWait();
    // CMD_SET_RADIO_PARAMS takes the frequency in kHz
    final accepted = await connector.setRadioParams(
      (hz / 1000).round(),
      loraBandwidthHz(r.bandwidth),
      r.sf,
      cr,
    );
    if (accepted) await connector.refreshDeviceInfo();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          accepted ? l10n.loraScan_applied : l10n.loraScan_applyRefused,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    if (!checkConnectionAndNavigate(connector)) return const SizedBox.shrink();
    final l10n = context.l10n;
    final nodeHz = connector.currentFreqHz == null
        ? null
        : connector.currentFreqHz! * 1000;
    return ListenableBuilder(
      listenable: _scan,
      builder: (context, _) {
        final busy = _scan.busy;
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.loraScan_title),
            centerTitle: true,
            actions: [
              if (busy)
                IconButton(
                  icon: const Icon(Icons.stop),
                  tooltip: l10n.loraScan_stop,
                  onPressed: () => unawaited(_scan.stop()),
                )
              else
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  tooltip: l10n.loraScan_start,
                  onPressed: _scan.settings.isValid ? _start : null,
                ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _SettingsCard(
                  settings: _scan.settings,
                  enabled: !busy,
                  controller: _settingsTile,
                  from: _from,
                  to: _to,
                  onBandEdited: _readBand,
                  onBand: _setBand,
                  nodeHz: nodeHz,
                  onChanged: _update,
                ),
                const SizedBox(height: 12),
                _StatusLine(scan: _scan),
                if (_scan.scanned != null) ...[
                  const SizedBox(height: 12),
                  _HeatmapCard(scan: _scan, nodeHz: nodeHz),
                ],
                if (_scan.scanned != null) ...[
                  const SizedBox(height: 16),
                  _CandidateList(scan: _scan, onApply: _apply),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

String _mhz(int hz) => (hz / 1e6).toStringAsFixed(3);

String _clock(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

String _bwLabel(int bw) {
  final k = loraBandwidthsKhz[bw];
  return k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toString();
}

class _SettingsCard extends StatelessWidget {
  final LoraScanSettings settings;
  final bool enabled;
  final ExpansibleController controller;
  final TextEditingController from;
  final TextEditingController to;
  final VoidCallback onBandEdited;
  final void Function(int fromHz, int toHz) onBand;
  final int? nodeHz;
  final ValueChanged<LoraScanSettings> onChanged;

  const _SettingsCard({
    required this.settings,
    required this.enabled,
    required this.controller,
    required this.from,
    required this.to,
    required this.onBandEdited,
    required this.onBand,
    required this.nodeHz,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = settings;
    final pass = s.passDuration;
    final passSeconds = pass.inMilliseconds / 1000;
    final summary =
        '${_mhz(s.fromHz)}–${_mhz(s.toHz)} MHz · '
        'BW ${(s.bandwidths.toList()..sort()).map(_bwLabel).join('/')} · '
        'SF ${(s.spreadingFactors.toList()..sort()).join(',')} · '
        '${l10n.loraScan_passEstimate(passSeconds.toStringAsFixed(1))}';

    Widget section(String title, Widget child) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );

    Widget chips<T>(
      List<T> values,
      bool Function(T) selected,
      String Function(T) label,
      void Function(T) onTap,
    ) {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final v in values)
            FilterChip(
              label: Text(label(v)),
              selected: selected(v),
              showCheckmark: false,
              onSelected: enabled ? (_) => onTap(v) : null,
            ),
        ],
      );
    }

    Set<int> toggled(Set<int> set, int v) {
      final out = {...set};
      if (!out.remove(v)) out.add(v);
      return out;
    }

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        controller: controller,
        initiallyExpanded: true,
        title: Text(l10n.loraScan_settings),
        subtitle: Text(summary, style: Theme.of(context).textTheme.bodySmall),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          section(
            l10n.loraScan_band,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: from,
                        enabled: enabled,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: l10n.loraScan_from,
                          suffixText: 'MHz',
                          isDense: true,
                        ),
                        onSubmitted: (_) => onBandEdited(),
                        onTapOutside: (_) => onBandEdited(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: to,
                        enabled: enabled,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: l10n.loraScan_to,
                          suffixText: 'MHz',
                          isDense: true,
                        ),
                        onSubmitted: (_) => onBandEdited(),
                        onTapOutside: (_) => onBandEdited(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (nodeHz != null)
                      ActionChip(
                        label: Text(l10n.loraScan_aroundNode),
                        onPressed: enabled
                            ? () => onBand(nodeHz! - 500000, nodeHz! + 500000)
                            : null,
                      ),
                    for (final (name, a, b) in const [
                      ('RU', 868700000, 869200000),
                      ('RU', 864000000, 865000000),
                      ('EU', 869400000, 869650000),
                      ('EU', 863000000, 870000000),
                      ('US', 902000000, 928000000),
                      ('ISM', 433050000, 434790000),
                    ])
                      ActionChip(
                        label: Text(
                          '$name ${_mhz(a).replaceAll(RegExp(r'\.?0+$'), '')}–'
                          '${_mhz(b).replaceAll(RegExp(r'\.?0+$'), '')}',
                        ),
                        onPressed: enabled ? () => onBand(a, b) : null,
                      ),
                  ],
                ),
              ],
            ),
          ),
          section(
            l10n.loraScan_bandwidths,
            chips<int>(
              List.generate(loraBandwidthsKhz.length, (i) => i),
              s.bandwidths.contains,
              _bwLabel,
              (v) =>
                  onChanged(s.copyWith(bandwidths: toggled(s.bandwidths, v))),
            ),
          ),
          section(
            l10n.loraScan_spreadingFactors,
            chips<int>(
              List.generate(8, (i) => i + 5),
              s.spreadingFactors.contains,
              (v) => 'SF$v',
              (v) => onChanged(
                s.copyWith(spreadingFactors: toggled(s.spreadingFactors, v)),
              ),
            ),
          ),
          section(
            l10n.loraScan_step,
            chips<int>(
              _stepsHz,
              (v) => v == s.stepHz,
              (v) => switch (v) {
                0 => l10n.loraScan_stepAuto,
                stepBandwidth => l10n.loraScan_stepBandwidth,
                _ => '${v ~/ 1000} kHz',
              },
              (v) => onChanged(s.copyWith(stepHz: v)),
            ),
          ),
          section(
            l10n.loraScan_cad,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                chips<int>(
                  _cadSymbols,
                  (v) => v == s.cadSymbols,
                  (v) => l10n.loraScan_symbols(v),
                  (v) => onChanged(s.copyWith(cadSymbols: v, detPeakMargin: 0)),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      l10n.loraScan_threshold,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Expanded(
                      child: Slider(
                        min: 11,
                        max: 23,
                        divisions: 12,
                        value: _margin(s).toDouble(),
                        label: 'SF + ${_margin(s)}',
                        onChanged: enabled
                            ? (v) => onChanged(
                                s.copyWith(detPeakMargin: v.round()),
                              )
                            : null,
                      ),
                    ),
                    Text(
                      'SF + ${_margin(s)}',
                      style: MeshTheme.mono(fontSize: 12),
                    ),
                  ],
                ),
                Text(
                  l10n.loraScan_thresholdHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          section(
            l10n.loraScan_duration,
            chips<int>(
              _durationsS,
              (v) => v == s.durationSeconds,
              (v) => '${v ~/ 60} min',
              (v) => onChanged(s.copyWith(durationSeconds: v)),
            ),
          ),
          section(
            l10n.loraScan_hot,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                chips<int>(
                  _hotsS,
                  (v) => v == s.hotSeconds,
                  (v) => v == 0 ? l10n.loraScan_hotOff : '$v s',
                  (v) => onChanged(s.copyWith(hotSeconds: v)),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.loraScan_hotHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          section(
            l10n.loraScan_listen,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                chips<int>(
                  _listensS,
                  (v) => v == s.listenSeconds,
                  (v) => v < 60 ? '$v s' : '${v ~/ 60} min',
                  (v) => onChanged(s.copyWith(listenSeconds: v)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // the firmware's default when 0
  static int _margin(LoraScanSettings s) =>
      s.detPeakMargin != 0 ? s.detPeakMargin : (s.cadSymbols <= 2 ? 17 : 13);
}

class _StatusLine extends StatelessWidget {
  final LoraScanController scan;

  const _StatusLine({required this.scan});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    String? text;
    var warn = false;
    if (scan.error != null) {
      text = scan.error == 1
          ? l10n.loraScan_unsupported
          : l10n.loraScan_error(scan.error!);
      warn = true;
    } else if (scan.state == LoraScanState.scanning) {
      final elapsed = DateTime.now().difference(scan.startedAt!).inSeconds;
      text = l10n.loraScan_scanning(
        scan.passes,
        _clock(elapsed),
        _clock(scan.scanned!.durationSeconds),
      );
      if (scan.scanned!.hotSeconds > 0) {
        text +=
            ' · ${l10n.loraScan_hotHits(scan.hotHits)}'
            ' · ${l10n.loraScan_caught(scan.caughtPackets)}';
      }
    } else if (scan.state == LoraScanState.listening) {
      final r = scan.listening!;
      text = l10n.loraScan_listening(
        _mhz(r.freqHz),
        r.sf,
        _bwLabel(r.bandwidth),
      );
    } else if (scan.scanned == null) {
      text = l10n.loraScan_intro;
    }
    if (text == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: warn ? scheme.error : scheme.onSurfaceVariant,
          ),
        ),
        if (scan.busy) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: switch (scan.state) {
              LoraScanState.scanning =>
                (DateTime.now().difference(scan.startedAt!).inMilliseconds /
                        (scan.scanned!.durationSeconds * 1000))
                    .clamp(0.0, 1.0),
              _ => null,
            },
          ),
          const SizedBox(height: 6),
          Text(
            l10n.loraScan_meshPaused,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// Detections per pass for each (bandwidth, SF) row over the band, above the
/// row's own false-alarm level (its median).
class _HeatmapCard extends StatelessWidget {
  final LoraScanController scan;
  final int? nodeHz;

  const _HeatmapCard({required this.scan, required this.nodeHz});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = scan.scanned!;
    final rows = [
      for (final bw in s.bandwidths.toList()..sort())
        for (final sf in s.spreadingFactors.toList()..sort()) (bw, sf),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.loraScan_heatmap,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              l10n.loraScan_heatmapHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: rows.length * 14.0 + 22,
              child: CustomPaint(
                size: Size.infinite,
                painter: _HeatmapPainter(
                  scan: scan,
                  rows: rows,
                  nodeHz: nodeHz,
                  scheme: Theme.of(context).colorScheme,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  final LoraScanController scan;
  final List<(int, int)> rows;
  final int? nodeHz;
  final ColorScheme scheme;

  _HeatmapPainter({
    required this.scan,
    required this.rows,
    required this.nodeHz,
    required this.scheme,
  });

  static const double _label = 58;
  static const double _rowH = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scan.scanned!;
    final passes = math.max(1, scan.passes);
    final w = size.width - _label;
    if (w <= 0) return;
    final lo = s.fromHz.toDouble(),
        hi = math.max(s.toHz, s.fromHz + 1).toDouble();
    double xOf(double hz) => _label + (hz - lo) / (hi - lo) * w;
    final textStyle = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    final bg = Paint()..color = scheme.surfaceContainerHighest;
    for (var r = 0; r < rows.length; r++) {
      final (bw, sf) = rows[r];
      final y = r * _rowH;
      final points = s.pointsFor(bw);
      final step = s.stepFor(bw).toDouble();
      final rates = [for (final f in points) scan.hitsAt(bw, sf, f) / passes];
      final sorted = [...rates]..sort();
      final base = sorted.isEmpty ? 0.0 : sorted[sorted.length ~/ 2];
      canvas.drawRect(Rect.fromLTWH(_label, y + 1, w, _rowH - 2), bg);
      for (var i = 0; i < points.length; i++) {
        final excess = (rates[i] - base).clamp(0.0, 1.0);
        if (excess <= 0) continue;
        final t = math.min(1.0, excess / 0.3);
        final left = xOf(math.max(lo, points[i] - step / 2));
        final right = xOf(math.min(hi, points[i] + step / 2));
        canvas.drawRect(
          Rect.fromLTRB(left, y + 1, math.max(left + 1, right), y + _rowH - 1),
          Paint()
            ..color = Color.lerp(
              scheme.primaryContainer,
              scheme.primary,
              t,
            )!.withValues(alpha: 0.25 + 0.75 * t),
        );
      }
      final tp = TextPainter(
        text: TextSpan(text: '${_bwLabel(bw)} SF$sf', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: _label - 4);
      tp.paint(canvas, Offset(0, y + (_rowH - tp.height) / 2));
    }
    // frequency axis
    final axisY = rows.length * _rowH + 4;
    for (final hz in [lo, (lo + hi) / 2, hi]) {
      final tp = TextPainter(
        text: TextSpan(text: (hz / 1e6).toStringAsFixed(3), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = (xOf(hz) - tp.width / 2).clamp(_label, size.width - tp.width);
      tp.paint(canvas, Offset(x, axisY));
    }
    final node = nodeHz;
    if (node != null && node >= lo && node <= hi) {
      final x = xOf(node.toDouble());
      final p = Paint()
        ..color = scheme.tertiary
        ..strokeWidth = 1;
      for (var y = 0.0; y < rows.length * _rowH; y += 6) {
        canvas.drawLine(Offset(x, y), Offset(x, y + 3), p);
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) => true;
}

class _CandidateList extends StatelessWidget {
  final LoraScanController scan;
  final Future<void> Function(LoraCandidate, LoraListenResult) onApply;

  const _CandidateList({required this.scan, required this.onApply});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final list = scan.candidates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.loraScan_candidates(list.length),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (list.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.hearing, size: 18),
                label: Text(l10n.loraScan_listenAll),
                onPressed: scan.busy ? null : () => scan.verifyAll(list),
              ),
          ],
        ),
        if (list.isEmpty && !scan.busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n.loraScan_noCandidates,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (final c in list)
          _CandidateTile(scan: scan, candidate: c, onApply: onApply),
      ],
    );
  }
}

class _CandidateTile extends StatelessWidget {
  final LoraScanController scan;
  final LoraCandidate candidate;
  final Future<void> Function(LoraCandidate, LoraListenResult) onApply;

  const _CandidateTile({
    required this.scan,
    required this.candidate,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final c = candidate;
    final r = c.best;
    final listeningHere =
        scan.listening != null &&
        [c, ...c.alternatives].any((t) => t.result == scan.listening);
    final mono = MeshTheme.mono(fontSize: 13, color: scheme.onSurface);
    // other settings at the same place; a retune after a listen shows its MHz
    final alternatives = c.alternatives
        .map(
          (a) =>
              a.retry ? _mhz(a.freqHz) : 'SF${a.sf}/${_bwLabel(a.bandwidth)}',
        )
        .join(', ');
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_mhz(c.freqHz)} MHz · SF${c.sf} / ${_bwLabel(c.bandwidth)} kHz',
                        style: mono,
                      ),
                      // a network heard without a count of its own has no rate
                      if (c.rate > 0 || c.alternatives.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (c.rate > 0)
                              l10n.loraScan_cadRate(
                                (c.rate * 100).round(),
                                (c.excess * 100).round(),
                              ),
                            if (c.alternatives.isNotEmpty)
                              l10n.loraScan_alternatives(alternatives),
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                if (listeningHere)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.hearing),
                    tooltip: l10n.loraScan_listenHere,
                    onPressed: scan.busy ? null : () => scan.verify(c),
                  ),
              ],
            ),
            if (r != null) ...[
              const SizedBox(height: 6),
              _ResultView(result: r, onApply: () => onApply(c, r)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  final LoraListenResult result;
  final VoidCallback onApply;

  const _ResultView({required this.result, required this.onApply});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final r = result;
    final good = r.valid;
    final small = Theme.of(context).textTheme.bodySmall;
    if (good.isEmpty) {
      final text = !r.done
          ? l10n.loraScan_waiting(r.packets.length, r.preambles)
          : (r.preambles > 0 || r.packets.isNotEmpty)
          ? l10n.loraScan_noDecode(
              r.preambles,
              r.headerErrors,
              r.packets.length,
            )
          : l10n.loraScan_nothing;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(text, style: small),
      );
    }
    final types = <String>{};
    final names = <String>{};
    for (final p in good) {
      final h = p.meshCore;
      if (h == null || !h.plausible) continue;
      types.add(_payloadType(h.payloadType));
      if (h.advertName != null && h.advertName!.isNotEmpty) {
        names.add(h.advertName!);
      }
    }
    final fei = good.map((p) => p.frequencyErrorHz).toList()..sort();
    final rssi = good.map((p) => p.rssi).reduce(math.max);
    final snr = good.map((p) => p.snr).reduce(math.max);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                label: Text(
                  r.isMeshCore ? 'MeshCore' : l10n.loraScan_otherLora,
                ),
                visualDensity: VisualDensity.compact,
                backgroundColor: r.isMeshCore
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
              ),
              Text(
                l10n.loraScan_packets(good.length, r.packets.length),
                style: small,
              ),
              if (r.duringScan)
                Text(l10n.loraScan_caughtDuringScan, style: small),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.loraScan_result(
              _mhz(r.senderHz!),
              fei.first,
              fei.last,
              rssi,
              snr.toStringAsFixed(1),
              r.codingRate ?? 0,
            ),
            style: MeshTheme.mono(fontSize: 12, color: scheme.onSurface),
          ),
          if (types.isNotEmpty)
            Text(
              types.join(', ') +
                  (names.isEmpty ? '' : ' · ${names.join(', ')}'),
              style: small,
            ),
          if (r.isMeshCore)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onApply,
                child: Text(l10n.loraScan_useSettings),
              ),
            ),
        ],
      ),
    );
  }

  static String _payloadType(int t) => switch (t) {
    payloadTypeREQ => 'REQ',
    payloadTypeRESPONSE => 'RESPONSE',
    payloadTypeTXTMSG => 'TXT_MSG',
    payloadTypeACK => 'ACK',
    payloadTypeADVERT => 'ADVERT',
    payloadTypeGRPTXT => 'GRP_TXT',
    payloadTypeGRPDATA => 'GRP_DATA',
    payloadTypeANONREQ => 'ANON_REQ',
    payloadTypePATH => 'PATH',
    payloadTypeTRACE => 'TRACE',
    payloadTypeMULTIPART => 'MULTIPART',
    payloadTypeCONTROL => 'CONTROL',
    _ => 'type $t',
  };
}
