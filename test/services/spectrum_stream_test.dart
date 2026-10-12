import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/review_mode/review_radio.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/spectrum_stream.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitFor(bool Function() condition, {int seconds = 5}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Uint8List _info({int config = 7, int points = 250}) {
  final w = BufferWriter()
    ..writeByte(respCodeSpectrumInfo)
    ..writeByte(spectrumStateRunning)
    ..writeByte(config)
    ..writeByte(points)
    ..writeUInt32LE(867004000)
    ..writeUInt32LE(8000)
    ..writeUInt32LE(19500)
    ..writeUInt16LE(50)
    ..writeByte(0)
    ..writeUInt16LE(1234);
  return w.toBytes();
}

Uint8List _chunk(int config, int frameNo, int first, List<int> levels) =>
    Uint8List.fromList([
      pushCodeSpectrumFrame,
      config,
      frameNo,
      first,
      ...levels,
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // One connector for the file: the notification service it starts is a
  // singleton whose replies can be listened to once.
  late MeshCoreConnector connector;
  late MessageRetryService retryService;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    connector = MeshCoreConnector();
    retryService = MessageRetryService();
    connector.initialize(
      retryService: retryService,
      pathHistoryService: PathHistoryService(StorageService()),
    );
    connector.reviewRadioFactoryForTest = () =>
        ReviewRadio(scheduledMessageInterval: const Duration(hours: 1));
    await connector.connectReview();
  });

  tearDownAll(() {
    connector.dispose();
    retryService.dispose();
  });

  test('builds OP_START as the firmware reads it', () {
    final f = buildSpectrumStartFrame(
      centreHz: 868000000,
      spanHz: 2000000,
      points: 250,
      intervalMs: 50,
      agg: SpectrumAgg.mean,
    );
    expect(f.length, 18);
    final d = ByteData.sublistView(f);
    expect(f[0], cmdSpectrum);
    expect(f[1], spectrumOpStart);
    expect(d.getUint32(2, Endian.little), 868000000);
    expect(d.getUint32(6, Endian.little), 2000000);
    expect(f[10], 250);
    expect(d.getUint32(11, Endian.little), 0);
    expect(d.getUint16(15, Endian.little), 50);
    expect(f[17], 1);
  });

  test('parses RESP_SPECTRUM_INFO', () {
    final info = SpectrumInfo.parse(_info())!;
    expect(info.state, spectrumStateRunning);
    expect(info.points, 250);
    expect(info.firstHz, 867004000);
    expect(info.stepHz, 8000);
    expect(info.lowHz, 867000000);
    expect(info.highHz, 869000000);
    expect(info.sweepsPerSecond, closeTo(123.4, 1e-9));
  });

  test('assembles chunked frames, skips those of earlier settings', () async {
    final stream = SpectrumStream(connector);
    addTearDown(stream.dispose);
    final got = <Float32List>[];
    stream.frames.listen(got.add);
    await stream.start();
    stream.handleFrame(_info(config: 9));
    final rest = List<int>.filled(250 - 168, 200);

    stream.handleFrame(_chunk(9, 1, 0, List.filled(168, 180)));
    stream.handleFrame(_chunk(9, 1, 168, rest));
    // frame 2 lost; 3 arrives, but of the previous settings
    stream.handleFrame(_chunk(8, 3, 0, List.filled(168, 180)));
    stream.handleFrame(_chunk(9, 4, 0, List.filled(168, 255)));
    stream.handleFrame(_chunk(9, 4, 168, rest));
    await Future<void>.delayed(Duration.zero);

    expect(got.length, 2);
    expect(got[0][0], -90);
    expect(got[0][249], -100);
    expect(got[1][0].isNaN, isTrue);
    expect(stream.status, SpectrumStatus.running);
  });

  test('runs against the review radio, follows settings, stops', () async {
    final stream = SpectrumStream(connector);
    addTearDown(stream.dispose);
    final got = <Float32List>[];
    stream.frames.listen(got.add);

    await stream.start();
    await _waitFor(() => got.length >= 3);
    expect(stream.status, SpectrumStatus.running);
    final info = stream.info!;
    expect(info.points, 250);
    expect(
      (info.lowHz + info.highHz) / 2,
      closeTo(connector.currentFreqHz!, info.stepHz.toDouble()),
    );
    expect(got.last.every((v) => v < -40 && v > -130), isTrue);

    stream.configure(spanHz: 8000000, centreHz: 868000000);
    await _waitFor(() => stream.info!.stepHz == 32000);
    expect(stream.info!.config, isNot(info.config));

    await stream.stop();
    expect(stream.status, SpectrumStatus.idle);
    final count = got.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(got.length, count);
  });

  test('a radio error ends the session with its code', () async {
    final stream = SpectrumStream(connector);
    addTearDown(stream.dispose);
    await stream.start();
    stream.handleFrame(
      Uint8List.fromList([pushCodeSpectrumStopped, 3, 0xFE, 0xFF]),
    );
    expect(stream.status, SpectrumStatus.failed);
    expect(stream.stopReason, spectrumStopRadio);
    expect(stream.errCode, -2);
  });
}
