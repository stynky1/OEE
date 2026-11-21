// Chei de permisiune per sectiune. Cat timp setting.auth_enabled = 0 (implicit), db.can(...) este mereu true.
// Cand se pune tableta pe linie si se activeaza utilizatorii, se completeaza tabelul rol -> chei (A-utilizatori).
class PermKey {
  const PermKey(this.key, this.label);
  final String key;
  final String label;
}

class Perm {
  static const viewLine = 'view.line';
  static const viewHistory = 'view.history';
  static const viewChannels = 'view.channels';
  static const classify = 'classify';
  static const reclassify = 'reclassify';
  static const group = 'group';
  static const voidEvent = 'void';
  static const adminShifts = 'admin.shifts';
  static const adminChannels = 'admin.channels';
  static const adminProducts = 'admin.products';
  static const adminLossCodes = 'admin.lossCodes';
  static const adminLanguages = 'admin.languages';
  static const adminDevices = 'admin.devices';
  static const adminUsers = 'admin.users';
  static const adminCollector = 'admin.collector';
  static const adminExport = 'admin.export';
  static const productsStart = 'products.start';

  static const all = <PermKey>[
    PermKey(viewLine, 'Vede ecranul Linia'),
    PermKey(viewHistory, 'Vede istoricul (schimburi / zile trecute)'),
    PermKey(viewChannels, 'Poate schimba canalul vizualizat'),
    PermKey(classify, 'Clasifică opriri'),
    PermKey(reclassify, 'Reclasifică opriri deja clasificate'),
    PermKey(group, 'Grupează opriri'),
    PermKey(voidEvent, 'Anulează / restaurează evenimente'),
    PermKey(adminShifts, 'Administrare: schimburi'),
    PermKey(adminChannels, 'Administrare: canale'),
    PermKey(adminProducts, 'Administrare: produse'),
    PermKey(adminLossCodes, 'Administrare: motive de oprire'),
    PermKey(adminLanguages, 'Administrare: limbi și traduceri'),
    PermKey(adminDevices, 'Administrare: dispozitive'),
    PermKey(adminUsers, 'Administrare: utilizatori și drepturi'),
    PermKey(adminCollector, 'Administrare: colector (diagnostic)'),
    PermKey(adminExport, 'Administrare: export / import'),
    PermKey(productsStart, 'Pornește un produs (schimbare produs)'),
  ];

  /// Rolurile, de la cel mai mic la cel mai mare drept (matricea din spec-administrare.md, cap. 3).
  static const roles = <String>['operator', 'supervisor', 'manager', 'admin'];

  /// Cheile fiecărui rol. Produsele se pornesc de la operator în sus (schimbarea produsului e operațională);
  /// editarea lor, programul, motivele și limbile cer manager; canalele, utilizatorii, colectorul și exportul cer admin.
  static Set<String> forRole(String role) {
    final op = <String>{viewLine, viewHistory, viewChannels, classify, group, productsStart};
    final sup = <String>{...op, reclassify, voidEvent};
    final mgr = <String>{...sup, adminShifts, adminProducts, adminLossCodes, adminLanguages};
    switch (role) {
      case 'operator':
        return op;
      case 'supervisor':
        return sup;
      case 'manager':
        return mgr;
      case 'admin':
        return {for (final k in all) k.key};
    }
    return <String>{};
  }
}
