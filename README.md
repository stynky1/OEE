# OEE — aplicația de tabletă (Flutter, Android)

Client BLE pentru dispozitivul ESP32-S3 din cabinet (nume BLE `OEE-xxxxxx`): primește mesajele JSON, le salvează local (SQLite, `oee.db`), apoi confirmă (ack). 

Versiune: 0.15.0+1 (include coada GATT cu reîncercare la 17/133/201, bannerul „Parametri neaplicați” și exportul CSV pentru Power BI).

## Build (GitHub Actions)
Repo-ul conține doar `lib/`, `pubspec.yaml` și `tool/`; scheletul Android se generează în CI (`flutter create --org ro.oee --project-name oee`). Pornește la push pe `main` sau manual (Actions → Build APK → Run workflow); APK-ul e în artefactul `oee-apk`.

Semnare (Settings → Secrets and variables → Actions):
- `KEYSTORE_BASE64` — keystore-ul în base64
- `KEYSTORE_PASSWORD` — parola
- `KEYSTORE_ALIAS` — aliasul cheii din keystore (implicit `oee`; dacă refolosești keystore-ul vechi, pune `erka`)

Fără secrete, APK-ul e semnat cu o cheie de debug nouă la fiecare build, iar o actualizare nu se mai instalează peste versiunea anterioară (trebuie dezinstalată întâi). Păstrează aceeași cheie pentru toate build-urile.


