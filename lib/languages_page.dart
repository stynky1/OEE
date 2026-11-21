// Administrare → Limbi si traduceri: lista limbilor, limba aplicatiei, adaugare limba, editare traduceri, import / export CSV.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'i18n.dart';
import 'i18n_catalog.dart';

class LanguagesPage extends StatelessWidget {
  const LanguagesPage({super.key});

  Future<void> _add(BuildContext context) async {
    final code = TextEditingController();
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('lang.add')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: code, decoration: InputDecoration(labelText: tr('lang.code'))),
          TextField(controller: name, decoration: InputDecoration(labelText: tr('lang.name'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('common.add'))),
        ],
      ),
    );
    if (ok != true) return;
    final done = await i18n.addLang(code.text, name.text);
    if (!done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('lang.invalid'))));
    }
  }

  Future<void> _delete(BuildContext context, Lang l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${l.name} (${l.code})'),
        content: Text(tr('lang.delete.q')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('common.delete'))),
        ],
      ),
    );
    if (ok == true) await i18n.removeLang(l.code);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: i18n,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: Text(tr('lang.title')), actions: [
            IconButton(tooltip: tr('lang.add'), icon: const Icon(Icons.add), onPressed: () => _add(context)),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            for (final l in i18n.langs)
              Card(
                child: ListTile(
                  leading: Icon(i18n.current == l.code ? Icons.check_circle : Icons.language,
                      color: i18n.current == l.code ? Colors.green : null),
                  title: Text('${l.name} (${l.code})'),
                  subtitle: Text('${i18n.translated(l.code)} / ${i18n.total} ${tr('lang.translated')}'
                      '${l.code == 'en' ? ' · ${tr('lang.primary')}' : ''}'
                      '${i18n.current == l.code ? ' · ${tr('lang.inuse')}' : ''}'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TranslationsPage(l))),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'use') i18n.setCurrent(l.code);
                      if (v == 'del') _delete(context, l);
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'use', child: Text(tr('lang.use'))),
                      if (!I18n.isBuiltin(l.code)) PopupMenuItem(value: 'del', child: Text(tr('common.delete'))),
                    ],
                  ),
                ),
              ),
          ]),
        ),
      );
}

class TranslationsPage extends StatefulWidget {
  const TranslationsPage(this.lang, {super.key});
  final Lang lang;
  @override
  State<TranslationsPage> createState() => _TranslationsPageState();
}

class _TranslationsPageState extends State<TranslationsPage> {
  final _q = TextEditingController();
  bool _onlyMissing = false;

  Future<void> _edit(String key) async {
    final code = widget.lang.code;
    final ctl = TextEditingController(text: i18n.text(code, key) ?? '');
    final res = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${widget.lang.name} · $key'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('tr.source'), style: Theme.of(context).textTheme.labelSmall),
          Text(i18n.text('en', key) ?? key),
          const SizedBox(height: 12),
          TextField(controller: ctl, autofocus: true, maxLines: null),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, ''), child: Text(tr('tr.clear'))),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(tr('common.save'))),
        ],
      ),
    );
    if (res != null) await i18n.setText(code, key, res);
  }

  Future<void> _export() async {
    await Clipboard.setData(ClipboardData(text: i18n.exportCsv(widget.lang.code)));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('tr.exported'))));
  }

  Future<void> _import() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('tr.import')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('tr.importHint')),
          TextField(controller: ctl, maxLines: 6, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.content_paste),
              label: Text(tr('tr.paste')),
              onPressed: () async {
                final d = await Clipboard.getData(Clipboard.kTextPlain);
                if (d?.text != null) ctl.text = d!.text!;
              },
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('tr.import'))),
        ],
      ),
    );
    if (ok != true) return;
    final n = await i18n.importCsv(widget.lang.code, ctl.text);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n ${tr('tr.imported')}')));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: i18n,
        builder: (context, _) {
          final code = widget.lang.code;
          final q = _q.text.trim().toLowerCase();
          final keys = [
            for (final k in kEn.keys)
              if ((!_onlyMissing || i18n.text(code, k) == null) &&
                  (q.isEmpty ||
                      k.toLowerCase().contains(q) ||
                      (i18n.text('en', k) ?? '').toLowerCase().contains(q) ||
                      (i18n.text(code, k) ?? '').toLowerCase().contains(q)))
                k
          ];
          return Scaffold(
            appBar: AppBar(title: Text('${tr('tr.title')} · ${widget.lang.name}'), actions: [
              PopupMenuButton<String>(
                onSelected: (v) => v == 'exp' ? _export() : _import(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'exp', child: Text(tr('tr.export'))),
                  PopupMenuItem(value: 'imp', child: Text(tr('tr.import'))),
                ],
              ),
            ]),
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  controller: _q,
                  decoration: InputDecoration(prefixIcon: const Icon(Icons.search), labelText: tr('tr.search')),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SwitchListTile(
                title: Text(tr('tr.onlyMissing')),
                value: _onlyMissing,
                onChanged: (v) => setState(() => _onlyMissing = v),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: keys.length,
                  itemBuilder: (_, i) {
                    final k = keys[i];
                    final v = i18n.text(code, k);
                    return ListTile(
                      title: Text(i18n.text('en', k) ?? k),
                      subtitle: Text(v ?? tr('tr.empty')),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => _edit(k),
                    );
                  },
                ),
              ),
            ]),
          );
        },
      );
}
