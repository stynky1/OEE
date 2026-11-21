// Pornirea / oprirea colectarii (permisiuni, serviciu foreground, BLE). Folosita din mai multe ecrane.
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_service.dart';

Future<void> startCollector(BleService ble) async {
  if (Platform.isAndroid) {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
      Permission.locationWhenInUse, // necesar doar pe Android <= 11 pentru scanare BLE
    ].request();
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'OEE activ',
      notificationText: 'Colectare date de la dispozitiv',
    );
  }
  await ble.start();
}

Future<void> stopCollector(BleService ble) async {
  await ble.stop();
  if (Platform.isAndroid) await FlutterForegroundTask.stopService();
}
