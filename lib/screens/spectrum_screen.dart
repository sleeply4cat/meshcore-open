import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/spectrum_stream.dart';
import '../theme/mesh_theme.dart';
import '../utils/disconnect_navigation_mixin.dart';

void pushSpectrumScreen(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (context) => const SpectrumScreen()),
  );
}

const List<int> _spansHz = [500000, 2000000, 8000000, 16000000];
const List<int> _intervalsMs = [200, 100, 50, 20, 0];
const List<int> _averages = [1, 3, 8, 20];
const List<int> _ranges = [40, 60, 80];

enum _Hold { off, decay, max }

/// Spectrum and waterfall of the band around the node, from its spectrum
/// stream. The stream runs while the screen is open and in front.
class SpectrumScreen extends StatefulWidget {
  const SpectrumScreen({super.key});

  @override
  State<SpectrumScreen> createState() => _SpectrumScreenState();
}

class _SpectrumScreenState extends State<SpectrumScreen>
    with DisconnectNavigationMixin, WidgetsBindingObserver {
  late final SpectrumStream _stream;
  late final StreamSubscription<Float32List> _frameSub;
  final _SpectrumView _view = _SpectrumView();
  bool _resumeOnForeground = false;

  @override
  void initState() {
    super.initState();
    _stream = SpectrumStream(context.read<MeshCoreConnector>());
    _frameSub = _stream.frames.listen(_view.addFrame);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_stream.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _stream.running) {
      _resumeOnForeground = true;
      unawaited(_stream.stop());
    } else if (state == AppLifecycleState.resumed && _resumeOnForeground) {
      _resumeOnForeground = false;
      unawaited(_stream.start());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_frameSub.cancel());
    _stream.dispose();
    _view.dispose();
    super.dispose();
  }

  void _setCentre(double hz) {
    _stream.configure(centreHz: hz.round());
    _view.clearHold();
  }

  void _centreAt(double fraction) {
    final info = _stream.info;
    if (info == null || !_stream.running) return;
    _setCentre(info.lowHz + fraction * (info.highHz - info.lowHz));
  }

  Future<void> _editCentre(double currentHz) async {
    final l10n = context.l10n;
    final controller = TextEditingController(
      text: (currentHz / 1e6).toStringAsFixed(3),
    );
    final mhz = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.spectrum_centre),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'MHz'),
          onSubmitted: (v) =>
              Navigator.pop(context, double.tryParse(v.replaceAll(',', '.'))),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              double.tryParse(controller.text.replaceAll(',', '.')),
            ),
            child: Text(l10n.common_ok),
          ),
        ],
      ),
    );
    controller.dispose();
    if (mhz != null && mhz > 0) _setCentre(mhz * 1e6);
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([_stream, _view]),
        builder: (context, _) => _SettingsSheet(stream: _stream, view: _view),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    if (!checkConnectionAndNavigate(connector)) return const SizedBox.shrink();
    final l10n = context.l10n;
    // the node reports its frequency in kHz
    final nodeKhz = connector.currentFreqHz;
    _view.nodeHz = nodeKhz == null ? null : nodeKhz * 1000;
    _view.nodeBwHz = connector.currentBwHz;
    _view.nodeSf = connector.currentSf;

    return ListenableBuilder(
      listenable: _stream,
      builder: (context, _) {
        _view.setInfo(_stream.info);
        final running = _stream.running;
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.spectrum_title),
            centerTitle: true,
            actions: [
              IconButton(
                icon: const Icon(Icons.tune),
                tooltip: l10n.spectrum_settings,
                onPressed: _showSettings,
              ),
              IconButton(
                icon: Icon(running ? Icons.stop : Icons.play_arrow),
                tooltip: running ? l10n.spectrum_stop : l10n.spectrum_start,
                onPressed: () =>
                    unawaited(running ? _stream.stop() : _stream.start()),
              ),
            ],
          ),
          body: SafeArea(
            child: _stream.status == SpectrumStatus.unsupported
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l10n.spectrum_unsupported,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : Column(
                    children: [
                      _buildTuning(context),
                      _buildStatusLine(context),
                      Expanded(
                        flex: 2,
                        child: _PlotGestures(
                          view: _view,
                          onCentre: _centreAt,
                          child: CustomPaint(
                            painter: _SpectrumPainter(
                              _view,
                              Theme.of(context).colorScheme,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        flex: 3,
                        child: _PlotGestures(
                          view: _view,
                          onCentre: _centreAt,
                          child: CustomPaint(
                            painter: _WaterfallPainter(_view),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                      _Footer(stream: _stream, view: _view),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildTuning(BuildContext context) {
    final l10n = context.l10n;
    final info = _stream.info;
    final span = _stream.spanHz;
    final centreHz = _stream.centreHz != 0
        ? _stream.centreHz.toDouble()
        : info != null && _stream.running
        ? (info.lowHz + info.highHz) / 2
        : (_view.nodeHz ?? 0).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final s in _spansHz)
                ButtonSegment(value: s, label: Text(_formatMhz(s / 1e6))),
            ],
            selected: {if (_spansHz.contains(span)) span},
            emptySelectionAllowed: true,
            onSelectionChanged: (v) {
              if (v.isEmpty) return;
              _stream.configure(spanHz: v.first);
              _view.clearHold();
            },
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: l10n.spectrum_left,
                onPressed: centreHz > 0
                    ? () => _setCentre(centreHz - span / 4)
                    : null,
              ),
              TextButton(
                onPressed: centreHz > 0 ? () => _editCentre(centreHz) : null,
                child: Text(
                  '${(centreHz / 1e6).toStringAsFixed(3)} MHz',
                  style: MeshTheme.mono(fontSize: 15),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: l10n.spectrum_right,
                onPressed: centreHz > 0
                    ? () => _setCentre(centreHz + span / 4)
                    : null,
              ),
              IconButton(
                icon: Icon(
                  _stream.centreHz == 0
                      ? Icons.my_location
                      : Icons.location_searching,
                ),
                tooltip: l10n.spectrum_nodeChannel,
                onPressed: _stream.centreHz == 0
                    ? null
                    : () {
                        _stream.configure(centreHz: 0);
                        _view.clearHold();
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusLine(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final (text, warn) = switch (_stream.status) {
      SpectrumStatus.idle => (l10n.spectrum_stopped, false),
      SpectrumStatus.starting => (l10n.spectrum_starting, false),
      SpectrumStatus.running => (l10n.spectrum_meshPaused, false),
      SpectrumStatus.unsupported => (l10n.spectrum_unsupported, true),
      SpectrumStatus.failed => (_failure(l10n), true),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: warn ? scheme.error : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  String _failure(AppLocalizations l10n) {
    final code = _stream.errCode ?? 0;
    return switch (_stream.stopReason) {
      null => l10n.spectrum_refused(code),
      spectrumStopTimeout => l10n.spectrum_stopTimeout,
      spectrumStopDisconnected => l10n.spectrum_stopDisconnected,
      spectrumStopRadio => l10n.spectrum_stopRadio(code),
      _ => l10n.spectrum_stopped,
    };
  }
}

String _formatMhz(double mhz) =>
    mhz == mhz.roundToDouble() ? mhz.toStringAsFixed(0) : mhz.toString();

String _formatHz(num hz) {
  if (hz >= 1e6) return '${(hz / 1e6).toStringAsFixed(2)} MHz';
  if (hz >= 1e3) return '${(hz / 1e3).toStringAsFixed(1)} kHz';
  return '${hz.round()} Hz';
}

/// What the plots show, kept from the frames: the trace (averaged), the hold,
/// the noise level and the waterfall.
class _SpectrumView extends ChangeNotifier {
  static const int waterfallRows = 1024;
  static const double sidePad = 12;
  static const double bottomPad = 18; // frequency labels

  SpectrumInfo? info;
  int? nodeHz;
  int? nodeBwHz;
  int? nodeSf;

  int average = 1;
  _Hold holdMode = _Hold.decay;
  int rangeDb = 60;

  Float32List? _last;
  Float32List? trace;
  Float32List? hold;
  double? noiseDb;
  double floorDb = -130;
  bool _floorSet = false;

  ui.Image? waterfall;
  int waterfallFilled = 0;

  /// The cursor, as a fraction of the plot width; null: none.
  double? cursor;

  /// New sweep settings change the noise level (with the RBW): measure it
  /// afresh.
  void setInfo(SpectrumInfo? v) {
    if (v?.config != info?.config) {
      noiseDb = null;
      _floorSet = false;
    }
    info = v;
  }

  void setAverage(int v) {
    average = v;
    notifyListeners();
  }

  void setHoldMode(_Hold v) {
    holdMode = v;
    hold = null;
    notifyListeners();
  }

  void setRange(int v) {
    rangeDb = v;
    notifyListeners();
  }

  void setCursor(double? v) {
    cursor = v;
    notifyListeners();
  }

  void clearHold() {
    hold = null;
    notifyListeners();
  }

  void clear() {
    hold = null;
    trace = null;
    _last = null;
    cursor = null;
    waterfall?.dispose();
    waterfall = null;
    waterfallFilled = 0;
    notifyListeners();
  }

  void addFrame(Float32List frame) {
    final n = frame.length;
    final last = _last;
    final dbm = Float32List(n);
    for (var i = 0; i < n; i++) {
      final v = frame[i];
      // a point without a reading keeps the previous one
      dbm[i] = v.isNaN && last != null && last.length == n ? last[i] : v;
    }
    _last = dbm;

    final t = trace;
    if (t == null || t.length != n || average == 1) {
      trace = Float32List.fromList(dbm);
    } else {
      for (var i = 0; i < n; i++) {
        t[i] = t[i].isNaN ? dbm[i] : t[i] + (dbm[i] - t[i]) / average;
      }
    }

    final h = hold;
    if (holdMode == _Hold.off) {
      hold = null;
    } else if (h == null || h.length != n) {
      hold = Float32List.fromList(dbm);
    } else {
      for (var i = 0; i < n; i++) {
        final held = holdMode == _Hold.decay ? h[i] - 0.25 : h[i];
        h[i] = dbm[i] > held || held.isNaN ? dbm[i] : held;
      }
    }

    // The noise: a low percentile of the frame, which signals hardly move,
    // smoothed. The plot's floor stays put while the noise is within its
    // lower part.
    final sorted = dbm.where((v) => !v.isNaN).toList()..sort();
    if (sorted.isNotEmpty) {
      final low = sorted[sorted.length ~/ 5];
      final noise = noiseDb == null ? low : noiseDb! + (low - noiseDb!) * 0.05;
      noiseDb = noise;
      if (!_floorSet || noise < floorDb + 4 || noise > floorDb + 25) {
        floorDb = ((noise - 12) / 5).floorToDouble() * 5;
        _floorSet = true;
      }
    }

    _pushWaterfallRow(dbm);
    notifyListeners();
  }

  /// A row on top of the waterfall: one pixel per point, the older rows
  /// moved down by one.
  void _pushWaterfallRow(Float32List dbm) {
    final n = dbm.length;
    final old = waterfall;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (old != null && old.width == n) {
      canvas.drawImage(old, const Offset(0, 1), Paint());
    } else {
      waterfallFilled = 0;
    }
    final lo = (noiseDb ?? -120) + 2;
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      final v = dbm[i];
      final level = v.isNaN ? 0 : ((v - lo) / 40 * 255).round().clamp(0, 255);
      paint.color = _palette[level];
      canvas.drawRect(Rect.fromLTWH(i.toDouble(), 0, 1, 1), paint);
    }
    final picture = recorder.endRecording();
    waterfall = picture.toImageSync(n, waterfallRows);
    picture.dispose();
    old?.dispose();
    if (waterfallFilled < waterfallRows) waterfallFilled++;
  }

  /// The peak of the trace, when it stands out of the noise.
  int? get peak {
    final t = trace;
    final noise = noiseDb;
    if (t == null || noise == null) return null;
    var best = -1;
    for (var i = 0; i < t.length; i++) {
      if (!t[i].isNaN && (best < 0 || t[i] > t[best])) best = i;
    }
    return best >= 0 && t[best] > noise + 10 ? best : null;
  }

  @override
  void dispose() {
    waterfall?.dispose();
    super.dispose();
  }
}

/// Dark blue, blue, cyan, yellow, red, white: weak to strong.
final List<Color> _palette = () {
  const stops = [
    [0.0, 0, 0, 24],
    [0.25, 20, 40, 160],
    [0.45, 0, 170, 210],
    [0.65, 240, 220, 40],
    [0.85, 230, 40, 20],
    [1.0, 255, 255, 255],
  ];
  return List<Color>.generate(256, (i) {
    final t = i / 255;
    var k = 0;
    while (k < stops.length - 2 && t > stops[k + 1][0]) {
      k++;
    }
    final a = stops[k], b = stops[k + 1];
    final u = (t - a[0]) / (b[0] - a[0]);
    int c(int j) => (a[j] + (b[j] - a[j]) * u).round();
    return Color.fromARGB(255, c(1), c(2), c(3));
  });
}();

const Color _waterfallBackground = Color.fromARGB(255, 0, 0, 24);

/// Tap or drag: the cursor; double tap: centre there.
class _PlotGestures extends StatelessWidget {
  final _SpectrumView view;
  final void Function(double fraction) onCentre;
  final Widget child;

  const _PlotGestures({
    required this.view,
    required this.onCentre,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double? fraction(Offset p) {
          const pad = _SpectrumView.sidePad;
          final w = constraints.maxWidth - 2 * pad;
          if (w <= 0) return null;
          return ((p.dx - pad) / w).clamp(0.0, 1.0);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => view.setCursor(fraction(d.localPosition)),
          onHorizontalDragUpdate: (d) =>
              view.setCursor(fraction(d.localPosition)),
          onDoubleTapDown: (d) {
            final f = fraction(d.localPosition);
            if (f != null) onCentre(f);
          },
          onDoubleTap: () {},
          child: child,
        );
      },
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  final _SpectrumView view;
  final ColorScheme scheme;

  _SpectrumPainter(this.view, this.scheme) : super(repaint: view);

  @override
  void paint(Canvas canvas, Size size) {
    const pl = _SpectrumView.sidePad, pb = _SpectrumView.bottomPad;
    final w = size.width - pl, ph = size.height - pb, pw = w - pl;
    if (pw <= 0 || ph <= 0) return;
    final floor = view.floorDb, range = view.rangeDb.toDouble();
    double yOf(double db) => ph - (db - floor) / range * ph;
    final grid = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    final label = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);

    canvas.drawRect(
      Rect.fromLTRB(pl, 0, w, ph),
      grid..style = PaintingStyle.stroke,
    );
    grid.style = PaintingStyle.fill;
    final top = floor + range;
    for (var db = (floor / 10).ceil() * 10; db <= top; db += 10) {
      final y = yOf(db.toDouble());
      canvas.drawLine(Offset(pl, y), Offset(w, y), grid);
      if (y < 12) continue;
      final unit = db + 10 > top ? ' dBm' : '';
      _text(
        canvas,
        '$db$unit',
        Offset(pl + 3, y - 1),
        label,
        align: _Align.leftBottom,
      );
    }

    final info = view.info;
    if (info == null) return;
    final lo = info.lowHz, hi = info.highHz;
    double xOf(double hz) => pl + (hz - lo) / (hi - lo) * pw;

    // the node's channel: shaded, its edges dashed, labelled at the bottom;
    // when it's out of view, an arrow to it at the edge
    final nodeHz = view.nodeHz, nodeBw = view.nodeBwHz;
    if (nodeHz != null && nodeBw != null) {
      final cl = xOf(nodeHz - nodeBw / 2), cr = xOf(nodeHz + nodeBw / 2);
      final color = scheme.tertiary;
      final edge = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      final l = math.max(cl, pl), r = math.min(cr, w);
      if (r > l) {
        canvas.drawRect(
          Rect.fromLTRB(l, 0, r, ph),
          Paint()..color = color.withValues(alpha: 0.14),
        );
      }
      for (final x in [cl, cr]) {
        if (x >= pl && x <= w) _dashed(canvas, x, 0, ph, edge);
      }
      final style = TextStyle(
        fontSize: 10,
        color: color,
        fontWeight: FontWeight.w600,
      );
      final mhz = (nodeHz / 1e6).toStringAsFixed(3);
      final bw = _formatHz(nodeBw).replaceAll(' ', '');
      final sf = view.nodeSf != null ? ' SF${view.nodeSf}' : '';
      if (cr < pl) {
        _text(
          canvas,
          '◀ $mhz',
          Offset(pl + 3, ph - 3),
          style,
          align: _Align.leftBottom,
        );
      } else if (cl > w) {
        _text(
          canvas,
          '$mhz ▶',
          Offset(w - 3, ph - 3),
          style,
          align: _Align.rightBottom,
        );
      } else {
        final x = ((cl + cr) / 2)
            .clamp(pl + 50, math.max(pl + 50, w - 50))
            .toDouble();
        _text(
          canvas,
          '$mhz $bw$sf',
          Offset(x, ph - 3),
          style,
          align: _Align.centreBottom,
        );
      }
    }

    // frequency grid
    final step = _niceStep((hi - lo) / math.max(2, pw / 70));
    final digits = step >= 1e6
        ? 0
        : step >= 1e5
        ? 1
        : step >= 1e4
        ? 2
        : 3;
    for (var f = (lo / step).ceil() * step; f <= hi; f += step) {
      final x = xOf(f);
      canvas.drawLine(Offset(x, 0), Offset(x, ph), grid);
      _text(
        canvas,
        (f / 1e6).toStringAsFixed(digits),
        Offset(x.clamp(pl + 14, w - 14), ph + 3),
        label,
        align: _Align.centreTop,
      );
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(pl, 0, pw, ph));
    final n = info.points;
    double xPt(int i) => pl + (i + 0.5) / n * pw;
    Path line(Float32List values) {
      final path = Path();
      for (var i = 0; i < n && i < values.length; i++) {
        final y = values[i].isNaN ? ph : yOf(values[i]);
        i == 0 ? path.moveTo(xPt(i), y) : path.lineTo(xPt(i), y);
      }
      return path;
    }

    final trace = view.trace;
    if (trace != null && trace.length == n) {
      final path = line(trace);
      final fill = Path.from(path)
        ..lineTo(xPt(n - 1), ph)
        ..lineTo(xPt(0), ph)
        ..close();
      canvas.drawPath(
        fill,
        Paint()..color = scheme.primary.withValues(alpha: 0.18),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = scheme.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25,
      );
    }
    final hold = view.hold;
    if (hold != null && hold.length == n) {
      canvas.drawPath(
        line(hold),
        Paint()
          ..color = scheme.tertiary.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    final peak = view.peak;
    if (peak != null && trace != null) {
      final x = xPt(peak), y = yOf(trace[peak]);
      canvas.drawPath(
        Path()
          ..moveTo(x, y - 3)
          ..lineTo(x - 5, y - 11)
          ..lineTo(x + 5, y - 11)
          ..close(),
        Paint()..color = scheme.onSurface,
      );
    }

    final cursor = view.cursor;
    if (cursor != null && trace != null && trace.length == n) {
      final i = (cursor * n).floor().clamp(0, n - 1);
      final x = pl + cursor * pw;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, ph),
        Paint()..color = scheme.onSurface.withValues(alpha: 0.6),
      );
      final value = trace[i].isNaN ? '–' : '${trace[i].toStringAsFixed(1)} dBm';
      final text =
          '${(info.frequencyOf(i) / 1e6).toStringAsFixed(3)} MHz  $value';
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: 12, color: scheme.onSurface),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final bw = tp.width + 12, bh = tp.height + 6;
      final bx = (x - bw / 2)
          .clamp(pl + 2, math.max(pl + 2, w - bw - 2))
          .toDouble();
      final box = Rect.fromLTWH(bx, 4, bw, bh);
      canvas.drawRect(
        box,
        Paint()..color = scheme.surface.withValues(alpha: 0.9),
      );
      canvas.drawRect(
        box,
        Paint()
          ..color = scheme.outline
          ..style = PaintingStyle.stroke,
      );
      tp.paint(canvas, Offset(bx + 6, 7));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) =>
      old.view != view || old.scheme != scheme;
}

class _WaterfallPainter extends CustomPainter {
  final _SpectrumView view;

  _WaterfallPainter(this.view) : super(repaint: view);

  @override
  void paint(Canvas canvas, Size size) {
    const pl = _SpectrumView.sidePad;
    final area = Rect.fromLTWH(pl, 0, size.width - 2 * pl, size.height);
    if (area.width <= 0) return;
    canvas.drawRect(area, Paint()..color = _waterfallBackground);
    final image = view.waterfall;
    if (image != null) {
      // a row per frame, a device pixel high: newest on top
      final dpr = ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio;
      final rows = math.min(
        view.waterfallFilled,
        (size.height * (dpr ?? 1)).ceil(),
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), rows.toDouble()),
        Rect.fromLTWH(pl, 0, area.width, rows / (dpr ?? 1)),
        Paint()..filterQuality = FilterQuality.none,
      );
    }
    final info = view.info, nodeHz = view.nodeHz, nodeBw = view.nodeBwHz;
    if (info != null && nodeHz != null && nodeBw != null) {
      final edge = Paint()..color = Colors.white38;
      for (final hz in [nodeHz - nodeBw / 2, nodeHz + nodeBw / 2]) {
        final x =
            pl + (hz - info.lowHz) / (info.highHz - info.lowHz) * area.width;
        if (x >= area.left && x <= area.right) {
          _dashed(canvas, x, 0, size.height, edge);
        }
      }
    }
    final cursor = view.cursor;
    if (cursor != null) {
      final x = pl + cursor * area.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()..color = Colors.white54,
      );
    }
  }

  @override
  bool shouldRepaint(_WaterfallPainter old) => old.view != view;
}

class _Footer extends StatelessWidget {
  final SpectrumStream stream;
  final _SpectrumView view;

  const _Footer({required this.stream, required this.view});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: view,
      builder: (context, _) {
        final info = stream.info;
        final peak = view.peak;
        final trace = view.trace;
        final rate = stream.rate;
        final running = stream.status == SpectrumStatus.running;
        String frames = '–';
        if (running && rate.fps > 0) {
          frames = '${rate.fps.toStringAsFixed(1)}/s';
          if (rate.lost >= 0.01) {
            frames += ' · ${l10n.spectrum_lost((rate.lost * 100).round())}';
          }
        }
        final items = <(String, String)>[
          (
            '▼',
            peak != null && info != null && trace != null
                ? '${(info.frequencyOf(peak) / 1e6).toStringAsFixed(3)} '
                      '${trace[peak].toStringAsFixed(1)} dBm'
                : '–',
          ),
          (
            l10n.spectrum_noise,
            view.noiseDb != null && running
                ? '${view.noiseDb!.toStringAsFixed(1)} dBm'
                : '–',
          ),
          (l10n.spectrum_frames, frames),
          (
            l10n.spectrum_sweeps,
            running && info != null && info.sweepsPerSecond > 0
                ? '${info.sweepsPerSecond.toStringAsFixed(0)}/s'
                : '–',
          ),
          ('RBW', info != null ? _formatHz(info.rbwHz) : '–'),
          (l10n.spectrum_step, info != null ? _formatHz(info.stepHz) : '–'),
        ];
        final labelStyle = TextStyle(
          fontSize: 11,
          color: scheme.onSurfaceVariant,
        );
        final valueStyle = MeshTheme.mono(
          fontSize: 12,
          color: scheme.onSurface,
        ).copyWith(fontFeatures: const [ui.FontFeature.tabularFigures()]);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 720
                  ? 6
                  : constraints.maxWidth >= 420
                  ? 3
                  : 2;
              final cell = constraints.maxWidth / columns;
              return Wrap(
                children: [
                  for (final (k, v) in items)
                    SizedBox(
                      width: cell,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: '$k ', style: labelStyle),
                            TextSpan(text: v, style: valueStyle),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _SettingsSheet extends StatelessWidget {
  final SpectrumStream stream;
  final _SpectrumView view;

  const _SettingsSheet({required this.stream, required this.view});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Widget row<T>(
      String title,
      T value,
      List<(T, String)> options,
      void Function(T) onChanged,
    ) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (v, text) in options)
                  ChoiceChip(
                    label: Text(text),
                    selected: v == value,
                    onSelected: (_) => onChanged(v),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row<int>(l10n.spectrum_rate, stream.intervalMs, [
              for (final ms in _intervalsMs)
                (
                  ms,
                  ms == 0
                      ? l10n.spectrum_everySweep
                      : l10n.spectrum_perSecond(1000 ~/ ms),
                ),
            ], (v) => stream.configure(intervalMs: v)),
            row<SpectrumAgg>(l10n.spectrum_aggregation, stream.agg, [
              (SpectrumAgg.max, l10n.spectrum_aggMax),
              (SpectrumAgg.mean, l10n.spectrum_aggMean),
              (SpectrumAgg.last, l10n.spectrum_aggLast),
            ], (v) => stream.configure(agg: v)),
            row<int>(l10n.spectrum_averaging, view.average, [
              for (final a in _averages) (a, a == 1 ? l10n.spectrum_off : '$a'),
            ], view.setAverage),
            row<_Hold>(l10n.spectrum_hold, view.holdMode, [
              (_Hold.off, l10n.spectrum_off),
              (_Hold.decay, l10n.spectrum_holdDecay),
              (_Hold.max, l10n.spectrum_holdMax),
            ], view.setHoldMode),
            row<int>(l10n.spectrum_range, view.rangeDb, [
              for (final r in _ranges) (r, '$r dB'),
            ], view.setRange),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.clear_all),
                label: Text(l10n.spectrum_clear),
                onPressed: view.clear,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double _niceStep(double raw) {
  final p = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (m * p >= raw) return m * p;
  }
  return 10 * p;
}

enum _Align { leftBottom, rightBottom, centreBottom, centreTop }

void _text(
  Canvas canvas,
  String text,
  Offset at,
  TextStyle style, {
  required _Align align,
}) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final offset = switch (align) {
    _Align.leftBottom => Offset(at.dx, at.dy - tp.height),
    _Align.rightBottom => Offset(at.dx - tp.width, at.dy - tp.height),
    _Align.centreBottom => Offset(at.dx - tp.width / 2, at.dy - tp.height),
    _Align.centreTop => Offset(at.dx - tp.width / 2, at.dy),
  };
  tp.paint(canvas, offset);
}

void _dashed(Canvas canvas, double x, double top, double bottom, Paint paint) {
  for (var y = top; y < bottom; y += 6) {
    canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 3, bottom)), paint);
  }
}
