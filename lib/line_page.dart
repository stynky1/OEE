// Ecranul "Linia" (tablou de bord): stare + viteza, KPI (OEE provizoriu, Disponibilitate, Performanta, Calitate),
// grafic de viteza fata de tinta, cronologia schimbului (atingi pentru detalii) si Pareto al cauzelor de oprire.
// Datele vin din mesajele salvate pe tableta (int = impulsuri pe 5 s, ev = evenimente); starea live din Status (1 Hz).
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'ble_service.dart';
import 'channels_page.dart';
import 'control.dart';
import 'db.dart';
import 'i18n.dart';
import 'login_page.dart';
import 'shifts.dart';

const _cRun = Color(0xFF16A34A);
const _cSlow = Color(0xFFFF9800); // portocaliu (distinct de rosu = oprit si de galben = microoprire)
const _cMicro = Color(0xFFFACC15); // galben
const _cStop = Color(0xFFDC2626);
const _cFast = Color(0xFF2563EB);
const _cNone = Color(0xFF9CA3AF);
const _cFuture = Color(0xFFE5E7EB);

const _intervalS = 5; // firmware: un mesaj "int" la fiecare 5 s
const _kLive = -1; // „Ultimele 8 ore” (live)
const _kCustom = -2; // „Interval” (de la – pana la, ales de utilizator)

class _Ev {
  _Ev(this.st, this.from, this.to, this.ms, this.cat, this.sub, this.comment, this.kind, {this.synthetic = false});
  final bool synthetic; // oprire de inceput de schimb creata local (device APP)
  final String st;
  final String? kind; // clasa IWS a motivului (unscheduled | planned | unplanned | ...), null = neclasificat sau cod vechi
  final DateTime from, to;
  final int ms;
  final String? cat, sub, comment;
}

class _Rng {
  _Rng(this.a, this.b);
  final DateTime a, b;
}

class _Win {
  _Win(this.start, this.end, this.isShift, {this.custom = false});
  final DateTime start, end; // UTC; end = sfarsitul schimbului (poate fi in viitor)
  final bool isShift; // schimb sau interval ales: se calculeaza indicatorii
  final bool custom; // interval ales de utilizator
}

String _fmt(int ms) {
  final s = (ms / 1000).round();
  if (s < 60) return '$s s';
  final m = s ~/ 60;
  if (m < 60) return '$m min ${s % 60} s';
  return '${m ~/ 60} h ${m % 60} min';
}

String _two(int v) => v.toString().padLeft(2, '0');

String _dm(DateTime t) => '${_two(t.day)}.${_two(t.month)}';

String _hhmm(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

String _iso(DateTime t) => '${t.toUtc().toIso8601String().split('.').first}Z';

/// 5285 -> „5.285” (separator de mii).
String _group(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return n < 0 ? '-$b' : b.toString();
}

String _pct(double? v) => v == null ? '—' : '${(v * 100).round()}%';

int _overlap(DateTime a0, DateTime a1, DateTime b0, DateTime b1) {
  final s = a0.isAfter(b0) ? a0 : b0;
  final e = a1.isBefore(b1) ? a1 : b1;
  final d = e.difference(s).inMilliseconds;
  return d > 0 ? d : 0;
}

Color _stColor(String st) {
  switch (st) {
    case 'stop':
      return _cStop;
    case 'slow':
      return _cSlow;
    case 'micro':
      return _cMicro;
    case 'fast':
      return _cFast;
    default:
      return _cRun;
  }
}

String _stName(String st) {
  switch (st) {
    case 'stop':
      return tr('ev.stop');
    case 'micro':
      return tr('ev.micro');
    case 'slow':
      return tr('ev.slow');
    case 'fast':
      return tr('ev.fast');
    default:
      return tr('ev.run');
  }
}

class LinePage extends StatefulWidget {
  const LinePage(this.ble, {super.key});
  final BleService ble;
  @override
  State<LinePage> createState() => _LinePageState();
}

class _LinePageState extends State<LinePage> {
  int _sel = _kLive; // >= 0: indexul schimbului in programul zilei; _kLive / _kCustom
  DateTime? _day; // ziua (locala) a schimbului afisat; null = azi / acum
  DateTime _cFrom = DateTime.now().subtract(const Duration(hours: 2)); // modul Interval
  DateTime _cTo = DateTime.now();
  Timer? _timer;
  int _lastStored = -1;
  DateTime? _tapT;
  double _tlWidth = 300;

  // rezultate incarcate
  List<_Ev> _events = const [];
  List<_Rng> _noData = const [];
  List<double?> _series = const [];
  List<double?> _targets = const []; // tinta (buc/ora) pe fiecare bucata a graficului
  int _bucketS = 60;
  DateTime? _chartStart;
  DateTime? _effStart; // primul moment cu date in fereastra
  double? _avail, _perf, _oee;
  int _stopMs = 0, _stopCount = 0, _noDataMs = 0, _unknownPulses = 0, _plannedMs = 0;
  double? _speedNow; // buc/ora, calculat pe ultimul minut
  int _pieces = 0; // sticle numarate in fereastra afisata (de la inceputul schimbului)
  int _exclMs = 0; // timp exclus din calcul (opriri neprogramate / planificate, dupa setare)
  int _loadedCh = 1; // canalul pentru care sunt incarcate rezultatele
  int _pending = 0; // opriri de clasificat pe canalul afisat

  @override
  void initState() {
    super.initState();
    _sel = _currentShift(DateTime.now().toUtc()) ?? _kLive;
    widget.ble.addListener(_onBle);
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
    _load();
  }

  @override
  void dispose() {
    widget.ble.removeListener(_onBle);
    _timer?.cancel();
    super.dispose();
  }

  bool _viewedActive(BleService ble) {
    for (final c in ble.channelList) {
      if (c.id == ble.db.viewCh) return c.active;
    }
    return true;
  }

  DateTime _lastLoad = DateTime.fromMillisecondsSinceEpoch(0);

  void _onBle() {
    // incarcarea e costisitoare cand sunt mii de evenimente: cel mult o data la 10 s (plus temporizatorul de 15 s)
    if (widget.ble.db.viewCh != _loadedCh) {
      _lastStored = widget.ble.stored;
      _load(); // s-a schimbat canalul afisat: reincarcare imediata
      return;
    }
    if (widget.ble.stored != _lastStored && DateTime.now().difference(_lastLoad).inSeconds >= 10) {
      _lastStored = widget.ble.stored;
      _load();
    }
  }

  ShiftSchedule get _sch => widget.ble.db.shifts;

  int? _currentShift(DateTime nowUtc) => _sch.current(nowUtc.toLocal())?.idx;

  _Win _shiftWin(ShiftWindow w) => _Win(_sch.start(w.day, w.idx).toUtc(), _sch.end(w.day, w.idx).toUtc(), true);

  /// Schimbul afisat cand este ales un schimb (_sel >= 0): ziua aleasa, altfel cea mai recenta aparitie a lui.
  ShiftWindow _shownShift(DateTime nowUtc) {
    final n = nowUtc.toLocal();
    if (_day != null) {
      final l = _sch.forDay(_day!).length;
      return ShiftWindow(_day!, _sel < l ? _sel : l - 1);
    }
    // cea mai recenta aparitie inceputa a schimbului ales (programul se poate fi schimbat intre zile)
    for (var back = 0; back <= 7; back++) {
      final d = DateTime(n.year, n.month, n.day - back);
      if (_sel < _sch.forDay(d).length && !_sch.start(d, _sel).isAfter(n)) return ShiftWindow(d, _sel);
    }
    // inca nu a existat (program nou): schimbul de azi, care urmeaza
    final t = DateTime(n.year, n.month, n.day);
    return ShiftWindow(t, _sel < _sch.forDay(t).length ? _sel : 0);
  }

  /// Un pas inapoi / inainte in istoric (schimb sau interval).
  void _step(int dir) {
    final nowU = DateTime.now().toUtc();
    if (_sel == _kCustom) {
      final len = _cTo.difference(_cFrom);
      final nf = _cFrom.add(len * dir), nt = _cTo.add(len * dir);
      if (nf.isAfter(DateTime.now())) return;
      setState(() {
        _cFrom = nf;
        _cTo = nt;
        _tapT = null;
      });
      _load();
      return;
    }
    ShiftWindow target;
    if (_sel < 0) {
      // live: primul pas inapoi arata schimbul curent (sau cel mai recent incheiat)
      if (dir > 0) return;
      final ls = _sch.lastStarted(DateTime.now());
      if (ls == null) return;
      target = ls;
    } else {
      target = _sch.neighbor(_shownShift(nowU), dir);
      final st = _sch.start(target.day, target.idx);
      if (st.isAfter(DateTime.now()) || st.year < 2025) return; // nu se merge in viitor
    }
    setState(() {
      _day = target.day;
      _sel = target.idx;
      _tapT = null;
    });
    _load();
  }

  bool _canForward(DateTime nowUtc) {
    if (_sel == _kCustom) return !_cFrom.add(_cTo.difference(_cFrom)).isAfter(DateTime.now());
    if (_sel < 0) return false; // live: nu exista „mai departe”
    final n = _sch.neighbor(_shownShift(nowUtc), 1);
    return !_sch.start(n.day, n.idx).isAfter(nowUtc.toLocal());
  }

  void _goLive() {
    setState(() {
      _day = null;
      _sel = _currentShift(DateTime.now().toUtc()) ?? _kLive;
      _tapT = null;
    });
    _load();
  }

  Future<void> _pickDay() async {
    final p = await showDatePicker(
      context: context,
      initialDate: _day ?? DateTime.now(),
      firstDate: DateTime(2025, 1, 1),
      lastDate: DateTime.now(),
      helpText: 'Alege ziua',
    );
    if (p == null || !mounted) return;
    setState(() {
      _day = DateTime(p.year, p.month, p.day);
      if (_sel < 0) _sel = 0;
      _tapT = null;
    });
    _load();
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final now = DateTime.now();
    final init = initial.isAfter(now) ? now : initial;
    final d = await showDatePicker(
        context: context, initialDate: init, firstDate: DateTime(2025, 1, 1), lastDate: now);
    if (d == null || !mounted) return null;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(init));
    if (t == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  void _startCustom() {
    final nowU = DateTime.now().toUtc();
    final w = _window(nowU);
    setState(() {
      _cFrom = w.start.toLocal();
      _cTo = (w.end.isAfter(nowU) ? nowU : w.end).toLocal();
      _sel = _kCustom;
      _tapT = null;
    });
    _load();
  }

  Future<void> _pickFrom() async {
    final t = await _pickDateTime(_cFrom);
    if (t == null) return;
    if (!t.isBefore(_cTo)) {
      _warn(tr('hist.fromBeforeTo'));
      return;
    }
    setState(() => _cFrom = t);
    _load();
  }

  Future<void> _pickTo() async {
    final t = await _pickDateTime(_cTo);
    if (t == null) return;
    if (!t.isAfter(_cFrom)) {
      _warn(tr('hist.toAfterFrom'));
      return;
    }
    setState(() => _cTo = t);
    _load();
  }

  void _warn(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  _Win _window(DateTime nowUtc) {
    if (_sel == _kCustom) return _Win(_cFrom.toUtc(), _cTo.toUtc(), true, custom: true);
    if (_sel == _kLive) return _Win(nowUtc.subtract(const Duration(hours: 8)), nowUtc, false);
    return _shiftWin(_shownShift(nowUtc));
  }

  Future<void> _load() async {
    _lastLoad = DateTime.now();
    final ble = widget.ble;
    final db = ble.db;
    final nowU = DateTime.now().toUtc();
    final w = _window(nowU);
    final upTo = nowU.isBefore(w.end) ? nowU : w.end;
    final a = _iso(w.start), b = _iso(upTo);
    final ch = db.viewCh;
    _loadedCh = ch;
    final pending = await db.pendingCount(ch: ch);

    final rows = await db.eventsDetailed(a, b);
    final span = await db.channelSpan(ch);
    final first = span?.$1;
    var chActive = true;
    for (final c in ble.channelList) {
      if (c.id == ch) chActive = c.active;
    }
    final ints = await db.intervalsSince(a);
    final recent = await db.intervalsSince(_iso(nowU.subtract(const Duration(seconds: 90))));
    final pt = await db.pulseTotals(a, b, ble.activeRun?.sku.cycleFor(ch) ?? 0);
    final bg = await db.bootGaps(a, b, w.start.millisecondsSinceEpoch, upTo.millisecondsSinceEpoch);

    final evs = <_Ev>[];
    for (final r in rows) {
      final f = DateTime.tryParse('${r['from_ts']}');
      final t = DateTime.tryParse('${r['to_ts']}');
      if (f == null || t == null) continue;
      final ms = (r['dur_ms'] as num?)?.toInt() ?? t.difference(f).inMilliseconds;
      final k1 = r['k1'] as String?;
      final c1 = r['c1'] as String?;
      evs.add(_Ev('${r['st']}', f, t, ms, c1 == null ? null : lossLabel(c1, k1), r['c2'] as String?,
          r['comment'] as String?, k1, synthetic: r['device'] == kAppDevice));
    }
    // oprire de inceput de schimb (de la inceputul schimbului pana la prima sticla): calculul porneste de la inceputul schimbului
    _Ev? lead;
    for (final e in evs) {
      if (e.synthetic && e.st == 'stop' && !e.from.isAfter(w.start.add(const Duration(seconds: 1)))) lead = e;
    }
    // schimb in desfasurare, conectat, canal activ, nicio sticla inca in schimb: oprirea inca nu e salvata, dar se numara
    final sinceStart = nowU.difference(w.start).inSeconds;
    if (lead == null && w.isShift && !w.custom && ble.connected && chActive && nowU.isBefore(w.end) && sinceStart >= 60 &&
        ((pt['pulses'] as num?)?.toInt() ?? 0) == 0 && !evs.any((e) => e.st != 'stop')) {
      lead = _Ev('stop', w.start, nowU, nowU.difference(w.start).inMilliseconds, null, null, null, null, synthetic: true);
      evs.add(lead);
    }

    final ds = first == null ? null : DateTime.tryParse(first);
    // canal fara date in fereastra: nimic de calculat (nu 100 % disponibilitate)
    var es = span == null ? upTo : ((ds != null && ds.isAfter(w.start)) ? ds : w.start);
    if (lead != null) es = w.start;

    // intervale fara date (ESP32 repornit): de la ultimul mesaj din boot-ul precedent pana la mesajul boot
    final gaps = <_Rng>[];
    for (final r in bg) {
      DateTime? bt = r['boot_ts'] == null ? null : DateTime.tryParse('${r['boot_ts']}');
      if (bt == null && r['first_ts'] != null && r['first_up_ms'] is num) {
        // mesajul boot nu are ora: repornirea = ora primului mesaj cu ora minus uptime-ul lui
        final ft = DateTime.tryParse('${r['first_ts']}');
        if (ft != null) bt = ft.subtract(Duration(milliseconds: (r['first_up_ms'] as num).toInt()));
      }
      if (bt == null && r['received_at'] is num) {
        bt = DateTime.fromMillisecondsSinceEpoch((r['received_at'] as num).toInt(), isUtc: true);
      }
      final pl = r['prev_last'] == null ? null : DateTime.tryParse('${r['prev_last']}');
      if (bt != null && pl != null && bt.isAfter(pl)) gaps.add(_Rng(pl, bt));
    }
    // golurile din oprirea de inceput de schimb nu se mai numara ca „fara date” (e deja oprire)
    if (lead != null) {
      final le = lead.to;
      for (var i = gaps.length - 1; i >= 0; i--) {
        final g = gaps[i];
        if (g.b.isAfter(w.start) && g.a.isBefore(le)) {
          if (g.b.isAfter(le)) {
            gaps[i] = _Rng(g.a.isAfter(le) ? g.a : le, g.b);
          } else {
            gaps.removeAt(i);
          }
        }
      }
    }
    // canal inactiv: dupa ultimul lui mesaj nu mai sunt date
    final lastCh = span == null ? null : DateTime.tryParse(span.$2);
    if (!chActive && lastCh != null && lastCh.isBefore(upTo)) gaps.add(_Rng(lastCh, upTo));
    // goluri unite (repornirile si coada canalului inactiv se pot suprapune: nu se numara de doua ori)
    final sortedGaps = [...gaps]..sort((x, y) => x.a.compareTo(y.a));
    var noDataMs = 0;
    DateTime? curA, curB;
    for (final g in sortedGaps) {
      if (curB != null && !g.a.isAfter(curB)) {
        if (g.b.isAfter(curB)) curB = g.b;
      } else {
        if (curA != null && curB != null) noDataMs += _overlap(curA, curB, es, upTo);
        curA = g.a;
        curB = g.b;
      }
    }
    if (curA != null && curB != null) noDataMs += _overlap(curA, curB, es, upTo);

    var stopMs = 0, stopCount = 0, exclMs = 0;
    for (final e in evs) {
      if (e.st != 'stop') continue;
      final o = _overlap(e.from, e.to, es, upTo);
      if (o > 0) {
        // IWS: opririle neprogramate (weekend, nu e nevoie de linie) nu fac parte din timpul planificat;
        // cele planificate raman pierdere in Disponibilitate, daca setarea e activa (implicit da)
        if (e.kind == 'unscheduled' || (e.kind == 'planned' && !db.plannedInAvail)) {
          exclMs += o;
          continue;
        }
        stopMs += o;
        stopCount++;
      }
    }
    final st = ble.viewStatus;
    // (daca oprirea de inceput de schimb e inca in curs, ea acopera deja acest interval)
    final leadLive = lead != null && lead.to.isAfter(nowU.subtract(const Duration(seconds: 2)));
    if (ble.connected && st != null && st.state == 2 && !leadLive) {
      final lf = nowU.subtract(Duration(milliseconds: st.sinceLastMs));
      final o = _overlap(lf, nowU, es, upTo);
      if (o > 0) {
        stopMs += o;
        stopCount++;
      }
    }

    // KPI (doar pentru schimburi): A = (planificat - opriri) / planificat; P = timp ideal / (planificat - opriri)
    double? av, pf, oee;
    final planned = upTo.difference(es).inMilliseconds - noDataMs - exclMs;
    final pulses = (pt['pulses'] as num?)?.toInt() ?? 0;
    final unknown = (pt['unknown'] as num?)?.toInt() ?? 0;
    final idealMs = ((pt['ideal_s'] as num?)?.toDouble() ?? 0) * 1000;
    if (w.isShift && planned > 0) {
      av = ((planned - stopMs) / planned).clamp(0.0, 1.0);
      final base = planned - stopMs;
      if (base > 0 && !(pulses > 0 && unknown == pulses)) {
        pf = (idealMs / base).clamp(0.0, 1.5);
        oee = (idealMs / planned).clamp(0.0, 1.0);
      }
    }

    // grafic de viteza: bucati de cel putin 60 s
    var cs = w.start; // graficul incepe de la primul mesaj din fereastra (nu din golul de dinainte)
    for (final r in ints) {
      final t0 = DateTime.tryParse('${r['ts']}');
      if (t0 != null) {
        if (t0.isAfter(cs)) cs = t0;
        break;
      }
    }
    final totalS = upTo.difference(cs).inSeconds;
    final bucketS = math.max(60, (totalS / 150).ceil());
    final nb = totalS <= 0 ? 0 : (totalS / bucketS).ceil();
    final sums = List<int>.filled(nb, 0);
    final cov = List<int>.filled(nb, 0);
    for (final r in ints) {
      final t = DateTime.tryParse('${r['ts']}');
      if (t == null) continue;
      final idx = t.difference(cs).inSeconds ~/ bucketS;
      if (idx < 0 || idx >= nb) continue;
      sums[idx] += (r['n'] as num?)?.toInt() ?? 0;
      cov[idx] += 1;
    }
    final series = <double?>[
      for (var i = 0; i < nb; i++) cov[i] == 0 ? null : sums[i] * 3600.0 / (cov[i] * _intervalS), // buc / ora
    ];

    // tinta pe fiecare bucata: ritmul propriu al canalului sau al produsului run-ului din acea bucata (se mentine pana la urmatorul run)
    final paces = await db.runPaces();
    final lastRun = List<int?>.filled(nb, null);
    for (final r in ints) {
      final t = DateTime.tryParse('${r['ts']}');
      if (t == null) continue;
      final idx = t.difference(cs).inSeconds ~/ bucketS;
      if (idx < 0 || idx >= nb) continue;
      lastRun[idx] = (r['run'] as num?)?.toInt();
    }
    final dflt = ble.activeRun == null ? null : ble.activeRun!.sku.rateFor(ch); // buc / ora
    final targets = List<double?>.filled(nb, null);
    double? carry;
    for (var i = 0; i < nb; i++) {
      final p = lastRun[i] == null ? null : paces[lastRun[i]!];
      if (p != null) carry = p; // buc / ora
      targets[i] = carry ?? dflt;
    }

    // in timpul unei opriri ESP32 nu trimite mesaje "int": minutele acoperite de o oprire se afiseaza cu 0 (nu se unesc punctele din jur)
    for (var i = 0; i < nb; i++) {
      if (series[i] != null) continue;
      final mid = cs.add(Duration(seconds: i * bucketS + bucketS ~/ 2));
      for (final e in evs) {
        if (e.st == 'stop' && !mid.isBefore(e.from) && !mid.isAfter(e.to)) {
          series[i] = 0.0;
          break;
        }
      }
    }

    // viteza curenta: impulsuri in ultimele 60 s
    double? speedNow;
    final cut = nowU.subtract(const Duration(seconds: 60));
    var rn = 0, rc = 0;
    for (final r in recent) {
      final t = DateTime.tryParse('${r['ts']}');
      if (t == null || t.isBefore(cut)) continue;
      rn += (r['n'] as num?)?.toInt() ?? 0;
      rc++;
    }
    if (rc > 0) speedNow = rn * 3600.0 / (rc * _intervalS); // buc / ora

    if (!mounted) return;
    setState(() {
      _pending = pending;
      _events = evs;
      _noData = gaps;
      _series = series;
      _targets = targets;
      _chartStart = cs;
      _bucketS = bucketS;
      _effStart = es;
      _avail = av;
      _perf = pf;
      _oee = oee;
      _stopMs = stopMs;
      _exclMs = exclMs;
      _stopCount = stopCount;
      _noDataMs = noDataMs;
      _plannedMs = planned > 0 ? planned : 0;
      _unknownPulses = unknown;
      _speedNow = speedNow;
      _pieces = pulses;
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.ble,
        builder: (context, _) {
          final ble = widget.ble;
          final nowU = DateTime.now().toUtc();
          final w = _window(nowU);
          final upTo = nowU.isBefore(w.end) ? nowU : w.end;
          final cur = _currentShift(nowU);
          final left = <Widget>[
            _kpiCard(context, w),
            const SizedBox(height: 12),
            _speedCard(context, w, upTo),
          ];
          final right = <Widget>[
            _timelineCard(context, w, upTo),
            const SizedBox(height: 12),
            _paretoCard(context),
          ];
          return Scaffold(
            appBar: AppBar(title: Text(tr('nav.line')), actions: [UserButton(widget.ble.db)]),
            body: ListView(padding: const EdgeInsets.all(16), children: [
              _statusCard(),
              if (ble.paramsPending && ble.activeRun != null)
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    leading: const Icon(Icons.sync_problem),
                    title: Text(tr('line.paramsPending')),
                    subtitle: Text(ble.connected ? tr('line.paramsRetrying') : tr('line.paramsOffline')),
                    trailing: ble.connected
                        ? TextButton(onPressed: () => ble.pushConfig(), child: Text(tr('line.paramsNow')))
                        : null,
                  ),
                ),
              if (ble.db.viewCh != 1 && (ble.status?.chans.isEmpty ?? true))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(trp('line.liveNote', {'ch': ble.db.viewCh}),
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              if (!_viewedActive(ble))
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(trp('ch.histNote', {'ch': ble.db.viewCh})),
                    trailing: TextButton(
                      onPressed: () => ble.setViewChannel(ble.db.mainCh),
                      child: Text(tr('ch.backMain')),
                    ),
                  ),
                ),
              if (!ble.running)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FilledButton.icon(
                    onPressed: () => startCollector(ble),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(tr('line.startCollect')),
                  ),
                ),
              const SizedBox(height: 16),
              ChannelSelector(ble),
              Wrap(spacing: 8, children: [
                for (var i = 0; i < _sch.forDay(_day ?? DateTime.now()).length; i++)
                  ChoiceChip(
                    label: Text(_sch.forDay(_day ?? DateTime.now())[i].name),
                    selected: _sel == i,
                    onSelected: (_) {
                      setState(() {
                        _sel = i;
                        _tapT = null;
                      });
                      _load();
                    },
                  ),
                ChoiceChip(
                  label: Text(tr('line.last8h')),
                  selected: _sel == _kLive,
                  onSelected: (_) {
                    setState(() {
                      _sel = _kLive;
                      _day = null;
                      _tapT = null;
                    });
                    _load();
                  },
                ),
                ChoiceChip(
                  label: Text(tr('line.interval')),
                  selected: _sel == _kCustom,
                  onSelected: (_) => _startCustom(),
                ),
              ]),
              Row(children: [
                IconButton(
                  tooltip: tr('hist.prev'),
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _step(-1),
                ),
                Expanded(
                  child: Text(_windowCaption(w, upTo, cur),
                      textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelMedium),
                ),
                IconButton(
                  tooltip: tr('hist.next'),
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _canForward(nowU) ? () => _step(1) : null,
                ),
                IconButton(
                  tooltip: tr('hist.pickDay'),
                  icon: const Icon(Icons.calendar_month_outlined),
                  onPressed: _pickDay,
                ),
                if (_day != null || _sel == _kCustom) TextButton(onPressed: _goLive, child: Text(tr('hist.now'))),
              ]),
              if (_sel == _kCustom)
                Wrap(spacing: 8, runSpacing: 4, children: [
                  OutlinedButton.icon(
                    onPressed: _pickFrom,
                    icon: const Icon(Icons.schedule),
                    label: Text(trp('hist.from', {'t': '${_dm(_cFrom)} ${_hhmm(_cFrom)}'})),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickTo,
                    icon: const Icon(Icons.schedule),
                    label: Text(trp('hist.to', {'t': '${_dm(_cTo)} ${_hhmm(_cTo)}'})),
                  ),
                ]),
              const SizedBox(height: 12),
              LayoutBuilder(builder: (context, box) {
                if (box.maxWidth >= 900) {
                  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Column(children: left)),
                    const SizedBox(width: 16),
                    Expanded(child: Column(children: right)),
                  ]);
                }
                return Column(children: [...left, const SizedBox(height: 12), ...right]);
              }),
            ]),
          );
        },
      );

  /// Tinta de la sfarsitul ferestrei afisate (cea din ultima bucata cu tinta cunoscuta).
  double? _winTarget() {
    for (var i = _targets.length - 1; i >= 0; i--) {
      if (_targets[i] != null) return _targets[i];
    }
    return null;
  }

  /// Tinta de viteza (buc/ora) a canalului afisat: viteza din reteta produsului activ pe acest canal.
  double? _targetBpm() {
    final run = widget.ble.activeRun;
    return run == null ? null : run.sku.rateFor(widget.ble.db.viewCh);
  }

  String _windowCaption(_Win w, DateTime upTo, int? cur) {
    final ls = w.start.toLocal();
    final day = '${_two(ls.day)}.${_two(ls.month)}';
    final outside = cur == null ? ' · ${tr('hist.outside')}' : '';
    if (w.custom) {
      final le = w.end.toLocal();
      return '${tr('line.interval')} · $day ${_hhmm(w.start)} → ${_two(le.day)}.${_two(le.month)} ${_hhmm(w.end)}';
    }
    if (!w.isShift) return '${tr('hist.last8until')}$outside';
    final state = upTo.isBefore(w.start)
        ? tr('hist.upcoming')
        : (upTo.isBefore(w.end) ? tr('hist.inprogress') : tr('hist.ended'));
    return '$day · ${_hhmm(w.start)}–${_hhmm(w.end)} · $state$outside';
  }

  // ───────────── KPI ─────────────

  Widget _kpiCard(BuildContext context, _Win w) {
    final run = widget.ble.activeRun;
    final t = run?.sku.targetFor(widget.ble.db.viewCh);
    final tgt = t == null ? null : (t > 1 ? t / 100 : t);
    final primary = Theme.of(context).colorScheme.primary;
    Color oeeColor = primary;
    if (_oee != null && tgt != null) {
      oeeColor = _oee! >= tgt ? _cRun : (_oee! >= tgt - 0.10 ? _cSlow : _cStop);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(w.custom ? tr('kpi.titleInterval') : (w.isShift ? tr('kpi.titleShift') : tr('kpi.title')),
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          Text(trp(w.isShift && !w.custom ? 'kpi.piecesShift' : 'kpi.pieces', {'n': _group(_pieces)}),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          if (!w.isShift)
            Text(tr('kpi.hint'))
          else ...[
            Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _Ring('OEE', _oee, oeeColor, tr('kpi.noQuality')),
              _Ring(tr('kpi.avail'), _avail, primary, null),
              _Ring(tr('kpi.perf'), _perf, primary, null),
              _Ring(tr('kpi.quality'), null, _cNone, tr('kpi.noData')),
            ]),
            const SizedBox(height: 12),
            Text(
              trp(w.custom ? 'kpi.calcInterval' : 'kpi.calcShift', {
                'a': _fmt(_plannedMs),
                'nd': _noDataMs > 0 ? trp('kpi.withoutNoData', {'t': _fmt(_noDataMs)}) : '',
              }),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 16, runSpacing: 4, children: [
              Text(trp('kpi.stops', {'n': _stopCount, 't': _fmt(_stopMs)})),
              if (_noDataMs > 0) Text(trp('kpi.noDataT', {'t': _fmt(_noDataMs)})),
              if (_exclMs > 0) Text(trp('kpi.excl', {'t': _fmt(_exclMs)})),
              Text(trp('kpi.toClassify', {'n': _pending})),
            ]),
            if (run == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('kpi.noProduct'),
                    style: Theme.of(context).textTheme.labelSmall),
              ),
            if (_unknownPulses > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  trp('kpi.unknownPulses', {'n': _unknownPulses}),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
          ],
        ]),
      ),
    );
  }

  // ───────────── grafic viteza ─────────────

  Widget _speedCard(BuildContext context, _Win w, DateTime upTo) {
    final target = _winTarget() ?? _targetBpm();
    final cs = _chartStart ?? w.start;
    final span = upTo.difference(cs).inMilliseconds;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(tr('speed.title'), style: Theme.of(context).textTheme.titleSmall)),
            if (target != null)
              Text(trp('speed.target', {'v': target.toStringAsFixed(0)}), style: Theme.of(context).textTheme.labelMedium),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            width: double.infinity,
            child: CustomPaint(
              painter: _SpeedPainter(_series, target, _targets, Theme.of(context).colorScheme.primary,
                  Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (var k = 0; k < 5; k++)
              Text(_hhmm(cs.add(Duration(milliseconds: span * k ~/ 4))),
                  style: Theme.of(context).textTheme.labelSmall),
          ]),
          if (_series.every((v) => v == null))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr('speed.nodata'),
                  style: Theme.of(context).textTheme.labelSmall),
            ),
          Text(trp('speed.avg', {'t': _bucketS >= 120 ? '${(_bucketS / 60).round()} min' : '1 min'}),
              style: Theme.of(context).textTheme.labelSmall),
        ]),
      ),
    );
  }

  // ───────────── cronologie ─────────────

  Widget _timelineCard(BuildContext context, _Win w, DateTime upTo) {
    final s = widget.ble.viewStatus;
    final liveStop = widget.ble.connected && s != null && s.state == 2;
    final liveFrom = liveStop ? DateTime.now().toUtc().subtract(Duration(milliseconds: s.sinceLastMs)) : null;
    final span = w.end.difference(w.start).inMilliseconds;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('tl.title'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, box) {
            _tlWidth = box.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                final frac = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0);
                setState(() => _tapT = w.start.add(Duration(milliseconds: (span * frac).round())));
              },
              child: SizedBox(
                height: 44,
                width: double.infinity,
                child: CustomPaint(
                  painter: _TimelinePainter(
                      w.start, w.end, upTo, _effStart ?? w.start, _events, _noData, liveFrom, _tapT),
                ),
              ),
            );
          }),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (var k = 0; k < 5; k++)
              Text(_hhmm(w.start.add(Duration(milliseconds: span * k ~/ 4))),
                  style: Theme.of(context).textTheme.labelSmall),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 4, children: [
            _Legend(_cRun, tr('ev.run')),
            _Legend(_cSlow, tr('ev.slow')),
            _Legend(_cMicro, tr('ev.micro')),
            _Legend(_cStop, tr('ev.stopped')),
            _Legend(_cFast, tr('ev.fast')),
            _Legend(_cNone, tr('ev.nodata')),
          ]),
          const Divider(height: 24),
          _details(context, w, upTo, span),
        ]),
      ),
    );
  }

  Widget _details(BuildContext context, _Win w, DateTime upTo, int spanMs) {
    final t = _tapT;
    final style = Theme.of(context).textTheme.bodyMedium;
    if (t == null) return Text(tr('tl.tap'), style: style);
    if (t.isAfter(upTo)) return Text(trp('tl.future', {'t': _hhmm(t)}), style: style);
    final tolMs = (spanMs / math.max(_tlWidth, 1) * 8).round();
    _Ev? hit;
    var best = 1 << 62;
    for (final e in _events) {
      final dist = t.isBefore(e.from)
          ? e.from.difference(t).inMilliseconds
          : (t.isAfter(e.to) ? t.difference(e.to).inMilliseconds : 0);
      if (dist > tolMs) continue;
      if (dist < best || (dist == best && e.st == 'stop')) {
        best = dist;
        hit = e;
      }
    }
    if (hit != null) {
      final e = hit;
      final cause = e.cat == null ? null : (e.sub == null ? e.cat : '${e.cat} › ${e.sub}');
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: _stColor(e.st), shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(_stName(e.st), style: Theme.of(context).textTheme.titleSmall),
        ]),
        const SizedBox(height: 4),
        Text('${_hhmm(e.from)} – ${_hhmm(e.to)} · ${_fmt(e.ms)}', style: style),
        if (e.synthetic) Text(tr('tl.shiftStart'), style: style),
        if (e.st == 'stop')
          Text(cause == null ? tr('tl.causeNone') : trp('tl.cause', {'c': cause}), style: style),
        if (e.comment != null && e.comment!.isNotEmpty) Text(trp('tl.comment', {'c': e.comment}), style: style),
      ]);
    }
    for (final g in _noData) {
      if (!t.isBefore(g.a) && !t.isAfter(g.b)) {
        return Text(trp('tl.gap', {'a': _hhmm(g.a), 'b': _hhmm(g.b)}),
            style: style);
      }
    }
    final es = _effStart;
    if (es != null && t.isBefore(es)) {
      return Text(trp('tl.before', {'t': _hhmm(t)}), style: style);
    }
    return Text(trp('tl.ok', {'t': _hhmm(t)}), style: style);
  }

  // ───────────── Pareto ─────────────

  Widget _paretoCard(BuildContext context) {
    final cats = <String, int>{};
    final counts = <String, int>{};
    final subs = <String, Map<String, int>>{};
    var total = 0;
    for (final e in _events) {
      if (e.st != 'stop') continue;
      final c = e.cat ?? 'Neclasificat';
      cats[c] = (cats[c] ?? 0) + e.ms;
      counts[c] = (counts[c] ?? 0) + 1;
      total += e.ms;
      if (e.sub != null) {
        final m = subs.putIfAbsent(c, () => <String, int>{});
        m[e.sub!] = (m[e.sub!] ?? 0) + e.ms;
      }
    }
    final order = cats.keys.toList()..sort((a, b) => cats[b]!.compareTo(cats[a]!));
    final maxMs = order.isEmpty ? 1 : cats[order.first]!;
    var cum = 0;
    final rows = <Widget>[];
    for (final c in order.take(6)) {
      final ms = cats[c]!;
      cum += ms;
      final unc = c == 'Neclasificat';
      final sm = subs[c];
      final subList = sm == null ? <String>[] : (sm.keys.toList()..sort((a, b) => sm[b]!.compareTo(sm[a]!)));
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(c)),
            Text('${counts[c]}× · ${_fmt(ms)} · ${total == 0 ? 0 : (ms * 100 / total).round()}%'),
          ]),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: maxMs <= 0 ? 0 : ms / maxMs,
            color: unc ? _cNone : _cStop,
            minHeight: 10,
          ),
          for (final sc in subList.take(3))
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Text('${sm![sc] == null ? '' : _fmt(sm[sc]!)} · $sc',
                  style: Theme.of(context).textTheme.labelSmall),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(trp('pareto.cum', {'p': total == 0 ? 0 : (cum * 100 / total).round()}),
                style: Theme.of(context).textTheme.labelSmall),
          ),
        ]),
      ));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('pareto.title'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          if (rows.isEmpty) Text(tr('pareto.none')) else ...rows,
        ]),
      ),
    );
  }

  // ───────────── stare ─────────────

  Widget _statusCard() {
    final ble = widget.ble;
    final s = ble.viewStatus;
    final run = ble.activeRun;
    var color = _cNone;
    var title = tr('st.offline');
    var sub = ble.running ? ble.state : tr('st.stoppedOff');
    var icon = Icons.bluetooth_disabled;
    if (ble.connected && s != null) {
      switch (s.state) {
        case 0:
          if (s.cum == 0) {
            // canal activ fara niciun impuls de la pornirea ESP32: ESP32 nu declara oprire inainte de primul impuls
            color = _cNone;
            title = tr('st.noPulse');
            sub = tr('st.noPulseSub');
            icon = Icons.sensors_off;
            break;
          }
          color = _cRun;
          title = tr('st.running');
          sub = tr('st.runningSub');
          icon = Icons.play_circle_outline;
          break;
        case 1:
          color = _cMicro;
          title = tr('st.micro');
          sub = trp('st.microSub', {'t': _fmt(s.sinceLastMs)});
          icon = Icons.pause_circle_outline;
          break;
        case 2:
          color = _cStop;
          title = tr('st.stopped');
          sub = trp('st.stoppedSub', {'t': _fmt(s.sinceLastMs)});
          icon = Icons.stop_circle_outlined;
          break;
        case 3:
          color = _cSlow;
          title = tr('st.slow');
          sub = tr('st.slowSub');
          icon = Icons.speed;
          break;
        case 4:
          color = _cFast;
          title = tr('st.fast');
          sub = tr('st.fastSub');
          icon = Icons.speed;
          break;
        case 255:
          color = _cNone;
          title = tr('st.inactive');
          sub = tr('st.inactiveSub');
          icon = Icons.block;
          break;
        default:
          color = _cNone;
          title = tr('st.unconf');
          sub = tr('st.unconfSub');
          icon = Icons.help_outline;
      }
    }
    final fg = color == _cMicro ? Colors.black87 : Colors.white;
    String? speedLine;
    if (ble.connected && s != null && s.state != 2 && _speedNow != null) {
      speedLine = trp('st.lastMin', {'v': _speedNow!.toStringAsFixed(0)});
      if (run != null) {
        final target = _targetBpm() ?? 0;
        if (target > 0) {
          final loss = (1 - _speedNow! / target) * 100;
          speedLine = '$speedLine · ${loss >= 0 ? tr('st.loss') : tr('st.over')} ${loss.abs().toStringAsFixed(0)}%';
        }
      }
    }
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Icon(icon, size: 56, color: fg),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: fg)),
            Text(sub, style: TextStyle(fontSize: 16, color: fg)),
            if (speedLine != null) Text(speedLine, style: TextStyle(fontSize: 15, color: fg)),
            if (run != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(trp('st.product', {'n': run.sku.name}), style: TextStyle(fontSize: 14, color: fg)),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.label);
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ]);
}

class _Ring extends StatelessWidget {
  const _Ring(this.label, this.value, this.color, this.note);
  final String label;
  final double? value;
  final Color color;
  final String? note;
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 68,
          height: 68,
          child: CustomPaint(
            painter: _RingPainter(value, color, Theme.of(context).colorScheme.surfaceContainerHighest),
            child: Center(
              child: Text(_pct(value), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        if (note != null) Text(note!, style: Theme.of(context).textTheme.labelSmall),
      ]);
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track);
  final double? value;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    const sw = 8.0;
    final rect = (Offset.zero & size).deflate(sw / 2);
    canvas.drawArc(rect, 0, 2 * math.pi, false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = sw
          ..color = track);
    final v = value;
    if (v == null) return;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * v.clamp(0.0, 1.0), false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = sw
          ..strokeCap = StrokeCap.round
          ..color = color);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.value != value || old.color != color || old.track != track;
}

class _SpeedPainter extends CustomPainter {
  _SpeedPainter(this.values, this.target, this.targets, this.lineColor, this.textColor);
  final List<double?> values;
  final double? target;
  final List<double?> targets; // tinta pe bucata (se schimba cand se schimba produsul / run-ul)
  final Color lineColor, textColor;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 34.0;
    final w = size.width - left;
    final h = size.height;
    var maxV = 1.0;
    for (final v in values) {
      if (v != null && v > maxV) maxV = v;
    }
    if (target != null && target! * 1.2 > maxV) maxV = target! * 1.2;
    maxV *= 1.08;

    double yOf(double v) => h - (v / maxV).clamp(0.0, 1.0) * h;

    final grid = Paint()
      ..color = textColor.withOpacity(0.2)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final v = maxV * i / 4;
      final y = yOf(v);
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
      final tp = TextPainter(
        text: TextSpan(text: v.toStringAsFixed(0), style: TextStyle(fontSize: 10, color: textColor)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, (y - tp.height / 2).clamp(0.0, h - tp.height)));
    }

    final n = values.length;
    if (n > 0) {
      double xOf(int i) => left + (n == 1 ? w / 2 : w * i / (n - 1));
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = lineColor;
      Path? path;
      for (var i = 0; i < n; i++) {
        final v = values[i];
        if (v == null) {
          if (path != null) canvas.drawPath(path, line);
          path = null;
          continue;
        }
        final p = Offset(xOf(i), yOf(v));
        if (path == null) {
          path = Path()..moveTo(p.dx, p.dy);
          // punct izolat: desenam un mic cerc ca sa fie vizibil
          canvas.drawCircle(p, 1.5, Paint()..color = lineColor);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      if (path != null) canvas.drawPath(path, line);
    }

    final dash = Paint()
      ..color = _cStop
      ..strokeWidth = 1.5;
    final varies = targets.length == n && n > 1 && targets.whereType<double>().toSet().length > 1;
    if (varies) {
      // tinta in trepte: fiecare bucata cu tinta run-ului ei
      for (var i = 0; i < n; i++) {
        final t = targets[i];
        if (t == null) continue;
        final xa = i == 0 ? left : left + w * (i - 0.5) / (n - 1);
        final xb = i == n - 1 ? size.width : left + w * (i + 0.5) / (n - 1);
        final y = yOf(t);
        for (var x = xa; x < xb; x += 10) {
          canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, xb), y), dash);
        }
      }
    } else if (target != null) {
      final y = yOf(target!);
      for (var x = left; x < size.width; x += 10) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, size.width), y), dash);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SpeedPainter old) => true;
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.start, this.end, this.upTo, this.dataStart, this.events, this.noData, this.liveStopFrom,
      this.tap);
  final DateTime start, end, upTo, dataStart;
  final List<_Ev> events;
  final List<_Rng> noData;
  final DateTime? liveStopFrom, tap;

  @override
  void paint(Canvas canvas, Size size) {
    final total = end.difference(start).inMilliseconds.toDouble();
    if (total <= 0) return;
    double x(DateTime t) => (t.difference(start).inMilliseconds / total).clamp(0.0, 1.0) * size.width;

    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)));
    canvas.drawRect(Offset.zero & size, Paint()..color = _cFuture); // viitorul schimbului
    canvas.drawRect(Rect.fromLTRB(0, 0, x(upTo), size.height), Paint()..color = _cNone); // trecut fara date
    // "Rulează" doar de la primul mesaj primit
    canvas.drawRect(Rect.fromLTRB(x(dataStart), 0, x(upTo), size.height), Paint()..color = _cRun);
    for (final g in noData) {
      canvas.drawRect(Rect.fromLTRB(x(g.a), 0, x(g.b), size.height), Paint()..color = _cNone);
    }
    for (final e in events) {
      final x0 = x(e.from);
      var x1 = x(e.to);
      if (x1 - x0 < 2) x1 = x0 + 2; // evenimentele scurte raman vizibile
      canvas.drawRect(Rect.fromLTRB(x0, 0, x1, size.height), Paint()..color = _stColor(e.st));
    }
    if (liveStopFrom != null) {
      canvas.drawRect(Rect.fromLTRB(x(liveStopFrom!), 0, x(upTo), size.height), Paint()..color = _cStop);
    }
    final tp = tap;
    if (tp != null) {
      final tx = x(tp);
      canvas.drawLine(Offset(tx, 0), Offset(tx, size.height),
          Paint()
            ..color = Colors.black87
            ..strokeWidth = 2);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) => true;
}
