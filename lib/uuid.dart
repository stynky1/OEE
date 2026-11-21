// UUID v4 (identitate globala a inregistrarilor de configurare; aceeasi in cloud).
import 'dart:math';

final _rng = Random.secure();

String newUuid() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // versiunea 4
  b[8] = (b[8] & 0x3f) | 0x80; // varianta RFC 4122
  String h(int from, int to) =>
      b.sublist(from, to).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}
