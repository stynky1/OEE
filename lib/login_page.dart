// Autentificare: alegi utilizatorul si introduci PIN-ul. Apare la pornirea aplicatiei cand autentificarea e activa
// (Administrare → Utilizatori) si dupa „Schimba utilizatorul”. Dupa 5 PIN-uri gresite: pauza de 30 s.
import 'package:flutter/material.dart';
import 'db.dart';
import 'i18n.dart';

String userRoleName(String role) {
  final t = tr('urole.$role');
  return t == 'urole.$role' ? role : t;
}

class LoginPage extends StatefulWidget {
  const LoginPage(this.db, {super.key});
  final Db db;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  List<AppUser> _users = const [];
  AppUser? _sel;
  String _pin = '';
  String? _err;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await widget.db.users(loginable: true);
    if (mounted) {
      setState(() {
        _users = u;
        if (u.length == 1) _sel = u.first;
      });
    }
  }

  void _key(String d) {
    if (_pin.length >= 8) return;
    setState(() {
      _pin += d;
      _err = null;
    });
  }

  void _back() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _enter() async {
    final u = _sel;
    if (u == null || _pin.length < 4 || _busy) return;
    setState(() => _busy = true);
    final r = await widget.db.login(u.id, _pin);
    if (!mounted) return;
    if (r == null) return; // Gate-ul trece pe aplicatie
    setState(() {
      _busy = false;
      _pin = '';
      _err = r.startsWith('locked:') ? trp('login.locked', {'s': r.substring(7)}) : tr('login.bad');
    });
  }

  Future<void> _forgot() async {
    final c = TextEditingController();
    String? err;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tr('login.recoverTitle')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('login.recoverHint')),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(border: const OutlineInputBorder(), errorText: err),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('common.cancel'))),
            FilledButton(
              onPressed: () async {
                final ok = await widget.db.recoverDisableAuth(c.text);
                if (ok) {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                } else {
                  setD(() => err = tr('login.recoverBad'));
                }
              },
              child: Text(tr('common.ok')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _keypad() {
    Widget k(String label, VoidCallback? onTap, {IconData? icon}) => Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            height: 56,
            child: FilledButton.tonal(
              onPressed: onTap,
              child: icon != null ? Icon(icon) : Text(label, style: const TextStyle(fontSize: 22)),
            ),
          ),
        );
    return Column(children: [
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9']
      ])
        Row(children: [for (final d in row) Expanded(child: k(d, () => _key(d)))]),
      Row(children: [
        Expanded(child: k('', _back, icon: Icons.backspace_outlined)),
        Expanded(child: k('0', () => _key('0'))),
        Expanded(child: k('', _pin.length >= 4 && _sel != null ? _enter : null, icon: Icons.check)),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Text('OEE', style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text(tr('login.title'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 20),
                if (_users.isEmpty)
                  Text(tr('login.noUsers'), textAlign: TextAlign.center)
                else ...[
                  Text(tr('login.pick'), style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final u in _users)
                      ChoiceChip(
                        label: Text('${u.name} · ${userRoleName(u.role)}'),
                        selected: _sel?.id == u.id,
                        onSelected: (_) => setState(() {
                          _sel = u;
                          _pin = '';
                          _err = null;
                        }),
                      ),
                  ]),
                  const SizedBox(height: 20),
                  Text(tr('login.pin'), style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).colorScheme.outline),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text('•' * _pin.length, style: const TextStyle(fontSize: 26, letterSpacing: 4)),
                  ),
                  if (_err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_err!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                    ),
                  const SizedBox(height: 12),
                  _keypad(),
                ],
                const SizedBox(height: 12),
                TextButton(onPressed: _forgot, child: Text(tr('login.forgot'))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Butonul utilizatorului din bara aplicatiei: numele + „Schimba utilizatorul”. Apare doar cu autentificarea activa.
class UserButton extends StatelessWidget {
  const UserButton(this.db, {super.key});
  final Db db;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: db.authTick,
        builder: (context, _, __) {
          final u = db.currentUser;
          if (!db.authEnabled || u == null) return const SizedBox.shrink();
          return PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: u.name,
            onSelected: (v) {
              if (v == 'out') db.logout();
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(enabled: false, child: Text('${u.name} · ${userRoleName(u.role)}')),
              PopupMenuItem<String>(value: 'out', child: Text(tr('login.switch'))),
            ],
          );
        },
      );
}
