// Administrare → Schimburi: programul de lucru, cu versiuni „valabil de la”.
// O modificare nu rescrie istoricul: zilele dinaintea datei alese raman cu programul vechi.
import 'package:flutter/material.dart';
import 'ble_service.dart';
import 'i18n.dart';
import 'shifts.dart';

String _dmy(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

class ShiftsPage extends StatefulWidget {
  const ShiftsPage(this.ble, {super.key});
  final BleService ble;
  @override
  State<ShiftsPage> createState() => _ShiftsPageState();
}

class _ShiftsPageState extends State<ShiftsPage> {
  ShiftSchedule get _sch => widget.ble.db.shifts;

  String _summary(List<ShiftDef> l) => l.map((s) => '${s.name} ${s.label}').join('  ·  ');

  Future<void> _edit() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _ShiftEditor(widget.ble)));
    if (ok == true && mounted) {
      setState(() {});
      widget.ble.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = dayOnly(DateTime.now());
    final plans = _sch.plans;
    var activeIdx = 0;
    for (var i = 0; i < plans.length; i++) {
      if (plans[i].from == null || !plans[i].from!.isAfter(today)) activeIdx = i;
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('sh.title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr('sh.intro')),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _edit, icon: const Icon(Icons.edit_calendar_outlined), label: Text(tr('sh.change'))),
        const SizedBox(height: 16),
        for (var i = plans.length - 1; i >= 0; i--)
          Card(
            child: ListTile(
              leading: Icon(i == activeIdx ? Icons.check_circle : Icons.history,
                  color: i == activeIdx ? Colors.green : null),
              title: Text(plans[i].from == null ? tr('sh.fromStart') : trp('sh.fromDate', {'d': _dmy(plans[i].from!)})),
              subtitle: Text(_summary(plans[i].shifts)),
              trailing: Text(i == activeIdx ? tr('sh.inForce') : (plans[i].from != null && plans[i].from!.isAfter(today) ? tr('sh.future') : tr('sh.old'))),
            ),
          ),
      ]),
    );
  }
}

class _Row {
  _Row(this.name, this.start, this.end) : ctl = TextEditingController(text: name);
  String name;
  int start, end;
  final TextEditingController ctl;
}

class _ShiftEditor extends StatefulWidget {
  const _ShiftEditor(this.ble);
  final BleService ble;
  @override
  State<_ShiftEditor> createState() => _ShiftEditorState();
}

class _ShiftEditorState extends State<_ShiftEditor> {
  late List<_Row> _rows;
  DateTime _from = dayOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    _rows = [for (final s in widget.ble.db.shifts.forDay(DateTime.now())) _Row(s.name, s.startMin, s.endMin)];
  }

  void _preset(List<ShiftDef> p) => setState(() => _rows = [for (final s in p) _Row(s.name, s.startMin, s.endMin)]);

  Future<void> _pick(_Row r, bool start) async {
    final cur = start ? r.start : r.end;
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay(hour: (cur % 1440) ~/ 60, minute: cur % 60));
    if (t == null) return;
    final m = t.hour * 60 + t.minute;
    setState(() {
      if (start) {
        final len = r.end - r.start;
        r.start = m;
        r.end = m + (len > 0 ? len : 480);
      } else {
        r.end = m <= r.start ? m + 1440 : m; // sfarsit „mai mic” decat inceputul = a doua zi
      }
    });
  }

  List<ShiftDef> _defs() => [for (final r in _rows) ShiftDef(r.ctl.text.trim(), r.start, r.end)];

  Future<void> _pickFrom() async {
    final p = await showDatePicker(
        context: context,
        initialDate: _from,
        firstDate: DateTime(2025, 1, 1),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        helpText: tr('sh.validFrom'));
    if (p != null) setState(() => _from = DateTime(p.year, p.month, p.day));
  }

  Future<void> _save() async {
    final defs = _defs();
    final err = ShiftSchedule.validate(defs);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final db = widget.ble.db;
    final plans = [
      for (final p in db.shifts.plans)
        if (!(p.from != null && p.from == _from)) p, // aceeasi data = inlocuieste
      ShiftPlan(_from, defs),
    ];
    await db.saveShifts(ShiftSchedule(plans));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final defs = _defs();
    final err = ShiftSchedule.validate(defs);
    final covered = err == null ? ShiftSchedule.coveredMin(defs) : 0;
    return Scaffold(
      appBar: AppBar(title: Text(tr('sh.editTitle'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final e in ShiftSchedule.presets.entries)
            ActionChip(label: Text(tr('sh.preset.${e.key}')), onPressed: () => _preset(e.value)),
        ]),
        const SizedBox(height: 12),
        for (var i = 0; i < _rows.length; i++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _rows[i].ctl,
                    decoration: InputDecoration(labelText: tr('sh.name'), isDense: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => _pick(_rows[i], true), child: Text(fmtMin(_rows[i].start))),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text('→')),
                OutlinedButton(
                    onPressed: () => _pick(_rows[i], false),
                    child: Text('${fmtMin(_rows[i].end)}${_rows[i].end > 1440 ? ' (+1)' : ''}')),
                IconButton(
                  tooltip: tr('common.delete'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _rows.length <= 1 ? null : () => setState(() => _rows.removeAt(i)),
                ),
              ]),
            ),
          ),
        TextButton.icon(
          onPressed: _rows.length >= 8
              ? null
              : () => setState(() {
                    final last = _rows.isEmpty ? 420 : _rows.last.end;
                    _rows.add(_Row(trp('sh.newName', {'n': _rows.length + 1}), last, last + 480));
                  }),
          icon: const Icon(Icons.add),
          label: Text(tr('sh.add')),
        ),
        const SizedBox(height: 8),
        if (err != null)
          Text(err, style: TextStyle(color: Theme.of(context).colorScheme.error))
        else
          Text(trp('sh.covers', {'t': '${covered ~/ 60} h${covered % 60 == 0 ? '' : ' ${covered % 60} min'}'}) +
              (covered < 1440 ? tr('sh.coversOut') : '.')),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event),
          title: Text(tr('sh.validFrom')),
          subtitle: Text(_dmy(_from)),
          trailing: TextButton(onPressed: _pickFrom, child: Text(tr('sh.changeBtn'))),
        ),
        const SizedBox(height: 8),
        FilledButton(onPressed: err == null ? _save : null, child: Text(tr('common.save'))),
      ]),
    );
  }
}
