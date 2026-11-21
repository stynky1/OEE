// Program de lucru configurabil: versiuni cu „valabil de la”, ca istoricul sa ramana neschimbat cand se modifica programul.
// Stocat ca JSON in setting 'shift_plan' (fara migrare de schema).
import 'dart:convert';
import 'i18n.dart';

/// Un schimb. Minute de la miezul noptii (local). endMin > 1440 = trece peste miezul noptii (ex. 23:00-07:00 = 1380..1860).
class ShiftDef {
  const ShiftDef(this.name, this.startMin, this.endMin);
  final String name;
  final int startMin, endMin;

  Map<String, Object?> toJson() => {'n': name, 's': startMin, 'e': endMin};
  static ShiftDef fromJson(Map<String, Object?> j) =>
      ShiftDef('${j['n']}', (j['s'] as num).toInt(), (j['e'] as num).toInt());

  String get label => '${fmtMin(startMin)}–${fmtMin(endMin)}${endMin > 1440 ? ' (+1)' : ''}';
}

String fmtMin(int m) {
  final x = m % 1440;
  return '${(x ~/ 60).toString().padLeft(2, '0')}:${(x % 60).toString().padLeft(2, '0')}';
}

/// O versiune a programului, valabila de la o zi (locala); null = de la inceput.
class ShiftPlan {
  const ShiftPlan(this.from, this.shifts);
  final DateTime? from;
  final List<ShiftDef> shifts;
}

class ShiftWindow {
  const ShiftWindow(this.day, this.idx);
  final DateTime day; // ziua (locala) in care incepe schimbul
  final int idx;
}

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class ShiftSchedule {
  ShiftSchedule(List<ShiftPlan> plans) : plans = _sorted(plans);
  final List<ShiftPlan> plans;

  static List<ShiftPlan> _sorted(List<ShiftPlan> p) {
    final l = [...p];
    l.sort((a, b) {
      if (a.from == null) return b.from == null ? 0 : -1;
      if (b.from == null) return 1;
      return a.from!.compareTo(b.from!);
    });
    return l;
  }

  /// Implicit: programul vechi (2 schimburi) pana la 01.11.2026, apoi 3 schimburi care acopera 24 h.
  /// Istoricul de pana acum nu se schimba.
  static ShiftSchedule initial() => ShiftSchedule([
        const ShiftPlan(null, [ShiftDef('Schimb 1', 420, 900), ShiftDef('Schimb 2', 900, 1410)]),
        ShiftPlan(DateTime(2026, 11, 2), presets['3x8-07']!),
      ]);

  static const presets = <String, List<ShiftDef>>{
    '3x8-07': [ShiftDef('Schimb 1', 420, 900), ShiftDef('Schimb 2', 900, 1380), ShiftDef('Schimb 3', 1380, 1860)],
    '3x8-06': [ShiftDef('Schimb 1', 360, 840), ShiftDef('Schimb 2', 840, 1320), ShiftDef('Schimb 3', 1320, 1800)],
    '2x12-07': [ShiftDef('Zi', 420, 1140), ShiftDef('Noapte', 1140, 1860)],
    '2x12-06': [ShiftDef('Zi', 360, 1080), ShiftDef('Noapte', 1080, 1800)],
  };

  List<ShiftDef> forDay(DateTime day) {
    final d = dayOnly(day);
    ShiftPlan pick = plans.first;
    for (final p in plans) {
      if (p.from == null || !p.from!.isAfter(d)) pick = p;
    }
    return pick.shifts;
  }

  DateTime start(DateTime day, int idx) {
    final d = dayOnly(day);
    return DateTime(d.year, d.month, d.day, 0, forDay(d)[idx].startMin);
  }

  DateTime end(DateTime day, int idx) {
    final d = dayOnly(day);
    return DateTime(d.year, d.month, d.day, 0, forDay(d)[idx].endMin);
  }

  /// Schimbul in desfasurare la momentul dat (local), sau null (in afara programului).
  ShiftWindow? current(DateTime nowLocal) {
    for (var back = 0; back <= 1; back++) {
      final d = dayOnly(DateTime(nowLocal.year, nowLocal.month, nowLocal.day - back));
      final l = forDay(d).length;
      for (var i = 0; i < l; i++) {
        if (!nowLocal.isBefore(start(d, i)) && nowLocal.isBefore(end(d, i))) return ShiftWindow(d, i);
      }
    }
    return null;
  }

  /// Ultimul schimb inceput (cel in desfasurare sau cel mai recent incheiat).
  ShiftWindow? lastStarted(DateTime nowLocal) {
    for (var back = 0; back <= 3; back++) {
      final d = dayOnly(DateTime(nowLocal.year, nowLocal.month, nowLocal.day - back));
      final l = forDay(d).length;
      for (var i = l - 1; i >= 0; i--) {
        if (!start(d, i).isAfter(nowLocal)) return ShiftWindow(d, i);
      }
    }
    return null;
  }

  ShiftWindow neighbor(ShiftWindow w, int dir) {
    final l = forDay(w.day).length;
    final i = w.idx + dir;
    if (i >= 0 && i < l) return ShiftWindow(w.day, i);
    final d = dayOnly(DateTime(w.day.year, w.day.month, w.day.day + dir));
    return ShiftWindow(d, dir < 0 ? forDay(d).length - 1 : 0);
  }

  /// Mesaj de eroare (in romana) sau null daca programul e valid.
  static String? validate(List<ShiftDef> s) {
    if (s.isEmpty) return tr('sh.e.empty');
    if (s.length > 8) return tr('sh.e.max');
    for (final x in s) {
      if (x.name.trim().isEmpty) return tr('sh.e.name');
      if (x.startMin < 0 || x.startMin >= 1440) return trp('sh.e.start', {'n': x.name});
      if (x.endMin <= x.startMin) return trp('sh.e.end', {'n': x.name});
      if (x.endMin - x.startMin > 1440) return trp('sh.e.long', {'n': x.name});
    }
    final l = [...s]..sort((a, b) => a.startMin.compareTo(b.startMin));
    for (var i = 1; i < l.length; i++) {
      if (l[i].startMin < l[i - 1].endMin) return trp('sh.e.overlap', {'a': l[i - 1].name, 'b': l[i].name});
    }
    if (l.last.endMin > l.first.startMin + 1440) {
      return trp('sh.e.overlapNext', {'a': l.last.name, 'b': l.first.name});
    }
    return null;
  }

  /// Sub 24 h acoperite? (doar avertisment)
  static int coveredMin(List<ShiftDef> s) => s.fold(0, (a, x) => a + (x.endMin - x.startMin));

  String toJsonString() => jsonEncode({
        'v': 1,
        'plans': [
          for (final p in plans)
            {
              'from': p.from == null
                  ? null
                  : '${p.from!.year.toString().padLeft(4, '0')}-${p.from!.month.toString().padLeft(2, '0')}-${p.from!.day.toString().padLeft(2, '0')}',
              'shifts': [for (final x in p.shifts) x.toJson()],
            }
        ],
      });

  static ShiftSchedule? fromJsonString(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map<String, Object?>;
      final out = <ShiftPlan>[];
      for (final p in (j['plans'] as List)) {
        final m = p as Map<String, Object?>;
        final f = m['from'] == null ? null : DateTime.parse('${m['from']}');
        final sh = [for (final x in (m['shifts'] as List)) ShiftDef.fromJson(x as Map<String, Object?>)];
        if (validate(sh) != null) return null;
        out.add(ShiftPlan(f == null ? null : DateTime(f.year, f.month, f.day), sh));
      }
      return out.isEmpty ? null : ShiftSchedule(out);
    } catch (_) {
      return null;
    }
  }
}
