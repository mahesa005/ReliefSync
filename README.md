# ReliefSync

Menghubungkan pelapor kejadian bencana dengan relawan terdekat yang punya kemampuan relevan.
Laporan bebas diringkas AI, kebutuhan dipetakan otomatis, relawan dicocokkan dengan skor
prioritas, lalu dipanggil lewat alarm bertingkat. Tidak ada peran koordinator: status "selesai"
ditentukan lewat konfirmasi bersama (lihat [PERUBAHAN.md](PERUBAHAN.md)).

IFest 2026 Hackathon, Tim STEICON. Skenario MVP: kebakaran permukiman, data relawan simulasi.

```
Laporan -> Ekstraksi AI -> Konfirmasi pelapor -> Kebutuhan -> Hard filter -> Priority score
-> Ranking (+fairness/tie-break) -> Batch alarm -> Penugasan -> Pengerjaan
-> Konfirmasi selesai bersama -> Update pengalaman & trust
```

| Bagian | Teknologi | Folder |
|---|---|---|
| Aplikasi | Flutter (Provider), font Nunito Sans, peta OpenStreetMap (tile via CARTO) | `app/` |
| Backend | Python FastAPI + SQLAlchemy | `backend/` |
| Database | Supabase Postgres (atau SQLite lokal tanpa setup) | `backend/supabase/schema.sql` |
| Notifikasi | Inbox in-app (polling 3 dtk) + FCM opsional | `backend/app/services/notify.py` |
| AI | Groq (`llama-3.3-70b-versatile`, batas 5 dtk): judul, deskripsi, skill+kuota dari katalog 12 skill (`skills` table) | `backend/app/services/extraction.py` |

---

## 1. Menjalankan backend

Prasyarat: Python 3.11+ (teruji di 3.14).

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env               # opsional, semua nilai punya default
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

- Dokumentasi API interaktif: http://localhost:8000/docs
- Tanpa konfigurasi apa pun, backend memakai **SQLite** (`backend/reliefsync.db`), **OTP simulasi**,
  **ekstraksi berbasis aturan**, dan **inbox notifikasi in-app**. Semua alur tetap bisa didemokan.
- Saat pertama jalan, backend mengisi 30 relawan simulasi di sekitar Tambora, Jakarta Barat, plus dua akun demo:

| Akun | Nomor HP | Kata sandi |
|---|---|---|
| Demo Pelapor | `081200000001` | `demo1234` |
| Demo Relawan (Teknik memindahkan korban, P3K, Penggunaan APAR) | `081200000002` | `demo1234` |

Relawan simulasi menjawab alarm sendiri (menerima ±70%), bergerak ke lokasi, lalu ikut
mengonfirmasi "sudah teratasi", sehingga seluruh alur terlihat hidup dari satu HP.

### Opsi konfigurasi (`backend/.env`)

| Variabel | Fungsi |
|---|---|
| `DATABASE_URL` | Kosong = SQLite. Untuk Supabase: `postgresql+psycopg://postgres.<ref>:<password>@<host>:5432/postgres` (Project Settings → Database). Tabel dibuat otomatis saat start, RLS diaktifkan. `supabase/schema.sql` tersedia untuk ditinjau / dijalankan manual. |
| `GROQ_API_KEY` | Mengaktifkan ekstraksi AI dengan Groq. Tanpa kunci → fallback berbasis aturan. |
| `LLM_MODEL`, `LLM_TIMEOUT_SECONDS` | Default `llama-3.3-70b-versatile`, 5 detik (NFR-1). Lewat batas waktu → fallback otomatis. |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_BUCKET` | Simpan foto laporan di Supabase Storage (bucket publik). Kosong → folder `backend/uploads/`. |
| `FIREBASE_CREDENTIALS` | Isi JSON service-account Firebase (atau path ke file-nya; JSON langsung memudahkan hosting seperti Railway) untuk push FCM sungguhan. `firebase-admin` sudah ada di `requirements.txt`. Lihat 2.5. |
| `SIMULATE_OTP` | `true` (default): kode OTP dikembalikan API dan ditampilkan di aplikasi. |
| `SEED_DEMO_DATA` | `true` (default): isi relawan simulasi + akun demo. |

### Parameter desain (bisa diubah tanpa ubah kode)

Semua angka di Section 4 dokumen konteks disimpan di tabel `app_config`: bobot skor, radius 5 km,
near-tie 0,02, alarm 30 dtk, jendela respons 5 mnt, kuota per kebutuhan, mode kuorum, dst.

```bash
curl localhost:8000/config                                   # lihat semua
curl -X PUT localhost:8000/config/alarm_seconds \
     -H "Authorization: Bearer <token>" -H "Content-Type: application/json" -d '{"value": 60}'
```

### Tes

```bash
cd backend && source .venv/bin/activate && pytest -q
```

Tes mencakup formula priority score, hard filter, fairness, tie-break, ukuran batch 4.10, tabel
kuorum T(N) 1–100, fallback AI (timeout/error), dan alur ujung-ke-ujung (lapor → alarm → eskalasi →
Bantuan Utama/Tambahan → AFK → selesai → update pengalaman → trust tier).

---

## 2. Menjalankan aplikasi Flutter

Prasyarat: Flutter 3.35+ (teruji di 3.47). Untuk Android: Android SDK dan **JDK 17-21**. Untuk iOS: Xcode.

### 2.1 Konfigurasi build (`dart_define.json`)

Pengaturan yang ikut tertanam saat build dibaca dari `app/dart_define.json`. File ini **tidak ikut git**;
salin dari contoh lalu isi:

```bash
cd app
cp dart_define.example.json dart_define.json
```

```json
{
  "CARTO_API_KEY": "<key CARTO untuk tile peta>",
  "API_BASE_URL": "https://reliefsync-production.up.railway.app"
}
```

| Kunci | Fungsi |
|---|---|
| `CARTO_API_KEY` | API key tile peta CARTO. Kosong → tile diminta tanpa key. |
| `API_BASE_URL` | Alamat backend. Kosong → `http://10.0.2.2:8000` (emulator Android) atau `http://localhost:8000` (simulator iOS / web), **yang tidak ada di HP asli**. Selalu isi untuk HP fisik atau APK. |

Semua perintah di bawah memakai `--dart-define-from-file=dart_define.json`. Alamat backend juga bisa diganti
saat aplikasi jalan lewat ikon ⚙️ di layar masuk. Tulis alamat **lengkap dengan skema** (`https://...` atau
`http://...`); tanpa skema, di web request malah dikirim ke alamat halaman aplikasi itu sendiri.

### 2.2 Menjalankan (debug)

```bash
cd app
flutter pub get
flutter devices                                       # lihat ID perangkat
flutter run -d <id> --dart-define-from-file=dart_define.json
```

Untuk backend lokal dari **HP fisik**, samakan jaringan Wi-Fi dengan laptop dan isi `API_BASE_URL` dengan
`http://<IP-laptop>:8000`.

### 2.3 Build APK (Android)

```bash
cd app
flutter build apk --release --dart-define-from-file=dart_define.json
```

Hasil: `app/build/app/outputs/flutter-apk/app-release.apk`. Pasang lewat USB
(`adb install app/build/app/outputs/flutter-apk/app-release.apk`) atau kirim file-nya ke HP.

- APK ditandatangani dengan **kunci debug** bawaan project: cukup untuk uji coba dan dibagikan ke tim,
  belum untuk Play Store.
- **JDK 22+ gagal** di Gradle Android. Jika Java bawaan mesin lebih baru, arahkan Flutter ke JDK yang cocok
  (tanpa mengubah Java sistem): `flutter config --jdk-dir <path-ke-jdk-21>`. Periksa dengan `flutter doctor -v`.
- Build pertama mengunduh Gradle dan dependency (beberapa GB, bisa belasan menit) dan butuh ruang disk kosong
  sekitar 9 GB.

### 2.4 Menjalankan ke iPhone

```bash
cd app
flutter run --release -d <id-iphone> --dart-define-from-file=dart_define.json
```

- Mode `--release` membuat aplikasi tetap terpasang dan bisa dibuka dari home screen setelah kabel dicabut
  (mode debug di iOS 14+ hanya bisa dibuka lewat Flutter/Xcode).
- Di Xcode (`app/ios/Runner.xcworkspace` → Signing & Capabilities) pilih Team dan ubah **Bundle Identifier**
  menjadi yang unik. Perubahan ini khusus mesin masing-masing, jangan di-commit.
- Dengan Apple ID gratis, aplikasi kedaluwarsa setelah **7 hari** (pasang ulang dengan perintah yang sama) dan
  perlu *Settings → General → VPN & Device Management → Trust* di iPhone.
- Build iOS pertama mengunduh Firebase iOS SDK lewat Swift Package Manager (lebih dari 1 GB, bisa lama di
  jaringan lambat; hanya sekali).
- Push notifikasi belum berjalan di iOS: butuh akun Apple Developer berbayar (APNs) dan konfigurasi Firebase iOS.

### 2.5 Notifikasi push (Android)

Alarm dan notifikasi tetap masuk saat aplikasi tertutup lewat FCM. Konfigurasi aplikasi
(`app/android/app/google-services.json`, `app/lib/firebase_options.dart`) sudah ada di repo. Yang perlu diatur di
**backend**: isi `FIREBASE_CREDENTIALS` dengan JSON service-account Firebase (Firebase Console → Project settings →
Service accounts → *Generate new private key*) lalu redeploy. `/health` menampilkan `"fcm": true` bila variabel
terisi (bukan jaminan isinya valid; cek log `FCM disabled: ...`).

- **Alarm** dikirim sebagai pesan data dan ditampilkan aplikasi sendiri: layar penuh di atas lock screen dan
  berdering terus sampai dibuka atau `alarm_seconds` habis. Aplikasi hanya terbuka otomatis bila HP terkunci atau
  layar mati (aturan Android); saat HP sedang dipakai yang muncul hanya banner.
- **Notifikasi biasa** memakai kanal `relief_standard` dengan suara bawaan.
- Android 13+ meminta izin notifikasi, dan Android 14+ meminta izin "notifikasi layar penuh" (sekali). Di beberapa
  merek (Xiaomi/Oppo/Vivo) aktifkan juga "Autostart" dan matikan optimasi baterai untuk ReliefSync.

### Skenario demo (±3 menit)

1. Masuk sebagai **Demo Pelapor**. Di emulator tanpa GPS: *Profil → Gunakan lokasi demo (Jakarta)*.
   Jika demo dilakukan di luar Jakarta dengan GPS asli: *Profil → Sebar relawan simulasi di sekitar saya*.
2. *Laporkan kejadian* → tulis, misalnya: "Kebakaran rumah di Gang Mawar RT 05, api menjalar. Ada lansia
   terjebak di lantai 2. Gang sempit, mobil damkar susah masuk." → *Kirim laporan*.
3. Periksa hasil ekstraksi (judul, deskripsi, dan skill yang dibutuhkan — bisa diedit sebelum konfirmasi),
   atur kebutuhan & jumlah relawan → *Konfirmasi & cari relawan*.
4. Halaman status menampilkan jumlah relawan yang dihubungi, relawan yang menerima (Utama/Tambahan, "relawan ke-N"),
   posisi mereka bergerak di peta, dan tombol *Instansi resmi* (Call → dialer `tel:`).
5. Di HP/emulator kedua masuk sebagai **Demo Relawan** → alarm layar penuh berbunyi 30 dtk → *Terima tugas* →
   *Sudah sampai* → *Sudah teratasi*. Relawan simulasi ikut mengonfirmasi; kuorum tercapai → status **Selesai**,
   lalu relawan diminta menilai kesesuaian laporan (dasar trust score pelapor).

---

## 3. Keputusan untuk Open Items

Dokumen konteks menyisakan beberapa hal terbuka. Implementasi memilih nilai default berikut; semuanya ada di
`app_config` sehingga bisa diganti tanpa mengubah kode.

| Open item | Pilihan implementasi |
|---|---|
| #2 Mekanisme kuorum (4.13 vs 5.11) | Default `quorum_mode = "proportional"` (tabel T(N) Section 4.13), dihitung atas partisipan **aktif** (non-AFK) sesuai 5.11, minimal 2 sumber berbeda (FR-7.2). Mode `"simple"` (3 orang / 50%) tersedia. |
| #14 Ukuran batch (FR-5.5 vs 4.10) | Section 4.10: Batch 1 = Required Need, Batch 2 = sisa kebutuhan, Batch 3+ = sisa × 2^k. Semua kandidat lain langsung mendapat notifikasi standar dan bisa menerima proaktif (FR-5.7/5.8). |
| FR-5.11 vs 4.11 (peran) | Aturan 4.11: menerima ≤5 mnt sejak alarm sendiri → Utama; setelah 5 mnt / pernah menolak → Tambahan. Penerima pertama = "relawan ke-1". Semua penerima aktif mengisi kuota. |
| #3 Kuota per kebutuhan | Estimasi LLM per skill saat ekstraksi laporan; fallback manual jika ada timeout. Bukan nilai tetap per kategori. |
| #4 Data instansi | Daftar kurasi: Jakarta Siaga 112 (khusus DKI), Damkar 113, 112 nasional, Ambulans 119, Basarnas 115, Polisi 110. |
| #5 Akses kontak instansi | Pelapor (sejak mengisi laporan) dan relawan yang terlibat, kapan saja. |
| #8 / #9 Ambang skor / top-X | Ambang 0 (hanya hard filter), maksimal 50 kandidat. |
| #12 Trust tier | "Akun baru" sampai 3 laporan dinilai; "Riwayat baik" jika ≥70% laporan sesuai. |
| Periode popup konfirmasi | 120 detik (AFK jika satu periode tidak menjawab). |
| Mekanisme update status | Polling (3–6 dtk), memenuhi NFR-3 tanpa server WebSocket. |

## 4. Struktur

```
backend/
  app/
    main.py              # FastAPI + loop engine (tick tiap 2 dtk)
    core/
      config.py          # env settings (DATABASE_URL, GROQ_API_KEY, ...)
      security.py        # JWT, OTP, hashing, phone masking
      app_config.py      # semua parameter desain (tersimpan di tabel app_config)
    db/
      session.py         # engine & session SQLAlchemy (SQLite / Supabase Postgres)
      models.py          # skema database (sumber tunggal SQLite & Supabase)
    api/                 # auth, me, reports, volunteer, admin/demo
    services/
      matching.py        # Section 4: hard filter, priority score, fairness, tie-break, ukuran batch
      dispatch.py        # batch alarm, eskalasi, terima/tolak, Utama vs Tambahan, cross-skill credit
      confirmation.py    # konfirmasi selesai bersama, AFK, 24 jam, update pengalaman
      extraction.py      # Groq: judul/deskripsi/skill+kuota dari katalog skills, fallback manual
      skills.py          # katalog 12 skill relawan (seed + baca)
      trust.py, agencies.py, notify.py, simulation.py, storage.py, geo.py
  tests/
  supabase/schema.sql
app/
  lib/
    services/            # api, session, lokasi, alerts (polling alarm), suara
    screens/             # auth, home, report, volunteer, map, profile
    widgets/
  assets/                # logo, font Nunito Sans (OFL), suara alarm
```

## 5. Batasan yang diketahui (MVP)

- Saat aplikasi terbuka, notifikasi lewat polling. Saat tertutup, push FCM hanya untuk **Android** (lihat 2.5)
  dan butuh `FIREBASE_CREDENTIALS` di backend. iOS belum: butuh akun Apple Developer berbayar (APNs).
- Lokasi manual lewat pin peta (FR-2.4); pencarian alamat (geocoding) dan konteks area (FR-3.6/4.4) belum dibuat.
- Endpoint `/config` dan `/demo/*` hanya butuh login biasa. Batasi aksesnya sebelum dipakai di luar demo.
- Tile peta lewat CDN CARTO (data OpenStreetMap) dengan `CARTO_API_KEY`. Pantau kuota key-nya bila pemakaian membesar.
