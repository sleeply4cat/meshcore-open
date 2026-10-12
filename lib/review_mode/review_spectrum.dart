import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../connector/meshcore_protocol.dart';
import '../services/spectrum_stream.dart';

/// A simulated spectrum session (CMD_SPECTRUM) for review mode: noise, a few
/// steady carriers, and LoRa packets now and then on the node's channel.
class ReviewSpectrum {
  ReviewSpectrum({required this.emit, math.Random? random})
    : _random = random ?? math.Random(1);

  final void Function(Uint8List frame) emit;
  final math.Random _random;

  Timer? _timer;
  DateTime _renewedAt = DateTime.now();
  int _config = 0;
  int _frameNo = 0;
  int _points = 0;
  int _firstHz = 0;
  int _stepHz = 0;
  int _rbwHz = 0;
  int _intervalMs = 0;
  int _agg = 0;
  int _nodeHz = 0;
  int _nodeBwHz = 0;
  DateTime? _packetEnd;
  DateTime _nextPacket = DateTime.now();

  bool get running => _timer != null;

  /// Returns the reply, as the firmware would.
  Uint8List handle(
    Uint8List frame, {
    required int nodeHz,
    required int nodeBwHz,
  }) {
    if (frame.length >= 2 && frame[1] == spectrumOpStop) {
      _stop(null);
      return _info();
    }
    if (frame.length < 18 || frame[1] != spectrumOpStart) {
      return Uint8List.fromList([respCodeErr, 6]);
    }
    final data = ByteData.sublistView(frame);
    var centre = data.getUint32(2, Endian.little);
    final span = data.getUint32(6, Endian.little);
    final points = frame[10];
    final rbw = data.getUint32(11, Endian.little);
    final interval = data.getUint16(15, Endian.little);
    final agg = frame[17];
    if (centre == 0) centre = nodeHz;
    if (points < 16 ||
        points > spectrumMaxPoints ||
        span < points * 100 ||
        span > spectrumMaxSpanHz ||
        centre < spectrumMinHz + span ~/ 2 ||
        centre > spectrumMaxHz - span ~/ 2 ||
        (interval != 0 && interval < 10) ||
        interval > 5000 ||
        agg > SpectrumAgg.last.index) {
      return Uint8List.fromList([respCodeErr, 6]);
    }
    final step = span ~/ points;
    final first = centre - span ~/ 2 + step ~/ 2;
    final rbwHz = rbw != 0 ? rbw : math.max(4800, step * 5 ~/ 2);
    if (first != _firstHz ||
        step != _stepHz ||
        points != _points ||
        rbwHz != _rbwHz) {
      _config = (_config + 1) & 0xFF;
    }
    _firstHz = first;
    _stepHz = step;
    _points = points;
    _rbwHz = rbwHz;
    _intervalMs = interval;
    _agg = agg;
    _nodeHz = nodeHz;
    _nodeBwHz = nodeBwHz;
    _renewedAt = DateTime.now();
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: interval == 0 ? 30 : interval),
      (_) => _tick(),
    );
    return _info();
  }

  Uint8List _info() {
    final w = BufferWriter()..writeByte(respCodeSpectrumInfo);
    if (!running) {
      w.writeBytes(Uint8List(20));
      return w.toBytes();
    }
    w
      ..writeByte(spectrumStateRunning)
      ..writeByte(_config)
      ..writeByte(_points)
      ..writeUInt32LE(_firstHz)
      ..writeUInt32LE(_stepHz)
      ..writeUInt32LE(_rbwHz)
      ..writeUInt16LE(_intervalMs)
      ..writeByte(_agg)
      // a point takes ~1.6 ms / RBW in kHz
      ..writeUInt16LE((10 * 1000 / (_points * 1600 / _rbwHz)).round());
    return w.toBytes();
  }

  void _stop(int? reason) {
    _timer?.cancel();
    _timer = null;
    if (reason != null) {
      emit(Uint8List.fromList([pushCodeSpectrumStopped, reason, 0, 0]));
    }
  }

  void _tick() {
    final now = DateTime.now();
    if (now.difference(_renewedAt) > const Duration(seconds: 15)) {
      _stop(spectrumStopTimeout);
      return;
    }
    if (_packetEnd != null && now.isAfter(_packetEnd!)) _packetEnd = null;
    if (_packetEnd == null && now.isAfter(_nextPacket)) {
      _packetEnd = now.add(Duration(milliseconds: 300 + _random.nextInt(1200)));
      _nextPacket = _packetEnd!.add(
        Duration(milliseconds: 1000 + _random.nextInt(4000)),
      );
    }

    final levels = Uint8List(_points);
    for (var i = 0; i < _points; i++) {
      final hz = _firstHz + i * _stepHz;
      // noise, in power, with the RBW's share of it
      var mw = _dbmToMw(-121 + 10 * math.log(_rbwHz / 7300) / math.ln10);
      mw *= 0.6 + _random.nextDouble() * 0.8;
      mw += _carrier(hz, _nodeHz - 1200000, -95);
      mw += _carrier(hz, _nodeHz + 2600000, -80);
      if (_packetEnd != null && (hz - _nodeHz).abs() <= _nodeBwHz / 2) {
        mw += _dbmToMw(-88 + _random.nextDouble() * 3);
      }
      final dbm = 10 * math.log(mw) / math.ln10;
      levels[i] = (-dbm * 2).round().clamp(0, 254);
    }
    _frameNo = (_frameNo + 1) & 0xFF;
    const chunk = maxFrameSize - 4;
    for (var first = 0; first < _points; first += chunk) {
      final n = math.min(chunk, _points - first);
      emit(
        Uint8List.fromList([
          pushCodeSpectrumFrame,
          _config,
          _frameNo,
          first,
          ...levels.sublist(first, first + n),
        ]),
      );
    }
  }

  /// A steady narrow signal, as seen through the RBW.
  double _carrier(int hz, int at, double dbm) {
    final off = (hz - at).abs() / math.max(_rbwHz / 2, _stepHz / 2);
    return off >= 1 ? 0 : _dbmToMw(dbm) * (1 - off * off);
  }

  static double _dbmToMw(double dbm) => math.pow(10, dbm / 10).toDouble();

  void dispose() => _stop(null);
}
