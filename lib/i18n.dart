// Dictionar de traduceri: engleza = limba principala (in cod), romana = livrata, limbi noi adaugate de utilizator.
// Traducerile editate se pastreaza in tabelul `setting` (chei `languages`, `language`, `i18n_<cod>`), fara migrare de schema.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'db.dart';
import 'i18n_catalog.dart';

class Lang {
  const Lang(this.code, this.name);
  final String code, name;
}

/// Singleton: `tr('cheie')` intoarce textul in limba aplicatiei (cade pe engleza, apoi pe cheie).
final I18n i18n = I18n();

String tr(String key) => i18n.t(key);

/// Text cu parametri: `trp('cheie', {'n': 3})` inlocuieste `{n}` in textul tradus.
String trp(String key, Map<String, Object?> p) {
  var s = i18n.t(key);
  p.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}

class I18n extends ChangeNotifier {
  Db? _db;
  List<Lang> langs = const [Lang('en', 'English'), Lang('ro', 'Română')];
  String current = 'ro';
  final Map<String, Map<String, String>> _user = {}; // limba -> cheie -> text editat de utilizator

  static bool isBuiltin(String code) => code == 'en' || code == 'ro';

  Future<void> load(Db db) async {
    _db = db;
    try {
      final l = await db.getSetting('languages');
      if (l != null) {
        final out = <Lang>[const Lang('en', 'English'), const Lang('ro', 'Română')];
        for (final x in (jsonDecode(l) as List)) {
          final m = x as Map<String, Object?>;
          final c = '${m['c']}';
          if (!isBuiltin(c)) out.add(Lang(c, '${m['n']}'));
        }
        langs = out;
      }
      final cur = await db.getSetting('language');
      if (cur != null && langs.any((x) => x.code == cur)) current = cur;
      for (final lg in langs) {
        final j = await db.getSetting('i18n_${lg.code}');
        if (j == null || j.isEmpty) continue;
        final m = jsonDecode(j) as Map<String, Object?>;
        _user[lg.code] = {for (final e in m.entries) e.key: '${e.value}'};
      }
    } catch (_) {}
  }

  String? text(String lang, String key) {
    final u = _user[lang]?[key];
    if (u != null && u.isNotEmpty) return u;
    if (lang == 'en') return kEn[key];
    if (lang == 'ro') return kRo[key];
    return null;
  }

  String t(String key) => text(current, key) ?? kEn[key] ?? key;

  int translated(String lang) => kEn.keys.where((k) => text(lang, k) != null).length;
  int get total => kEn.length;

  Future<void> _persist(String lang) async {
    await _db?.setSetting('i18n_$lang', jsonEncode(_user[lang] ?? {}));
  }

  Future<void> _persistLangs() async {
    final extra = [
      for (final l in langs)
        if (!isBuiltin(l.code)) {'c': l.code, 'n': l.name}
    ];
    await _db?.setSetting('languages', jsonEncode(extra));
  }

  Future<void> setText(String lang, String key, String? value) async {
    final m = _user.putIfAbsent(lang, () => {});
    if (value == null || value.trim().isEmpty) {
      m.remove(key);
    } else {
      m[key] = value.trim();
    }
    await _persist(lang);
    notifyListeners();
  }

  Future<void> setCurrent(String code) async {
    if (!langs.any((l) => l.code == code)) return;
    current = code;
    await _db?.setSetting('language', code);
    notifyListeners();
  }

  /// Adauga o limba; false daca codul e invalid sau exista deja.
  Future<bool> addLang(String code, String name) async {
    final c = code.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}(-[a-z]{2})?$').hasMatch(c) || langs.any((l) => l.code == c) || name.trim().isEmpty) {
      return false;
    }
    langs = [...langs, Lang(c, name.trim())];
    await _persistLangs();
    notifyListeners();
    return true;
  }

  Future<void> removeLang(String code) async {
    if (isBuiltin(code)) return;
    langs = [for (final l in langs) if (l.code != code) l];
    _user.remove(code);
    await _persistLangs();
    await _db?.setSetting('i18n_$code', '');
    if (current == code) await setCurrent('ro');
    notifyListeners();
  }

  // ----- CSV: cheie, engleza, traducere (pentru traducere in afara aplicatiei si reimport) -----

  static String _esc(String s) => (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains(';'))
      ? '"${s.replaceAll('"', '""')}"'
      : s;

  String exportCsv(String lang) {
    final b = StringBuffer('key,en,$lang\n');
    for (final k in kEn.keys) {
      b.writeln('${_esc(k)},${_esc(text('en', k) ?? '')},${_esc(text(lang, k) ?? '')}');
    }
    return b.toString();
  }

  static List<List<String>> parseCsv(String src, String delim) {
    final rows = <List<String>>[];
    var row = <String>[];
    final f = StringBuffer();
    var q = false;
    for (var i = 0; i < src.length; i++) {
      final ch = src[i];
      if (q) {
        if (ch == '"') {
          if (i + 1 < src.length && src[i + 1] == '"') {
            f.write('"');
            i++;
          } else {
            q = false;
          }
        } else {
          f.write(ch);
        }
      } else if (ch == '"') {
        q = true;
      } else if (ch == delim) {
        row.add(f.toString());
        f.clear();
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < src.length && src[i + 1] == '\n') i++;
        row.add(f.toString());
        f.clear();
        if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
        row = <String>[];
      } else {
        f.write(ch);
      }
    }
    row.add(f.toString());
    if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
    return rows;
  }

  /// Importa traduceri pentru `lang`; intoarce numarul de texte aplicate. Coloana se alege dupa antet (codul limbii), altfel a 3-a.
  Future<int> importCsv(String lang, String src) async {
    final first = src.split('\n').first;
    final delim = first.contains('\t') ? '\t' : (first.contains(',') ? ',' : (first.contains(';') ? ';' : ','));
    final rows = parseCsv(src, delim);
    if (rows.isEmpty) return 0;
    var col = 2;
    var start = 0;
    final head = rows.first.map((c) => c.trim().toLowerCase()).toList();
    if (head.isNotEmpty && head.first == 'key') {
      start = 1;
      final i = head.indexOf(lang.toLowerCase());
      if (i >= 0) col = i;
    }
    final m = _user.putIfAbsent(lang, () => {});
    var n = 0;
    for (var r = start; r < rows.length; r++) {
      final row = rows[r];
      if (row.length <= col) continue;
      final k = row[0].trim();
      final v = row[col].trim();
      if (!kEn.containsKey(k) || v.isEmpty) continue;
      if (text(lang, k) != v) {
        m[k] = v;
        n++;
      }
    }
    await _persist(lang);
    notifyListeners();
    return n;
  }
}
