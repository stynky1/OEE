// Ecranul „Administrare”: lista sectiunilor, fiecare vizibila doar daca db.can(cheie).
// Sectiunile neimplementate apar dezactivate, cu pasul in care vin.
import 'package:flutter/material.dart';
import 'ble_service.dart';
import 'channels_page.dart';
import 'export.dart';
import 'i18n.dart';
import 'languages_page.dart';
import 'login_page.dart';
import 'loss_page.dart';
import 'perm.dart';
import 'shifts_page.dart';
import 'users_page.dart';

class AdminPage extends StatelessWidget {
  const AdminPage(this.ble, {super.key});
  final BleService ble;

  @override
  Widget build(BuildContext context) {
    final db = ble.db;
    final items = <_Item>[
      _Item(Perm.adminChannels, Icons.settings_input_component_outlined, tr('admin.channels.title'),
          tr('admin.channels.sub'), (c) => ChannelsPage(ble)),
      _Item(Perm.adminShifts, Icons.schedule, tr('admin.shifts.title'), tr('admin.shifts.sub'), (c) => ShiftsPage(ble)),
      _Item(Perm.adminProducts, Icons.inventory_2_outlined, tr('admin.products.title'), tr('admin.products.sub'), null),
      _Item(Perm.adminLossCodes, Icons.list_alt, tr('admin.losscodes.title'), tr('admin.losscodes.sub'), (c) => LossCodesPage(ble)),
      _Item(Perm.adminLanguages, Icons.translate, tr('admin.lang.title'), tr('admin.lang.sub'),
          (c) => const LanguagesPage()),
      _Item(Perm.adminUsers, Icons.manage_accounts_outlined, tr('admin.users.title'), tr('admin.users.sub'),
          (c) => UsersPage(ble)),
      _Item(Perm.adminExport, Icons.ios_share, tr('admin.export.title'), tr('admin.export.sub'),
          (c) => ExportPage(ble)),
    ];
    return ListenableBuilder(
      listenable: i18n,
      builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(tr('admin.title')), actions: [UserButton(db)]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final i in items)
          if (db.can(i.key))
            Card(
              child: ListTile(
                enabled: i.builder != null,
                leading: Icon(i.icon),
                title: Text(i.title),
                subtitle: Text(i.subtitle),
                trailing: i.builder == null ? null : const Icon(Icons.chevron_right),
                onTap: i.builder == null
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(builder: i.builder!)),
              ),
            ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(tr('admin.auth.title')),
            subtitle: Text(db.authEnabled ? tr('usr.authOn') : tr('usr.authOff')),
          ),
        ),
        ExpansionTile(
          title: Text(tr('admin.keys')),
          children: [
            for (final p in Perm.all)
              ListTile(dense: true, title: Text(p.label), subtitle: Text(p.key)),
          ],
        ),
      ]),
    ));
  }
}

class _Item {
  const _Item(this.key, this.icon, this.title, this.subtitle, this.builder);
  final String key;
  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder? builder;
}
