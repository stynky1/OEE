#!/usr/bin/env python3
"""Adauga permisiunile BLE / serviciu foreground in AndroidManifest.xml generat de `flutter create`.
Rulat de CI dupa `flutter create`. Idempotent."""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "android/app/src/main/AndroidManifest.xml"
s = open(path, encoding="utf-8").read()

perms = """    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="true"/>
"""

service = """        <service
            android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
            android:foregroundServiceType="connectedDevice"
            android:exported="false"/>
"""

if "BLUETOOTH_CONNECT" not in s:
    # BLUETOOTH_SCAN poate aparea doar prin merge; marcam prin BLUETOOTH_CONNECT
    s = re.sub(r"(<manifest[^>]*>\s*)", lambda m: m.group(1) + "\n" + perms, s, count=1)
if "ForegroundService" not in s:
    s = s.replace("</application>", service + "    </application>", 1)

# Numele aplicatiei afisat sub icoana (applicationId ro.oee.oee: aplicatie noua, separata de ErKa)
s = re.sub(r'android:label="[^"]*"', 'android:label="OEE"', s, count=1)

open(path, "w", encoding="utf-8").write(s)
print("Manifest actualizat:", path)
