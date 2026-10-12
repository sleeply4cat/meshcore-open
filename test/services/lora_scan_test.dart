import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/services/lora_scan.dart';

Uint8List _hit(int freq, int bw, int sf) {
  final d = ByteData(7)
    ..setUint8(0, pushCodeLoraScanHit)
    ..setUint32(1, freq, Endian.little)
    ..setUint8(5, bw)
    ..setUint8(6, sf);
  return d.buffer.asUint8List();
}

Uint8List _pass(int n) => Uint8List.fromList([pushCodeLoraScanPass, n, n >> 8]);

Uint8List _hotHit(int freq, int bw, int sf) =>
    Uint8List.fromList([..._hit(freq, bw, sf), 1]);

// a flood GRP_TXT with a 2-hop path of 2-byte hashes, SF7 / 62.5 kHz
Uint8List _packet({required int fei, int flags = 3, int tuned = 868856000}) {
  const payload = [0x15, 0x42, 1, 2, 3, 4, 9];
  final d = ByteData(16)
    ..setUint8(0, pushCodeLoraScanPacket)
    ..setUint32(1, tuned, Endian.little)
    ..setInt32(5, fei, Endian.little)
    ..setInt8(9, -117)
    ..setInt8(10, -24)
    ..setUint8(11, 7)
    ..setUint8(12, flags)
    ..setUint8(13, 6)
    ..setUint8(14, 7)
    ..setUint8(15, payload.length);
  return Uint8List.fromList([...d.buffer.asUint8List(), ...payload]);
}

void main() {
  const settings = LoraScanSettings(
    fromHz: 868400000,
    toHz: 869400000,
    bandwidths: {6, 7},
    spreadingFactors: {7, 9},
  );

  test('OP_SCAN carries the settings as the firmware reads them', () {
    final f = buildLoraScanFrame(settings);
    final d = ByteData.sublistView(f);
    expect(f.length, 22);
    expect(f[0], cmdLoraScan);
    expect(f[1], loraScanOpScan);
    expect(d.getUint32(2, Endian.little), 868400000);
    expect(d.getUint32(6, Endian.little), 869400000);
    expect(d.getUint32(10, Endian.little), 0);
    expect(d.getUint16(14, Endian.little), (1 << 6) | (1 << 7));
    expect(f[16], (1 << 2) | (1 << 4));
    expect(f[17], 2);
    expect(d.getUint16(20, Endian.little), 600);
  });

  test('OP_LISTEN layout', () {
    final f = buildLoraListenFrame(
      freqHz: 868856000,
      bandwidth: 6,
      sf: 7,
      syncWord: 0x12,
      durationSeconds: 120,
    );
    final d = ByteData.sublistView(f);
    expect(f.length, 11);
    expect(d.getUint32(2, Endian.little), 868856000);
    expect([f[6], f[7], f[8]], [6, 7, 0x12]);
    expect(d.getUint16(9, Endian.little), 120);
  });

  test('points and the pass estimate', () {
    expect(settings.pointsFor(6).length, 33); // 31.25 kHz steps, both ends
    expect(settings.pointsFor(7).length, 17);
    expect(settings.passDuration.inMilliseconds, inInclusiveRange(1000, 2500));
  });

  test('parses a packet and its MeshCore header', () {
    final p = LoraScanPacket.parse(_packet(fei: 135))!;
    expect(p.senderHz, 868856000 - 135);
    expect(p.rssi, -117);
    expect(p.snr, -6);
    expect(p.valid, isTrue);
    expect((p.bandwidth, p.sf), (6, 7));
    final h = p.meshCore!;
    expect(h.payloadType, payloadTypeGRPTXT);
    expect(h.hops, 2);
    expect(h.hashWidth, 2);
    expect(h.plausible, isTrue);
    // a header without a payload CRC is not a packet to trust
    expect(LoraScanPacket.parse(_packet(fei: 0, flags: 1))!.valid, isFalse);
  });

  test('picks candidates, and the senders frequency from a listen', () {
    final scan = LoraScanController(
      MeshCoreConnector(),
      settings.copyWith(spreadingFactors: {7, 8, 9}),
    )..beginScan();
    addTearDown(scan.dispose);
    // SF7 / 62.5 kHz every pass at 868.8375 and every other pass at 868.86875;
    // SF8 / 125 kHz (the same symbol time) at the same place now and then;
    // SF9 / 125 kHz there too (another network); a stray hit elsewhere
    for (var pass = 1; pass <= 10; pass++) {
      scan.handleFrame(_hit(868837500, 6, 7));
      if (pass.isEven) scan.handleFrame(_hit(868868750, 6, 7));
      if (pass % 3 == 0) scan.handleFrame(_hit(868837500, 7, 8));
      if (pass % 2 == 1) scan.handleFrame(_hit(868837500, 7, 9));
      if (pass == 4) scan.handleFrame(_hit(869150000, 6, 9));
      scan.handleFrame(_pass(pass));
    }
    final c = scan.findCandidates();
    expect(c, hasLength(2));
    final top = c.first;
    expect((top.bandwidth, top.sf), (6, 7));
    // the hottest point, a sixth of a step toward the warmer neighbour
    expect((top.freqHz - 868842708).abs(), lessThan(10));
    expect(top.alternatives.map((a) => (a.bandwidth, a.sf)), [(7, 8)]);
    expect((c[1].bandwidth, c[1].sf), (7, 9));

    final r = LoraListenResult(868856000, 6, 7);
    for (final fei in [135, -34, 848, -42, 158]) {
      r.packets.add(LoraScanPacket.parse(_packet(fei: fei))!);
    }
    expect(r.senderHz, 868856000 - 135); // the median
    expect(r.isMeshCore, isTrue);
    expect(r.codingRate, 7);
  });

  test('OP_SCAN_HOT layout', () {
    final f = buildLoraScanHotFrame(
      [(868840000, 6, 7), (868856000, 6, 7)],
      ms: 10000,
      syncWord: 0x12,
    );
    final d = ByteData.sublistView(f);
    expect(f.length, 8 + 2 * 6);
    expect([f[0], f[1]], [cmdLoraScan, loraScanOpHot]);
    expect(d.getUint16(2, Endian.little), 10000);
    expect([f[4], f[5], f[6], f[7]], [1, 0x12, 0, 2]);
    expect(d.getUint32(14, Endian.little), 868856000);
  });

  test('hot detections stay out of the counts; caught packets answer', () {
    final scan = LoraScanController(MeshCoreConnector(), settings)..beginScan();
    addTearDown(scan.dispose);
    for (var pass = 1; pass <= 6; pass++) {
      scan.handleFrame(_hit(868837500, 6, 7));
      scan.handleFrame(_hotHit(868850000, 6, 7));
      scan.handleFrame(_pass(pass));
    }
    expect(scan.hotHits, 6);
    expect(scan.hitsAt(6, 7, 868850000), 0);
    final c = scan.candidates.single;
    expect(c.heard, isFalse);

    scan.handleFrame(_packet(fei: 200, tuned: 868840000));
    final heard = scan.candidates.single;
    expect(heard.heard, isTrue);
    expect(heard.best!.duringScan, isTrue);
    expect(heard.best!.senderHz, 868840000 - 200);
    expect(heard.best!.isMeshCore, isTrue);
  });

  test('a network heard stays when its counts fade', () {
    final scan = LoraScanController(MeshCoreConnector(), settings)..beginScan();
    addTearDown(scan.dispose);
    for (var pass = 1; pass <= 4; pass++) {
      scan.handleFrame(_hit(868837500, 6, 7));
      scan.handleFrame(_pass(pass));
    }
    scan.handleFrame(_packet(fei: 200, tuned: 868840000));
    // many quiet passes: the place no longer fires above its row
    for (var pass = 5; pass <= 200; pass++) {
      scan.handleFrame(_pass(pass));
    }
    final c = scan.candidates.single;
    expect(c.heard, isTrue);
    expect(c.freqHz, 868840000 - 200);
    expect(c.best!.isMeshCore, isTrue);
  });
}
