import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../connector/pending_command_replies.dart';

// Spectrum stream (CMD_SPECTRUM, firmware built with SPECTRUM_STREAM on an
// nRF52 + SX1262 companion). The radio sweeps a band and the node pushes the
// levels; the mesh is paused while it runs. The node ends the session if it
// isn't renewed with another OP_START within 15 s. Protocol: see
// documentation/ble-protocol.md.

const int spectrumOpStart = 1;
const int spectrumOpStop = 2;

const int spectrumStateOff = 0;
const int spectrumStateStarting = 1;
const int spectrumStateRunning = 2;

const int spectrumStopClient = 0;
const int spectrumStopTimeout = 1;
const int spectrumStopDisconnected = 2;
const int spectrumStopRadio = 3;

const int spectrumMaxPoints = 250;
const int spectrumMinHz = 150000000;
const int spectrumMaxHz = 960000000;
const int spectrumMaxSpanHz = 32000000;

/// What a frame holds of the sweeps since the previous frame.
enum SpectrumAgg { max, mean, last }

const int _errUnsupportedCmd = 1;
const int _levelNoData = 255;
const Duration _keepalive = Duration(seconds: 5);

/// [centreHz] 0: the node's frequency. [rbwHz] 0: picked by the node from the
/// step. [intervalMs] 0: a frame per sweep.
Uint8List buildSpectrumStartFrame({
  required int centreHz,
  required int spanHz,
  required int points,
  int rbwHz = 0,
  required int intervalMs,
  required SpectrumAgg agg,
}) {
  final writer = BufferWriter()
    ..writeByte(cmdSpectrum)
    ..writeByte(spectrumOpStart)
    ..writeUInt32LE(centreHz)
    ..writeUInt32LE(spanHz)
    ..writeByte(points)
    ..writeUInt32LE(rbwHz)
    ..writeUInt16LE(intervalMs)
    ..writeByte(agg.index);
  return writer.toBytes();
}

Uint8List buildSpectrumStopFrame() =>
    Uint8List.fromList([cmdSpectrum, spectrumOpStop]);

/// RESP_SPECTRUM_INFO: the session as the node runs it.
class SpectrumInfo {
  final int state;
  final int config;
  final int points;
  final int firstHz;
  final int stepHz;
  final int rbwHz;
  final int intervalMs;
  final int agg;

  /// Since the node's previous reply; 0 until known.
  final double sweepsPerSecond;

  const SpectrumInfo({
    required this.state,
    required this.config,
    required this.points,
    required this.firstHz,
    required this.stepHz,
    required this.rbwHz,
    required this.intervalMs,
    required this.agg,
    required this.sweepsPerSecond,
  });

  /// Edges of the swept band: each point is the centre of its step.
  double get lowHz => firstHz - stepHz / 2;
  double get highHz => lowHz + stepHz * points;
  int frequencyOf(int point) => firstHz + point * stepHz;

  static SpectrumInfo? parse(Uint8List frame) {
    if (frame.length < 21 || frame[0] != respCodeSpectrumInfo) return null;
    final r = BufferReader(frame)..skipBytes(1);
    return SpectrumInfo(
      state: r.readUInt8(),
      config: r.readUInt8(),
      points: r.readUInt8(),
      firstHz: r.readUInt32LE(),
      stepHz: r.readUInt32LE(),
      rbwHz: r.readUInt32LE(),
      intervalMs: r.readUInt16LE(),
      agg: r.readUInt8(),
      sweepsPerSecond: r.readUInt16LE() / 10,
    );
  }
}

enum SpectrumStatus {
  idle,
  starting,
  running,

  /// The firmware has no spectrum stream.
  unsupported,

  /// The node refused the settings, or ended the session (see stopReason).
  failed,
}

/// Runs a spectrum session on the connected node while [running], renewing
/// it, and turns its pushes into [frames] of dBm per point (NaN: no reading).
class SpectrumStream extends ChangeNotifier {
  SpectrumStream(this._connector) {
    _sub = _connector.receivedFrames.listen(handleFrame);
  }

  final MeshCoreConnector _connector;
  late final StreamSubscription<Uint8List> _sub;
  final StreamController<Float32List> _frames =
      StreamController<Float32List>.broadcast();
  Timer? _keepaliveTimer;
  bool _disposed = false;

  int _centreHz = 0;
  int _spanHz = 2000000;
  int _points = spectrumMaxPoints;
  int _intervalMs = 50;
  SpectrumAgg _agg = SpectrumAgg.max;
  bool _running = false;

  SpectrumStatus _status = SpectrumStatus.idle;
  SpectrumInfo? _info;
  int? _stopReason;
  int? _errCode;

  bool _sending = false;
  bool _sendAgain = false;

  Uint8List _levels = Uint8List(spectrumMaxPoints);
  int _assembling = -1;
  int _lastFrameNo = -1;
  final List<({DateTime at, int lost})> _recent = [];

  /// 0: the node's frequency.
  int get centreHz => _centreHz;
  int get spanHz => _spanHz;
  int get points => _points;
  int get intervalMs => _intervalMs;
  SpectrumAgg get agg => _agg;
  bool get running => _running;
  SpectrumStatus get status => _status;
  SpectrumInfo? get info => _info;

  /// spectrumStop* when the node ended the session by itself.
  int? get stopReason => _stopReason;

  /// The firmware's error code for a refused command, or the RadioLib error
  /// for spectrumStopRadio.
  int? get errCode => _errCode;

  Stream<Float32List> get frames => _frames.stream;

  /// Frames received per second, and the share of frames lost on the way
  /// (0..1), over the last 2 s.
  ({double fps, double lost}) get rate {
    if (_recent.length < 2) return (fps: 0, lost: 0);
    final span = _recent.last.at.difference(_recent.first.at);
    if (span.inMilliseconds <= 0) return (fps: 0, lost: 0);
    final got = _recent.length - 1;
    final lost = _recent.skip(1).fold<int>(0, (a, e) => a + e.lost);
    return (fps: got * 1000 / span.inMilliseconds, lost: lost / (lost + got));
  }

  /// Applies the settings; a running session takes them at once.
  void configure({
    int? centreHz,
    int? spanHz,
    int? points,
    int? intervalMs,
    SpectrumAgg? agg,
  }) {
    if (points != null) _points = points.clamp(16, spectrumMaxPoints);
    _spanHz = (spanHz ?? _spanHz).clamp(_points * 100, spectrumMaxSpanHz);
    if (centreHz != null) _centreHz = centreHz;
    if (_centreHz != 0) {
      _centreHz = _centreHz.clamp(
        spectrumMinHz + _spanHz ~/ 2,
        spectrumMaxHz - _spanHz ~/ 2,
      );
    }
    if (intervalMs != null) _intervalMs = intervalMs;
    if (agg != null) _agg = agg;
    notifyListeners();
    if (_running) unawaited(_sendStart());
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _stopReason = null;
    _errCode = null;
    _status = SpectrumStatus.starting;
    _recent.clear();
    _lastFrameNo = -1;
    notifyListeners();
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(_keepalive, (_) => _sendStart());
    await _sendStart();
  }

  /// Ends the session: the node gives the radio back to the mesh.
  Future<void> stop() async {
    if (!_running) return;
    _end(SpectrumStatus.idle);
    if (!_connector.isConnected) return;
    try {
      await _connector.sendFrame(buildSpectrumStopFrame());
    } catch (_) {
      // gone: the node ends the session by itself
    }
  }

  void _end(SpectrumStatus status) {
    _running = false;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _status = status;
    _assembling = -1;
    if (!_disposed) notifyListeners();
  }

  Future<void> _sendStart() async {
    if (!_running || !_connector.isConnected) return;
    if (_sending) {
      _sendAgain = true;
      return;
    }
    _sending = true;
    try {
      do {
        _sendAgain = false;
        await _connector.sendFrame(
          buildSpectrumStartFrame(
            centreHz: _centreHz,
            spanHz: _spanHz,
            points: _points,
            intervalMs: _intervalMs,
            agg: _agg,
          ),
          waitForGenericAck: true,
        );
      } while (_sendAgain && _running);
    } on FirmwareCommandException catch (e) {
      if (_running) {
        _errCode = e.errCode;
        _end(
          e.errCode == _errUnsupportedCmd
              ? SpectrumStatus.unsupported
              : SpectrumStatus.failed,
        );
      }
    } catch (_) {
      // a lost reply or link: the next renewal tries again
    } finally {
      _sending = false;
    }
  }

  @visibleForTesting
  void handleFrame(Uint8List frame) {
    if (frame.isEmpty || _disposed) return;
    switch (frame[0]) {
      case respCodeSpectrumInfo:
        final info = SpectrumInfo.parse(frame);
        if (info == null || !_running) return;
        if (info.config != _info?.config) _assembling = -1;
        _info = info;
        if (info.state == spectrumStateRunning) {
          _status = SpectrumStatus.running;
        } else if (info.state == spectrumStateStarting) {
          _status = SpectrumStatus.starting;
        }
        notifyListeners();
      case pushCodeSpectrumFrame:
        _handleChunk(frame);
      case pushCodeSpectrumStopped:
        if (!_running || frame.length < 2) return;
        _stopReason = frame[1];
        _errCode = frame.length >= 4
            ? ByteData.sublistView(frame, 2, 4).getInt16(0, Endian.little)
            : null;
        _end(SpectrumStatus.failed);
    }
  }

  void _handleChunk(Uint8List frame) {
    final info = _info;
    if (!_running || info == null || frame.length < 5) return;
    if (frame[1] != info.config) return; // of earlier settings
    final frameNo = frame[2], first = frame[3];
    final n = math.min(frame.length - 4, info.points - first);
    if (n <= 0) return;
    if (first == 0 || frameNo != _assembling) {
      if (_levels.length < info.points) _levels = Uint8List(info.points);
      _levels.fillRange(0, info.points, _levelNoData);
      _assembling = frameNo;
    }
    _levels.setRange(first, first + n, frame, 4);
    if (first + n < info.points) return;

    final dbm = Float32List(info.points);
    for (var i = 0; i < info.points; i++) {
      final l = _levels[i];
      dbm[i] = l == _levelNoData ? double.nan : -l / 2;
    }
    _assembling = -1;
    _countFrame(frameNo);
    if (_status != SpectrumStatus.running) {
      _status = SpectrumStatus.running;
      notifyListeners();
    }
    _frames.add(dbm);
  }

  void _countFrame(int frameNo) {
    final lost = _lastFrameNo < 0 ? 0 : (frameNo - _lastFrameNo - 1) & 0xFF;
    _lastFrameNo = frameNo;
    final now = DateTime.now();
    _recent.add((at: now, lost: lost));
    while (_recent.length > 2 &&
        now.difference(_recent.first.at) > const Duration(seconds: 2)) {
      _recent.removeAt(0);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    _keepaliveTimer?.cancel();
    unawaited(_sub.cancel());
    unawaited(_frames.close());
    super.dispose();
  }
}
