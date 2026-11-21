// Stocare locala durabila (SQLite). Ack-ul catre ESP32 se trimite NUMAI dupa ce insertMessages() a reusit.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'sha256.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'i18n.dart';
import 'perm.dart';
import 'protocol.dart';
import 'shifts.dart';
import 'uuid.dart';

/// Versiunea schemei locale. v3 = UUID-uri + tabele de configurare (vezi _migrateToV3).
const int kDbVersion = 5;

class Sku {
  Sku({this.id, required this.name, this.mode = 'pace', required this.value,
      this.triggerS = 10, this.targetOee, this.color = 0xFF9E9E9E});
  int? id;
  String name;
  String mode; // 'pace' (buc/ora) sau 'cycle' (secunde)
  double value;
  double triggerS;
  double? targetOee;
  int color;

  /// Reteta pe senzor (canal 1..8): viteza, T si tinta OEE proprii. Gol = produs vechi / canal necompletat.
  Map<int, SkuChan> chans = {};

  double rateFor(int ch) => chans[ch]?.rateBph ?? pacePerHour;
  double triggerFor(int ch) => chans[ch]?.triggerS ?? triggerS;
  double? targetFor(int ch) => chans[ch] == null ? targetOee : chans[ch]!.targetOee;
  double cycleFor(int ch) => 3600 / rateFor(ch);

  /// Timp de ciclu cu precizie completa (3600/5500 = 0.654545..., NU 0.7).
  double get cycleS => mode == 'pace' ? 3600 / value : value;
  double get pacePerHour => mode == 'pace' ? value : 3600 / value;

  static Sku fromRow(Map<String, Object?> r) => Sku(
        id: r['id'] as int?,
        name: r['name'] as String,
        mode: r['mode'] as String,
        value: (r['value'] as num).toDouble(),
        triggerS: (r['trigger_s'] as num).toDouble(),
        targetOee: (r['target_oee'] as num?)?.toDouble(),
        color: r['color'] as int,
      );

  Map<String, Object?> toRow() => {
        'name': name, 'mode': mode, 'value': value, 'trigger_s': triggerS,
        'target_oee': targetOee, 'color': color,
      };
}

/// Valorile unui produs pe un senzor (canal).
class SkuChan {
  SkuChan({required this.rateBph, required this.triggerS, this.targetOee});
  double rateBph;
  double triggerS;
  double? targetOee;
}

/// Utilizator al aplicatiei (PIN-ul si sarea nu ies din baza de date).
class AppUser {
  AppUser(this.id, this.uuid, this.name, this.role, this.active);
  final int id;
  final String uuid, name, role;
  final bool active;
}

class ActiveRun {
  ActiveRun(this.runNo, this.sku);
  final int runNo;
  final Sku sku;
}

class LossCode {
  LossCode(this.id, this.parentId, this.name, {this.kind, this.active = true});
  final int id;
  final int? parentId;
  final String name;

  /// Clasa IWS (doar la nivelul 1): unscheduled | planned | unplanned | rate | micro | quality; null = cod vechi (din teste).
  final String? kind;
  final bool active;
}

/// Clasele IWS ale motivelor (nivelul 1) si ce vede operatorul pe un stop.
const List<String> kLossKinds = ['unscheduled', 'planned', 'unplanned', 'rate', 'micro', 'quality'];
const List<String> kStopKinds = ['unscheduled', 'planned', 'unplanned'];

/// Numele afisat al unui motiv de nivel 1: clasa IWS (tradusa) sau numele vechi.
String lossLabel(String? name, String? kind) {
  if (kind == null) return name ?? '';
  final t = i18n.t('cls.$kind');
  return t == 'cls.$kind' ? (name ?? kind) : t;
}

/// Un canal ESP32 (1..8) asa cum e configurat pe tableta. [rateBph]/[triggerS] = ritm nominal / T proprii (null = din produs).
class ChannelRow {
  ChannelRow({
    required this.id,
    required this.name,
    required this.active,
    required this.role,
    this.rateBph,
    this.triggerS,
    this.msgs = 0,
    this.last,
  });
  final int id;
  final String name;
  final bool active;
  final String role;
  final double? rateBph;
  final double? triggerS;
  final int msgs;
  final String? last;

  ChannelRow copyWith({String? name, bool? active, String? role, double? rateBph, double? triggerS, bool clearRate = false, bool clearTrigger = false}) =>
      ChannelRow(
        id: id,
        name: name ?? this.name,
        active: active ?? this.active,
        role: role ?? this.role,
        rateBph: clearRate ? null : (rateBph ?? this.rateBph),
        triggerS: clearTrigger ? null : (triggerS ?? this.triggerS),
        msgs: msgs,
        last: last,
      );
}

class Db {
  Db._(this._db);
  final Database _db;

  /// Canalul principal al liniei (setting main_channel, implicit 1). Ecranele Linia / Opriri si calculele KPI
  /// folosesc doar acest canal; celelalte canale se afiseaza abia cand exista suport (pasul 7).
  int mainCh = 1;

  /// Canalul afisat in Linia si Opriri (selectorul de canal). Porneste pe canalul principal.
  int viewCh = 1;

  /// Rezultatul ultimei migrari, afisat in Colector (null = nicio migrare la aceasta pornire).
  static String? migrationNote;

  static Future<Db> open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'oee.db');
    final db = await openDatabase(path, version: kDbVersion, onCreate: (d, v) async {
      await _create(d); // forma v2 (+ nomenclator de test)
      await _migrateToV3(d); // + uuid, tabele de configurare, valori implicite
      await _migrateToV4(d); // clase IWS pentru motive
      await _migrateToV5(d); // reteta pe senzor
    }, onUpgrade: (d, from, to) async {
      if (from < 2) {
        // v1 (prototipul cu inregistrari binare) nu are date de pastrat
        for (final t in ['raw_message', 'time_ref', 'message', 'cause', 'sku', 'run', 'loss_code']) {
          await d.execute('DROP TABLE IF EXISTS $t');
        }
        await _create(d);
        await _migrateToV3(d);
        await _migrateToV4(d);
        await _migrateToV5(d);
        return;
      }
      if (from < 3) {
        // Copie de siguranta INAINTE de orice modificare (fisierul e inca nemodificat in acest punct).
        var backup = 'fara copie';
        try {
          final dst = p.join(dir, 'oee_pre_v3.db');
          await File(path).copy(dst);
          backup = 'copie: oee_pre_v3.db';
        } catch (e) {
          backup = 'copie ESUATA ($e)';
        }
        await _migrateToV3(d);
        migrationNote = 'v$from → v$to · $backup';
      }
      if (from < 4) {
        await _migrateToV4(d);
        migrationNote = '${migrationNote == null ? '' : '$migrationNote · '}v4: clase IWS pentru motive';
      }
      if (from < 5) {
        await _migrateToV5(d);
        migrationNote = '${migrationNote == null ? '' : '$migrationNote · '}v5: reteta pe senzor';
      }
    });
    final out = Db._(db);
    try {
      final r = await db.query('setting', where: 'key = ?', whereArgs: ['main_channel']);
      if (r.isNotEmpty) out.mainCh = int.tryParse('${r.first['value']}') ?? 1;
      out.viewCh = out.mainCh;
      final a = await db.query('setting', where: 'key = ?', whereArgs: ['auth_enabled']);
      out.authEnabled = a.isNotEmpty && '${a.first['value']}' == '1';
      final al = await db.query('setting', where: 'key = ?', whereArgs: ['auto_lock_min']);
      out.autoLockMin = al.isEmpty ? 0 : (int.tryParse('${al.first['value']}') ?? 0);
      final sp = await db.query('setting', where: 'key = ?', whereArgs: ['shift_plan']);
      final pa = await db.query('setting', where: 'key = ?', whereArgs: ['planned_in_avail']);
      out.plannedInAvail = pa.isEmpty || '${pa.first['value']}' != '0';
      await out.backfillTimes();
      out.shifts = ShiftSchedule.fromJsonString(sp.isEmpty ? null : '${sp.first['value']}') ?? ShiftSchedule.initial();
    } catch (_) {}
    return out;
  }

  /// v2 → v3: strict aditiv (nu sterge si nu rescrie date existente).
  ///  - uuid pe sku, run, loss_code, cause (completat pentru randurile existente);
  ///  - message.ch / mc / md (canal si microopriri agregate; implicit canalul 1);
  ///  - cause.user_uuid / reason / group_id (pentru corectii si grupare);
  ///  - tabele noi: channel, shift_def, app_user, setting, event_void, audit_log.
  static Future<void> _migrateToV3(Database d) async {
    for (final t in ['sku', 'run', 'loss_code', 'cause']) {
      await d.execute('ALTER TABLE $t ADD COLUMN uuid TEXT');
    }
    await d.execute('ALTER TABLE message ADD COLUMN ch INTEGER NOT NULL DEFAULT 1');
    await d.execute('ALTER TABLE message ADD COLUMN mc INTEGER');
    await d.execute('ALTER TABLE message ADD COLUMN md INTEGER');
    await d.execute('ALTER TABLE cause ADD COLUMN user_uuid TEXT');
    await d.execute('ALTER TABLE cause ADD COLUMN reason TEXT');
    await d.execute('ALTER TABLE cause ADD COLUMN group_id TEXT');
    await _createConfigTables(d);
    // UUID pentru randurile existente (tabele mici; cause poate avea mii de randuri, dar e o singura data)
    for (final e in {'sku': 'id', 'run': 'run_no', 'loss_code': 'id'}.entries) {
      final rows = await d.rawQuery('SELECT ${e.value} AS k FROM ${e.key}');
      final b = d.batch();
      for (final r in rows) {
        b.update(e.key, {'uuid': newUuid()}, where: '${e.value} = ?', whereArgs: [r['k']]);
      }
      await b.commit(noResult: true);
    }
    final causes = await d.rawQuery('SELECT device, boot, seq FROM cause');
    final cb = d.batch();
    for (final r in causes) {
      cb.update('cause', {'uuid': newUuid()},
          where: 'device = ? AND boot = ? AND seq = ?', whereArgs: [r['device'], r['boot'], r['seq']]);
    }
    await cb.commit(noResult: true);
    await _seedConfig(d);
  }

  /// v4 → v5: reteta pe senzor. Tabela `sku_channel` (produs x canal: viteza, T, tinta OEE). Aditiv: coloanele
  /// `channel.rate_override` / `trigger_override` raman, dar nu se mai folosesc. Valorile de pana acum se copiaza in
  /// fiecare produs (ritmul propriu al canalului, altfel ritmul produsului), deci KPI-urile istorice nu se schimba.
  static Future<void> _migrateToV5(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS sku_channel (
        sku_id INTEGER NOT NULL, ch INTEGER NOT NULL,
        rate_bph REAL NOT NULL, trigger_s REAL NOT NULL, target_oee REAL,
        PRIMARY KEY (sku_id, ch)
      )''');
    final skus = await d.query('sku');
    final chans = await d.query('channel');
    for (final s in skus) {
      final mode = s['mode'] as String;
      final v = (s['value'] as num).toDouble();
      final pace = mode == 'pace' ? v : 3600 / v;
      for (final c in chans) {
        final id = (c['id'] as num).toInt();
        final ro = (c['rate_override'] as num?)?.toDouble();
        final to = (c['trigger_override'] as num?)?.toDouble();
        if (!(id == 1 || (c['active'] as num?) == 1 || ro != null)) continue;
        await d.insert('sku_channel', {
          'sku_id': s['id'],
          'ch': id,
          'rate_bph': (ro != null && ro > 0) ? ro : pace,
          'trigger_s': to ?? (s['trigger_s'] as num).toDouble(),
          'target_oee': s['target_oee'],
        });
      }
    }
  }

  /// v3 → v4: motivele devin clase IWS (nivelul 1, cu `kind`) cu detalii (nivelul 2). Aditiv:
  /// coloane noi `kind`, `active`, `sort`; codurile vechi folosite de clasificari raman (inactive, vizibile in istoric),
  /// cele nefolosite se sterg; se adauga clasele si detaliile implicite (editabile din Administrare).
  static Future<void> _migrateToV4(Database d) async {
    await d.execute('ALTER TABLE loss_code ADD COLUMN kind TEXT');
    await d.execute('ALTER TABLE loss_code ADD COLUMN active INTEGER NOT NULL DEFAULT 1');
    await d.execute('ALTER TABLE loss_code ADD COLUMN sort INTEGER NOT NULL DEFAULT 0');
    final used = <int>{};
    for (final r in await d.rawQuery('SELECT DISTINCT code1 AS a, code2 AS b FROM cause')) {
      if (r['a'] != null) used.add((r['a'] as num).toInt());
      if (r['b'] != null) used.add((r['b'] as num).toInt());
    }
    final old = await d.rawQuery('SELECT id, parent_id FROM loss_code');
    for (final r in old) {
      final id = (r['id'] as num).toInt();
      final parent = (r['parent_id'] as num?)?.toInt();
      final keep = used.contains(id) ||
          (parent == null && old.any((x) => (x['parent_id'] as num?)?.toInt() == id && used.contains((x['id'] as num).toInt())));
      if (keep) {
        await d.update('loss_code', {'active': 0}, where: 'id = ?', whereArgs: [id]);
      } else {
        await d.delete('loss_code', where: 'id = ?', whereArgs: [id]);
      }
    }
    const names = {
      'unscheduled': 'Unscheduled', 'planned': 'Planned', 'unplanned': 'Unplanned',
      'rate': 'Rate loss', 'micro': 'Micro stops', 'quality': 'Quality loss',
    };
    const details = <String, List<String>>{
      'unscheduled': ['Weekend / sărbătoare legală', 'Nu este nevoie de linie'],
      'planned': ['Change Over', 'CIL', 'Mentenanță preventivă', 'CIP', 'Training'],
      'unplanned': ['Defect electric', 'Defect mecanic', 'Breakdown', 'Oprire minoră', 'Eroare operator'],
    };
    var order = 0;
    for (final k in kLossKinds) {
      final id = await d.insert('loss_code',
          {'parent_id': null, 'name': names[k], 'uuid': newUuid(), 'kind': k, 'active': 1, 'sort': order++});
      var n = 0;
      for (final x in details[k] ?? const <String>[]) {
        await d.insert('loss_code', {'parent_id': id, 'name': x, 'uuid': newUuid(), 'active': 1, 'sort': n++});
      }
    }
  }

  static Future<void> _createConfigTables(Database d) async {
    // Canalele ESP32 (1..8). id = numarul canalului. role: produs | rebut | intrare | iesire (vezi spec-8-canale.md 2.6).
    await d.execute('''
      CREATE TABLE channel (
        id INTEGER PRIMARY KEY, uuid TEXT NOT NULL, name TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 0, role TEXT NOT NULL DEFAULT 'produs',
        count_level INTEGER NOT NULL DEFAULT 1,
        rate_override REAL, trigger_override REAL,
        min_pulse_us INTEGER, min_interval_us INTEGER
      )''');
    // Program de lucru: minute de la miezul noptii (local); end_min > 1440 = trece peste miezul noptii.
    await d.execute('''
      CREATE TABLE shift_def (
        id INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT NOT NULL, name TEXT NOT NULL,
        start_min INTEGER NOT NULL, end_min INTEGER NOT NULL,
        days_mask INTEGER NOT NULL DEFAULT 127, sort INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1
      )''');
    await d.execute('''
      CREATE TABLE app_user (
        id INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT NOT NULL, name TEXT NOT NULL,
        role TEXT NOT NULL, pin_hash TEXT, pin_salt TEXT, language TEXT,
        active INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL
      )''');
    await d.execute('CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT)');
    // Anularea ("stergerea") opririlor: mesajul brut ramane; anularea se poate restaura.
    await d.execute('''
      CREATE TABLE event_void (
        device TEXT NOT NULL, boot INTEGER NOT NULL, seq INTEGER NOT NULL,
        voided_at INTEGER NOT NULL, user_uuid TEXT, reason TEXT, restored_at INTEGER,
        PRIMARY KEY (device, boot, seq)
      )''');
    await d.execute('''
      CREATE TABLE audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, user_uuid TEXT,
        action TEXT NOT NULL, entity TEXT, entity_uuid TEXT, detail TEXT
      )''');
  }

  /// Valori implicite, identice cu comportamentul de pana acum (fara regresie): canalul 1 activ,
  /// 2..8 inactive; Schimb 1 = 07:00–15:00, Schimb 2 = 15:00–23:30 (de validat de Stefan, cap. 6 din spec-administrare).
  static Future<void> _seedConfig(Database d) async {
    for (var ch = 1; ch <= 8; ch++) {
      await d.insert('channel', {
        'id': ch, 'uuid': newUuid(), 'name': 'Canal $ch', 'active': ch == 1 ? 1 : 0,
      });
    }
    await d.insert('shift_def',
        {'uuid': newUuid(), 'name': 'Schimb 1', 'start_min': 7 * 60, 'end_min': 15 * 60, 'sort': 1});
    await d.insert('shift_def',
        {'uuid': newUuid(), 'name': 'Schimb 2', 'start_min': 15 * 60, 'end_min': 23 * 60 + 30, 'sort': 2});
    await d.insert('setting', {'key': 'main_channel', 'value': '1'});
    await d.insert('setting', {'key': 'language', 'value': 'ro'});
  }

  /// Rezumat pentru Colector: versiunea schemei si cate randuri de configurare exista.
  Future<String> configSummary() async {
    Future<int> n(String t) async =>
        Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM $t')) ?? 0;
    final v = Sqflite.firstIntValue(await _db.rawQuery('PRAGMA user_version')) ?? 0;
    final noUuid = Sqflite.firstIntValue(await _db.rawQuery(
            "SELECT (SELECT COUNT(*) FROM sku WHERE uuid IS NULL) + (SELECT COUNT(*) FROM run WHERE uuid IS NULL)"
            " + (SELECT COUNT(*) FROM loss_code WHERE uuid IS NULL) + (SELECT COUNT(*) FROM cause WHERE uuid IS NULL)")) ??
        0;
    return 'schema v$v · canale ${await n('channel')} · schimburi ${await n('shift_def')}'
        ' · produse ${await n('sku')} · run-uri ${await n('run')} · fara uuid $noUuid';
  }

  static Future<void> _create(Database d) async {
    // Cheia naturala (device, boot, seq) = aceeasi ca in cloud -> sincronizare idempotenta.
    await d.execute('''
      CREATE TABLE message (
        device TEXT NOT NULL, boot INTEGER NOT NULL, seq INTEGER NOT NULL,
        type TEXT NOT NULL, run INTEGER NOT NULL, ts TEXT, up_ms INTEGER NOT NULL,
        st TEXT, from_ts TEXT, to_ts TEXT, dur_ms INTEGER, n INTEGER, kind TEXT,
        body TEXT NOT NULL, received_at INTEGER NOT NULL, synced INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (device, boot, seq)
      )''');
    await d.execute('CREATE INDEX message_unsynced ON message (synced, boot, seq)');
    await d.execute('''
      CREATE TABLE sku (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, mode TEXT NOT NULL,
        value REAL NOT NULL, trigger_s REAL NOT NULL, target_oee REAL, color INTEGER NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE run (
        run_no INTEGER PRIMARY KEY AUTOINCREMENT, sku_id INTEGER NOT NULL,
        started_at INTEGER NOT NULL, ended_at INTEGER
      )''');
    await d.execute('''
      CREATE TABLE loss_code (id INTEGER PRIMARY KEY, parent_id INTEGER, name TEXT NOT NULL)''');
    await d.execute('''
      CREATE TABLE cause (
        device TEXT NOT NULL, boot INTEGER NOT NULL, seq INTEGER NOT NULL,
        code1 INTEGER NOT NULL, code2 INTEGER, comment TEXT, created_at INTEGER NOT NULL,
        PRIMARY KEY (device, boot, seq)
      )''');
    // Nomenclator implicit, doar pentru teste; in productie vine din cloud (loss_code, 2 niveluri).
    const seed = <String, List<String>>{
      'Mecanic': ['Transportor', 'Umplere', 'Capsare', 'Etichetare'],
      'Electric / automatizare': ['Senzor', 'Motor', 'PLC'],
      'Materiale': ['Lipsa sticle', 'Lipsa dopuri', 'Lipsa etichete'],
      'Operational': ['Schimb produs', 'Curatare', 'Pauza', 'Lipsa personal'],
      'Calitate': ['Reglaj calitate', 'Defect produs'],
    };
    var id = 1;
    for (final e in seed.entries) {
      final parent = id++;
      await d.insert('loss_code', {'id': parent, 'parent_id': null, 'name': e.key});
      for (final c in e.value) {
        await d.insert('loss_code', {'id': id++, 'parent_id': parent, 'name': c});
      }
    }
  }

  // ----- mesaje de la dispozitiv -----
  Future<void> insertMessages(String device, List<Msg> msgs) async {
    if (msgs.isEmpty) return;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final b = _db.batch();
    for (final m in msgs) {
      final j = m.json;
      b.insert(
        'message',
        {
          'device': device, 'boot': m.boot, 'seq': m.seq, 'type': m.type, 'run': m.run,
          'ts': m.ts, 'up_ms': m.upMs, 'st': j['st'], 'from_ts': j['from'], 'to_ts': j['to'],
          'dur_ms': j['dur_ms'], 'n': j['n'], 'kind': j['k'], 'body': jsonEncode(j),
          'ch': j['ch'] ?? 1, 'mc': j['mc'], 'md': j['md'],
          'received_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore, // retransmisie => duplicat ignorat
      );
    }
    await b.commit(noResult: true); // batch = o singura tranzactie
    if (_needBackfill || msgs.any((m) => m.ts == null && m.type != 'boot')) await backfillTimes();
  }

  bool _needBackfill = true;

  /// P-31: mesajele fara ora (ESP32 inainte ca tableta sa scrie Time) primesc ora din uptime:
  /// ora unui mesaj cu ora din acelasi boot, minus diferenta de uptime. Mesajele `boot` nu se ating.
  /// Intoarce numarul de mesaje completate; boot-urile fara niciun mesaj cu ora raman pentru mai tarziu.
  Future<int> backfillTimes() async {
    var filled = 0;
    var unresolved = false;
    final boots = await _db.rawQuery("SELECT DISTINCT device, boot FROM message WHERE ts IS NULL AND type != 'boot'");
    String iso(int ms) => '${DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String().substring(0, 19)}Z';
    for (final r in boots) {
      final dev = r['device'], boot = r['boot'];
      final ref = await _db.rawQuery(
          "SELECT ts, up_ms FROM message WHERE device = ? AND boot = ? AND ts IS NOT NULL AND type != 'boot' ORDER BY seq LIMIT 1",
          [dev, boot]);
      if (ref.isEmpty) {
        unresolved = true;
        continue;
      }
      final t0 = DateTime.tryParse('${ref.first['ts']}');
      if (t0 == null) continue;
      final offset = t0.millisecondsSinceEpoch - ((ref.first['up_ms'] as num?)?.toInt() ?? 0);
      final rows = await _db.rawQuery(
          "SELECT seq, type, up_ms, dur_ms, from_ts, to_ts FROM message WHERE device = ? AND boot = ? AND ts IS NULL AND type != 'boot'",
          [dev, boot]);
      final b = _db.batch();
      for (final m in rows) {
        final end = offset + ((m['up_ms'] as num?)?.toInt() ?? 0);
        final vals = <String, Object?>{'ts': iso(end)};
        if (m['type'] == 'ev') {
          final dur = (m['dur_ms'] as num?)?.toInt() ?? 0;
          vals['to_ts'] = m['to_ts'] ?? iso(end);
          vals['from_ts'] = m['from_ts'] ?? iso(end - dur);
        }
        b.update('message', vals, where: 'device = ? AND boot = ? AND seq = ?', whereArgs: [dev, boot, m['seq']]);
        filled++;
      }
      await b.commit(noResult: true);
    }
    _needBackfill = unresolved;
    return filled;
  }

  Future<int> count() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM message')) ?? 0;

  /// Interogare doar pentru citire (exportul CSV foloseste propriile SELECT-uri).
  Future<List<Map<String, Object?>>> rawRead(String sql, [List<Object?>? args]) => _db.rawQuery(sql, args);

  /// Urma in audit a unui export (cine si ce interval).
  Future<void> logExport(String detail) => _audit('export', 'export', detail);

  Future<int> unsyncedCount() async => Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM message WHERE synced = 0')) ??
      0;

  Future<List<Map<String, Object?>>> latest(int n) =>
      _db.query('message', orderBy: 'boot DESC, seq DESC', limit: n);

  // ----- produse (SKU) si run-uri -----
  Future<List<Sku>> skus() async {
    final out = (await _db.query('sku', orderBy: 'name COLLATE NOCASE')).map(Sku.fromRow).toList();
    for (final s in out) {
      await _loadChans(s);
    }
    return out;
  }

  Future<Sku> _loadChans(Sku s) async {
    final rows = await _db.query('sku_channel', where: 'sku_id = ?', whereArgs: [s.id]);
    s.chans = {
      for (final r in rows)
        (r['ch'] as num).toInt(): SkuChan(
            rateBph: (r['rate_bph'] as num).toDouble(),
            triggerS: (r['trigger_s'] as num).toDouble(),
            targetOee: (r['target_oee'] as num?)?.toDouble()),
    };
    return s;
  }

  /// Salveaza produsul si reteta lui (cate un rand pe canal). Valorile de baza ale produsului (ritm, T, tinta)
  /// sunt cele ale canalului principal, pentru firmware 2 si pentru istoric.
  Future<void> saveSku(Sku s) async {
    final main = s.chans[mainCh] ?? (s.chans.isEmpty ? null : s.chans.values.first);
    if (main != null) {
      s.mode = 'pace';
      s.value = main.rateBph;
      s.triggerS = main.triggerS;
      s.targetOee = main.targetOee;
    }
    if (s.id == null) {
      s.id = await _db.insert('sku', {...s.toRow(), 'uuid': newUuid()});
    } else {
      await _db.update('sku', s.toRow(), where: 'id = ?', whereArgs: [s.id]);
    }
    await _db.delete('sku_channel', where: 'sku_id = ?', whereArgs: [s.id]);
    for (final e in s.chans.entries) {
      await _db.insert('sku_channel', {
        'sku_id': s.id,
        'ch': e.key,
        'rate_bph': e.value.rateBph,
        'trigger_s': e.value.triggerS,
        'target_oee': e.value.targetOee,
      });
    }
    await _db.insert('audit_log', {
      'ts': DateTime.now().toUtc().millisecondsSinceEpoch,
      'user_uuid': currentUser?.uuid,
      'action': 'recipe_edit',
      'entity': 'sku',
      'detail': jsonEncode({
        'sku': s.name,
        'chans': {for (final e in s.chans.entries) '${e.key}': [e.value.rateBph, e.value.triggerS, e.value.targetOee]},
      }),
    });
  }

  Future<void> deleteSku(int id) async {
    await _db.delete('sku_channel', where: 'sku_id = ?', whereArgs: [id]);
    await _db.delete('sku', where: 'id = ?', whereArgs: [id]);
  }

  /// Canalele active care nu au viteza in reteta produsului: pornirea se blocheaza pana se completeaza.
  Future<List<ChannelRow>> missingChannels(Sku s) async {
    final fresh = await _loadChans(Sku(id: s.id, name: s.name, value: 1));
    return [
      for (final c in await channels(stats: false))
        if (c.active && (fresh.chans[c.id]?.rateBph ?? 0) <= 0) c
    ];
  }

  Future<ActiveRun?> startRun(Sku s) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.update('run', {'ended_at': now}, where: 'ended_at IS NULL');
    final no = await _db.insert('run', {'sku_id': s.id, 'started_at': now, 'uuid': newUuid()});
    return ActiveRun(no, s);
  }

  Future<ActiveRun?> activeRun() async {
    final r = await _db.rawQuery('''
      SELECT r.run_no AS run_no, s.* FROM run r JOIN sku s ON s.id = r.sku_id
      WHERE r.ended_at IS NULL ORDER BY r.run_no DESC LIMIT 1''');
    if (r.isEmpty) return null;
    return ActiveRun(r.first['run_no'] as int, await _loadChans(Sku.fromRow(r.first)));
  }

  Future<String?> skuNameForRun(int runNo) async {
    final r = await _db.rawQuery(
        'SELECT s.name AS name FROM run r JOIN sku s ON s.id = r.sku_id WHERE r.run_no = ?', [runNo]);
    return r.isEmpty ? null : r.first['name'] as String?;
  }

  // ----- opriri care cer motiv (pauza >= Triggering Cycle Time) -----
  Future<List<Map<String, Object?>>> pendingStops({int? ch}) => _db.rawQuery('''
      SELECT m.* FROM message m
      LEFT JOIN cause c ON c.device = m.device AND c.boot = m.boot AND c.seq = m.seq
      WHERE m.type = 'ev' AND m.st = 'stop' AND m.ch = ? AND c.seq IS NULL
      ORDER BY m.boot DESC, m.seq DESC LIMIT 200''', [ch ?? viewCh]);

  /// Motive: nivelul 1 (parentId null) sau detaliile unei clase. Implicit doar cele active;
  /// [kinds] limiteaza clasele (operatorul vede doar clasele de oprire); [legacy] = codurile vechi (fara clasa).
  Future<List<LossCode>> lossCodes({int? parentId, bool onlyActive = true, List<String>? kinds, bool legacy = false}) async {
    final where = <String>[parentId == null ? 'parent_id IS NULL' : 'parent_id = ?'];
    final args = <Object?>[if (parentId != null) parentId];
    if (onlyActive) where.add('active = 1');
    if (legacy) where.add('kind IS NULL');
    if (kinds != null) {
      where.add('kind IN (${List.filled(kinds.length, '?').join(',')})');
      args.addAll(kinds);
    }
    final rows = await _db.query('loss_code', where: where.join(' AND '), whereArgs: args, orderBy: 'sort, id');
    return rows
        .map((r) => LossCode((r['id'] as num).toInt(), (r['parent_id'] as num?)?.toInt(), '${r['name']}',
            kind: r['kind'] as String?, active: (r['active'] as num?) != 0))
        .toList();
  }

  Future<void> _logLoss(String detail) => _db.insert('audit_log', {
        'ts': DateTime.now().toUtc().millisecondsSinceEpoch,
        'user_uuid': currentUser?.uuid,
        'action': 'loss_code_edit',
        'entity': 'loss_code',
        'detail': detail,
      });

  /// De cate ori e folosit un motiv in clasificari (ca nivel 1 sau 2).
  Future<int> lossUsage(int id) async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM cause WHERE code1 = ? OR code2 = ?', [id, id])) ?? 0;

  /// Adauga (id null) sau redenumeste un detaliu (nivelul 2) al unei clase.
  Future<void> saveLossDetail({int? id, required int parentId, required String name}) async {
    final n = name.trim();
    if (n.isEmpty) return;
    if (id == null) {
      final mx = Sqflite.firstIntValue(
              await _db.rawQuery('SELECT COALESCE(MAX(sort), -1) FROM loss_code WHERE parent_id = ?', [parentId])) ??
          -1;
      await _db.insert('loss_code', {'parent_id': parentId, 'name': n, 'uuid': newUuid(), 'active': 1, 'sort': mx + 1});
    } else {
      await _db.update('loss_code', {'name': n}, where: 'id = ?', whereArgs: [id]);
    }
    await _logLoss('${id ?? 'new'}:$n');
  }

  Future<void> setLossActive(int id, bool active) async {
    await _db.update('loss_code', {'active': active ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
    await _logLoss('$id:${active ? 'on' : 'off'}');
  }

  /// Sterge un detaliu nefolosit (cele folosite se dezactiveaza, ca istoricul sa ramana).
  Future<bool> deleteLossDetail(int id) async {
    if (await lossUsage(id) > 0) return false;
    await _db.delete('loss_code', where: 'id = ?', whereArgs: [id]);
    await _logLoss('$id:del');
    return true;
  }

  /// Opririle planificate intra ca pierdere in Disponibilitate (implicit da); cele neprogramate nu intra niciodata.
  bool plannedInAvail = true;
  Future<void> setPlannedInAvail(bool v) async {
    await _db.insert('setting', {'key': 'planned_in_avail', 'value': v ? '1' : '0'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    plannedInAvail = v;
    await _logLoss('planned_in_avail=${v ? 1 : 0}');
  }

  Future<void> saveCause(String device, int boot, int seq, int code1, int? code2, String? comment) async {
    await _db.insert(
        'cause',
        {
          'device': device, 'boot': boot, 'seq': seq, 'code1': code1, 'code2': code2,
          'comment': comment, 'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
          'uuid': newUuid(), 'user_uuid': currentUser?.uuid,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Toate opririle de clasificat de pe un canal (fara limita), de la cele mai noi la cele mai vechi.
  Future<List<Map<String, Object?>>> allPendingStops(int ch) => _db.rawQuery('''
      SELECT m.* FROM message m
      LEFT JOIN cause c ON c.device = m.device AND c.boot = m.boot AND c.seq = m.seq
      WHERE m.type = 'ev' AND m.st = 'stop' AND m.ch = ? AND c.seq IS NULL
      ORDER BY m.boot DESC, m.seq DESC''', [ch]);

  /// Clasifica in masa opririle date cu acelasi motiv (o singura tranzactie) si scrie o linie de audit.
  Future<int> saveCauseBulk(List<Map<String, Object?>> rows, int code1, int? code2, String? comment) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final user = currentUser?.uuid;
    await _db.transaction((txn) async {
      final b = txn.batch();
      for (final r in rows) {
        b.insert(
            'cause',
            {
              'device': r['device'], 'boot': r['boot'], 'seq': r['seq'], 'code1': code1, 'code2': code2,
              'comment': comment, 'created_at': now, 'uuid': newUuid(), 'user_uuid': user,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await b.commit(noResult: true);
    });
    await _audit('cause_bulk', 'cause', jsonEncode({'n': rows.length, 'code1': code1, 'code2': code2}));
    return rows.length;
  }


  // ----- canale (Administrare) -----
  /// Opriri de clasificat: pe un canal ([ch]) sau pe toate canalele active (ch null) — pentru insigna din bara de navigare.
  Future<int> pendingCount({int? ch}) async {
    final r = await _db.rawQuery('''
        SELECT COUNT(*) AS n FROM message m
        LEFT JOIN cause c ON c.device = m.device AND c.boot = m.boot AND c.seq = m.seq
        WHERE m.type = 'ev' AND m.st = 'stop' AND c.seq IS NULL
          AND ${ch == null ? 'm.ch IN (SELECT id FROM channel WHERE active = 1)' : 'm.ch = ?'}''',
        ch == null ? [] : [ch]);
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Canalele configurate; cu [stats] si numarul de mesaje / ultimul moment pe canal (scanare completa: doar in ecranul de administrare).
  Future<List<ChannelRow>> channels({bool stats = true}) async {
    final rows = await _db.query('channel', orderBy: 'id');
    final st = stats
        ? await _db.rawQuery('SELECT ch, COUNT(*) AS n, MAX(COALESCE(ts, to_ts)) AS last FROM message GROUP BY ch')
        : const <Map<String, Object?>>[];
    final stats0 = {for (final r in st) (r['ch'] as num).toInt(): r};
    return rows.map((r) {
      final id = (r['id'] as num).toInt();
      return ChannelRow(
        id: id,
        name: '${r['name']}',
        active: (r['active'] as num?) == 1,
        role: '${r['role']}',
        rateBph: (r['rate_override'] as num?)?.toDouble(),
        triggerS: (r['trigger_override'] as num?)?.toDouble(),
        msgs: (stats0[id]?['n'] as num?)?.toInt() ?? 0,
        last: stats0[id]?['last'] as String?,
      );
    }).toList();
  }

  /// Salveaza numele, activarea (afisarea), rolul si ritmul nominal propriu al canalului (buc/h; null = din produsul liniei).
  Future<void> saveChannel(ChannelRow c) async {
    await _db.update(
        'channel',
        {
          'name': c.name,
          'active': c.active ? 1 : 0,
          'role': c.role,
          'rate_override': c.rateBph,
          'trigger_override': c.triggerS,
        },
        where: 'id = ?',
        whereArgs: [c.id]);
    await _db.insert('audit_log', {
      'ts': DateTime.now().toUtc().millisecondsSinceEpoch,
      'user_uuid': currentUser?.uuid,
      'action': 'channel_edit',
      'entity': 'channel',
      'detail': jsonEncode({
        'ch': c.id, 'name': c.name, 'active': c.active, 'role': c.role, 'rate_bph': c.rateBph, 'trigger_s': c.triggerS,
      }),
    });
  }

  // ----- program de lucru (schimburi) -----
  ShiftSchedule shifts = ShiftSchedule.initial();

  Future<void> saveShifts(ShiftSchedule s) async {
    final js = s.toJsonString();
    await _db.insert('setting', {'key': 'shift_plan', 'value': js}, conflictAlgorithm: ConflictAlgorithm.replace);
    await _db.insert('audit_log', {
      'ts': DateTime.now().toUtc().millisecondsSinceEpoch,
      'user_uuid': currentUser?.uuid,
      'action': 'shift_plan_edit',
      'entity': 'shift_plan',
      'detail': js,
    });
    shifts = s;
  }

  // ----- permisiuni si utilizatori -----
  /// Cat timp autentificarea e oprita (implicit), orice cheie e permisa. Dupa activare: doar cheile utilizatorului curent.
  bool authEnabled = false;
  Set<String> userPerms = {};
  AppUser? currentUser;
  int autoLockMin = 0; // 0 = fara deconectare automata
  final ValueNotifier<int> authTick = ValueNotifier<int>(0);
  bool can(String key) => !authEnabled || userPerms.contains(key);

  static String _newSalt([int n = 16]) {
    final r = Random.secure();
    return List.generate(n, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String _hashPin(String salt, String pin) {
    List<int> h = utf8.encode('$salt:$pin');
    for (var i = 0; i < 3000; i++) {
      h = sha256Bytes(h);
    }
    return sha256Hex(h);
  }

  Future<void> _audit(String action, String entity, String detail, {String? entityUuid, String? user}) =>
      _db.insert('audit_log', {
        'ts': DateTime.now().toUtc().millisecondsSinceEpoch,
        'user_uuid': user ?? currentUser?.uuid,
        'action': action,
        'entity': entity,
        'entity_uuid': entityUuid,
        'detail': detail,
      });

  AppUser _userOf(Map<String, Object?> r) => AppUser(
      (r['id'] as num).toInt(), '${r['uuid']}', '${r['name']}', '${r['role']}', (r['active'] as num?) != 0);

  /// [loginable] = doar utilizatorii activi cu PIN (cei care pot intra).
  Future<List<AppUser>> users({bool loginable = false}) async {
    final rows = await _db.query('app_user',
        where: loginable ? 'active = 1 AND pin_hash IS NOT NULL' : null, orderBy: 'name COLLATE NOCASE');
    return rows.map(_userOf).toList();
  }

  Future<int> _activeAdmins({int? excluding}) async =>
      Sqflite.firstIntValue(await _db.rawQuery(
          "SELECT COUNT(*) FROM app_user WHERE role = 'admin' AND active = 1 AND pin_hash IS NOT NULL AND id <> ?",
          [excluding ?? -1])) ??
      0;

  Future<int> activeAdminCount() => _activeAdmins();

  /// Adauga (id null) sau modifica un utilizator. Intoarce cheia mesajului de eroare sau null daca a reusit.
  /// [pin] null = PIN neschimbat (la utilizator nou e obligatoriu).
  Future<String?> saveUser({int? id, required String name, required String role, String? pin, bool active = true}) async {
    final n = name.trim();
    if (n.isEmpty) return 'usr.errName';
    if (!Perm.roles.contains(role)) return 'usr.errRole';
    if (pin != null && !RegExp(r'^\d{4,8}$').hasMatch(pin)) return 'usr.errPin';
    if (id == null && pin == null) return 'usr.errPin';
    final dup = await _db.query('app_user',
        where: 'LOWER(name) = ? AND id <> ?', whereArgs: [n.toLowerCase(), id ?? -1]);
    if (dup.isNotEmpty) return 'usr.errDup';
    if (id != null) {
      final cur = await _db.query('app_user', where: 'id = ?', whereArgs: [id]);
      if (cur.isNotEmpty) {
        final wasAdmin = cur.first['role'] == 'admin' && (cur.first['active'] as num?) != 0;
        if (wasAdmin && (role != 'admin' || !active) && await _activeAdmins(excluding: id) == 0) {
          return 'usr.errLastAdmin';
        }
      }
    }
    final vals = <String, Object?>{'name': n, 'role': role, 'active': active ? 1 : 0};
    if (pin != null) {
      final salt = _newSalt();
      vals['pin_salt'] = salt;
      vals['pin_hash'] = _hashPin(salt, pin);
    }
    String uuid;
    if (id == null) {
      uuid = newUuid();
      await _db.insert('app_user', {
        ...vals,
        'uuid': uuid,
        'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
    } else {
      await _db.update('app_user', vals, where: 'id = ?', whereArgs: [id]);
      uuid = '${(await _db.query('app_user', where: 'id = ?', whereArgs: [id])).first['uuid']}';
    }
    await _audit('user_edit', 'app_user',
        jsonEncode({'name': n, 'role': role, 'active': active, 'pin_changed': pin != null, 'new': id == null}),
        entityUuid: uuid);
    return null;
  }

  int _fails = 0;
  DateTime? _lockUntil;

  /// Intoarce null la succes, 'bad' (PIN gresit) sau 'locked:N' (blocat N secunde dupa 5 greseli).
  Future<String?> login(int userId, String pin) async {
    final now = DateTime.now();
    if (_lockUntil != null && now.isBefore(_lockUntil!)) {
      return 'locked:${_lockUntil!.difference(now).inSeconds + 1}';
    }
    final rows = await _db.query('app_user', where: 'id = ? AND active = 1', whereArgs: [userId]);
    if (rows.isEmpty) return 'bad';
    final r = rows.first;
    final ok = r['pin_hash'] != null && _hashPin('${r['pin_salt']}', pin) == r['pin_hash'];
    if (!ok) {
      await _audit('login_fail', 'app_user', jsonEncode({'name': r['name']}), entityUuid: '${r['uuid']}', user: '');
      _fails++;
      if (_fails >= 5) {
        _fails = 0;
        _lockUntil = now.add(const Duration(seconds: 30));
        return 'locked:30';
      }
      return 'bad';
    }
    _fails = 0;
    currentUser = _userOf(r);
    userPerms = Perm.forRole(currentUser!.role);
    await _audit('login', 'app_user', jsonEncode({'name': currentUser!.name}), entityUuid: currentUser!.uuid);
    authTick.value++;
    return null;
  }

  Future<void> logout() async {
    final u = currentUser;
    if (u != null) await _audit('logout', 'app_user', jsonEncode({'name': u.name}), entityUuid: u.uuid);
    currentUser = null;
    userPerms = {};
    authTick.value++;
  }

  /// Pasul 1 la pornirea autentificarii: necesita un administrator activ cu PIN; genereaza si retine (hash) codul de
  /// recuperare de 8 cifre si il intoarce ca sa fie afisat o singura data. Null = nu exista administrator.
  Future<String?> prepareAuth() async {
    if (await _activeAdmins() == 0) return null;
    final code = (10000000 + Random.secure().nextInt(90000000)).toString();
    final salt = _newSalt();
    await setSetting('recovery_salt', salt);
    await setSetting('recovery_hash', _hashPin(salt, code));
    return code;
  }

  /// Pasul 2: porneste autentificarea (utilizatorul curent se deconecteaza, apare ecranul de PIN).
  Future<void> commitAuth() async {
    await _audit('auth_enable', 'setting', 'on');
    await setAuthEnabled(true);
  }

  Future<void> disableAuth() async {
    await _audit('auth_disable', 'setting', 'off');
    await setAuthEnabled(false);
  }

  /// Cu codul de recuperare (cand se uita PIN-ul administratorului) autentificarea se opreste.
  Future<bool> recoverDisableAuth(String code) async {
    final salt = await getSetting('recovery_salt');
    final hash = await getSetting('recovery_hash');
    if (salt == null || hash == null || _hashPin(salt, code.trim()) != hash) {
      await _audit('recovery_fail', 'setting', '', user: '');
      return false;
    }
    await _audit('recovery_used', 'setting', 'auth off', user: '');
    await setAuthEnabled(false);
    return true;
  }

  Future<void> setAutoLock(int minutes) async {
    await setSetting('auto_lock_min', '$minutes');
    autoLockMin = minutes;
    authTick.value++;
  }

  Future<String?> getSetting(String key) async {
    final r = await _db.query('setting', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) =>
      _db.insert('setting', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> setAuthEnabled(bool v) async {
    await _db.insert('setting', {'key': 'auth_enabled', 'value': v ? '1' : '0'}, conflictAlgorithm: ConflictAlgorithm.replace);
    authEnabled = v;
    currentUser = null;
    userPerms = {};
    authTick.value++;
  }

  Future<void> setMainChannel(int ch) async {
    await _db.insert('setting', {'key': 'main_channel', 'value': '$ch'}, conflictAlgorithm: ConflictAlgorithm.replace);
    mainCh = ch;
  }

  // ----- diagnostic (Colector) -----
  /// Pe fiecare boot: primul / ultimul seq salvat, cate mesaje, goluri reale (doar intre seq-urile salvate), prima / ultima primire.
  Future<List<Map<String, Object?>>> bootStats({int limit = 12}) => _db.rawQuery('''
      SELECT device, boot, MIN(seq) AS first_seq, MAX(seq) AS last_seq, COUNT(*) AS cnt,
             MAX(seq) - MIN(seq) + 1 - COUNT(*) AS gaps,
             MIN(received_at) AS first_rx, MAX(received_at) AS last_rx
      FROM message GROUP BY device, boot ORDER BY boot DESC LIMIT ?''', [limit]);

  /// Ultimele evenimente (stop / micro / slow / fast) cu interval, de la cele mai noi.
  Future<List<Map<String, Object?>>> recentEvents({int limit = 30}) => _db.rawQuery(
      "SELECT boot, seq, st, from_ts, to_ts, dur_ms, ch FROM message WHERE type = 'ev' "
      'ORDER BY boot DESC, seq DESC LIMIT ?',
      [limit]);

  /// Istoricul scrierilor de parametri pe ESP32 (in audit_log, action = config_write).
  Future<void> logConfigWrite(Map<String, Object?> detail) async {
    await _db.insert('audit_log', {
      'ts': DateTime.now().toUtc().millisecondsSinceEpoch,
      'user_uuid': currentUser?.uuid,
      'action': 'config_write',
      'entity': 'device',
      'detail': jsonEncode(detail),
    });
  }

  Future<List<Map<String, Object?>>> configHistory({int limit = 15}) => _db.rawQuery(
      "SELECT ts, detail FROM audit_log WHERE action = 'config_write' ORDER BY id DESC LIMIT ?", [limit]);

  // ----- ecranul "Linia" -----
  /// Evenimente (stop / micro / slow / fast) cu interval cunoscut, care se termina dupa [fromIso] (UTC, fara milisecunde).
  Future<List<Map<String, Object?>>> eventsSince(String fromIso) => _db.rawQuery('''
      SELECT st, from_ts, to_ts, dur_ms FROM message
      WHERE type = 'ev' AND ch = ? AND from_ts IS NOT NULL AND to_ts IS NOT NULL AND to_ts >= ?
      ORDER BY to_ts''', [viewCh, fromIso]);

  /// Evenimente cu cauza (daca a fost clasificata), care se suprapun cu intervalul [fromIso, toIso].
  Future<List<Map<String, Object?>>> eventsDetailed(String fromIso, String toIso) => _db.rawQuery('''
      SELECT m.st AS st, m.from_ts AS from_ts, m.to_ts AS to_ts, m.dur_ms AS dur_ms,
             l1.name AS c1, l1.kind AS k1, l2.name AS c2, c.comment AS comment
      FROM message m
      LEFT JOIN cause c ON c.device = m.device AND c.boot = m.boot AND c.seq = m.seq
      LEFT JOIN loss_code l1 ON l1.id = c.code1
      LEFT JOIN loss_code l2 ON l2.id = c.code2
      WHERE m.type = 'ev' AND m.ch = ? AND m.from_ts IS NOT NULL AND m.to_ts IS NOT NULL
        AND m.to_ts >= ? AND m.from_ts <= ?
      ORDER BY m.from_ts''', [viewCh, fromIso, toIso]);

  /// Impulsuri numarate in [fromIso, toIso) si timpul ideal corespunzator (impulsuri x timp de ciclu al produsului run-ului).
  /// "unknown" = impulsuri al caror run nu are produs local (reinstalare etc.).
  /// [fallbackCycleS]: timp de ciclu folosit pentru impulsurile al caror run nu exista local (ex. dupa reinstalare); 0 = fara.
  Future<Map<String, Object?>> pulseTotals(String fromIso, String toIso, [double fallbackCycleS = 0]) async {
    final r = await _db.rawQuery('''
      SELECT COALESCE(SUM(m.n), 0) AS pulses,
             COALESCE(SUM(m.n * COALESCE(
               3600.0 / NULLIF(sc.rate_bph, 0),
               CASE WHEN s.id IS NOT NULL THEN (CASE WHEN s.mode = 'pace' THEN 3600.0 / s.value ELSE s.value END) END, ?)), 0) AS ideal_s,
             COALESCE(SUM(CASE WHEN s.id IS NULL AND ? = 0 THEN m.n ELSE 0 END), 0) AS unknown
      FROM message m
      LEFT JOIN run r ON r.run_no = m.run
      LEFT JOIN sku s ON s.id = r.sku_id
      LEFT JOIN sku_channel sc ON sc.sku_id = s.id AND sc.ch = m.ch
      WHERE m.type = 'int' AND m.ch = ? AND m.ts >= ? AND m.ts < ?''', [fallbackCycleS, fallbackCycleS, viewCh, fromIso, toIso]);
    return r.first;
  }

  /// Mesajele "int" (impulsuri pe interval) de la [fromIso] incoace, pentru graficul de viteza.
  Future<List<Map<String, Object?>>> intervalsSince(String fromIso) => _db.rawQuery(
      "SELECT ts, n, run FROM message WHERE type = 'int' AND ch = ? AND ts >= ? ORDER BY ts", [viewCh, fromIso]);

  /// Ritmul nominal (buc/h) al fiecarui run, dupa produsul lui: pentru tinta din graficul istoric.
  Future<Map<int, double>> runPaces() async {
    final rows = await _db.rawQuery('''
        SELECT r.run_no AS run_no, s.mode AS mode, s.value AS value, sc.rate_bph AS ch_rate
        FROM run r JOIN sku s ON s.id = r.sku_id
        LEFT JOIN sku_channel sc ON sc.sku_id = s.id AND sc.ch = ?''', [viewCh]);
    final out = <int, double>{};
    for (final r in rows) {
      final cr = (r['ch_rate'] as num?)?.toDouble() ?? 0;
      if (cr > 0) {
        out[(r['run_no'] as num).toInt()] = cr;
        continue;
      }
      final v = (r['value'] as num?)?.toDouble() ?? 0;
      if (v <= 0) continue;
      out[(r['run_no'] as num).toInt()] = r['mode'] == 'pace' ? v : 3600 / v;
    }
    return out;
  }

  /// Repornirile ESP32 din interval, cu ultimul moment cunoscut din boot-ul precedent (golul dintre ele = ESP32 oprit).
  /// Daca mesajul boot nu are ora, momentul repornirii se deduce din primul mesaj al aceluiasi boot care are ora (ts - up);
  /// doar daca nu exista niciunul se foloseste momentul primirii pe tableta.
  Future<List<Map<String, Object?>>> bootGaps(String fromIso, String toIso, int fromMs, int toMs) => _db.rawQuery('''
      SELECT b.ts AS boot_ts, b.received_at AS received_at,
             (SELECT p.ts FROM message p WHERE p.device = b.device AND p.boot = b.boot
               AND p.ts IS NOT NULL ORDER BY p.seq LIMIT 1) AS first_ts,
             (SELECT p.up_ms FROM message p WHERE p.device = b.device AND p.boot = b.boot
               AND p.ts IS NOT NULL ORDER BY p.seq LIMIT 1) AS first_up_ms,
             (SELECT MAX(COALESCE(p.ts, p.to_ts)) FROM message p
               WHERE p.device = b.device AND p.boot = b.boot - 1) AS prev_last
      FROM message b
      WHERE b.type = 'boot' ''');
  // Fara filtru pe timp: repornirile sunt putine, iar suprapunerea cu fereastra se calculeaza in Dart;
  // astfel o repornire fara ora, primita mai tarziu, nu mai e pierduta.

  /// Primul si ultimul moment cu date (int / ev) ale unui canal; null daca canalul nu are date.
  Future<(String, String)?> channelSpan(int ch) async {
    final r = await _db.rawQuery('''
      SELECT MIN(COALESCE(ts, from_ts)) AS a, MAX(COALESCE(ts, to_ts)) AS b FROM message
      WHERE ch = ? AND type != 'boot' AND COALESCE(ts, from_ts) IS NOT NULL''', [ch]);
    if (r.isEmpty || r.first['a'] == null || r.first['b'] == null) return null;
    return ('${r.first['a']}', '${r.first['b']}');
  }

  /// Primul moment cunoscut din date (de aici incolo putem spune ca linia a rulat).
  Future<String?> firstTs() async {
    final r = await _db.rawQuery('''
      SELECT MIN(COALESCE(ts, to_ts)) AS t FROM message WHERE COALESCE(ts, to_ts) IS NOT NULL''');
    return r.isEmpty ? null : r.first['t'] as String?;
  }

  /// Opririle clasificate in perioada, pe categoria principala: numar si durata totala.
  Future<List<Map<String, Object?>>> causeTotals(String fromIso) => _db.rawQuery('''
      SELECT l.name AS name, COUNT(*) AS n, SUM(m.dur_ms) AS ms
      FROM cause c
      JOIN message m ON m.device = c.device AND m.boot = c.boot AND m.seq = c.seq
      JOIN loss_code l ON l.id = c.code1
      WHERE m.to_ts >= ?
      GROUP BY l.id ORDER BY ms DESC LIMIT 5''', [fromIso]);

  /// Unde sunt golurile: cate o linie pe interval lipsa, ex. "boot 17: lipsesc seq 12–15".
  Future<List<String>> seqGapDetails() async {
    final rows = await _db.rawQuery('SELECT device, boot, seq FROM message ORDER BY device, boot, seq');
    final out = <String>[];
    String? dev;
    int? boot;
    var prev = 0;
    for (final r in rows) {
      final d = r['device'] as String;
      final b = r['boot'] as int;
      final s = r['seq'] as int;
      if (d != dev || b != boot) {
        dev = d;
        boot = b;
        prev = s - 1; // ce a fost inainte de primul mesaj stocat (ex. reinstalare) nu e gol
      }
      if (s > prev + 1) {
        final a = prev + 1, z = s - 1;
        out.add(a == z ? 'boot $b: lipseste seq $a' : 'boot $b: lipsesc seq $a–$z');
      }
      prev = s;
    }
    return out;
  }

  /// Cel mai mare seq salvat pentru un boot (0 daca boot-ul nu exista inca).
  Future<int> maxSeq(String device, int boot) async =>
      Sqflite.firstIntValue(await _db.rawQuery(
          'SELECT MAX(seq) FROM message WHERE device = ? AND boot = ?', [device, boot])) ??
      0;

  /// Seq-urile salvate dupa [seq] pentru un boot, crescator (pentru avansarea peste goluri umplute).
  Future<List<int>> seqsAfter(String device, int boot, int seq, {int limit = 500}) async {
    final rows = await _db.rawQuery(
        'SELECT seq FROM message WHERE device = ? AND boot = ? AND seq > ? ORDER BY seq LIMIT ?',
        [device, boot, seq, limit]);
    return [for (final r in rows) r['seq'] as int];
  }

  /// Goluri in numerotarea mesajelor: pentru fiecare boot, cel mai mare seq minus cate mesaje avem (seq incepe de la 1).
  Future<int> seqGaps() async =>
      Sqflite.firstIntValue(await _db.rawQuery('''
        SELECT COALESCE(SUM(mx - mn + 1 - cnt), 0) FROM (
          SELECT MAX(seq) AS mx, MIN(seq) AS mn, COUNT(*) AS cnt FROM message GROUP BY device, boot
        )''')) ??
      0;
}
