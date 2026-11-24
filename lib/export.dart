// Export CSV pentru Power BI / Excel (Administrare → Export CSV).
// Fisiere UTF-8 cu BOM, separator virgula, zecimale cu punct. Se partajeaza prin fereastra de partajare Android
// (OneDrive / SharePoint, e-mail, aplicatie de fisiere). Indicatorii pe schimb se calculeaza ca in „Linia”, doar pentru schimburi incheiate.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'ble_service.dart';
import 'db.dart';
import 'i18n.dart';
import 'login_page.dart';
import 'shifts.dart';

class ExportFile {
  ExportFile(this.name, this.rows, this.text);
  final String name;
  final int rows;
  final String text;
}

class _Rng {
  _Rng(this.a, this.b);
  final DateTime a, b;
}

String _iso(DateTime t) => '${t.toUtc().toIso8601String().split('.').first}Z';
String _two(int v) => v.toString().padLeft(2, '0');

String _loc(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

DateTime? _p(Object? v) => v == null ? null : DateTime.tryParse('$v');

int _overlap(DateTime a0, DateTime a1, DateTime b0, DateTime b1) {
  final s = a0.isAfter(b0) ? a0 : b0;
  final e = a1.isBefore(b1) ? a1 : b1;
  final d = e.difference(s).inMilliseconds;
  return d > 0 ? d : 0;
}

String _num(num v) {
  if (v is int) return '$v';
  final d = v.toDouble();
  if (d.isNaN || d.isInfinite) return '';
  var s = d.toStringAsFixed(6);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}

String _cell(Object? v) {
  if (v == null) return '';
  var s = v is num ? _num(v) : '$v';
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    s = '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

ExportFile _csv(String name, List<String> head, List<List<Object?>> rows) {
  final b = StringBuffer(head.join(','));
  for (final r in rows) {
    b.write('\r\n');
    b.write(r.map(_cell).join(','));
  }
  b.write('\r\n');
  return ExportFile(name, rows.length, b.toString());
}

/// Ziua (locala) in care incepe schimbul si numele lui, la momentul dat; gol daca e in afara programului.
({String day, String name}) _shiftAt(ShiftSchedule sch, DateTime t) {
  final w = sch.current(t.toLocal());
  if (w == null) return (day: '', name: '');
  final d = w.day;
  return (day: '${d.year}-${_two(d.month)}-${_two(d.day)}', name: sch.forDay(d)[w.idx].name);
}

/// Construieste toate fisierele. [fromUtc] = null → toate datele.
Future<List<ExportFile>> buildExport(BleService ble, DateTime? fromUtc) async {
  final db = ble.db;
  final sch = db.shifts;
  final nowU = DateTime.now().toUtc();
  final a = fromUtc == null ? '0000-01-01T00:00:00Z' : _iso(fromUtc);
  final b = _iso(nowU);
  final chans = await db.channels(stats: false);
  final chName = {for (final c in chans) c.id: c.name};
  final out = <ExportFile>[];

  // 1) evenimente (opriri, microopriri, viteza redusa / peste nominal) cu motivul dat de operator
  final ev = await db.rawRead('''
    SELECT m.device AS device, m.boot AS boot, m.seq AS seq, m.ch AS ch, m.st AS st,
           m.from_ts AS from_ts, m.to_ts AS to_ts, m.dur_ms AS dur_ms, m.run AS run, s.name AS product,
           l1.kind AS k1, l1.name AS c1, l2.name AS c2, c.comment AS comment, c.created_at AS classified_at,
           u.name AS user_name, CASE WHEN v.seq IS NOT NULL THEN 1 ELSE 0 END AS voided
    FROM message m
    LEFT JOIN cause c ON c.device = m.device AND c.boot = m.boot AND c.seq = m.seq
    LEFT JOIN loss_code l1 ON l1.id = c.code1
    LEFT JOIN loss_code l2 ON l2.id = c.code2
    LEFT JOIN app_user u ON u.uuid = c.user_uuid
    LEFT JOIN run r ON r.run_no = m.run
    LEFT JOIN sku s ON s.id = r.sku_id
    LEFT JOIN event_void v ON v.device = m.device AND v.boot = m.boot AND v.seq = m.seq AND v.restored_at IS NULL
    WHERE m.type = 'ev' AND m.from_ts IS NOT NULL AND m.to_ts IS NOT NULL AND m.to_ts >= ? AND m.from_ts <= ?
    ORDER BY m.from_ts''', [a, b]);
  final evRows = <List<Object?>>[];
  for (final r in ev) {
    final f = _p(r['from_ts']);
    final t = _p(r['to_ts']);
    final ms = (r['dur_ms'] as num?)?.toInt() ?? ((f != null && t != null) ? t.difference(f).inMilliseconds : null);
    final sh = f == null ? (day: '', name: '') : _shiftAt(sch, f);
    final ch = (r['ch'] as num?)?.toInt() ?? 1;
    final c1 = r['c1'] as String?;
    final k1 = r['k1'] as String?;
    final cls = (r['classified_at'] as num?)?.toInt();
    evRows.add([
      r['device'], r['boot'], r['seq'], ch, chName[ch] ?? 'CH$ch', r['st'],
      r['from_ts'], r['to_ts'], _loc(f), _loc(t), ms == null ? null : ms / 1000,
      sh.day, sh.name, r['run'], r['product'],
      c1 == null ? null : lossLabel(c1, k1), k1, r['c2'], r['comment'], r['user_name'],
      cls == null ? null : _loc(DateTime.fromMillisecondsSinceEpoch(cls, isUtc: true)),
      r['voided'],
    ]);
  }
  out.add(_csv('events.csv', [
    'device', 'boot', 'seq', 'channel', 'channel_name', 'type', 'start_utc', 'end_utc', 'start_local', 'end_local',
    'duration_s', 'shift_day', 'shift', 'run', 'product', 'cause_class', 'cause_class_code', 'cause_detail',
    'comment', 'classified_by', 'classified_at_local', 'voided',
  ], evRows));

  // 2) productie pe ora (impulsuri si timp ideal pe canal / run)
  final hr = await db.rawRead('''
    SELECT substr(m.ts, 1, 13) AS hr, m.ch AS ch, m.run AS run, s.name AS product,
           SUM(m.n) AS pulses, COUNT(*) AS msgs, SUM(COALESCE(m.mc, 0)) AS micro_n, SUM(COALESCE(m.md, 0)) AS micro_ms,
           SUM(m.n * COALESCE(3600.0 / NULLIF(sc.rate_bph, 0),
               CASE WHEN s.id IS NOT NULL THEN (CASE WHEN s.mode = 'pace' THEN 3600.0 / s.value ELSE s.value END) END, 0)) AS ideal_s
    FROM message m
    LEFT JOIN run r ON r.run_no = m.run
    LEFT JOIN sku s ON s.id = r.sku_id
    LEFT JOIN sku_channel sc ON sc.sku_id = s.id AND sc.ch = m.ch
    WHERE m.type = 'int' AND m.ts >= ? AND m.ts < ?
    GROUP BY substr(m.ts, 1, 13), m.ch, m.run
    ORDER BY 1, 2''', [a, b]);
  final hrRows = <List<Object?>>[];
  for (final r in hr) {
    final t = DateTime.tryParse('${r['hr']}:00:00Z');
    final ch = (r['ch'] as num?)?.toInt() ?? 1;
    final sh = t == null ? (day: '', name: '') : _shiftAt(sch, t);
    final idealS = (r['ideal_s'] as num?)?.toDouble() ?? 0;
    hrRows.add([
      t == null ? null : _iso(t), _loc(t), sh.day, sh.name, ch, chName[ch] ?? 'CH$ch', r['run'], r['product'],
      r['pulses'], idealS / 60, r['micro_n'], ((r['micro_ms'] as num?) ?? 0) / 1000, r['msgs'],
    ]);
  }
  out.add(_csv('production_hourly.csv', [
    'hour_start_utc', 'hour_start_local', 'shift_day', 'shift', 'channel', 'channel_name', 'run', 'product',
    'pulses', 'ideal_min', 'micro_stops', 'micro_stop_s', 'messages',
  ], hrRows));

  // 3) indicatori pe schimb (calcul identic cu „Linia”; doar schimburi incheiate; fara opririle live)
  final spans = <int, (DateTime, DateTime)>{};
  for (final c in chans) {
    final sp = await db.channelSpan(c.id);
    if (sp == null) continue;
    final x = _p(sp.$1);
    final y = _p(sp.$2);
    if (x != null && y != null) spans[c.id] = (x, y);
  }
  final bootGaps = <_Rng>[];
  for (final r in await db.bootGaps(a, b, 0, nowU.millisecondsSinceEpoch)) {
    var bt = _p(r['boot_ts']);
    if (bt == null && r['first_ts'] != null && r['first_up_ms'] is num) {
      final ft = _p(r['first_ts']);
      if (ft != null) bt = ft.subtract(Duration(milliseconds: (r['first_up_ms'] as num).toInt()));
    }
    if (bt == null && r['received_at'] is num) {
      bt = DateTime.fromMillisecondsSinceEpoch((r['received_at'] as num).toInt(), isUtc: true);
    }
    final pl = _p(r['prev_last']);
    if (bt != null && pl != null && bt.isAfter(pl)) bootGaps.add(_Rng(pl, bt));
  }
  final kpiRows = <List<Object?>>[];
  if (spans.isNotEmpty) {
    final firstData = spans.values.map((e) => e.$1).reduce((x, y) => x.isBefore(y) ? x : y);
    final base = (fromUtc ?? firstData).toLocal();
    final startDay = dayOnly(DateTime(base.year, base.month, base.day - 1));
    final today = dayOnly(DateTime.now());
    for (var d = startDay; !d.isAfter(today); d = DateTime(d.year, d.month, d.day + 1)) {
      final n = sch.forDay(d).length;
      for (var i = 0; i < n; i++) {
        final ws = sch.start(d, i).toUtc();
        final we = sch.end(d, i).toUtc();
        if (we.isAfter(nowU)) continue;
        if (fromUtc != null && we.isBefore(fromUtc)) continue;
        final shiftName = sch.forDay(d)[i].name;
        for (final c in chans) {
          final sp = spans[c.id];
          if (sp == null) continue;
          if (!sp.$1.isBefore(we) || (!c.active && !sp.$2.isAfter(ws))) continue;
          final fb = ble.activeRun?.sku.cycleFor(c.id) ?? 0;
          final row = await _kpiRow(db, c, sp, ws, we, bootGaps, fb);
          if (row == null) continue;
          kpiRows.add([
            '${d.year}-${_two(d.month)}-${_two(d.day)}', shiftName, c.id, c.name,
            _loc(ws), _loc(we), ...row,
          ]);
        }
      }
    }
  }
  out.add(_csv('kpi_shift.csv', [
    'shift_day', 'shift', 'channel', 'channel_name', 'start_local', 'end_local', 'products', 'planned_min',
    'no_data_min', 'excluded_min', 'stop_min', 'stop_count', 'pulses', 'ideal_min', 'availability', 'performance', 'oee',
  ], kpiRows));

  // 4) tabele de referinta
  final sk = await db.rawRead('''
    SELECT s.id AS id, s.name AS name, sc.ch AS ch, sc.rate_bph AS rate_bph, sc.trigger_s AS trigger_s,
           COALESCE(sc.target_oee, s.target_oee) AS target_oee, s.mode AS mode, s.value AS value
    FROM sku s LEFT JOIN sku_channel sc ON sc.sku_id = s.id ORDER BY s.id, sc.ch''');
  out.add(_csv('products.csv', ['product_id', 'product', 'channel', 'rate_per_hour', 'trigger_s', 'target_oee_pct'], [
    for (final r in sk)
      [
        r['id'], r['name'], r['ch'],
        r['rate_bph'] ?? (r['mode'] == 'pace' ? r['value'] : 3600 / ((r['value'] as num?) ?? 1)),
        r['trigger_s'], r['target_oee'],
      ]
  ]));

  final lc = await db.rawRead('SELECT id, parent_id, name, kind, active FROM loss_code ORDER BY parent_id IS NOT NULL, sort, id');
  out.add(_csv('loss_codes.csv', ['id', 'parent_id', 'level', 'name', 'class_code', 'active'], [
    for (final r in lc)
      [
        r['id'], r['parent_id'], r['parent_id'] == null ? 1 : 2,
        r['parent_id'] == null ? lossLabel('${r['name']}', r['kind'] as String?) : r['name'], r['kind'], r['active'],
      ]
  ]));

  final shRows = <List<Object?>>[];
  for (final p in sch.plans) {
    final f = p.from;
    final from = f == null ? '' : '${f.year}-${_two(f.month)}-${_two(f.day)}';
    for (final s in p.shifts) {
      shRows.add([from, s.name, fmtMin(s.startMin), fmtMin(s.endMin), s.endMin > 1440 ? 1 : 0]);
    }
  }
  out.add(_csv('shifts.csv', ['valid_from', 'shift', 'start', 'end', 'ends_next_day'], shRows));

  out.add(_csv('channels.csv', ['channel', 'name', 'active', 'role'], [
    for (final c in chans) [c.id, c.name, c.active ? 1 : 0, c.role],
  ]));

  final runs = await db.rawRead(
      'SELECT r.run_no AS run_no, r.sku_id AS sku_id, s.name AS product, r.started_at AS s0, r.ended_at AS e0 '
      'FROM run r LEFT JOIN sku s ON s.id = r.sku_id ORDER BY r.run_no');
  DateTime? fromMs(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true) : null;
  out.add(_csv('runs.csv', ['run', 'product_id', 'product', 'started_utc', 'started_local', 'ended_utc', 'ended_local'], [
    for (final r in runs)
      [
        r['run_no'], r['sku_id'], r['product'],
        fromMs(r['s0']) == null ? null : _iso(fromMs(r['s0'])!), _loc(fromMs(r['s0'])),
        fromMs(r['e0']) == null ? null : _iso(fromMs(r['e0'])!), _loc(fromMs(r['e0'])),
      ]
  ]));

  out.add(ExportFile('README.txt', 0, _readme(fromUtc, nowU)));
  return out;
}

/// Un rand de indicatori pentru un canal si un schimb; null daca nu e nimic de calculat (canal fara date in fereastra).
Future<List<Object?>?> _kpiRow(Db db, ChannelRow c, (DateTime, DateTime) sp, DateTime ws, DateTime we,
    List<_Rng> bootGaps, double fallbackCycleS) async {
  final a = _iso(ws), b = _iso(we);
  final es = sp.$1.isAfter(ws) ? sp.$1 : ws;
  if (!es.isBefore(we)) return null;
  final gaps = [...bootGaps];
  if (!c.active && sp.$2.isBefore(we)) gaps.add(_Rng(sp.$2, we));
  gaps.sort((x, y) => x.a.compareTo(y.a));
  var noDataMs = 0;
  DateTime? curA, curB;
  for (final g in gaps) {
    if (curB != null && !g.a.isAfter(curB)) {
      if (g.b.isAfter(curB)) curB = g.b;
    } else {
      if (curA != null && curB != null) noDataMs += _overlap(curA, curB, es, we);
      curA = g.a;
      curB = g.b;
    }
  }
  if (curA != null && curB != null) noDataMs += _overlap(curA, curB, es, we);

  final stops = await db.rawRead('''
    SELECT m.from_ts AS from_ts, m.to_ts AS to_ts, l1.kind AS k1
    FROM message m
    LEFT JOIN cause c ON c.device = m.device AND c.boot = m.boot AND c.seq = m.seq
    LEFT JOIN loss_code l1 ON l1.id = c.code1
    WHERE m.type = 'ev' AND m.st = 'stop' AND m.ch = ? AND m.from_ts IS NOT NULL AND m.to_ts IS NOT NULL
      AND m.to_ts >= ? AND m.from_ts <= ?
      AND NOT EXISTS (SELECT 1 FROM event_void v WHERE v.device = m.device AND v.boot = m.boot AND v.seq = m.seq AND v.restored_at IS NULL)''', [c.id, a, b]);
  var stopMs = 0, stopCount = 0, exclMs = 0;
  for (final e in stops) {
    final f = _p(e['from_ts']);
    final t = _p(e['to_ts']);
    if (f == null || t == null) continue;
    final o = _overlap(f, t, es, we);
    if (o <= 0) continue;
    final k = e['k1'] as String?;
    if (k == 'unscheduled' || (k == 'planned' && !db.plannedInAvail)) {
      exclMs += o;
      continue;
    }
    stopMs += o;
    stopCount++;
  }

  final pt = (await db.rawRead('''
    SELECT COALESCE(SUM(m.n), 0) AS pulses,
           COALESCE(SUM(m.n * COALESCE(
             3600.0 / NULLIF(sc.rate_bph, 0),
             CASE WHEN s.id IS NOT NULL THEN (CASE WHEN s.mode = 'pace' THEN 3600.0 / s.value ELSE s.value END) END, ?)), 0) AS ideal_s,
           COALESCE(SUM(CASE WHEN s.id IS NULL AND ? = 0 THEN m.n ELSE 0 END), 0) AS unknown,
           GROUP_CONCAT(DISTINCT s.name) AS products
    FROM message m
    LEFT JOIN run r ON r.run_no = m.run
    LEFT JOIN sku s ON s.id = r.sku_id
    LEFT JOIN sku_channel sc ON sc.sku_id = s.id AND sc.ch = m.ch
    WHERE m.type = 'int' AND m.ch = ? AND m.ts >= ? AND m.ts < ?''', [fallbackCycleS, fallbackCycleS, c.id, a, b]))
      .first;
  final pulses = (pt['pulses'] as num?)?.toInt() ?? 0;
  final unknown = (pt['unknown'] as num?)?.toInt() ?? 0;
  final idealMs = ((pt['ideal_s'] as num?)?.toDouble() ?? 0) * 1000;

  final planned = we.difference(es).inMilliseconds - noDataMs - exclMs;
  if (planned <= 0) return null;
  final av = ((planned - stopMs) / planned).clamp(0.0, 1.0);
  double? pf, oee;
  final baseMs = planned - stopMs;
  if (baseMs > 0 && !(pulses > 0 && unknown == pulses)) {
    pf = (idealMs / baseMs).clamp(0.0, 1.5);
    oee = (idealMs / planned).clamp(0.0, 1.0);
  }
  return [
    pt['products'], planned / 60000, noDataMs / 60000, exclMs / 60000, stopMs / 60000, stopCount, pulses,
    idealMs / 60000, av, pf, oee,
  ];
}

String _readme(DateTime? from, DateTime now) => '''OEE - export CSV pentru Power BI / Excel
Generat: ${_loc(now)} (ora tabletei). Interval: ${from == null ? 'toate datele' : 'de la ${_loc(from)}'}.

Format: UTF-8 cu BOM, separator virgula, zecimale cu punct. In Power BI: Obtine date > Text/CSV; la zecimale alege
setarile regionale "English (United States)" (Transform > Using Locale), altfel cifrele pot fi citite gresit.

events.csv            un rand pe eveniment (opriri, microopriri, viteza redusa / peste nominal), cu motivul dat de operator.
production_hourly.csv impulsuri si timp ideal pe ora, canal si run. ideal_min = impulsuri x timp de ciclu al produsului.
kpi_shift.csv         indicatori pe schimb si canal, calculati ca in ecranul Linia (doar schimburi incheiate):
                      availability = (planificat - opriri) / planificat; performance = timp ideal / (planificat - opriri);
                      oee = timp ideal / planificat. Performanta nu e plafonata la 100% (poate depasi 1).
products.csv, loss_codes.csv, shifts.csv, channels.csv, runs.csv   tabele de referinta.

Legatura: events.channel / production_hourly.channel / kpi_shift.channel = channels.channel; run = runs.run;
product dupa nume (products.product). Ora locala = ora setata pe tableta.
''';

class ExportPage extends StatefulWidget {
  const ExportPage(this.ble, {super.key});
  final BleService ble;
  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  int _days = 31; // 0 = toate datele
  bool _busy = false;
  String? _error;
  List<ExportFile> _files = const [];

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final from = _days == 0 ? null : DateTime.now().toUtc().subtract(Duration(days: _days));
      final files = await buildExport(widget.ble, from);
      if (!mounted) return;
      setState(() => _files = files);
      final dir = await getTemporaryDirectory();
      final t = DateTime.now();
      final sub = Directory('${dir.path}/oee_export_${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}');
      await sub.create(recursive: true);
      final xs = <XFile>[];
      for (final f in files) {
        final file = File('${sub.path}/${f.name}');
        await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(f.text)]);
        xs.add(XFile(file.path, mimeType: f.name.endsWith('.csv') ? 'text/csv' : 'text/plain'));
      }
      await widget.ble.db.logExport('days=$_days files=${files.length}');
      await Share.shareXFiles(xs, subject: 'OEE export');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: i18n,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: Text(tr('exp.title')), actions: [UserButton(widget.ble.db)]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text(tr('exp.range'), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final o in [(7, 'exp.d7'), (31, 'exp.d31'), (0, 'exp.all')])
                ChoiceChip(
                  label: Text(tr(o.$2)),
                  selected: _days == o.$1,
                  onSelected: _busy ? null : (_) => setState(() => _days = o.$1),
                ),
            ]),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.ios_share),
              label: Text(tr('exp.go')),
            ),
            const SizedBox(height: 12),
            Text(tr('exp.note')),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (_files.isNotEmpty) ...[
              const Divider(height: 32),
              Text(tr('exp.files'), style: Theme.of(context).textTheme.titleSmall),
              for (final f in _files)
                ListTile(
                  dense: true,
                  title: Text(f.name),
                  trailing: f.rows == 0 && f.name.endsWith('.txt') ? null : Text(trp('exp.rows', {'n': f.rows})),
                ),
            ],
          ]),
        ),
      );
}
