// Protocol BLE OEE v2 — vezi docs/arhitectura.md, cap. 5.
// Date: mesaje JSON (cate unul pe linie, '\n') in notificarile caracteristicii Data.
// Config / Status / Ack / Time: binare, little-endian.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

final Guid kServiceUuid = Guid('7e1a0001-2f4b-4c1e-9a77-0e5ba2c0d001');
final Guid kDataUuid = Guid('7e1a0002-2f4b-4c1e-9a77-0e5ba2c0d001');
final Guid kAckUuid = Guid('7e1a0003-2f4b-4c1e-9a77-0e5ba2c0d001');
final Guid kStatusUuid = Guid('7e1a0004-2f4b-4c1e-9a77-0e5ba2c0d001');
final Guid kConfigUuid = Guid('7e1a0005-2f4b-4c1e-9a77-0e5ba2c0d001');
final Guid kTimeUuid = Guid('7e1a0007-2f4b-4c1e-9a77-0e5ba2c0d001');

const int kStatusSize = 56;
const int kConfigSize = 28;

/// Un mesaj al dispozitivului. type: 'int' (interval), 'ev' (eveniment), 'boot'.
class Msg {
  Msg(this.boot, this.seq, this.type, this.run, this.ts, this.upMs, this.json);
  final int boot, seq, run, upMs;
  final String type;
  final String? ts; // UTC ISO-8601 sau null daca ora ESP32 nu era setata
  final Map<String, dynamic> json;

  /// Parseaza o notificare. Se opreste la PRIMA linie invalida: mesajele de dupa ea nu sunt
  /// returnate, ca ack-ul cumulativ sa nu acopere o inregistrare care nu a fost salvata.
  /// ESP32 retransmite ce nu e confirmat (la expirarea ack-ului, 5 s).
  static ParsedBatch parse(List<int> data) {
    final out = <Msg>[];
    var invalid = false;
    final text = utf8.decode(data, allowMalformed: true);
    for (final line in text.split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      try {
        final j = jsonDecode(l);
        if (j is! Map<String, dynamic>) {
          invalid = true;
          break;
        }
        final b = j['b'], s = j['s'];
        if (b is! int || s is! int) {
          invalid = true;
          break;
        }
        out.add(Msg(b, s, (j['t'] ?? '') as String, (j['run'] ?? 0) as int,
            j['ts'] as String?, (j['up'] ?? 0) as int, j));
      } catch (_) {
        invalid = true;
        break;
      }
    }
    return ParsedBatch(out, invalid);
  }
}

class ParsedBatch {
  ParsedBatch(this.msgs, this.invalid);
  final List<Msg> msgs; // mesajele valide dinaintea primei linii invalide
  final bool invalid; // true daca s-a intalnit o linie invalida
}

String stateLabel(int s) => switch (s) {
      0 => 'ruleaza',
      1 => 'microoprire in curs',
      2 => 'OPRITA',
      3 => 'viteza redusa',
      4 => 'viteza peste nominal',
      255 => 'neconfigurat (alege un produs)',
      _ => 'necunoscut',
    };

/// Starea unui canal din Status (intrare de 10 B de la offsetul 56): stare, nivel, ms de la ultimul impuls, total pe boot.
class ChanStat {
  const ChanStat(this.state, this.level, this.sinceLastMs, this.cum);
  final int state, level, sinceLastMs, cum;
}

class DeviceStatus {
  const DeviceStatus(this.fw, this.boot, this.lastSeq, this.cum, this.nowUs,
      this.dropped, this.rejected, this.edgesLost, this.fsFreeKb, this.level,
      this.state, this.sinceLastMs, this.utcS, this.ackBoot, this.ackSeq, [this.chans = const []]);
  /// Canalele 1..8 (gol la firmware 2, cu Status de 56 B).
  final List<ChanStat> chans;

  /// Aceleasi date globale, dar cu starea / contorul canalului [ch] (1..8); pentru firmware fara canale intoarce obiectul nemodificat.
  DeviceStatus forChannel(int ch) {
    if (ch < 1 || ch > chans.length) return this;
    final c = chans[ch - 1];
    return DeviceStatus(fw, boot, lastSeq, c.cum, nowUs, dropped, rejected, edgesLost, fsFreeKb, c.level, c.state,
        c.sinceLastMs, utcS, ackBoot, ackSeq, chans);
  }
  final String fw;
  final int boot, lastSeq, cum, nowUs, dropped, rejected, edgesLost, fsFreeKb;
  final int level, state, sinceLastMs, utcS;
  final int ackBoot, ackSeq; // ultimul ack primit de ESP32 (Status @24, @28)

  static DeviceStatus? parse(List<int> data) {
    if (data.length < kStatusSize) return null;
    final bd = ByteData.sublistView(Uint8List.fromList(data));
    final chans = <ChanStat>[];
    if (data.length >= kStatusSize + 80) {
      for (var i = 0; i < 8; i++) {
        final o = kStatusSize + i * 10;
        chans.add(ChanStat(bd.getUint8(o), bd.getUint8(o + 1), bd.getUint32(o + 2, Endian.little),
            bd.getUint32(o + 6, Endian.little)));
      }
    }
    return DeviceStatus(
      '${bd.getUint8(1)}.${bd.getUint8(2)}.${bd.getUint8(3)}',
      bd.getUint32(4, Endian.little),
      bd.getUint32(8, Endian.little),
      bd.getUint32(12, Endian.little),
      bd.getUint64(16, Endian.little),
      bd.getUint32(32, Endian.little),
      bd.getUint32(36, Endian.little),
      bd.getUint32(40, Endian.little),
      bd.getUint16(44, Endian.little),
      bd.getUint8(46),
      bd.getUint8(47),
      bd.getUint32(48, Endian.little),
      bd.getUint32(52, Endian.little),
      bd.getUint32(24, Endian.little),
      bd.getUint32(28, Endian.little),
      chans,
    );
  }
}

/// Ack cumulativ: [boot u32][seq u32]
Uint8List encodeAck(int boot, int seq) {
  final bd = ByteData(8)
    ..setUint32(0, boot, Endian.little)
    ..setUint32(4, seq, Endian.little);
  return bd.buffer.asUint8List();
}

Uint8List encodeTime(int utcSeconds) {
  final bd = ByteData(4)..setUint32(0, utcSeconds, Endian.little);
  return bd.buffer.asUint8List();
}

/// Parametrii per SKU / run, 28 octeti (vezi struct Cfg din firmware).
/// cycleS = timp de ciclu ideal (s), triggerS = "Triggering Cycle Time" (s).
Uint8List encodeConfig({
  required int runNo,
  required double cycleS,
  required double triggerS,
  int countLevel = 1, // placa Waveshare: intrare activa pe nivel jos
  int intervalS = 5,
  int tolPct = 10,
  int exitPct = 95,
  int windowS = 60,
  int holdS = 60,
  int microX10 = 20,
}) {
  final cycleUs = (cycleS * 1e6).round();
  final triggerUs = (triggerS * 1e6).round();
  const minPulseUs = 1000;
  final minIntervalUs = (cycleUs * 0.3).round().clamp(minPulseUs, 60000000);
  final bd = ByteData(kConfigSize)
    ..setUint8(0, 2)
    ..setUint8(1, countLevel)
    ..setUint8(2, intervalS)
    ..setUint8(3, tolPct)
    ..setUint32(4, runNo, Endian.little)
    ..setUint32(8, cycleUs, Endian.little)
    ..setUint32(12, triggerUs, Endian.little)
    ..setUint32(16, minPulseUs, Endian.little)
    ..setUint32(20, minIntervalUs, Endian.little)
    ..setUint8(24, exitPct)
    ..setUint8(25, windowS)
    ..setUint8(26, holdS)
    ..setUint8(27, microX10);
  return bd.buffer.asUint8List();
}

/// Regulile pe care le impune firmware-ul; aplicatia le verifica inainte sa scrie parametrii.
String? validateSkuTiming(double cycleS, double triggerS, {int windowS = 60, int microX10 = 20}) {
  if (cycleS < 0.001 || cycleS > 600) return 'Timpul de ciclu trebuie sa fie intre 0.001 si 600 s';
  if (triggerS < cycleS * microX10 / 10) {
    return 'Triggering Cycle Time trebuie sa fie cel putin ${microX10 / 10}x timpul de ciclu';
  }
  if (triggerS > windowS) return 'Triggering Cycle Time nu poate depasi $windowS s (fereastra de viteza)';
  return null;
}

/// Verifica ca ESP32 a retinut Config-ul scris ([sent] = Config v2 de 28 B).
/// Firmware 2 il intoarce identic (28 B). Firmware 3 il intoarce ca 9 blocuri de 32 B (288 B):
/// blocul 0 = global (interval, run), blocul 1 = canalul 1 (parametrii scrisi, activ).
bool configEchoMatches(List<int> sent, List<int> back) {
  if (back.length == sent.length) {
    for (var i = 0; i < sent.length; i++) {
      if (back[i] != sent[i]) return false;
    }
    return true;
  }
  if (sent.length != 28 || back.length < 64) return false;
  final s = ByteData.sublistView(Uint8List.fromList(sent));
  final b = ByteData.sublistView(Uint8List.fromList(back));
  if (b.getUint8(0) != 3 || b.getUint8(1) != 0) return false; // bloc global
  if (b.getUint8(2) != s.getUint8(2)) return false; // interval_s
  if (b.getUint32(8, Endian.little) != s.getUint32(4, Endian.little)) return false; // run
  const o = 32; // canalul 1
  if (b.getUint8(o) != 3 || b.getUint8(o + 1) != 1) return false;
  if (b.getUint8(o + 2) != s.getUint8(1)) return false; // count_level
  if (b.getUint8(o + 3) != 1) return false; // activ
  if (b.getUint8(o + 4) != s.getUint8(3)) return false; // tol_pct
  if (b.getUint8(o + 5) != s.getUint8(24)) return false; // exit_pct
  if (b.getUint8(o + 6) != s.getUint8(25)) return false; // window_s
  if (b.getUint8(o + 7) != s.getUint8(26)) return false; // hold_s
  if (b.getUint32(o + 12, Endian.little) != s.getUint32(8, Endian.little)) return false; // C
  if (b.getUint32(o + 16, Endian.little) != s.getUint32(12, Endian.little)) return false; // T
  if (b.getUint32(o + 20, Endian.little) != s.getUint32(16, Endian.little)) return false;
  if (b.getUint32(o + 24, Endian.little) != s.getUint32(20, Endian.little)) return false;
  if (b.getUint8(o + 28) != s.getUint8(27)) return false; // micro_x10
  return true;
}

// ───────────── Config v3 (firmware 3): blocuri de 32 B, ch = 0 global, ch = 1..8 canal (vezi spec-8-canale.md 3.3) ─────────────
const int kBlockSize = 32;

/// Bloc global: interval `int` (s), prag `ev micro` (s; 0 = toate microopririle ca evenimente) si run-ul activ.
Uint8List encodeBlockGlobal({required int runNo, int intervalS = 5, int microEvS = 3}) {
  final bd = ByteData(kBlockSize);
  bd.setUint8(0, 3);
  bd.setUint8(1, 0);
  bd.setUint8(2, intervalS);
  bd.setUint8(4, microEvS);
  bd.setUint32(8, runNo, Endian.little);
  return bd.buffer.asUint8List();
}

/// Bloc de canal. Un canal inactiv se scrie cu campurile goale (firmware-ul il accepta ca dezactivare).
Uint8List encodeBlockChannel({
  required int ch,
  required bool active,
  double cycleS = 0,
  double triggerS = 0,
  int countLevel = 1, // intrare activa pe nivel jos
  int tolPct = 10,
  int exitPct = 95,
  int windowS = 60,
  int holdS = 60,
  int microX10 = 20,
}) {
  final bd = ByteData(kBlockSize);
  bd.setUint8(0, 3);
  bd.setUint8(1, ch);
  bd.setUint8(2, countLevel);
  bd.setUint8(3, active ? 1 : 0);
  if (active) {
    final cycleUs = (cycleS * 1e6).round();
    final triggerUs = (triggerS * 1e6).round();
    const minPulseUs = 1000;
    final minIntervalUs = (cycleUs * 0.3).round().clamp(minPulseUs, 60000000);
    bd.setUint8(4, tolPct);
    bd.setUint8(5, exitPct);
    bd.setUint8(6, windowS);
    bd.setUint8(7, holdS);
    bd.setUint32(12, cycleUs, Endian.little);
    bd.setUint32(16, triggerUs, Endian.little);
    bd.setUint32(20, minPulseUs, Endian.little);
    bd.setUint32(24, minIntervalUs, Endian.little);
    bd.setUint8(28, microX10);
  }
  return bd.buffer.asUint8List();
}

/// Compara blocurile scrise cu Config-ul recitit (9 blocuri de 32 B: global + CH1..CH8).
/// Intoarce (blocuri care difera, canale necitite) — 0 = blocul global. Un canal inactiv se verifica doar ca inactiv.
(List<int>, List<int>) configBlockMismatches(List<Uint8List> sent, List<int> back) {
  final bad = <int>[];
  final unread = <int>[];
  for (final s in sent) {
    final ch = s[1];
    final off = ch * kBlockSize;
    if (back.length < off + kBlockSize) {
      unread.add(ch);
      continue;
    }
    bool same(int from, int len) {
      for (var k = from; k < from + len; k++) {
        if (back[off + k] != s[k]) return false;
      }
      return true;
    }

    final bool ok;
    if (ch == 0) {
      ok = same(0, 5) && same(8, 4); // ver, ch, interval, 0, micro_ev_s, run
    } else if (s[3] == 0) {
      ok = back[off] == 3 && back[off + 1] == ch && back[off + 3] == 0;
    } else {
      ok = same(0, 29); // ver .. micro_x10
    }
    if (!ok) bad.add(ch);
  }
  return (bad, unread);
}
