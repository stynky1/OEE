// Ecranul de configurare a produselor (SKU): nume, ritm sau timp de ciclu, Triggering Cycle Time,
// target OEE, culoare. Perimetrul (linii) si masinile se configureaza in cloud (etapa urmatoare).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ble_service.dart';
import 'db.dart';
import 'i18n.dart';
import 'login_page.dart';
import 'perm.dart';
import 'protocol.dart';

const _palette = <int>[
  0xFF1E88E5, 0xFF43A047, 0xFFFB8C00, 0xFFE53935, 0xFF8E24AA, 0xFF00ACC1, 0xFF6D4C41, 0xFF9E9E9E,
];

class SkuPage extends StatefulWidget {
  const SkuPage(this.ble, {super.key});
  final BleService ble;
  @override
  State<SkuPage> createState() => _SkuPageState();
}

class _SkuPageState extends State<SkuPage> {
  List<Sku> _skus = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await widget.ble.db.skus();
    if (mounted) {
      setState(() {
        _skus = l;
        _loaded = true;
      });
    }
  }

  Future<void> _edit([Sku? sku]) async {
    final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => SkuForm(widget.ble.db, sku, widget.ble.channelList)));
    if (saved == true) {
      final id = sku?.id;
      if (id != null) await widget.ble.applyActiveRecipe(id);
      await _load();
    }
  }

  /// Reteta pe scurt: viteza fiecarui canal activ (CH1 150/min ...), sau "necompletat".
  String _recipeLine(Sku s) {
    final parts = <String>[];
    for (final c in widget.ble.channelList) {
      if (!c.active) continue;
      final r = s.chans[c.id]?.rateBph;
      parts.add('CH${c.id} ${r == null ? '—' : r.toStringAsFixed(0)}');
    }
    return parts.isEmpty ? tr('sku.noChan') : '${parts.join(' · ')} ${tr('sku.unit')}';
  }

  /// Porneste produsul doar daca fiecare canal activ are viteza in reteta; altfel deschide reteta.
  Future<void> _start(Sku s) async {
    final missing = await widget.ble.db.missingChannels(s);
    if (missing.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(trp('sku.errMissing', {'ch': missing.map((c) => 'CH${c.id}').join(', ')})),
          duration: const Duration(seconds: 6)));
      await _edit(s);
      return;
    }
    await widget.ble.startRun(s);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.ble,
        builder: (context, _) {
          final activeId = widget.ble.activeRun?.sku.id;
          return Scaffold(
            appBar: AppBar(title: Text(tr('sku.title')), actions: [UserButton(widget.ble.db)]),
            floatingActionButton: widget.ble.db.can(Perm.adminProducts)
                ? FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add))
                : null,
            body: !_loaded
                ? const SizedBox.shrink()
                : _skus.isEmpty
                ? Center(child: Text(tr('sku.none')))
                : ListView(children: [
                    for (final s in _skus)
                      ListTile(
                        leading: CircleAvatar(backgroundColor: Color(s.color), radius: 10),
                        title: Text(s.name),
                        subtitle: Text(_recipeLine(s)),
                        trailing: s.id == activeId
                            ? Chip(label: Text(tr('sku.active')))
                            : (widget.ble.db.can(Perm.productsStart)
                                ? FilledButton.tonal(onPressed: () => _start(s), child: Text(tr('sku.start')))
                                : null),
                        onTap: widget.ble.db.can(Perm.adminProducts) ? () => _edit(s) : null,
                      ),
                  ]),
          );
        },
      );
}

class SkuForm extends StatefulWidget {
  const SkuForm(this.db, this.sku, this.channels, {super.key});
  final Db db;
  final Sku? sku;
  final List<ChannelRow> channels;
  @override
  State<SkuForm> createState() => _SkuFormState();
}

class _ChanCtl {
  _ChanCtl(this.rate, this.trig, this.oee);
  final TextEditingController rate, trig, oee;
}

String _fmt(double? v) => v == null ? '' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v');

class _SkuFormState extends State<SkuForm> {
  late final TextEditingController _name;
  final Map<int, _ChanCtl> _ctl = {};
  late int _color;
  String? _error;

  List<ChannelRow> get _active => [
        for (final c in widget.channels)
          if (c.active) c
      ];

  @override
  void initState() {
    super.initState();
    final s = widget.sku;
    _name = TextEditingController(text: s?.name ?? '');
    _color = s?.color ?? _palette.last;
    for (final c in _active) {
      final r = s?.chans[c.id];
      _ctl[c.id] = _ChanCtl(
        TextEditingController(text: _fmt(r?.rateBph)),
        TextEditingController(text: _fmt(r?.triggerS ?? 10.0)),
        TextEditingController(text: _fmt(r?.targetOee)),
      );
      for (final t in [_ctl[c.id]!.rate, _ctl[c.id]!.trig]) {
        t.addListener(() => setState(() {}));
      }
    }
  }

  double? _num(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return setState(() => _error = tr('sku.errName'));
    final chans = <int, SkuChan>{};
    for (final c in _active) {
      final k = _ctl[c.id]!;
      final rate = _num(k.rate), trig = _num(k.trig);
      final tag = 'CH${c.id} ${c.name}';
      // canal necompletat: reteta se poate salva, dar produsul nu porneste pana la completare
      if (k.rate.text.trim().isEmpty && k.oee.text.trim().isEmpty) continue;
      if (rate == null || rate <= 0) return setState(() => _error = '$tag: ${tr('sku.errCycle')}');
      if (trig == null) return setState(() => _error = '$tag: ${tr('sku.errTrig')}');
      final err = validateSkuTiming(3600 / rate, trig);
      if (err != null) return setState(() => _error = '$tag: $err');
      final oee = k.oee.text.trim().isEmpty ? null : _num(k.oee);
      if (oee != null && (oee < 0 || oee > 100)) return setState(() => _error = '$tag: ${tr('sku.errOee')}');
      chans[c.id] = SkuChan(rateBph: rate, triggerS: trig, targetOee: oee);
    }
    if (chans.isEmpty) return setState(() => _error = tr('sku.noChan'));
    final s = widget.sku ?? Sku(name: '', value: 1);
    // canalele inactive pastreaza valorile salvate (nu se pierd daca canalul se reactiveaza)
    for (final e in s.chans.entries) {
      chans.putIfAbsent(e.key, () => e.value);
    }
    s.name = _name.text.trim();
    s.color = _color;
    s.chans = chans;
    await widget.db.saveSku(s);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sku == null ? tr('sku.new') : tr('sku.edit')),
        actions: [
          if (widget.sku?.id != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await widget.db.deleteSku(widget.sku!.id!);
                if (context.mounted) Navigator.of(context).pop(true);
              },
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: InputDecoration(labelText: tr('sku.name'))),
        const SizedBox(height: 16),
        Wrap(spacing: 8, children: [
          for (final c in _palette)
            GestureDetector(
              onTap: () => setState(() => _color = c),
              child: CircleAvatar(
                backgroundColor: Color(c),
                radius: 16,
                child: _color == c ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
              ),
            ),
        ]),
        const SizedBox(height: 20),
        Text(tr('sku.perChan'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(tr('sku.perChanHelp'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        for (final c in _active) _chanCard(c),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _save, child: Text(tr('common.save'))),
      ]),
    );
  }

  Widget _chanCard(ChannelRow c) {
    final k = _ctl[c.id]!;
    final rate = _num(k.rate);
    final cycle = (rate == null || rate <= 0) ? null : 3600 / rate;
    final nf = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    const kb = TextInputType.numberWithOptions(decimal: true);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('CH${c.id} · ${c.name}', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: k.rate,
                    keyboardType: kb,
                    inputFormatters: nf,
                    decoration: InputDecoration(
                        labelText: tr('sku.perHour'),
                        helperMaxLines: 2,
                        helperText: cycle == null ? null : trp('sku.cycleFull', {'c': cycle.toStringAsFixed(4)})))),
            const SizedBox(width: 12),
            Expanded(
                child: TextField(
                    controller: k.trig,
                    keyboardType: kb,
                    inputFormatters: nf,
                    decoration: InputDecoration(labelText: tr('sku.trigger')))),
          ]),
          const SizedBox(height: 4),
          TextField(
              controller: k.oee,
              keyboardType: kb,
              inputFormatters: nf,
              decoration: InputDecoration(labelText: tr('sku.targetOee'))),
        ]),
      ),
    );
  }
}
