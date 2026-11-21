// Client BLE: scaneaza dupa serviciul OEE, se conecteaza, seteaza ora ESP32, scrie parametrii run-ului activ,
// se aboneaza la Data/Status, salveaza mesajele JSON in SQLite si DOAR APOI confirma (ack cumulativ).
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'db.dart';
import 'protocol.dart';

class BleService extends ChangeNotifier {
  BleService(this.db);
  final Db db;

  bool running = false;
  bool connected = false;
  String state = 'oprit';
  String? deviceName;
  DeviceStatus? status;
  ActiveRun? activeRun;
  String? configInfo; // rezultatul ultimei scrieri de parametri
  int stored = 0;
  int unsynced = 0;
  int received = 0;
  int gaps = 0; // goluri in seq (mesaje lipsa) in toata baza locala
  List<String> gapDetails = const []; // unde sunt golurile (boot si interval de seq)
  int mtu = 0; // MTU negociat (firmware-ul nu trimite date sub 200)
  bool dataSubscribed = false; // abonat la notificarile Data
  int notifRaw = 0; // notificari Data brute primite in conexiunea curenta (inainte de parsare)
  String? lastError;
  List<Map<String, Object?>> latest = const [];
  int pendingStopCount = 0; // opriri de clasificat pe toate canalele active (insigna din bara de navigare)
  List<ChannelRow> channelList = const []; // canalele configurate (fara statistici)

  int scans = 0; // scanari pornite de la Pornește
  String lastScan = '-'; // rezultatul ultimei scanari (ora si ce s-a gasit)
  int resubs = 0; // cate retransmiteri a cerut aplicatia (reabonare la Data) din cauza golurilor
  int gapsAccepted = 0; // goluri acceptate dupa 3 incercari (pierdute la sursa)

  // urmarirea continuitatii seq (doar in conexiunea curenta)
  final Map<int, int> _contig = {}; // boot -> cel mai mare seq contiguu primit
  int _ackB0 = 0; // ack-ul ESP32 (boot) la conectare
  int _lastAckB = -1, _lastAckS = -1;
  int _stallB = -1, _stallS = -1, _stallRounds = 0;
  DateTime _lastResub = DateTime.fromMillisecondsSinceEpoch(0);

  BluetoothCharacteristic? _cfgChar;

  /// true cat timp parametrii run-ului activ NU sunt confirmati pe ESP32 (scriere esuata, respinsa sau neinceputa).
  bool paramsPending = false;
  bool _cfgBusy = false, _cfgAgain = false;
  int _cfgRetries = 0;
  Timer? _cfgTimer;

  // Coada seriala pentru TOATE operatiunile GATT (read / write / setNotify): Android accepta o singura operatiune
  // in zbor; suprapunerea lor da GATT_INSUFFICIENT_RESOURCES (17) sau GATT_ERROR (133).
  Future<void> _gattTail = Future.value();

  static bool _retryable(Object e) {
    final t = e.toString();
    if (t.contains('disconnected')) return false;
    return t.contains('android-code: 17') ||
        t.contains('android-code: 133') ||
        t.contains('returned 201') || // ERROR_GATT_WRITE_REQUEST_BUSY: alta operatiune e in zbor
        t.contains('REQUEST_BUSY') ||
        t.contains('GATT_INSUFFICIENT_RESOURCES') ||
        t.contains('GATT_ERROR');
  }

  /// Ruleaza [op] cand coada e libera; la 17 / 133 reincearca de cel mult [tries] ori (pauza 300, 600 ms ...);
  /// dupa fiecare operatiune lasa 40 ms libere.
  Future<T> _gatt<T>(Future<T> Function() op, {int tries = 3}) {
    final done = Completer<T>();
    final prev = _gattTail;
    _gattTail = done.future.then<void>((_) {}, onError: (_) {});
    prev.then((_) async {
      for (var i = 1;; i++) {
        try {
          final v = await op();
          await Future.delayed(const Duration(milliseconds: 40));
          done.complete(v);
          return;
        } catch (e) {
          if (i >= tries || !_retryable(e)) {
            done.completeError(e);
            return;
          }
          await Future.delayed(Duration(milliseconds: 300 * i));
        }
      }
    });
    return done.future;
  }
  Future<void> _chain = Future.value(); // serializeaza prelucrarea notificarilor (insert -> ack, in ordine)

  void _set(String s) {
    state = s;
    notifyListeners();
  }

  Timer? _refreshTimer;
  DateTime _lastGapCalc = DateTime.fromMillisecondsSinceEpoch(0);

  /// Reimprospatare cel mult o data la 2 s (altfel, la ~1,5 mesaje/s, interogarile pe toata baza incetinesc ack-ul).
  void _scheduleRefresh() {
    if (_refreshTimer != null) return;
    _refreshTimer = Timer(const Duration(seconds: 2), () {
      _refreshTimer = null;
      unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    stored = await db.count();
    unsynced = await db.unsyncedCount();
    gaps = await db.seqGaps();
    if (gaps == 0) {
      gapDetails = const [];
    } else if (DateTime.now().difference(_lastGapCalc).inSeconds >= 30 || gapDetails.isEmpty) {
      gapDetails = await db.seqGapDetails(); // scanare completa: cel mult o data la 30 s
      _lastGapCalc = DateTime.now();
    }
    latest = await db.latest(15);
    activeRun = await db.activeRun();
    pendingStopCount = await db.pendingCount();
    channelList = await db.channels(stats: false);
    notifyListeners();
  }

  /// Starea live a canalului afisat (Status per canal, firmware 3); la firmware 2 = canalul 1.
  DeviceStatus? get viewStatus => status?.forChannel(db.viewCh);

  /// Cerere de schimbare a filei (indexul filei); o citeste Shell.
  final ValueNotifier<int?> tabRequest = ValueNotifier<int?>(null);

  /// Alege canalul afisat in Linia si Opriri (selectorul de canal).
  void setViewChannel(int ch) {
    if (db.viewCh == ch) return;
    db.viewCh = ch;
    notifyListeners();
  }

  /// Nume afisabil pentru un canal (numele echipamentului, sau „Canal N”).
  String channelName(int ch) {
    for (final c in channelList) {
      if (c.id == ch) return c.name;
    }
    return 'Canal $ch';
  }

  Future<void> start() async {
    if (running) return;
    running = true;
    await refresh();
    unawaited(_loop());
  }

  Future<void> stop() async {
    running = false;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    for (final d in FlutterBluePlus.connectedDevices) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    _set('oprit');
  }

  /// Dupa editarea retetei produsului activ: reincarca run-ul activ din baza si rescrie parametrii pe ESP32.
  Future<void> applyActiveRecipe(int skuId) async {
    final a = activeRun;
    if (a == null || a.sku.id != skuId) return;
    activeRun = await db.activeRun();
    configInfo = connected ? null : 'parametrii se scriu la urmatoarea conectare';
    paramsPending = true;
    _cfgRetries = 0;
    notifyListeners();
    if (connected) await pushConfig();
  }

  /// Porneste un run pentru produsul ales si, daca ESP32 e conectat, ii scrie parametrii.
  Future<void> startRun(Sku sku) async {
    activeRun = await db.startRun(sku);
    configInfo = connected ? null : 'parametrii se scriu la urmatoarea conectare';
    paramsPending = true;
    _cfgRetries = 0;
    notifyListeners();
    if (connected) await pushConfig();
  }

  /// Scrie parametrii run-ului activ pe ESP32 si verifica prin recitire ca i-a acceptat
  /// (firmware-ul ignora silentios o configuratie invalida).
  Future<void> pushConfig() async {
    if (_cfgBusy) {
      _cfgAgain = true; // o scriere e in curs: o repetam dupa ea, cu run-ul activ de atunci
      return;
    }
    _cfgBusy = true;
    _cfgTimer?.cancel();
    try {
      do {
        _cfgAgain = false;
        await _pushConfigOnce();
      } while (_cfgAgain && connected);
    } finally {
      _cfgBusy = false;
    }
    // esec: reincercare automata (la 5, 10, 15, 20, 25 s), cat timp suntem conectati
    if (paramsPending && connected && _cfgRetries < 5) {
      _cfgRetries++;
      _cfgTimer = Timer(Duration(seconds: 5 * _cfgRetries), () {
        if (connected && paramsPending) unawaited(pushConfig());
      });
    }
  }

  Future<void> _pushConfigOnce() async {
    final ch = _cfgChar, run = activeRun;
    if (ch == null || run == null) return;
    final err = validateSkuTiming(run.sku.cycleS, run.sku.triggerS);
    if (err != null) {
      configInfo = 'Parametri invalizi: $err';
      paramsPending = false; // nu se mai poate repara prin reincercare; se corecteaza reteta
      await _logConfig(run, 'invalid: $err');
      notifyListeners();
      return;
    }
    final bytes = encodeConfig(
        runNo: run.runNo, cycleS: run.sku.cycleS, triggerS: run.sku.triggerS);
    var ok = false;
    try {
      final cur = await _gatt(() => ch.read());
      if (cur.length >= 2 * kBlockSize) {
        // firmware 3: Config de 288 B (global + 8 canale)
        configInfo = await _pushBlocks(ch, run);
        ok = configInfo!.startsWith('Parametri scrisi');
      } else {
        await _gatt(() => ch.write(bytes, withoutResponse: false));
        final back = await _gatt(() => ch.read());
        ok = configEchoMatches(bytes, back);
        configInfo = ok
            ? 'Parametri scrisi: ${run.sku.name}, ciclu ${run.sku.cycleS.toStringAsFixed(4)} s, '
                'trigger ${run.sku.triggerS.toStringAsFixed(1)} s'
            : 'ESP32 a respins parametrii (recitirea difera)';
      }
    } catch (e) {
      configInfo = 'Scrierea parametrilor a esuat: $e';
    }
    if (ok) {
      paramsPending = false;
      _cfgRetries = 0;
    } else {
      paramsPending = true;
    }
    await _logConfig(run, configInfo ?? '');
    notifyListeners();
  }

  /// Firmware 3: scrie blocul global si cele 8 canale (activ / inactiv, ciclu C si trigger T), apoi recitește Config
  /// si compara fiecare bloc. Ciclul, T si ritmul fiecarui canal vin din reteta produsului activ (viteza pe senzor).
  Future<String> _pushBlocks(BluetoothCharacteristic ch, ActiveRun run) async {
    final chans = await db.channels(stats: false);
    final blocks = <Uint8List>[encodeBlockGlobal(runNo: run.runNo)];
    final skipped = <String>[];
    var active = 0;
    for (final c in chans) {
      if (!c.active) {
        blocks.add(encodeBlockChannel(ch: c.id, active: false));
        continue;
      }
      final rc = run.sku.chans[c.id];
      if (rc == null || rc.rateBph <= 0) {
        skipped.add('CH${c.id} ${c.name}: lipseste viteza in reteta');
        blocks.add(encodeBlockChannel(ch: c.id, active: false));
        continue;
      }
      final cycleS = 3600 / rc.rateBph;
      final triggerS = rc.triggerS;
      final e = validateSkuTiming(cycleS, triggerS);
      if (e != null) {
        skipped.add('CH${c.id} ${c.name}: $e');
        blocks.add(encodeBlockChannel(ch: c.id, active: false));
        continue;
      }
      active++;
      blocks.add(encodeBlockChannel(ch: c.id, active: true, cycleS: cycleS, triggerS: triggerS));
    }
    for (final b in blocks) {
      await _gatt(() => ch.write(b, withoutResponse: false));
      await Future.delayed(const Duration(milliseconds: 80)); // firmware-ul aplica blocurile din bucla principala
    }
    await Future.delayed(const Duration(milliseconds: 300));
    final back = await _gatt(() => ch.read());
    final (bad, unread) = configBlockMismatches(blocks, back);
    String nm(int id) => id == 0 ? 'global' : 'CH$id ${channelName(id)}';
    final parts = <String>[];
    if (bad.isEmpty && unread.isEmpty) {
      parts.add('Parametri scrisi (firmware 3): ${run.sku.name}, $active ${active == 1 ? 'canal activ' : 'canale active'}');
    } else {
      if (bad.isNotEmpty) parts.add('ESP32 a respins: ${bad.map(nm).join(', ')}');
      if (unread.isNotEmpty) parts.add('necitite la recitire: ${unread.map(nm).join(', ')}');
    }
    if (skipped.isNotEmpty) parts.add('sarite (parametri invalizi): ${skipped.join('; ')}');
    return parts.join(' · ');
  }

  /// Retine in baza ce s-a scris pe ESP32 si cu ce rezultat (ce parametri erau activi la un moment dat).
  Future<void> _logConfig(ActiveRun run, String result) async {
    try {
      await db.logConfigWrite({
        'run': run.runNo,
        'sku': run.sku.name,
        'cycle_s': run.sku.cycleS,
        'trigger_s': run.sku.triggerS,
        'result': result,
      });
    } catch (_) {}
  }

  Future<void> _loop() async {
    while (running) {
      try {
        await _connectOnce();
      } catch (e) {
        lastError = e.toString();
      }
      connected = false;
      _cfgChar = null;
      if (!running) break;
      _set('reconectare...');
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  int _attempt = 0;

  /// Intai dispozitivul deja asociat (bonded) cu telefonul: conectare directa, fara scanare (scanarea cu filtru
  /// a ramas blocata dupa pierderi de semnal). La fiecare a 3-a incercare, sau daca nu exista asociere, se scaneaza.
  Future<BluetoothDevice?> _scan() async {
    _attempt++;
    if (_attempt % 3 != 0) {
      try {
        for (final d in await FlutterBluePlus.bondedDevices) {
          if (d.platformName.startsWith('OEE-')) {
            scans++;
            lastScan = 'asociat ${d.platformName}: conectare directa';
            notifyListeners();
            return d;
          }
        }
      } catch (_) {}
    }
    return _scanService();
  }

  Future<BluetoothDevice?> _scanService() async {
    _set('caut dispozitiv...');
    final done = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.onScanResults.listen((list) {
      for (final r in list) {
        if (!done.isCompleted) done.complete(r.device);
      }
    });
    await FlutterBluePlus.startScan(
        withServices: [kServiceUuid], timeout: const Duration(seconds: 15));
    final dev = await done.future
        .timeout(const Duration(seconds: 16), onTimeout: () => null);
    scans++;
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    lastScan = '${two(n.hour)}:${two(n.minute)}:${two(n.second)} ${dev == null ? 'nimic gasit' : 'gasit ${dev.platformName.isNotEmpty ? dev.platformName : dev.remoteId.str}'}';
    notifyListeners();
    await sub.cancel();
    await FlutterBluePlus.stopScan();
    return dev;
  }

  Future<void> _connectOnce() async {
    final dev = await _scan();
    if (dev == null) return;
    deviceName = dev.platformName.isNotEmpty ? dev.platformName : dev.remoteId.str;
    _set('conectare la $deviceName...');

    await dev.connect(timeout: const Duration(seconds: 20)); // cere MTU mare; firmware-ul cere >= 200
    mtu = 0;
    dataSubscribed = false;
    notifRaw = 0;
    try {
      mtu = await dev.requestMtu(247); // explicit, la fiecare conexiune (firmware-ul cere >= 200)
    } catch (_) {
      // deja negociat sau nesuportat; ramane 0 = necunoscut
    }
    final services = await dev.discoverServices();
    final svc = services.firstWhere((s) => s.uuid == kServiceUuid);
    BluetoothCharacteristic ch(Guid u) => svc.characteristics.firstWhere((c) => c.uuid == u);
    final data = ch(kDataUuid), ack = ch(kAckUuid), st = ch(kStatusUuid);
    final timeChar = ch(kTimeUuid);
    _cfgChar = ch(kConfigUuid);

    final key = deviceName!;
    final subs = <StreamSubscription>[];
    try {
      // 1. ceasul: daca ESP32 nu are ora sau deriva > 2 s fata de tableta, i-o setam
      final first = DeviceStatus.parse(await _gatt(() => st.read()));
      _resetTracking(first?.ackBoot ?? 0);
      if (first != null) {
        status = first;
        final nowS = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
        if (first.utcS == 0 || (first.utcS - nowS).abs() > 2) {
          await _gatt(() => timeChar.write(encodeTime(nowS), withoutResponse: false));
        }
      }
      connected = true;

      // 2. parametrii run-ului activ
      activeRun = await db.activeRun();
      paramsPending = activeRun != null;
      _cfgRetries = 0;
      await pushConfig();

      // 3. date
      subs.add(st.onValueReceived.listen((v) {
        final s = DeviceStatus.parse(v);
        if (s != null) {
          status = s;
          notifyListeners();
        }
      }));
      subs.add(data.onValueReceived.listen((v) {
        notifRaw++;
        _chain = _chain.then((_) => _handle(key, data, ack, v)).catchError((e) {
          lastError = e.toString();
        });
      }));
      await _gatt(() => st.setNotifyValue(true));
      await _gatt(() => data.setNotifyValue(true)); // la abonare ESP32 retransmite tot ce nu e confirmat
      dataSubscribed = true;
      lastError = null; // conexiune reusita: o eroare veche nu mai e relevanta

      _set('conectat: $deviceName');
      await dev.connectionState
          .firstWhere((s) => s == BluetoothConnectionState.disconnected);
    } finally {
      connected = false;
      dataSubscribed = false;
      _cfgTimer?.cancel();
      for (final s in subs) {
        await s.cancel();
      }
      try {
        await dev.disconnect();
      } catch (_) {}
    }
  }

  static bool _keyGreater(int b1, int s1, int b2, int s2) => b1 > b2 || (b1 == b2 && s1 > s2);

  /// Reseteaza starea de urmarire a continuitatii la fiecare conexiune noua.
  void _resetTracking(int ackBoot) {
    _contig.clear();
    _ackB0 = ackBoot;
    _lastAckB = -1;
    _lastAckS = -1;
    _stallB = -1;
    _stallS = -1;
    _stallRounds = 0;
  }

  /// Avanseaza, pentru fiecare boot din [boots], cel mai mare seq CONTIGUU salvat. Ack-ul acopera doar pana la primul gol:
  /// o notificare pierduta pe drum nu mai este "confirmata" de mesajele urmatoare.
  Future<({int? ackB, int? ackS, bool blocked, int stallB, int stallS})> _advance(
      String device, List<int> boots) async {
    int? ackB, ackS;
    for (final b in boots) {
      var c = _contig[b] ?? 0;
      final more = await db.seqsAfter(device, b, c);
      for (final s in more) {
        if (s == c + 1) {
          c = s;
        } else {
          break;
        }
      }
      _contig[b] = c;
      if (c > 0) {
        ackB = b;
        ackS = c;
      }
      if (more.any((s) => s > c)) {
        return (ackB: ackB, ackS: ackS, blocked: true, stallB: b, stallS: c);
      }
    }
    return (ackB: ackB, ackS: ackS, blocked: false, stallB: -1, stallS: -1);
  }

  /// Cere ESP32 sa retransmita de la ultima confirmare (reabonare la Data), cel mult o data la 8 s.
  Future<void> _requestResend(BluetoothCharacteristic data, int b, int s) async {
    if (_cfgBusy) return; // nu reabonam cat timp se scriu parametrii
    if (DateTime.now().difference(_lastResub).inSeconds < 8) return;
    _lastResub = DateTime.now();
    if (b == _stallB && s == _stallS) {
      _stallRounds++;
    } else {
      _stallB = b;
      _stallS = s;
      _stallRounds = 1;
    }
    resubs++;
    try {
      await _gatt(() => data.setNotifyValue(false));
      await _gatt(() => data.setNotifyValue(true)); // firmware: abonare noua => retransmite tot ce nu e confirmat
    } catch (e) {
      lastError = 'Reabonarea la Data a esuat: $e';
    }
  }

  Future<void> _handle(String device, BluetoothCharacteristic data, BluetoothCharacteristic ack, List<int> v) async {
    final batch = Msg.parse(v);
    final msgs = batch.msgs;
    if (batch.invalid) {
      lastError = 'Linie invalida in notificare: golul se cere retransmis';
      notifyListeners();
    }
    if (msgs.isEmpty) return;
    received += msgs.length;

    // de unde asteptam seq pentru fiecare boot nou (calculat inainte de insert)
    final boots = <int>{for (final m in msgs) m.boot}.toList()..sort();
    for (final b in boots) {
      if (_contig.containsKey(b)) continue;
      final dbMax = await db.maxSeq(device, b);
      if (dbMax > 0) {
        _contig[b] = dbMax; // golurile vechi din baza nu blocheaza; conteaza doar cele noi
      } else if (b > _ackB0) {
        _contig[b] = 0; // boot nou dupa ultimul ack al ESP32: asteptam de la seq 1
      } else {
        var lo = 1 << 30;
        for (final m in msgs) {
          if (m.boot == b && m.seq < lo) lo = m.seq;
        }
        _contig[b] = lo - 1; // reluare la mijlocul unui boot (ex. reinstalare): luam primul seq primit ca baza
      }
    }

    await db.insertMessages(device, msgs); // 1. durabil pe tableta

    if (_stallB >= 0 && !boots.contains(_stallB)) {
      boots.add(_stallB);
      boots.sort();
    }
    var r = await _advance(device, boots);
    // gol care nu s-a umplut dupa 3 retransmiteri: pierdut definitiv la sursa (ex. jurnal depasit) -> il acceptam
    if (r.blocked && _stallRounds >= 3 && r.stallB == _stallB && r.stallS == _stallS) {
      final more = await db.seqsAfter(device, r.stallB, r.stallS, limit: 1);
      if (more.isNotEmpty) {
        _contig[r.stallB] = more.first - 1;
        gapsAccepted++;
        _stallRounds = 0;
        _stallB = -1;
        _stallS = -1;
        r = await _advance(device, boots);
      }
    }
    final ab = r.ackB, asq = r.ackS;
    if (ab != null && asq != null && _keyGreater(ab, asq, _lastAckB, _lastAckS)) {
      // 2. abia apoi confirmare cumulativa, doar pana la primul gol; coada GATT reincearca la 17 / 133
      await _gatt(() => ack.write(encodeAck(ab, asq)));
      _lastAckB = ab;
      _lastAckS = asq;
      if (lastError != null && lastError!.contains('writeCharacteristic')) lastError = null;
    }
    if (r.blocked) {
      await _requestResend(data, r.stallB, r.stallS);
    } else {
      _stallRounds = 0;
      _stallB = -1;
      _stallS = -1;
    }
    _scheduleRefresh();
  }
}
