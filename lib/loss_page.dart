// Administrare → Motive de oprire: clasele IWS (nivelul 1, fixe) cu detalii editabile (nivelul 2).
// Detaliile folosite in clasificari nu se sterg, doar se dezactiveaza (istoricul ramane); codurile vechi din teste apar separat.
import 'package:flutter/material.dart';
import 'ble_service.dart';
import 'db.dart';
import 'i18n.dart';

class LossCodesPage extends StatefulWidget {
  const LossCodesPage(this.ble, {super.key});
  final BleService ble;
  @override
  State<LossCodesPage> createState() => _LossCodesPageState();
}

class _Group {
  _Group(this.cls, this.items);
  final LossCode cls;
  final List<LossCode> items;
}

class _LossCodesPageState extends State<LossCodesPage> {
  Db get _db => widget.ble.db;
  List<_Group> _groups = const [];
  List<_Group> _legacy = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final out = <_Group>[];
    for (final c in await _db.lossCodes()) {
      if (c.kind == null) continue;
      out.add(_Group(c, await _db.lossCodes(parentId: c.id, onlyActive: false)));
    }
    final old = <_Group>[];
    for (final c in await _db.lossCodes(onlyActive: false, legacy: true)) {
      old.add(_Group(c, await _db.lossCodes(parentId: c.id, onlyActive: false)));
    }
    if (mounted) {
      setState(() {
        _groups = out;
        _legacy = old;
      });
    }
  }

  Future<void> _edit(LossCode cls, LossCode? d) async {
    final used = d == null ? 0 : await _db.lossUsage(d.id);
    if (!mounted) return;
    final ctl = TextEditingController(text: d?.name ?? '');
    final act = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(d == null ? tr('loss.add') : tr('loss.edit')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(autofocus: true, controller: ctl, decoration: InputDecoration(labelText: tr('loss.name'))),
          if (d != null && used > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(trp('loss.used', {'n': used}), style: Theme.of(ctx).textTheme.bodySmall),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          if (d != null && used == 0)
            TextButton(onPressed: () => Navigator.pop(ctx, 'del'), child: Text(tr('common.delete'))),
          if (d != null && used > 0)
            TextButton(
                onPressed: () => Navigator.pop(ctx, d.active ? 'off' : 'on'),
                child: Text(d.active ? tr('loss.deactivate') : tr('loss.activate'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(tr('common.save'))),
        ],
      ),
    );
    if (act == null) return;
    if (act == 'save') {
      await _db.saveLossDetail(id: d?.id, parentId: cls.id, name: ctl.text);
    } else if (act == 'del' && d != null) {
      await _db.deleteLossDetail(d.id);
    } else if (d != null) {
      await _db.setLossActive(d.id, act == 'on');
    }
    await _load();
  }

  Widget _group(_Group g, {required bool editable}) {
    final kind = g.cls.kind;
    final auto = kind == 'micro';
    return Card(
      child: ExpansionTile(
        initiallyExpanded: editable && (kind == 'planned' || kind == 'unplanned'),
        title: Text(editable ? lossLabel(g.cls.name, kind) : g.cls.name),
        subtitle: Text(editable ? tr('loss.note.$kind') : tr('loss.legacyItem')),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final d in g.items)
            ListTile(
              dense: true,
              title: Text(d.name + (d.active ? '' : ' ${tr('loss.inactiveTag')}'),
                  style: d.active ? null : TextStyle(color: Theme.of(context).disabledColor)),
              trailing: editable ? const Icon(Icons.edit_outlined, size: 18) : null,
              onTap: editable ? () => _edit(g.cls, d) : null,
            ),
          if (editable && !auto)
            ListTile(
              dense: true,
              leading: const Icon(Icons.add),
              title: Text(tr('loss.add')),
              onTap: () => _edit(g.cls, null),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('admin.losscodes.title'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(tr('loss.intro'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: Text(tr('loss.plannedAvail')),
              subtitle: Text(tr('loss.plannedAvailSub')),
              value: _db.plannedInAvail,
              onChanged: (v) async {
                await _db.setPlannedInAvail(v);
                widget.ble.refresh();
                if (mounted) setState(() {});
              },
            ),
          ),
          const SizedBox(height: 8),
          for (final g in _groups) _group(g, editable: true),
          if (_legacy.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(tr('loss.legacy'), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(tr('loss.legacyNote'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            for (final g in _legacy) _group(g, editable: false),
          ],
        ]),
      );
}
