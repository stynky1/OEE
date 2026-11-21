// Administrare → Canale: numele echipamentului, afisarea in Linia / Opriri, rolul si ritmul nominal propriu al fiecarui canal (CH1..CH8).
// Pasul A2 (nume, afisare, ritm propriu) + A6: „Activ” = ESP32 numara canalul SI el se afiseaza; la salvare, cu firmware 3 conectat,
// tableta scrie blocurile Config ale celor 8 canale (activ / inactiv, ciclu C, trigger T) si le recitește.
import 'package:flutter/material.dart';
import 'ble_service.dart';
import 'db.dart';
import 'i18n.dart';

const List<String> kChannelRoles = ['produs', 'rebut', 'intrare', 'iesire'];

String roleName(String r) {
  final t = tr('role.$r');
  return t == 'role.$r' ? r : t;
}

/// Selectorul de canal din Linia si Opriri: apare doar cand sunt cel putin 2 canale afisate.
class ChannelSelector extends StatelessWidget {
  const ChannelSelector(this.ble, {super.key});
  final BleService ble;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final c in ble.channelList)
        if (c.active || c.id == ble.db.viewCh) c
    ];
    if (!ble.db.can('view.channels') || shown.length < 2) return const SizedBox.shrink();
    final cur = shown.any((c) => c.id == ble.db.viewCh) ? ble.db.viewCh : shown.first.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: tr('ch.selector'),
          prefixIcon: const Icon(Icons.precision_manufacturing_outlined),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: cur,
            isExpanded: true,
            isDense: true,
            items: [
              for (final c in shown)
                DropdownMenuItem<int>(
                  value: c.id,
                  child: Text('CH${c.id} · ${c.name}${c.active ? '' : tr('ch.inactiveTag')}',
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              if (v != null) ble.setViewChannel(v);
            },
          ),
        ),
      ),
    );
  }
}

class ChannelsPage extends StatefulWidget {
  const ChannelsPage(this.ble, {super.key});
  final BleService ble;
  @override
  State<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends State<ChannelsPage> {
  List<ChannelRow> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.ble.db.channels();
    if (mounted) setState(() => _rows = r);
  }

  String _last(String? iso) {
    final t = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (t == null) return tr('ch.noData');
    String two(int v) => v.toString().padLeft(2, '0');
    return trp('ch.last', {'d': '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}'});
  }

  Future<void> _edit(ChannelRow c) async {
    final out = await showDialog<(ChannelRow, bool)>(
      context: context,
      builder: (_) => _ChannelDialog(c, widget.ble.db.mainCh == c.id),
    );
    if (out == null) return;
    final db = widget.ble.db;
    await db.saveChannel(out.$1);
    if (out.$2 && db.mainCh != c.id) await db.setMainChannel(c.id);
    if (!out.$1.active && db.viewCh == c.id) widget.ble.setViewChannel(db.mainCh);
    await widget.ble.refresh();
    await _load();
    await _applyToDevice();
  }

  /// Admin: vizualizare doar-citire a istoricului unui canal inactiv (fara scriere pe ESP32).
  void _viewHistory(ChannelRow c) {
    widget.ble.setViewChannel(c.id);
    widget.ble.tabRequest.value = 0;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// Scrie canalele pe ESP32 (firmware 3) si anunta rezultatul.
  Future<void> _applyToDevice() async {
    final ble = widget.ble;
    String msg;
    if (!ble.connected) {
      msg = tr('ch.offline');
    } else if (ble.activeRun == null) {
      msg = tr('ch.noRun');
    } else {
      await ble.pushConfig();
      msg = ble.configInfo ?? tr('ch.saved');
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 6)));
  }

  @override
  Widget build(BuildContext context) {
    final main = widget.ble.db.mainCh;
    return Scaffold(
      appBar: AppBar(title: Text(tr('ch.title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
          tr('ch.help'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (final c in _rows)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text('${c.id}')),
              title: Text('${c.name}${c.id == main ? tr('ch.main') : ''}'),
              subtitle: Text([
                c.active ? tr('ch.active') : tr('ch.inactive'),
                roleName(c.role),
                trp('ch.msgs', {'n': c.msgs}),
                _last(c.last),
              ].join(' · ')),
              trailing: (!c.active && c.msgs > 0)
                  ? TextButton.icon(
                      onPressed: () => _viewHistory(c),
                      icon: const Icon(Icons.history, size: 18),
                      label: Text(tr('ch.viewHist')),
                    )
                  : const Icon(Icons.edit_outlined),
              onTap: () => _edit(c),
            ),
          ),
      ]),
    );
  }
}

class _ChannelDialog extends StatefulWidget {
  const _ChannelDialog(this.c, this.isMain);
  final ChannelRow c;
  final bool isMain;
  @override
  State<_ChannelDialog> createState() => _ChannelDialogState();
}

class _ChannelDialogState extends State<_ChannelDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.c.name);
  late bool _active = widget.c.active;
  late String _role = widget.c.role;
  late bool _main = widget.isMain;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _err = tr('ch.errName'));
      return;
    }
    final out = ChannelRow(
      id: widget.c.id,
      name: name,
      active: _active || _main, // canalul principal ramane afisat
      role: _role,
      rateBph: widget.c.rateBph, // nefolosit din v5: viteza se seteaza in reteta produsului
      triggerS: widget.c.triggerS,
    );
    Navigator.of(context).pop((out, _main));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(trp('ch.dlgTitle', {'n': widget.c.id})),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: _name, decoration: InputDecoration(labelText: tr('ch.name'))),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('ch.activeSw')),
              value: _active || _main,
              onChanged: _main ? null : (v) => setState(() => _active = v),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('ch.mainCb')),
              value: _main,
              onChanged: widget.isMain ? null : (v) => setState(() => _main = v ?? false),
            ),
            Text(tr('ch.role')),
            Wrap(spacing: 8, children: [
              for (final r in kChannelRoles)
                ChoiceChip(label: Text(roleName(r)), selected: _role == r, onSelected: (_) => setState(() => _role = r)),
            ]),
            if (_err != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(_err!, style: const TextStyle(color: Colors.red))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: _save, child: Text(tr('common.save'))),
        ],
      );
}
