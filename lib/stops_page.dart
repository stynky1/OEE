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

class _StopsPageState extends State<StopsPage> {
  List<Map<String, Object?>> _rows = const [];
  final Map<int, String?> _skuNames = {};

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

  Future<void> _load() async {
    final rows = await widget.ble.db.pendingStops();
    for (final r in rows) {
      final run = r['run'] as int;
      if (!_skuNames.containsKey(run)) _skuNames[run] = await widget.ble.db.skuNameForRun(run);
    }
    if (mounted) setState(() => _rows = rows);
  }

  String _fmtDur(int ms) {
    final s = (ms / 1000).round();
    if (s < 60) return '$s s';
    final m = s ~/ 60;
    return m < 60 ? '$m min ${s % 60} s' : '${m ~/ 60} h ${m % 60} min';
  }

  String _fmtTime(String? iso) {
    if (iso == null) return '?';
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '?';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<void> _classify(Map<String, Object?> r) async {
    if (!widget.ble.db.can('classify')) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CauseSheet(widget.ble.db, r),
    );
    if (ok == true) await widget.ble.refresh();
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

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('stops.title')), actions: [
          if (_rows.isNotEmpty && widget.ble.db.can(Perm.reclassify))
            IconButton(
                icon: const Icon(Icons.playlist_add_check),
                tooltip: tr('bulk.title'),
                onPressed: _bulk),
          UserButton(widget.ble.db),
        ]),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: ListenableBuilder(listenable: widget.ble, builder: (_, __) => ChannelSelector(widget.ble)),
          ),
          Expanded(child: _list()),
        ]),
      );

  Widget _list() => _rows.isEmpty
            ? Center(child: Text(tr('stops.none')))
            : ListView(children: [
                for (final r in _rows)
                  ListTile(
                    leading: const Icon(Icons.report_problem_outlined),
                    title: Text(trp('stops.item', {'t': _fmtDur(r['dur_ms'] as int)})),
                    subtitle: Text(
                        '${_fmtTime(r['from_ts'] as String?)} → ${_fmtTime(r['to_ts'] as String?)}'
                        '${(r['from_ts'] == null || r['to_ts'] == null) ? '  ${tr('stops.noClock')}' : ''}'
                        '${_skuNames[r['run'] as int] != null ? '\n${_skuNames[r['run'] as int]}' : ''}'),
                    isThreeLine: _skuNames[r['run'] as int] != null,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _classify(r),
                  ),
              ]);
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
