// Lista opririlor care cer motiv (pauza >= Triggering Cycle Time). Motiv pe 2 niveluri: categorie + subcategorie.
// Microopririle si viteza redusa se clasifica automat si NU apar aici.
import 'package:flutter/material.dart';
import 'ble_service.dart';
import 'channels_page.dart';
import 'db.dart';
import 'i18n.dart';
import 'login_page.dart';
import 'perm.dart';

class StopsPage extends StatefulWidget {
  const StopsPage(this.ble, {super.key});
  final BleService ble;
  @override
  State<StopsPage> createState() => _StopsPageState();
}

String _durTxt(int ms) {
  final s = (ms / 1000).round();
  if (s < 60) return '$s s';
  final m = s ~/ 60;
  return m < 60 ? '$m min ${s % 60} s' : '${m ~/ 60} h ${m % 60} min';
}

String _two(int v) => v.toString().padLeft(2, '0');

String _timeTxt(String? iso) {
  if (iso == null) return '?';
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return '?';
  return '${_two(t.day)}.${_two(t.month)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

String _isoUtc(DateTime t) => '${t.toUtc().toIso8601String().split('.').first}Z';

class _StopsPageState extends State<StopsPage> {
  List<Map<String, Object?>> _rows = const []; // de clasificat
  List<Map<String, Object?>> _all = const []; // toate opririle din perioada aleasa
  final Map<int, String?> _skuNames = {};
  int _mode = 0; // 0 = de clasificat, 1 = toate opririle
  int _period = 0; // 0 azi, 1 ieri, 2 ultimele 7 zile, 3 ultimele 30 de zile, 4 toate, 5 interval ales
  DateTimeRange? _range;
  int _sort = 0; // 0 cele mai noi, 1 cele mai vechi, 2 dupa SKU
  String? _skuFilter; // null = toate produsele; '' = fara produs
  final Set<String> _sel = {};

  @override
  void initState() {
    super.initState();
    widget.ble.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.ble.removeListener(_load);
    super.dispose();
  }

  String _key(Map<String, Object?> r) => '${r['device']}|${r['boot']}|${r['seq']}';

  List<DateTime?> _bounds() {
    final n = DateTime.now();
    switch (_period) {
      case 0:
        return [DateTime(n.year, n.month, n.day), null];
      case 1:
        return [DateTime(n.year, n.month, n.day - 1), DateTime(n.year, n.month, n.day)];
      case 2:
        return [DateTime(n.year, n.month, n.day - 6), null];
      case 3:
        return [DateTime(n.year, n.month, n.day - 29), null];
      case 5:
        final g = _range;
        if (g == null) return [null, null];
        return [
          DateTime(g.start.year, g.start.month, g.start.day),
          DateTime(g.end.year, g.end.month, g.end.day + 1),
        ];
    }
    return [null, null];
  }

  Future<void> _load() async {
    final db = widget.ble.db;
    if (_mode == 0) {
      final rows = await db.pendingStops();
      for (final r in rows) {
        final run = r['run'] as int;
        if (!_skuNames.containsKey(run)) _skuNames[run] = await db.skuNameForRun(run);
      }
      if (mounted) setState(() => _rows = rows);
    } else {
      final b = _bounds();
      final rows = await db.stopsList(db.viewCh,
          fromIso: b[0] == null ? null : _isoUtc(b[0]!), toIso: b[1] == null ? null : _isoUtc(b[1]!));
      if (mounted) {
        setState(() {
          _all = rows;
          final keys = {for (final r in rows) _key(r)};
          _sel.removeWhere((k) => !keys.contains(k));
        });
      }
    }
  }

  Future<void> _classify(Map<String, Object?> r) async {
    if (!widget.ble.db.can('classify')) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CauseSheet(widget.ble.db, r),
    );
    if (ok == true) {
      await widget.ble.refresh();
      await _load();
    }
  }

  Future<void> _bulk() async {
    final ch = widget.ble.db.viewCh;
    final all = await widget.ble.db.allPendingStops(ch);
    if (!mounted) return;
    final n = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BulkSheet(widget.ble.db, all, ch),
    );
    if (n != null && n > 0) {
      await widget.ble.refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trp('bulk.done', {'n': '$n'}))));
      }
    }
  }

  void _toggle(String k) => setState(() {
        if (!_sel.remove(k)) _sel.add(k);
      });

  void _snack(String key) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(key))));
  }

  Future<void> _split(Map<String, Object?> r) async {
    final f = DateTime.tryParse('${r['from_ts'] ?? ''}');
    final t = DateTime.tryParse('${r['to_ts'] ?? ''}');
    if (f == null || t == null) return _snack('stops.noClock');
    if (t.difference(f).inSeconds < 2) return _snack('stops.tooShort');
    final at = await showDialog<DateTime>(context: context, builder: (_) => _SplitDialog(f.toLocal(), t.toLocal()));
    if (at == null) return;
    final ok = await widget.ble.db.splitStop(r, at);
    await widget.ble.refresh();
    await _load();
    _snack(ok ? 'stops.done.split' : 'stops.failed');
  }

  Future<void> _merge() async {
    final rs = [for (final r in _all) if (_sel.contains(_key(r))) r];
    if (rs.length < 2) return;
    DateTime? f, t;
    var sum = 0;
    for (final r in rs) {
      final a = DateTime.tryParse('${r['from_ts'] ?? ''}'), b = DateTime.tryParse('${r['to_ts'] ?? ''}');
      if (a == null || b == null) return _snack('stops.noClock');
      if (f == null || a.isBefore(f)) f = a;
      if (t == null || b.isAfter(t)) t = b;
      sum += (r['dur_ms'] as num?)?.toInt() ?? b.difference(a).inMilliseconds;
    }
    final span = t!.difference(f!).inMilliseconds;
    final gap = span - sum;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(trp('stops.mergeTitle', {'n': '${rs.length}'})),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(trp('stops.mergeBody',
              {'a': _timeTxt(_isoUtc(f!)), 'b': _timeTxt(_isoUtc(t!)), 't': _durTxt(span)})),
          if (gap > 1000) ...[
            const SizedBox(height: 8),
            Text(trp('stops.mergeGap', {'g': _durTxt(gap)}), style: const TextStyle(color: Colors.red)),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: Text(tr('stops.mergeDo'))),
        ],
      ),
    );
    if (ok != true) return;
    final done = await widget.ble.db.mergeStops(rs);
    setState(_sel.clear);
    await widget.ble.refresh();
    await _load();
    _snack(done ? 'stops.done.merge' : 'stops.failed');
  }

  Future<void> _pickPeriod(int p) async {
    if (p == 5) {
      final now = DateTime.now();
      final g = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2024),
        lastDate: DateTime(now.year, now.month, now.day + 1),
        initialDateRange: _range,
      );
      if (g == null) return;
      _range = g;
    }
    setState(() {
      _period = p;
      _sel.clear();
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _sel.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: selecting ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_sel.clear)) : null,
        title: Text(selecting ? trp('stops.sel', {'n': '${_sel.length}'}) : tr(_mode == 0 ? 'stops.title' : 'stops.titleAll')),
        actions: [
          if (selecting)
            IconButton(
                icon: const Icon(Icons.call_merge),
                tooltip: tr('stops.merge'),
                onPressed: _sel.length >= 2 ? _merge : null)
          else ...[
            if (_mode == 0 && _rows.isNotEmpty && widget.ble.db.can(Perm.reclassify))
              IconButton(icon: const Icon(Icons.playlist_add_check), tooltip: tr('bulk.title'), onPressed: _bulk),
            UserButton(widget.ble.db),
          ],
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: ListenableBuilder(listenable: widget.ble, builder: (_, __) => ChannelSelector(widget.ble)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, label: Text(tr('stops.modePending'))),
              ButtonSegment(value: 1, label: Text(tr('stops.modeAll'))),
            ],
            selected: {_mode},
            onSelectionChanged: (s) {
              setState(() {
                _mode = s.first;
                _sel.clear();
              });
              _load();
            },
          ),
        ),
        if (_mode == 1) _filters(),
        Expanded(child: _mode == 0 ? _list() : _allList()),
      ]),
    );
  }

  Widget _filters() {
    final skus = <String>{for (final r in _all) (r['sku'] as String?) ?? ''}.toList()..sort();
    String d(DateTime x) => '${_two(x.day)}.${_two(x.month)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final e in [
              (0, 'stops.p.today'),
              (1, 'stops.p.yesterday'),
              (2, 'stops.p.7d'),
              (3, 'stops.p.30d'),
              (4, 'stops.p.all'),
              (5, 'stops.p.range'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(e.$1 == 5 && _period == 5 && _range != null
                      ? '${d(_range!.start)} – ${d(_range!.end)}'
                      : tr(e.$2)),
                  selected: _period == e.$1,
                  onSelected: (_) => _pickPeriod(e.$1),
                ),
              ),
          ]),
        ),
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final e in [(0, 'stops.sort.new'), (1, 'stops.sort.old'), (2, 'stops.sort.sku')])
            ChoiceChip(label: Text(tr(e.$2)), selected: _sort == e.$1, onSelected: (_) => setState(() => _sort = e.$1)),
          DropdownButton<String?>(
            value: skus.contains(_skuFilter) ? _skuFilter : null,
            items: <DropdownMenuItem<String?>>[
              DropdownMenuItem<String?>(value: null, child: Text(tr('stops.skuAll'))),
              for (final s in skus) DropdownMenuItem<String?>(value: s, child: Text(s.isEmpty ? tr('stops.skuNone') : s)),
            ],
            onChanged: (v) => setState(() => _skuFilter = v),
          ),
        ]),
      ]),
    );
  }

  List<Map<String, Object?>> _visible() {
    final l = [
      for (final r in _all)
        if (_skuFilter == null || ((r['sku'] as String?) ?? '') == _skuFilter) r
    ];
    int byTime(Map<String, Object?> a, Map<String, Object?> b) => '${a['from_ts'] ?? ''}'.compareTo('${b['from_ts'] ?? ''}');
    if (_sort == 1) {
      l.sort(byTime);
    } else if (_sort == 2) {
      l.sort((a, b) {
        final c = '${a['sku'] ?? ''}'.compareTo('${b['sku'] ?? ''}');
        return c != 0 ? c : byTime(b, a);
      });
    } else {
      l.sort((a, b) => byTime(b, a));
    }
    return l;
  }

  Widget _allList() {
    final vis = _visible();
    if (vis.isEmpty) return Center(child: Text(tr('stops.none.all')));
    final kids = <Widget>[];
    String? lastSku;
    for (final r in vis) {
      if (_sort == 2) {
        final s = (r['sku'] as String?) ?? tr('stops.skuNone');
        if (s != lastSku) {
          kids.add(Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(s, style: Theme.of(context).textTheme.titleSmall),
          ));
          lastSku = s;
        }
      }
      kids.add(_allTile(r));
    }
    return ListView(children: kids);
  }

  Widget _allTile(Map<String, Object?> r) {
    final db = widget.ble.db;
    final k = _key(r);
    final sel = _sel.contains(k);
    final selecting = _sel.isNotEmpty;
    final has = r['code1'] != null;
    final cause = !has
        ? tr('stops.noCause')
        : '${lossLabel(r['c1'] as String?, r['k1'] as String?)}${r['c2'] != null ? ' / ${r['c2']}' : ''}';
    final kind = r['kind'] as String?;
    final tag = (kind == 'split' || kind == 'merge' || kind == 'shift_start') ? ' · ${tr('stops.kind.$kind')}' : '';
    final comment = (r['comment'] as String?)?.trim() ?? '';
    final sku = (r['sku'] as String?) ?? '';
    final line2 = [if (sku.isNotEmpty) sku, if (comment.isNotEmpty) comment].join(' · ');
    final canEdit = db.can(has ? Perm.reclassify : 'classify');
    final canMod = db.can(Perm.reclassify);
    final dur = (r['dur_ms'] as num?)?.toInt() ?? 0;
    return ListTile(
      selected: sel,
      leading: selecting
          ? Checkbox(value: sel, onChanged: (_) => _toggle(k))
          : Icon(has ? Icons.check_circle_outline : Icons.report_problem_outlined, color: has ? null : Colors.red),
      title: Text('${_durTxt(dur)} · $cause'),
      subtitle: Text('${_timeTxt(r['from_ts'] as String?)} → ${_timeTxt(r['to_ts'] as String?)}$tag'
          '${line2.isEmpty ? '' : '\n$line2'}'),
      isThreeLine: line2.isNotEmpty,
      trailing: selecting || !canMod
          ? null
          : PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') _classify(r);
                if (v == 'split') _split(r);
                if (v == 'sel') _toggle(k);
              },
              itemBuilder: (_) => [
                if (canEdit) PopupMenuItem(value: 'edit', child: Text(tr('stops.edit'))),
                PopupMenuItem(value: 'split', child: Text(tr('stops.split'))),
                PopupMenuItem(value: 'sel', child: Text(tr('stops.merge'))),
              ],
            ),
      onTap: selecting ? () => _toggle(k) : (canEdit ? () => _classify(r) : null),
      onLongPress: canMod ? () => _toggle(k) : null,
    );
  }

  Widget _list() => _rows.isEmpty
      ? Center(child: Text(tr('stops.none')))
      : ListView(children: [
          for (final r in _rows)
            ListTile(
              leading: const Icon(Icons.report_problem_outlined),
              title: Text(trp('stops.item', {'t': _durTxt(r['dur_ms'] as int)})),
              subtitle: Text('${_timeTxt(r['from_ts'] as String?)} → ${_timeTxt(r['to_ts'] as String?)}'
                  '${(r['from_ts'] == null || r['to_ts'] == null) ? '  ${tr('stops.noClock')}' : ''}'
                  '${_skuNames[r['run'] as int] != null ? '\n${_skuNames[r['run'] as int]}' : ''}'),
              isThreeLine: _skuNames[r['run'] as int] != null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _classify(r),
            ),
        ]);
}

/// Impartirea unei opriri in doua: se alege momentul in care se termina primul defect.
class _SplitDialog extends StatefulWidget {
  const _SplitDialog(this.from, this.to);
  final DateTime from, to;
  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  late final int _total = widget.to.difference(widget.from).inSeconds;
  late int _off = _total ~/ 2;

  void _adj(int d) => setState(() => _off = (_off + d).clamp(1, _total - 1).toInt());

  String _t(DateTime x) => '${_two(x.hour)}:${_two(x.minute)}:${_two(x.second)}';

  @override
  Widget build(BuildContext context) {
    final at = widget.from.add(Duration(seconds: _off));
    return AlertDialog(
      title: Text(tr('stops.splitTitle')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('stops.splitHint')),
          const SizedBox(height: 12),
          Text('${tr('stops.part1')}: ${_t(widget.from)} → ${_t(at)} (${_durTxt(_off * 1000)})'),
          Text('${tr('stops.part2')}: ${_t(at)} → ${_t(widget.to)} (${_durTxt((_total - _off) * 1000)})'),
          Slider(
            min: 1,
            max: (_total - 1).toDouble(),
            value: _off.toDouble(),
            onChanged: (v) => setState(() => _off = v.round()),
          ),
          Wrap(spacing: 8, children: [
            for (final e in [(-300, '−5 min'), (-60, '−1 min'), (60, '+1 min'), (300, '+5 min')])
              OutlinedButton(onPressed: () => _adj(e.$1), child: Text(e.$2)),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('common.cancel'))),
        FilledButton(onPressed: () => Navigator.of(context).pop(at), child: Text(tr('stops.splitDo'))),
      ],
    );
  }
}

class _CauseSheet extends StatefulWidget {
  const _CauseSheet(this.db, this.row);
  final Db db;
  final Map<String, Object?> row;
  @override
  State<_CauseSheet> createState() => _CauseSheetState();
}

class _CauseSheetState extends State<_CauseSheet> {
  List<LossCode> _l1 = const [], _l2 = const [];
  int? _c1, _c2;
  final _comment = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.db.lossCodes(kinds: kStopKinds).then((l) => mounted ? setState(() => _l1 = l) : null);
    // editare: porneste de la motivul existent
    final c1 = (widget.row['code1'] as num?)?.toInt();
    if (c1 != null) {
      _c1 = c1;
      _c2 = (widget.row['code2'] as num?)?.toInt();
      _comment.text = '${widget.row['comment'] ?? ''}';
      widget.db.lossCodes(parentId: c1).then((l) => mounted ? setState(() => _l2 = l) : null);
    }
  }

  Future<void> _pick1(int id) async {
    final l = await widget.db.lossCodes(parentId: id);
    setState(() {
      _c1 = id;
      _c2 = null;
      _l2 = l;
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(tr('cause.title'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(tr('cause.cat')),
            Wrap(spacing: 8, children: [
              for (final c in _l1)
                ChoiceChip(label: Text(lossLabel(c.name, c.kind)), selected: _c1 == c.id, onSelected: (_) => _pick1(c.id)),
            ]),
            if (_l2.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(tr('cause.sub')),
              Wrap(spacing: 8, children: [
                for (final c in _l2)
                  ChoiceChip(
                      label: Text(c.name),
                      selected: _c2 == c.id,
                      onSelected: (_) => setState(() => _c2 = c.id)),
              ]),
            ],
            const SizedBox(height: 12),
            TextField(controller: _comment, decoration: InputDecoration(labelText: tr('cause.comment'))),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _c1 == null || (_l2.isNotEmpty && _c2 == null)
                  ? null
                  : () async {
                      final r = widget.row;
                      await widget.db.saveCause(r['device'] as String, r['boot'] as int, r['seq'] as int,
                          _c1!, _c2, _comment.text.trim().isEmpty ? null : _comment.text.trim());
                      if (context.mounted) Navigator.of(context).pop(true);
                    },
              child: Text(tr('common.save')),
            ),
          ]),
        ),
      );
}

/// Clasificare in masa: toate opririle dintr-un interval primesc acelasi motiv (de ex. Neprogramat pentru probe).
class _BulkSheet extends StatefulWidget {
  const _BulkSheet(this.db, this.rows, this.ch);
  final Db db;
  final List<Map<String, Object?>> rows;
  final int ch;
  @override
  State<_BulkSheet> createState() => _BulkSheetState();
}

class _BulkSheetState extends State<_BulkSheet> {
  List<LossCode> _l1 = const [], _l2 = const [];
  int? _c1, _c2;
  int _scope = 0; // 0 = mai vechi de 24 h, 1 = dinainte de azi 00:00, 2 = toate
  bool _busy = false;
  final _comment = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.db.lossCodes(kinds: kStopKinds).then((l) => mounted ? setState(() => _l1 = l) : null);
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _pick1(int id) async {
    final l = await widget.db.lossCodes(parentId: id);
    setState(() {
      _c1 = id;
      _c2 = null;
      _l2 = l;
    });
  }

  DateTime? _cutoff() {
    final now = DateTime.now();
    if (_scope == 0) return now.subtract(const Duration(hours: 24));
    if (_scope == 1) return DateTime(now.year, now.month, now.day);
    return null;
  }

  List<Map<String, Object?>> _selected() {
    final cut = _cutoff();
    if (cut == null) return widget.rows;
    final out = <Map<String, Object?>>[];
    for (final r in widget.rows) {
      final end = DateTime.tryParse('${r['to_ts'] ?? ''}');
      if (end != null && end.isBefore(cut)) out.add(r);
    }
    return out;
  }

  Future<void> _apply() async {
    final rows = _selected();
    if (_c1 == null || rows.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(trp('bulk.confirmTitle', {'n': '${rows.length}'})),
        content: Text(tr('bulk.confirmBody')),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: Text(tr('common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(true), child: Text(trp('bulk.apply', {'n': '${rows.length}'}))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final n = await widget.db
        .saveCauseBulk(rows, _c1!, _c2, _comment.text.trim().isEmpty ? null : _comment.text.trim());
    if (mounted) Navigator.of(context).pop(n);
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selected();
    final ready = _c1 != null && (_l2.isEmpty || _c2 != null) && sel.isNotEmpty && !_busy;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(tr('bulk.title'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(tr('bulk.scope')),
          Wrap(spacing: 8, children: [
            for (final e in [(0, 'bulk.older24'), (1, 'bulk.olderToday'), (2, 'bulk.all')])
              ChoiceChip(
                  label: Text(tr(e.$2)), selected: _scope == e.$1, onSelected: (_) => setState(() => _scope = e.$1)),
          ]),
          const SizedBox(height: 8),
          Text(trp('bulk.count', {'n': '${sel.length}', 'ch': '${widget.ch}'}),
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          Text(tr('cause.cat')),
          Wrap(spacing: 8, children: [
            for (final c in _l1)
              ChoiceChip(label: Text(lossLabel(c.name, c.kind)), selected: _c1 == c.id, onSelected: (_) => _pick1(c.id)),
          ]),
          if (_l2.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(tr('cause.sub')),
            Wrap(spacing: 8, children: [
              for (final c in _l2)
                ChoiceChip(label: Text(c.name), selected: _c2 == c.id, onSelected: (_) => setState(() => _c2 = c.id)),
            ]),
          ],
          const SizedBox(height: 12),
          TextField(controller: _comment, decoration: InputDecoration(labelText: tr('cause.comment'))),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: ready ? _apply : null,
            child: Text(trp('bulk.apply', {'n': '${sel.length}'})),
          ),
        ]),
      ),
    );
  }
}
