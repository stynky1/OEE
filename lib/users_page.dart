// Administrare → Utilizatori: lista, adaugare / editare (nume, rol, PIN, activ), pornirea autentificarii si deconectarea automata.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ble_service.dart';
import 'db.dart';
import 'i18n.dart';
import 'login_page.dart';
import 'perm.dart';

class UsersPage extends StatefulWidget {
  const UsersPage(this.ble, {super.key});
  final BleService ble;
  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  List<AppUser> _users = const [];
  Db get _db => widget.ble.db;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await _db.users();
    if (mounted) setState(() => _users = u);
  }

  Future<void> _edit([AppUser? u]) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _UserDialog(_db, u, first: _users.isEmpty),
    );
    if (ok == true) await _load();
  }

  Future<void> _toggleAuth(bool on) async {
    if (on) {
      if (await _db.activeAdminCount() == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('usr.needAdmin'))));
        }
        return;
      }
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(tr('usr.enableQ')),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('common.cancel'))),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('common.ok'))),
          ],
        ),
      );
      if (go != true) return;
      final code = await _db.prepareAuth();
      if (code == null || !mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(tr('usr.recovery')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: SelectableText(code, style: const TextStyle(fontSize: 34, letterSpacing: 4, fontWeight: FontWeight.bold))),
            const SizedBox(height: 12),
            Text(tr('usr.recoveryHelp')),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('common.ok')))],
        ),
      );
      await _db.commitAuth(); // Gate-ul inchide ecranele deschise si arata ecranul de PIN
    } else {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(tr('usr.disableQ')),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('common.cancel'))),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('common.ok'))),
          ],
        ),
      );
      if (go == true) {
        await _db.disableAuth();
        if (mounted) setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([i18n, _db.authTick]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(tr('usr.title'))),
        floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.person_add_alt)),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.lock_outline),
              title: Text(tr('usr.auth')),
              subtitle: Text(_db.authEnabled ? tr('usr.authOn') : tr('usr.authOff')),
              value: _db.authEnabled,
              onChanged: _toggleAuth,
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(tr('usr.autoLock')),
              trailing: DropdownButton<int>(
                value: const [0, 1, 2, 5, 10, 15, 30].contains(_db.autoLockMin) ? _db.autoLockMin : 0,
                items: [
                  for (final m in const [0, 1, 2, 5, 10, 15, 30])
                    DropdownMenuItem(value: m, child: Text(m == 0 ? tr('usr.autoLockOff') : trp('usr.autoLockMin', {'n': m}))),
                ],
                onChanged: (v) async {
                  if (v != null) await _db.setAutoLock(v);
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_users.isEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text(tr('usr.none')))
          else
            for (final u in _users)
              Card(
                child: ListTile(
                  leading: CircleAvatar(child: Text(u.name.isEmpty ? '?' : u.name[0].toUpperCase())),
                  title: Text(u.name),
                  subtitle: Text('${userRoleName(u.role)}${u.active ? '' : ' · ${tr('usr.inactive')}'}'),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => _edit(u),
                ),
              ),
          const SizedBox(height: 16),
          ExpansionTile(
            title: Text(tr('usr.roles')),
            children: [
              for (final r in Perm.roles)
                ListTile(dense: true, title: Text(userRoleName(r)), subtitle: Text(tr('urole.$r.d'))),
            ],
          ),
        ]),
      ),
    );
  }
}

class _UserDialog extends StatefulWidget {
  const _UserDialog(this.db, this.user, {required this.first});
  final Db db;
  final AppUser? user;
  final bool first;
  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.user?.name ?? '');
  final TextEditingController _pin = TextEditingController();
  late String _role = widget.user?.role ?? (widget.first ? 'admin' : 'operator');
  late bool _active = widget.user?.active ?? true;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final e = await widget.db.saveUser(
      id: widget.user?.id,
      name: _name.text,
      role: _role,
      pin: _pin.text.isEmpty ? null : _pin.text,
      active: _active,
    );
    if (e == null) {
      if (mounted) Navigator.of(context).pop(true);
    } else {
      setState(() => _err = tr(e));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.user == null ? tr('usr.new') : tr('usr.edit')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: _name, decoration: InputDecoration(labelText: tr('usr.name'))),
            const SizedBox(height: 12),
            Text(tr('usr.role')),
            const SizedBox(height: 4),
            Wrap(spacing: 8, children: [
              for (final r in Perm.roles)
                ChoiceChip(label: Text(userRoleName(r)), selected: _role == r, onSelected: (_) => setState(() => _role = r)),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(tr('urole.$_role.d'), style: Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
              decoration: InputDecoration(labelText: widget.user == null ? tr('usr.pin') : tr('usr.pinKeep')),
            ),
            if (widget.user != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('usr.active')),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            if (_err != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(_err!, style: const TextStyle(color: Colors.red))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: _save, child: Text(tr('common.save'))),
        ],
      );
}
