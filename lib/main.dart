import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'admin_page.dart';
import 'ble_service.dart';
import 'control.dart';
import 'db.dart';
import 'i18n.dart';
import 'line_page.dart';
import 'login_page.dart';
import 'perm.dart';
import 'protocol.dart';
import 'sku_page.dart';
import 'stops_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'oee_ble',
      channelName: 'OEE — conexiune dispozitiv',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false, // pornirea automata dupa reboot se adauga dupa testul de rezistenta
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  final db = await Db.open();
  await i18n.load(db);
  final ble = BleService(db);
  await ble.refresh();
  runApp(OeeApp(ble));
}

class OeeApp extends StatelessWidget {
  const OeeApp(this.ble, {super.key});
  final BleService ble;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: i18n,
        builder: (context, _) => MaterialApp(
          title: 'OEE',
          theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
          home: WithForegroundTask(child: Gate(ble)),
        ),
      );
}

/// Poarta aplicatiei: cu autentificarea activa si fara utilizator conectat arata ecranul de PIN, altfel aplicatia.
/// Deconectare automata dupa inactivitate (setarea din Utilizatori).
class Gate extends StatefulWidget {
  const Gate(this.ble, {super.key});
  final BleService ble;
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  Timer? _idle;

  Db get _db => widget.ble.db;

  @override
  void initState() {
    super.initState();
    _db.authTick.addListener(_onAuth);
  }

  @override
  void dispose() {
    _db.authTick.removeListener(_onAuth);
    _idle?.cancel();
    super.dispose();
  }

  void _onAuth() {
    if (_db.authEnabled && _db.currentUser == null && mounted) {
      // inchide ecranele deschise (Administrare etc.) cand cineva s-a deconectat
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
    _touch();
  }

  void _touch() {
    _idle?.cancel();
    if (_db.authEnabled && _db.currentUser != null && _db.autoLockMin > 0) {
      _idle = Timer(Duration(minutes: _db.autoLockMin), () => _db.logout());
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: _db.authTick,
        builder: (context, _, __) {
          final locked = _db.authEnabled && _db.currentUser == null;
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _touch(),
            child: locked ? LoginPage(_db) : Shell(widget.ble),
          );
        },
      );
}

class Shell extends StatefulWidget {
  const Shell(this.ble, {super.key});
  final BleService ble;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  void _onTabRequest() {
    final t = widget.ble.tabRequest.value;
    if (t == null) return;
    widget.ble.tabRequest.value = null;
    if (mounted) setState(() => _tab = t);
  }

  @override
  void initState() {
    super.initState();
    widget.ble.tabRequest.addListener(_onTabRequest);
  }

  @override
  void dispose() {
    widget.ble.tabRequest.removeListener(_onTabRequest);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    final pages = [LinePage(ble), StopsPage(ble), SkuPage(ble), CollectorPage(ble), AdminPage(ble)];
    final showAdmin = ble.db.can(Perm.adminChannels) || ble.db.can(Perm.adminShifts) ||
        ble.db.can(Perm.adminUsers) || ble.db.can(Perm.adminLanguages) || ble.db.can(Perm.adminExport) ||
        ble.db.can(Perm.adminLossCodes);
    if (!showAdmin && _tab == 4) _tab = 0;
    final wide = MediaQuery.of(context).size.width >= 720; // tableta: bara laterala in loc de bara de jos
    if (wide) {
      return Scaffold(
        body: SafeArea(
          child: Row(children: [
            ListenableBuilder(
              listenable: ble,
              builder: (context, _) => NavigationRail(
                selectedIndex: _tab,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: [
                  NavigationRailDestination(
                      icon: const Icon(Icons.dashboard_outlined), label: Text(tr('nav.line'))),
                  NavigationRailDestination(
                    icon: Badge(
                      isLabelVisible: ble.pendingStopCount > 0,
                      label: Text('${ble.pendingStopCount}'),
                      child: const Icon(Icons.report_problem_outlined),
                    ),
                    label: Text(tr('nav.stops')),
                  ),
                  NavigationRailDestination(
                      icon: const Icon(Icons.inventory_2_outlined), label: Text(tr('nav.products'))),
                  NavigationRailDestination(icon: const Icon(Icons.bluetooth), label: Text(tr('nav.collector'))),
                  if (showAdmin)
                    NavigationRailDestination(
                        icon: const Icon(Icons.admin_panel_settings_outlined), label: Text(tr('admin.title'))),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: pages[_tab]),
          ]),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(child: pages[_tab]),
      bottomNavigationBar: ListenableBuilder(
        listenable: ble,
        builder: (context, _) => NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            NavigationDestination(icon: const Icon(Icons.dashboard_outlined), label: tr('nav.line')),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: ble.pendingStopCount > 0,
                label: Text('${ble.pendingStopCount}'),
                child: const Icon(Icons.report_problem_outlined),
              ),
              label: tr('nav.stops'),
            ),
            NavigationDestination(icon: const Icon(Icons.inventory_2_outlined), label: tr('nav.products')),
            NavigationDestination(icon: const Icon(Icons.bluetooth), label: tr('nav.collector')),
            if (showAdmin)
              NavigationDestination(icon: const Icon(Icons.admin_panel_settings_outlined), label: tr('nav.admin')),
          ],
        ),
      ),
    );
  }
}

class CollectorPage extends StatelessWidget {
  const CollectorPage(this.ble, {super.key});
  final BleService ble;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ble,
        builder: (context, _) {
          final s = ble.status;
          final run = ble.activeRun;
          final stopped = ble.connected && s != null && s.state == 2;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('Stare: ${ble.state}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton(
                  onPressed: ble.running ? null : () => startCollector(ble),
                  child: const Text('Pornește')),
              OutlinedButton(
                  onPressed: ble.running ? () => stopCollector(ble) : null,
                  child: const Text('Oprește')),
            ]),
            if (stopped)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.stop_circle_outlined),
                  title: Text('LINIA E OPRITĂ de ${(s.sinceLastMs / 1000).round()} s'),
                ),
              ),
            if (ble.db.can(Perm.adminCollector)) ...[
            const Divider(height: 32),
            const SizedBox(height: 8),
            _kv('Produs activ', run == null ? 'niciunul (alege în Produse)' : run.sku.name),
            if (ble.configInfo != null)
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(ble.configInfo!)),
            FutureBuilder<String>(
              future: ble.db.configSummary(),
              builder: (context, snap) => _kv('Baza de date', snap.data ?? '…'),
            ),
            if (Db.migrationNote != null) _kv('Ultima migrare', Db.migrationNote!),
            _kv('Stocate pe tabletă', '${ble.stored}'),
            _kv('Primite în sesiune', '${ble.received}'),
            _kv('Goluri în seq (mesaje lipsă)', '${ble.gaps}'),
            for (final g in ble.gapDetails.take(10))
              Text(g, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            _kv('Scanari / ultima scanare', '${ble.scans} · ${ble.lastScan}'),
            _kv('Retransmiteri cerute / goluri acceptate', '${ble.resubs} / ${ble.gapsAccepted}'),
            _kv('MTU (minim 200)', ble.mtu == 0 ? 'necunoscut' : '${ble.mtu}'),
            _kv('Abonat la Data', ble.dataSubscribed ? 'da' : 'nu'),
            _kv('Notificări Data brute', '${ble.notifRaw}'),
            if (s != null) ...[
              _kv('Ack primit de ESP32 (boot / seq)', '${s.ackBoot} / ${s.ackSeq}'),
              _kv('Firmware', s.fw),
              _kv('Starea liniei', stateLabel(s.state)),
              _kv('Ora dispozitivului (UTC)',
                  s.utcS == 0 ? 'nesetată' : DateTime.fromMillisecondsSinceEpoch(s.utcS * 1000, isUtc: true).toIso8601String()),
              _kv('Boot / ultimul seq', '${s.boot} / ${s.lastSeq}'),
              _kv('Impulsuri (în acest boot)', '${s.cum}'),
              _kv('Nivel intrare', s.level == 0 ? 'jos (activ)' : 'sus'),
              _kv('Pierdute în ESP32 (dropped)', '${s.dropped}'),
              _kv('Respinse de filtre', '${s.rejected}'),
              _kv('Fronturi pierdute (ISR)', '${s.edgesLost}'),
              _kv('Flash liber', '${s.fsFreeKb} KB'),
            ],
            if (ble.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Ultima eroare: ${ble.lastError}', style: const TextStyle(color: Colors.red)),
              ),
            const Divider(height: 32),
            Text('Diagnostic', style: Theme.of(context).textTheme.titleSmall),
            _DiagTile('Pe boot (goluri reale)', () async {
              final rows = await ble.db.bootStats();
              return [
                for (final r in rows)
                  'boot ${r['boot']}: seq ${r['first_seq']}–${r['last_seq']} · ${r['cnt']} mesaje · '
                      '${(r['gaps'] as int) == 0 ? 'fără goluri' : '${r['gaps']} lipsă'} · '
                      '${_hm(r['first_rx'] as int?)}–${_hm(r['last_rx'] as int?)}',
              ];
            }),
            _DiagTile('Ultimele evenimente', () async {
              final rows = await ble.db.recentEvents();
              return [
                for (final r in rows)
                  '${r['st']} · ${_ts(r['from_ts'])} → ${_ts(r['to_ts'])} · '
                      '${((r['dur_ms'] as int?) ?? 0) / 1000} s · b${r['boot']}#${r['seq']}'
                      '${(r['ch'] as int?) != null && r['ch'] != 1 ? ' · canal ${r['ch']}' : ''}',
              ];
            }),
            _DiagTile('Scrieri de parametri', () async {
              final rows = await ble.db.configHistory();
              final out = <String>[];
              for (final r in rows) {
                final ms = r['ts'] as int;
                Map<String, dynamic> j = {};
                try {
                  j = jsonDecode('${r['detail']}') as Map<String, dynamic>;
                } catch (_) {}
                out.add('${_hm(ms)} · ${j['sku']} · ciclu ${(j['cycle_s'] as num?)?.toStringAsFixed(4)} s · '
                    'T ${(j['trigger_s'] as num?)?.toStringAsFixed(1)} s · run ${j['run']} · ${j['result']}');
              }
              return out;
            }),
            _DiagTile('Erori GATT (ultimele 20)', () async => List<String>.from(ble.gattLog)),
            const Divider(height: 32),
            Text('Ultimele mesaje', style: Theme.of(context).textTheme.titleSmall),
            for (final r in ble.latest)
              Text(_line(r), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
          ]);
        },
      );

  String _line(Map<String, Object?> r) {
    final t = r['type'];
    final id = 'b${r['boot']} #${r['seq']}';
    if (t == 'int') return '$id int  n=${r['n']}  ${r['kind']}';
    if (t == 'ev') return '$id ev   ${r['st']}  ${(r['dur_ms'] as int) / 1000} s';
    return '$id $t';
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(k)),
          Flexible(child: Text(v, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.bold))),
        ]),
      );
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Ora locala din milisecunde UTC (HH:MM:SS).
String _hm(int? ms) {
  if (ms == null) return '—';
  final t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
  return '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

/// Ora locala dintr-un timestamp ISO (UTC).
String _ts(Object? iso) {
  final t = DateTime.tryParse('$iso');
  if (t == null) return '—';
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

/// Sectiune de diagnostic: se incarca la deschidere, se poate reimprospata.
class _DiagTile extends StatefulWidget {
  const _DiagTile(this.title, this.load);
  final String title;
  final Future<List<String>> Function() load;
  @override
  State<_DiagTile> createState() => _DiagTileState();
}

class _DiagTileState extends State<_DiagTile> {
  List<String>? _lines;
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    List<String> l;
    try {
      l = await widget.load();
    } catch (e) {
      l = ['eroare: $e'];
    }
    if (mounted) {
      setState(() {
        _lines = l;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
        title: Text(widget.title),
        tilePadding: EdgeInsets.zero,
        onExpansionChanged: (open) {
          if (open) _run();
        },
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _busy ? null : _run,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Reîmprospătează'),
            ),
          ),
          if (_lines == null)
            const Padding(padding: EdgeInsets.all(8), child: Text('…'))
          else if (_lines!.isEmpty)
            const Padding(padding: EdgeInsets.all(8), child: Text('nimic de afișat'))
          else
            for (final s in _lines!)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(s, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ),
              ),
        ],
      );
}
