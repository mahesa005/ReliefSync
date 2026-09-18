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
| Aplikasi | Flutter (Provider), font Nunito Sans, peta OpenStreetMap | `app/` |
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
| `FIREBASE_CREDENTIALS` | Path service-account Firebase + `pip install firebase-admin` untuk push FCM sungguhan (kanal `relief_alarm` vs `relief_standard`). |
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

Prasyarat: Flutter 3.35+ (teruji di 3.47), Android Studio / Xcode.

```bash
cd app
flutter pub get
flutter run                        # emulator Android / simulator iOS
```

Alamat backend default: `http://10.0.2.2:8000` (emulator Android) atau `http://localhost:8000` (simulator iOS).
Untuk **HP fisik**, samakan jaringan Wi-Fi dengan laptop lalu:

- ketuk ikon ⚙️ di layar masuk dan isi `http://<IP-laptop>:8000`, **atau**
- `flutter run --dart-define=API_BASE_URL=http://<IP-laptop>:8000`

Build APK: `flutter build apk --release --dart-define=API_BASE_URL=http://<server>:8000`

### Skenario demo (±3 menit)

1. Masuk sebagai **Demo Pelapor**. Di emulator tanpa GPS: *Profil → Gunakan lokasi demo (Jakarta)*.
   Jika demo dilakukan di luar Jakarta dengan GPS asli: *Profil → Sebar relawan simulasi di sekitar saya*.
2. *Laporkan kejadian* → tulis, misalnya: "Kebakaran rumah di Gang Mawar RT 05, api menjalar. Ada lansia
   terjebak di lantai 2. Gang sempit, mobil damkar susah masuk." → *Kirim laporan*.
3. Periksa hasil ekstraksi (setiap field punya cuplikan bukti; yang tanpa bukti = "belum diketahui"),
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

- Notifikasi andal saat aplikasi terbuka (polling). Push saat aplikasi tertutup butuh FCM
  (`FIREBASE_CREDENTIALS` di backend + konfigurasi Firebase di aplikasi: `google-services.json`,
  `firebase_messaging`), belum disertakan.
- Lokasi manual lewat pin peta (FR-2.4); pencarian alamat (geocoding) dan konteks area (FR-3.6/4.4) belum dibuat.
- Endpoint `/config` dan `/demo/*` hanya butuh login biasa. Batasi aksesnya sebelum dipakai di luar demo.
- Tile peta memakai server OpenStreetMap publik; untuk produksi gunakan penyedia tile sendiri.
