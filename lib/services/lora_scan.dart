import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../connector/pending_command_replies.dart';
import '../connector/raw_packet.dart';

// LoRa channel scan (CMD_LORA_SCAN, nRF52 + SX1262 companions): the node runs
// CAD over a band and reports each detection; the app counts them, picks the
// candidates and keeps the node going round them between passes (hot points),
// receiving after each detection there, so that most candidates are heard
// during the scan itself. Protocol: see documentation/ble-protocol.md.

const int loraScanOpScan = 1;
const int loraScanOpListen = 2;
const int loraScanOpStop = 3;
const int loraScanOpHot = 4;

const int loraScanDoneComplete = 0;
const int loraScanDoneStopped = 1;
const int loraScanDoneDisconnected = 2;
const int loraScanDoneRadio = 3;

/// The radio's LoRa bandwidths, by the index the protocol uses.
const List<double> loraBandwidthsKhz = [
  7.8,
  10.4,
  15.6,
  20.8,
  31.25,
  41.7,
  62.5,
  125,
  250,
  500,
];

int loraBandwidthHz(int index) => (loraBandwidthsKhz[index] * 1000).round();

/// [LoraScanSettings.stepHz]: a step of the bandwidth, without overlap.
const int stepBandwidth = 1;

/// Hot points the node takes (three per candidate: its peak and an eighth of
/// its bandwidth either side).
const int maxHotPoints = 24;

const int syncWordMeshCore = 0x12;

class LoraScanSettings {
  final int fromHz;
  final int toHz;

  /// 0: half of each bandwidth; [stepBandwidth]: each bandwidth.
  final int stepHz;
  final Set<int> bandwidths;
  final Set<int> spreadingFactors;
  final int cadSymbols;

  /// detPeak = SF + this; 0: the firmware's default for [cadSymbols].
  final int detPeakMargin;
  final int durationSeconds;

  /// On the hot points after each pass; 0: none.
  final int hotSeconds;
  final int listenSeconds;
  final int syncWord;

  const LoraScanSettings({
    required this.fromHz,
    required this.toHz,
    this.stepHz = 0,
    this.bandwidths = const {6, 7, 8},
    this.spreadingFactors = const {7, 8, 9, 10},
    this.cadSymbols = 2,
    this.detPeakMargin = 0,
    this.durationSeconds = 600,
    this.hotSeconds = 10,
    this.listenSeconds = 120,
    this.syncWord = syncWordMeshCore,
  });

  LoraScanSettings copyWith({
    int? fromHz,
    int? toHz,
    int? stepHz,
    Set<int>? bandwidths,
    Set<int>? spreadingFactors,
    int? cadSymbols,
    int? detPeakMargin,
    int? durationSeconds,
    int? hotSeconds,
    int? listenSeconds,
    int? syncWord,
  }) {
    return LoraScanSettings(
      fromHz: fromHz ?? this.fromHz,
      toHz: toHz ?? this.toHz,
      stepHz: stepHz ?? this.stepHz,
      bandwidths: bandwidths ?? this.bandwidths,
      spreadingFactors: spreadingFactors ?? this.spreadingFactors,
      cadSymbols: cadSymbols ?? this.cadSymbols,
      detPeakMargin: detPeakMargin ?? this.detPeakMargin,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      hotSeconds: hotSeconds ?? this.hotSeconds,
      listenSeconds: listenSeconds ?? this.listenSeconds,
      syncWord: syncWord ?? this.syncWord,
    );
  }

  bool get isValid =>
      fromHz >= 150000000 &&
      toHz <= 960000000 &&
      toHz >= fromHz &&
      bandwidths.isNotEmpty &&
      spreadingFactors.isNotEmpty;

  int stepFor(int bandwidth) => switch (stepHz) {
    0 => loraBandwidthHz(bandwidth) ~/ 2,
    stepBandwidth => loraBandwidthHz(bandwidth),
    _ => stepHz,
  };

  List<int> pointsFor(int bandwidth) {
    final step = stepFor(bandwidth);
    return [for (var f = fromHz; f <= toHz; f += step) f];
  }

  /// One pass over every point, bandwidth and SF; a CAD takes about
  /// (symbols + 1) symbol times plus ~5 ms (measured on an SX1262).
  Duration get passDuration {
    var us = 0.0;
    for (final bw in bandwidths) {
      final points = pointsFor(bw).length;
      for (final sf in spreadingFactors) {
        final symbolUs = (1 << sf) / loraBandwidthsKhz[bw] * 1000;
        us += points * ((cadSymbols + 1) * symbolUs + 5000);
      }
    }
    return Duration(microseconds: us.round());
  }
}

Uint8List buildLoraScanFrame(LoraScanSettings s) {
  final writer = BufferWriter()
    ..writeByte(cmdLoraScan)
    ..writeByte(loraScanOpScan)
    ..writeUInt32LE(s.fromHz)
    ..writeUInt32LE(s.toHz)
    ..writeUInt32LE(s.stepHz)
    ..writeUInt16LE(s.bandwidths.fold(0, (m, b) => m | (1 << b)))
    ..writeByte(s.spreadingFactors.fold(0, (m, sf) => m | (1 << (sf - 5))))
    ..writeByte(s.cadSymbols)
    ..writeByte(s.detPeakMargin)
    ..writeByte(0)
    ..writeUInt16LE(s.durationSeconds);
  return writer.toBytes();
}

/// OP_SCAN_HOT: [points] to go round for [ms] after each pass, receiving with
/// [syncWord] after each detection there.
Uint8List buildLoraScanHotFrame(
  List<(int freqHz, int bandwidth, int sf)> points, {
  required int ms,
  required int syncWord,
}) {
  final writer = BufferWriter()
    ..writeByte(cmdLoraScan)
    ..writeByte(loraScanOpHot)
    ..writeUInt16LE(ms)
    ..writeByte(1)
    ..writeByte(syncWord)
    ..writeByte(0)
    ..writeByte(points.length);
  for (final (f, bw, sf) in points) {
    writer
      ..writeUInt32LE(f)
      ..writeByte(bw)
      ..writeByte(sf);
  }
  return writer.toBytes();
}

Uint8List buildLoraListenFrame({
  required int freqHz,
  required int bandwidth,
  required int sf,
  required int syncWord,
  required int durationSeconds,
}) {
  final writer = BufferWriter()
    ..writeByte(cmdLoraScan)
    ..writeByte(loraScanOpListen)
    ..writeUInt32LE(freqHz)
    ..writeByte(bandwidth)
    ..writeByte(sf)
    ..writeByte(syncWord)
    ..writeUInt16LE(durationSeconds);
  return writer.toBytes();
}

Uint8List buildLoraScanStopFrame() =>
    Uint8List.fromList([cmdLoraScan, loraScanOpStop]);

/// What a MeshCore packet header says, from a raw LoRa payload.
class MeshCoreHeader {
  final int routeType;
  final int payloadType;
  final int version;
  final int hops;
  final int hashWidth;
  final String? advertName;
  final int? advertType;

  const MeshCoreHeader({
    required this.routeType,
    required this.payloadType,
    required this.version,
    required this.hops,
    required this.hashWidth,
    this.advertName,
    this.advertType,
  });

  /// A version and type MeshCore sends, and a path that fits.
  bool get plausible => version == 0 && payloadType <= 0x0B && hashWidth <= 3;

  static MeshCoreHeader? parse(Uint8List p) {
    if (p.length < 2) return null;
    final header = p[0];
    final route = header & 0x03;
    var i = 1 + ((route == 0 || route == 3) ? 4 : 0); // transport codes
    if (i >= p.length) return null;
    final pathLen = p[i++];
    final width = decodePathHashWidth(pathLen);
    i += decodePathByteLen(pathLen);
    if (i > p.length) return null;
    final type = (header >> 2) & 0x0F;
    String? name;
    int? advType;
    // ADVERT: public key (32), timestamp (4), signature (64), then app data
    if (type == payloadTypeADVERT && p.length > i + 100) {
      final app = p.sublist(i + 100);
      final flags = app[0];
      advType = flags & 0x0F;
      var j = 1;
      if (flags & 0x10 != 0) j += 8; // location
      if (flags & 0x20 != 0) j += 2;
      if (flags & 0x40 != 0) j += 2;
      if (flags & 0x80 != 0 && j < app.length) {
        final end = app.indexOf(0, j);
        name = utf8.decode(
          app.sublist(j, end < 0 ? app.length : end),
          allowMalformed: true,
        );
      }
    }
    return MeshCoreHeader(
      routeType: route,
      payloadType: type,
      version: header >> 6,
      hops: pathLen == 0xFF ? 0 : pathLen & 63,
      hashWidth: width,
      advertName: name,
      advertType: advType,
    );
  }
}

/// PUSH_LORA_SCAN_PACKET.
class LoraScanPacket {
  final int tunedHz;

  /// Tuned minus the sender's frequency.
  final int frequencyErrorHz;
  final int rssi;
  final double snr;
  final int codingRate;
  final bool crcOk;
  final bool hasCrc;
  final int bandwidth;
  final int sf;
  final int length;
  final Uint8List payload;

  const LoraScanPacket({
    required this.tunedHz,
    required this.frequencyErrorHz,
    required this.rssi,
    required this.snr,
    required this.codingRate,
    required this.crcOk,
    required this.hasCrc,
    required this.bandwidth,
    required this.sf,
    required this.length,
    required this.payload,
  });

  int get senderHz => tunedHz - frequencyErrorHz;

  /// A header with a payload CRC, and the CRC good: a real packet (a header
  /// alone now and then passes by chance).
  bool get valid => hasCrc && crcOk;

  MeshCoreHeader? get meshCore => valid ? MeshCoreHeader.parse(payload) : null;

  static LoraScanPacket? parse(Uint8List f) {
    if (f.length < 16 || f[0] != pushCodeLoraScanPacket) return null;
    final r = BufferReader(f)..skipBytes(1);
    final tuned = r.readUInt32LE();
    final fei = r.readInt32LE();
    final rssi = r.readInt8();
    final snr = r.readInt8() / 4;
    final cr = r.readUInt8();
    final flags = r.readUInt8();
    final bw = r.readUInt8();
    final sf = r.readUInt8();
    final length = r.readUInt8();
    return LoraScanPacket(
      tunedHz: tuned,
      frequencyErrorHz: fei,
      rssi: rssi,
      snr: snr,
      codingRate: cr,
      crcOk: flags & 1 != 0,
      hasCrc: flags & 2 != 0,
      bandwidth: bw,
      sf: sf,
      length: length,
      payload: r.readRemainingBytes(),
    );
  }
}

class LoraListenResult {
  final int freqHz;
  final int bandwidth;
  final int sf;
  final List<LoraScanPacket> packets = [];
  int preambles = 0;
  int headerErrors = 0;
  bool done = false;

  /// Caught during the scan, on its hot points (not a listen of its own).
  final bool duringScan;

  /// A listen on a frequency corrected after another.
  bool retry = false;

  LoraListenResult(
    this.freqHz,
    this.bandwidth,
    this.sf, {
    this.duringScan = false,
  });

  List<LoraScanPacket> get valid => packets.where((p) => p.valid).toList();

  bool get decoded => packets.any((p) => p.valid);

  bool get isMeshCore => valid.any((p) => p.meshCore?.plausible ?? false);

  /// The senders' frequency: the median over the good packets.
  int? get senderHz {
    final hz = valid.map((p) => p.senderHz).toList()..sort();
    return hz.isEmpty ? null : hz[hz.length ~/ 2];
  }

  int? get codingRate => valid.isEmpty ? null : valid.first.codingRate;
}

/// A place in the band where CAD fires more than its false-alarm level.
class LoraCandidate {
  final int freqHz;
  final int bandwidth;
  final int sf;

  /// Detections per pass, and above the false-alarm level of its row.
  final double rate;
  final double excess;

  /// Other settings that fired at the same place, less often; and, after a
  /// listen that heard headers but no good packet, these settings again on a
  /// corrected frequency.
  final List<LoraCandidate> alternatives;

  /// Packets caught on its hot points during the scan.
  LoraListenResult? caught;

  /// The latest listen on these settings.
  LoraListenResult? result;

  /// Made after another listen, on its corrected frequency.
  bool retry = false;

  LoraCandidate({
    required this.freqHz,
    required this.bandwidth,
    required this.sf,
    required this.rate,
    required this.excess,
    List<LoraCandidate>? alternatives,
  }) : alternatives = alternatives ?? [];

  /// What decoded something: packets caught during the scan, or a listen on
  /// these or the alternative settings; else the latest listen, or the
  /// packets caught (all broken).
  LoraListenResult? get best {
    if (caught?.decoded ?? false) return caught;
    for (final c in [this, ...alternatives]) {
      if (c.result?.decoded ?? false) return c.result;
    }
    return result ?? caught;
  }

  bool get heard => best?.decoded ?? false;

  /// The place, and an eighth of the bandwidth either side.
  List<(int, int, int)> get hotPoints {
    final eighth = loraBandwidthHz(bandwidth) ~/ 8;
    return [
      for (final d in [-eighth, 0, eighth]) (freqHz + d, bandwidth, sf),
    ];
  }

  bool covers(int freqHz, int bandwidth, int sf) =>
      bandwidth == this.bandwidth &&
      sf == this.sf &&
      (freqHz - this.freqHz).abs() <= loraBandwidthHz(bandwidth) / 2;
}

enum LoraScanState { idle, scanning, listening }

/// Runs scans and listens on the connected node and keeps their results.
class LoraScanController extends ChangeNotifier {
  LoraScanController(this._connector, this._settings) {
    _sub = _connector.receivedFrames.listen(handleFrame);
  }

  final MeshCoreConnector _connector;
  late final StreamSubscription<Uint8List> _sub;
  bool _disposed = false;

  LoraScanSettings _settings;
  LoraScanSettings? _scanned;
  LoraScanState _state = LoraScanState.idle;
  int _passes = 0;
  DateTime? _startedAt;
  int? _error;
  int? _doneReason;
  final Map<(int, int), Map<int, int>> _hits = {};
  int _hotHits = 0;
  final List<LoraScanPacket> _caught = [];
  List<LoraCandidate> _candidates = [];
  String _hotKey = '';
  int _hotNext = 0; // where the next hot points start, round the candidates
  LoraListenResult? _listening;
  final List<LoraCandidate> _queue = [];
  LoraCandidate? _owner; // of the listen on
  bool _stoppedForPacket = false; // the listen on decoded a packet
  Completer<void>? _idle; // completes when the scan or listen on ends

  LoraScanSettings get settings => _settings;

  /// The settings of the latest scan, which the counts belong to.
  LoraScanSettings? get scanned => _scanned;
  LoraScanState get state => _state;
  bool get busy => _state != LoraScanState.idle;
  int get passes => _passes;
  DateTime? get startedAt => _startedAt;

  /// Detections on the hot points, and packets caught there.
  int get hotHits => _hotHits;
  int get caughtPackets => _caught.length;

  /// A firmware error code for a refused command, or a RadioLib error.
  int? get error => _error;
  int? get doneReason => _doneReason;
  List<LoraCandidate> get candidates => _candidates;
  LoraListenResult? get listening => _listening;

  /// Detections per (bandwidth, SF) row, per point.
  int hitsAt(int bandwidth, int sf, int freqHz) =>
      _hits[(bandwidth, sf)]?[freqHz] ?? 0;

  set settings(LoraScanSettings s) {
    _settings = s;
    notifyListeners();
  }

  Future<void> startScan() async {
    if (busy) return;
    beginScan();
    await _send(buildLoraScanFrame(_settings));
  }

  /// Resets the counts for a scan with the current settings.
  @visibleForTesting
  void beginScan() {
    _hits.clear();
    _caught.clear();
    _hotHits = 0;
    _hotKey = '';
    _hotNext = 0;
    _candidates = [];
    _passes = 0;
    _error = null;
    _doneReason = null;
    _scanned = _settings;
    _startedAt = DateTime.now();
    _state = LoraScanState.scanning;
    notifyListeners();
  }

  /// Listens on [c] (and on its alternatives, while nothing is decoded).
  Future<void> verify(LoraCandidate c) => verifyAll([c]);

  Future<void> verifyAll(List<LoraCandidate> list) async {
    if (busy) return;
    for (final c in list) {
      c.alternatives.removeWhere((a) => a.retry);
      for (final t in [c, ...c.alternatives]) {
        t.result = null;
      }
    }
    _queue
      ..clear()
      ..addAll(list);
    await _listenNext();
  }

  Future<void> stop() async {
    _queue.clear();
    if (!busy || !_connector.isConnected) return;
    try {
      await _connector.sendFrame(buildLoraScanStopFrame());
    } catch (_) {
      // the node ends it at its time limit anyway
    }
  }

  /// Stops the scan or listen on and waits until the node has given the
  /// radio back to the mesh (a few seconds at most).
  Future<void> stopAndWait() async {
    if (!busy) return;
    final idle = _idle ??= Completer<void>();
    await stop();
    try {
      await idle.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _state = LoraScanState.idle;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _listenNext() async {
    if (_queue.isEmpty) return;
    final c = _queue.removeAt(0);
    // the first of the candidate's settings not tried yet
    final next = [c, ...c.alternatives].firstWhere((t) => t.result == null);
    final result = LoraListenResult(next.freqHz, next.bandwidth, next.sf)
      ..retry = next.retry;
    next.result = result;
    _listening = result;
    _owner = c;
    _stoppedForPacket = false;
    _error = null;
    _state = LoraScanState.listening;
    notifyListeners();
    await _send(
      buildLoraListenFrame(
        freqHz: next.freqHz,
        bandwidth: next.bandwidth,
        sf: next.sf,
        syncWord: _settings.syncWord,
        durationSeconds: _settings.listenSeconds,
      ),
    );
  }

  /// The hot points: around candidates not heard yet, the next ones round
  /// the list each pass, so that each gets its turn whatever its rank.
  Future<void> _updateHotPoints() async {
    final s = _scanned;
    if (s == null || s.hotSeconds == 0 || _state != LoraScanState.scanning) {
      return;
    }
    final open = _candidates.where((c) => !c.heard).toList();
    final points = <(int, int, int)>[];
    final take = math.min(open.length, maxHotPoints ~/ 3);
    for (var i = 0; i < take; i++) {
      points.addAll(open[(_hotNext + i) % open.length].hotPoints);
    }
    if (open.isNotEmpty) _hotNext = (_hotNext + take) % open.length;
    final key = points.join();
    if (key == _hotKey) return;
    _hotKey = key;
    try {
      await _connector.sendFrame(
        buildLoraScanHotFrame(
          points,
          ms: points.isEmpty ? 0 : s.hotSeconds * 1000,
          syncWord: s.syncWord,
        ),
        waitForGenericAck: true,
      );
    } catch (_) {
      _hotKey = ''; // the scan ended meanwhile, or the reply got lost
    }
  }

  /// Headers but no good packet: the frequency is likely off by more than
  /// the receiver takes (BW/4). Headers carry the frequency error even with a
  /// broken payload: listen again there; with header errors only, try a
  /// quarter bandwidth either side. Once per listen.
  void _retryAround(LoraCandidate owner, LoraListenResult r) {
    if (r.retry) return;
    final headers =
        r.packets.where((p) => p.hasCrc).map((p) => p.senderHz).toList()
          ..sort();
    final quarter = loraBandwidthHz(r.bandwidth) ~/ 4;
    final freqs = headers.isNotEmpty
        ? [headers[headers.length ~/ 2]]
        : r.headerErrors >= 3
        ? [r.freqHz + quarter, r.freqHz - quarter]
        : const <int>[];
    for (final f in freqs.reversed) {
      if ((f - r.freqHz).abs() < 2000) continue;
      owner.alternatives.insert(
        0,
        LoraCandidate(
          freqHz: f,
          bandwidth: r.bandwidth,
          sf: r.sf,
          rate: owner.rate,
          excess: owner.excess,
        )..retry = true,
      );
    }
  }

  Future<void> _stopListen() async {
    try {
      await _connector.sendFrame(buildLoraScanStopFrame());
    } catch (_) {
      // the listen ends at its time limit anyway
    }
  }

  Future<void> _send(Uint8List frame) async {
    try {
      await _connector.sendFrame(frame, waitForGenericAck: true);
    } on FirmwareCommandException catch (e) {
      _error = e.errCode;
      _queue.clear();
      _state = LoraScanState.idle;
      if (!_disposed) notifyListeners();
    } catch (_) {
      _queue.clear();
      _state = LoraScanState.idle;
      if (!_disposed) notifyListeners();
    }
  }

  /// The candidates. Networks heard during the scan come first and stay,
  /// whatever their counts do later: one per (bandwidth, SF) and sender
  /// frequency (within a quarter bandwidth), at the senders' median frequency,
  /// with the counts of the candidate found there, if any. Broken packets go to
  /// the candidates they fell on.
  void _refreshCandidates() {
    final counted = findCandidates();
    final heard = <LoraCandidate>[];
    final groups = <List<LoraScanPacket>>[];
    for (final p in _caught.where((p) => p.valid)) {
      final quarter = loraBandwidthHz(p.bandwidth) / 4;
      final g = groups.where(
        (g) =>
            g.first.bandwidth == p.bandwidth &&
            g.first.sf == p.sf &&
            (g.first.senderHz - p.senderHz).abs() <= quarter,
      );
      if (g.isEmpty) {
        groups.add([p]);
      } else {
        g.first.add(p);
      }
    }
    for (final g in groups) {
      final hz = g.map((p) => p.senderHz).toList()..sort();
      final freq = hz[hz.length ~/ 2];
      final bw = g.first.bandwidth, sf = g.first.sf;
      final match = counted.where((c) => c.covers(freq, bw, sf)).firstOrNull;
      counted.remove(match);
      heard.add(
        LoraCandidate(
            freqHz: freq,
            bandwidth: bw,
            sf: sf,
            rate: match?.rate ?? 0,
            excess: match?.excess ?? 0,
            alternatives: match?.alternatives,
          )
          ..caught = (LoraListenResult(freq, bw, sf, duringScan: true)
            ..packets.addAll(g)
            ..done = true),
      );
    }
    for (final c in counted) {
      final broken = _caught.where(
        (p) => !p.valid && c.covers(p.tunedHz, p.bandwidth, p.sf),
      );
      if (broken.isEmpty) continue;
      c.caught = LoraListenResult(c.freqHz, c.bandwidth, c.sf, duringScan: true)
        ..packets.addAll(broken)
        ..done = true;
    }
    _candidates = [...heard, ...counted];
  }

  @visibleForTesting
  void handleFrame(Uint8List f) {
    if (f.isEmpty || _disposed) return;
    switch (f[0]) {
      case pushCodeLoraScanHit:
        if (f.length < 7 || _state != LoraScanState.scanning) return;
        if (f.length > 7 && f[7] == 1) {
          _hotHits++; // not for the counts: hot points are seen more often
          notifyListeners();
          return;
        }
        final r = BufferReader(f)..skipBytes(1);
        final freq = r.readUInt32LE();
        final key = (r.readUInt8(), r.readUInt8());
        final row = _hits.putIfAbsent(key, () => {});
        row[freq] = (row[freq] ?? 0) + 1;
        notifyListeners();
      case pushCodeLoraScanPass:
        if (f.length < 3 || _state != LoraScanState.scanning) return;
        _passes = f[1] | f[2] << 8;
        _refreshCandidates();
        notifyListeners();
        unawaited(_updateHotPoints());
      case pushCodeLoraScanPacket:
        final p = LoraScanPacket.parse(f);
        if (p == null) return;
        if (_state == LoraScanState.scanning) {
          _caught.add(p);
          _refreshCandidates();
          notifyListeners();
          // a candidate heard: off the hot points, room for the next one
          if (p.valid) unawaited(_updateHotPoints());
          return;
        }
        if (_listening == null) return;
        _listening!.packets.add(p);
        // one good packet answers the candidate (its frequency error gives
        // the exact frequency): on to the next one rather than wait it out
        if (p.valid && !_stoppedForPacket) {
          _stoppedForPacket = true;
          unawaited(_stopListen());
        }
        notifyListeners();
      case pushCodeLoraScanDone:
        if (f.length < 11) return;
        final r = BufferReader(f)..skipBytes(1);
        final op = r.readUInt8();
        final reason = r.readUInt8();
        final err = r.readInt16LE();
        r.skipBytes(2);
        final preambles = r.readUInt16LE();
        final headerErrors = r.readUInt16LE();
        _doneReason = reason;
        if (reason == loraScanDoneRadio) _error = err;
        if (op == loraScanOpScan) {
          _refreshCandidates();
          _state = LoraScanState.idle;
        }
        if (_idle != null && (op == loraScanOpScan || _queue.isEmpty)) {
          _idle!.complete();
          _idle = null;
        } else if (op == loraScanOpListen && _listening != null) {
          final done = _listening!
            ..preambles = preambles
            ..headerErrors = headerErrors
            ..done = true;
          final owner = _owner;
          _listening = null;
          _state = LoraScanState.idle;
          final finished = reason == loraScanDoneComplete || _stoppedForPacket;
          if (owner != null && !done.decoded && finished) {
            _retryAround(owner, done);
            // nothing decoded: on to the candidate's next settings, if any
            if (owner.alternatives.any((a) => a.result == null)) {
              _queue.insert(0, owner);
            }
          }
          if (finished) unawaited(_listenNext());
        }
        notifyListeners();
    }
  }

  /// Per (bandwidth, SF) row: local peaks that fire at least 5 % of passes
  /// more than the row's median (its false-alarm level), three times at
  /// least. CAD of one signal also fires on settings with the same symbol time
  /// (SF9 / 125 kHz and SF10 / 250 kHz): those within a quarter bandwidth
  /// become alternatives of the row that fires most. Anything further, or
  /// with another symbol time, stays a candidate of its own: it may be
  /// another network.
  @visibleForTesting
  List<LoraCandidate> findCandidates() {
    final s = _scanned;
    if (s == null || _passes == 0) return [];
    final found = <LoraCandidate>[];
    for (final bw in s.bandwidths) {
      final points = s.pointsFor(bw);
      for (final sf in s.spreadingFactors) {
        final row = _hits[(bw, sf)] ?? const {};
        final rates = [for (final f in points) (row[f] ?? 0) / _passes];
        final sorted = [...rates]..sort();
        final base = sorted[sorted.length ~/ 2];
        final ex = [for (final r in rates) r - base];
        for (var k = 0; k < points.length; k++) {
          if ((row[points[k]] ?? 0) < 3 || ex[k] < 0.05) continue;
          final em = k > 0 ? ex[k - 1] : 0.0;
          final ep = k + 1 < points.length ? ex[k + 1] : 0.0;
          if (ex[k] < em || ex[k] <= ep) continue;
          // moved toward the hotter neighbour: a parabola through the three
          final curve = em - 2 * ex[k] + ep;
          final shift = curve < 0
              ? (0.5 * (em - ep) / curve).clamp(-0.5, 0.5)
              : 0.0;
          found.add(
            LoraCandidate(
              freqHz: (points[k] + shift * s.stepFor(bw)).round(),
              bandwidth: bw,
              sf: sf,
              rate: rates[k],
              excess: ex[k],
            ),
          );
        }
      }
    }
    // LoRa fires one (bandwidth, SF) pair and its twins of the same symbol
    // time; interference fires them all. Places where other symbol times fire
    // too go down the list.
    double score(LoraCandidate c) {
      final others = found.where(
        (o) =>
            (_symbolMs(o) / _symbolMs(c) - 1).abs() >= 0.02 &&
            (o.freqHz - c.freqHz).abs() <=
                math.max(
                      loraBandwidthHz(o.bandwidth),
                      loraBandwidthHz(c.bandwidth),
                    ) /
                    2,
      );
      return c.excess / (1 + others.length);
    }

    final scores = {for (final c in found) c: score(c)};
    found.sort((a, b) => scores[b]!.compareTo(scores[a]!));
    final out = <LoraCandidate>[];
    for (final c in found) {
      final near = out.where(
        (o) =>
            (_symbolMs(o) / _symbolMs(c) - 1).abs() < 0.02 &&
            (o.freqHz - c.freqHz).abs() <=
                math.max(
                      loraBandwidthHz(o.bandwidth),
                      loraBandwidthHz(c.bandwidth),
                    ) /
                    4,
      );
      if (near.isEmpty) {
        out.add(c);
      } else {
        near.first.alternatives.add(c);
      }
    }
    return out;
  }

  static double _symbolMs(LoraCandidate c) =>
      (1 << c.sf) / loraBandwidthsKhz[c.bandwidth];

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    unawaited(_sub.cancel());
    super.dispose();
  }
}
