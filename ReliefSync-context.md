# ReliefSync — Konteks Proyek Lengkap

IFest 2026 Hackathon — Tim STEICON. Dokumen ini menggabungkan empat sumber (User Story final, spesifikasi algoritma prioritas relawan, UI/UX Spec, dan FR & NFR Revisi 3) menjadi satu konteks tunggal untuk pengembangan. Scope: MVP Hack Day 24 jam, skenario tunggal kebakaran permukiman, data relawan simulasi.

---

## 1. Ringkasan Produk

ReliefSync menghubungkan pelapor kejadian bencana dengan relawan terdekat yang punya kemampuan relevan, lewat ekstraksi AI atas laporan bebas, pencocokan otomatis berbasis skor, dan notifikasi bertingkat (batch alarm). Tidak ada role Koordinator manusia: seluruh alur verifikasi ekstraksi, pencocokan, dan penugasan berjalan otomatis, dipegang pengguna sendiri, atau dikonfirmasi kolektif oleh komunitas.

Alur inti sistem:

```
Laporan -> Ekstraksi AI -> Kebutuhan -> Skill -> Hard Filter -> Priority Score
-> Ranking -> Fairness/Tie-Break -> Batch Alarm -> Penugasan -> Pengerjaan
-> Collective Confirmation (Selesai) -> Update Experience/History
```

Catatan penting untuk sesi tanya-jawab final: exsum yang sudah disubmit sebelumnya menekankan human-in-the-loop lewat koordinator. Desain saat ini full-otomatis di titik itu, dengan verifikasi kolektif komunitas menggantikan verifikasi tunggal koordinator.

### Tech Stack

| Komponen | Pilihan |
|---|---|
| App | Flutter |
| Backend | Python FastAPI |
| Database | Supabase |
| Notifikasi | FCM |
| Struktur folder root | `Backend/`, `App/` |

### Aktor

- **Pengguna Terdaftar** — base role untuk semua akun. Wajib verifikasi nomor HP. Dapat langsung bertindak sebagai **Pelapor** (membuat laporan) kapan saja tanpa langkah tambahan. Bisa menerima notifikasi untuk mengonfirmasi kejadian.
- **Status Relawan** — layer opsional di atas Pengguna Terdaftar. Bisa diaktifkan saat registrasi atau kapan saja setelahnya, dengan melengkapi profil tambahan (kemampuan, ketersediaan; jangkauan lokasi TIDAK di-declare, lihat Section 7). Bisa dinonaktifkan sewaktu-waktu. Satu akun bisa berstatus pelapor dan relawan sekaligus, tidak eksklusif, tidak ada akun terpisah per peran.
- **Warga terdampak** — penerima manfaat, tidak berinteraksi langsung dengan sistem.

Model data: satu entitas `User` dengan profil relawan opsional menempel, bukan dua entitas terpisah. Profil relawan awal boleh di-*pre-seed* sebagai data simulasi demi kecukupan kandidat saat demo.

### Perubahan Besar dari Desain Sebelumnya

- **Peran berlapis**: satu akun = base role, status relawan tinggal diaktifkan/nonaktifkan, bukan dua jenis akun terpisah.
- **Multi-relawan per kebutuhan**: berhenti dari asumsi 1 kebutuhan = 1 relawan. Sekarang ada **Responden Utama** (penerima pertama) + **Tenaga Tambahan** (penerima berikutnya), dengan kuota ditentukan tipe kasus.
- **Status "selesai" bukan keputusan sepihak**: butuh konfirmasi dari lebih dari satu sumber (collective confirmation), bukan cuma relawan yang ditugaskan, untuk mencegah misinformasi dari human error atau penyalahgunaan.
- **Kontak instansi resmi jadi aksi langsung** (tombol call + saran otomatis), bukan cuma pencatatan pasif seperti desain awal.

---

## 2. Functional Requirements (FR)

### 2.1 Autentikasi & Manajemen Akun

| ID | Requirement |
|---|---|
| FR-1.1 | Sistem mewajibkan pengguna mendaftar akun dengan nomor HP sebelum dapat mengirim laporan |
| FR-1.2 | Sistem melakukan verifikasi nomor HP via OTP (disimulasikan untuk MVP) |
| FR-1.3 | Pengguna dapat langsung mengaktifkan status relawan saat registrasi (opsional) |
| FR-1.4 | Pengguna yang belum jadi relawan saat registrasi tetap dapat mengaktifkan status relawan kapan saja setelahnya, dengan melengkapi profil tambahan: kemampuan/skill, ketersediaan|
| FR-1.5 | Satu akun tidak dibatasi hanya untuk satu peran; pengguna yang sama dapat membuat laporan (pelapor) dan menerima tugas (relawan) selama status relawannya aktif |
| FR-1.6 | Pengguna dapat menonaktifkan status relawan sewaktu-waktu, namun tetap dapat melapor |
| FR-1.7 | Pengguna dapat menonaktifkan notifikasi permintaan konfirmasi sekitar, namun tetap dapat melapor |

### 2.2 Pelaporan Kejadian

| ID | Requirement |
|---|---|
| FR-2.1 | Pelapor dapat membuat laporan berisi deskripsi bebas, lokasi, foto kejadian, dan kontak |
| FR-2.2 | Input suara (speech-to-text) tersedia sebagai alternatif input teks — **implementasi: dictation bawaan keyboard OS, bukan fitur speech-to-text custom di dalam aplikasi** |
| FR-2.3 | Tombol "gunakan lokasi saat ini" mengisi koordinat GPS perangkat otomatis |
| FR-2.4 | Pelapor dapat menentukan lokasi secara manual (pin di peta atau cari alamat), untuk kasus GPS tidak akurat atau melapor lokasi selain posisinya sendiri — *stretch goal, tergantung Open Item #1 (provider geocoding)* |
| FR-2.5 | Sistem menyimpan teks asli laporan beserta waktu penerimaan, terpisah dari hasil ekstraksi |
| FR-2.6 | Pelapor dapat melihat status laporannya secara rinci, termasuk jumlah relawan yang sedang dihubungi/ditawari, bukan hanya status biner "diproses/selesai" |
| FR-2.7 | Pelapor dapat melihat status konfirmasi kejadian yang dilakukan oleh user lain |

**Kunci desain**: lokasi adalah field terpisah sejak awal, diisi manual/GPS — **bukan** hasil ekstraksi LLM.

### 2.3 Ekstraksi AI & Konfirmasi Pelapor

| ID | Requirement |
|---|---|
| FR-3.1 | AI mengekstraksi info terstruktur dari teks laporan: jenis kejadian, lokasi disebutkan, kondisi akses, kebutuhan dinyatakan |
| FR-3.2 | Setiap field hasil ekstraksi disertai cuplikan teks asli sebagai bukti |
| FR-3.3 | Field tanpa bukti pendukung diisi "belum diketahui" — tidak dikarang |
| FR-3.4 | Sistem menampilkan hasil ekstraksi kepada pelapor untuk dikonfirmasi/dikoreksi sebelum laporan berstatus final |
| FR-3.5 | Laporan tidak lanjut ke identifikasi kebutuhan & pencocokan sebelum pelapor mengonfirmasi hasil ekstraksi |
| FR-3.6 *(kondisional, stretch goal)* | Jika layanan reverse-geocoding tersedia, sistem memperkaya laporan dengan konteks area (mis. permukiman padat, komersial) |

Catatan: konfirmasi pelapor (FR-3.4) hanya memvalidasi kesesuaian ekstraksi dengan teks asli, **bukan** kebenaran kejadian itu sendiri (itu ranah trust score, Section 2.9).

### 2.4 Identifikasi Kebutuhan

| ID | Requirement |
|---|---|
| FR-4.1 | Sistem memetakan laporan menjadi kategori kebutuhan dukungan berdasarkan aturan (rule-based) |
| FR-4.2 | Pelapor dapat menyesuaikan kategori kebutuhan hasil pemetaan otomatis |
| FR-4.3 | Sistem menentukan jumlah relawan yang dibutuhkan untuk tiap kebutuhan, berdasarkan tipe kasus (angka pasti = Open Item, hasil tuning tim) |
| FR-4.4 *(kondisional, bergantung FR-3.6)* | Jika konteks area tersedia, sistem menyesuaikan pemetaan kebutuhan berdasarkan jenis kawasan |
| FR-4.5 | Jika konteks area tidak tersedia/gagal, sistem tetap memproses pemetaan kebutuhan berdasarkan isi laporan saja (fallback) |

### 2.5 Pencocokan & Notifikasi Bertingkat

| ID | Requirement |
|---|---|
| FR-5.1 | Sistem menyaring kandidat relawan berdasarkan kesesuaian kemampuan, ketersediaan, dan lokasi terbaru (hard filter — lihat Section 4 untuk formula lengkap) |
| FR-5.2 | Sistem menghitung skor kecocokan kuantitatif tiap kandidat yang lolos filter |
| FR-5.3 | Sistem menetapkan ambang skor minimum; kandidat di atas ambang masuk kumpulan kandidat terpanggil ("top X") |
| FR-5.4 | Sistem mengecualikan pelapor dari daftar kandidat untuk laporan yang ia buat sendiri, meskipun status relawannya aktif |
| FR-5.5 | Kandidat top X diurutkan berdasarkan skor, lalu dibagi menjadi batch berisi 5 kandidat |
| FR-5.6 | Batch pertama (peringkat 1–5) menerima notifikasi prioritas tinggi ("alarm") |
| FR-5.7 | Batch berikutnya menerima notifikasi standar tanpa alarm |
| FR-5.8 | Kandidat pada batch notifikasi standar tetap dapat menerima tugas secara proaktif sebelum gilirannya mendapat alarm |
| FR-5.9 | Jika tidak ada yang menerima dari batch alarm aktif dalam jangka waktu tertentu, sistem mengeskalasi alarm ke batch berikutnya |
| FR-5.10 | Jika seluruh kandidat batch aktif menolak sebelum waktu eskalasi berakhir, sistem langsung mengeskalasi tanpa menunggu sisa waktu |
| FR-5.11 | Kandidat pertama yang menerima tugas untuk suatu kebutuhan ditandai sebagai **Responden Utama** |
| FR-5.12 | Kandidat lain tetap dapat menerima tugas yang sama setelah ada Responden Utama; mereka ditandai sebagai **Tenaga Tambahan** |
| FR-5.13 | Sistem terus menawarkan tugas ke kandidat berikutnya sampai jumlah penerima mencapai kuota kebutuhan (FR-4.3), bukan berhenti begitu ada 1 penerima |
| FR-5.14 | Jika seluruh kandidat top X telah dieskalasi dan kuota belum terpenuhi, kebutuhan berstatus "sebagian terpenuhi" (jika ada penerima) atau "belum ada penanggung jawab" (jika nol penerima) |

**Kunci desain**: radius jangkauan relawan dihapus dari FR-5.1 sebagai atribut yang di-declare; jarak jadi murni faktor skor otomatis saat matching (lihat Distance, Section 4).

### 2.6 Penugasan & Penerimaan

| ID | Requirement |
|---|---|
| FR-6.1 | Relawan yang menerima notifikasi (alarm maupun standar) dapat menerima atau menolak tugas |
| FR-6.2 | Tugas tidak dianggap tertangani hanya karena notifikasi terkirim; status tetap "ditawarkan" sampai ada yang menerima |
| FR-6.3 | Penolakan satu kandidat menutup tawaran padanya saja, tanpa mengganggu kandidat lain yang masih aktif di batch sama |

### 2.7 Pengerjaan & Penyelesaian Tugas

| ID | Requirement |
|---|---|
| FR-7.1 | Relawan (Responden Utama maupun Tenaga Tambahan) dapat memperbarui status tugasnya sendiri menjadi "sedang dikerjakan" |
| FR-7.2 | Status kebutuhan tidak dapat diubah menjadi "selesai" hanya berdasarkan laporan dari satu pihak; memerlukan konfirmasi kolektif dari lebih dari satu sumber dengan threshold tertentu (responder dan/atau pelapor) — **prioritas tertinggi untuk diputuskan, memblokir implementasi Section 7 dan trust score di Section 9** (lihat Section 5 untuk mekanisme final) |
| FR-7.3 | Setelah kebutuhan berstatus "selesai", sistem meminta konfirmasi kesesuaian kondisi lapangan dengan laporan awal, sebagai basis trust score pelapor (Section 2.9) |
| FR-7.4 | Laporan dapat otomatis terselesaikan setelah 24 jam |

### 2.8 Pemantauan Status

| ID | Requirement |
|---|---|
| FR-8.1 | Pelapor dapat melihat status kebutuhannya: belum ada penanggung jawab / sebagian terpenuhi / tertangani penuh, beserta jumlah relawan yang sudah konfirmasi bisa bantu |
| FR-8.2 | Relawan dapat melihat daftar kebutuhan terbuka di area jangkauannya |
| FR-8.3 | Perubahan status tampil tanpa refresh manual |
| FR-8.4 | User dapat melihat jumlah yang sudah mengonfirmasi kejadian |
| FR-8.5 | Pelapor dapat men-track GPS location dari relawan yang jalan ke lokasi mereka |
| FR-8.6 | Status relawan dapat berubah dari "On the Way" menjadi "Nearby/On location", dst. |

### 2.9 Kredibilitas Pelapor

| ID | Requirement |
|---|---|
| FR-9.1 | Sistem menghitung trust score pelapor berdasarkan riwayat kesesuaian laporan dengan kondisi lapangan (sumber data: hasil FR-7.3) |
| FR-9.2 | Trust score ditampilkan sebagai salah satu dari 3 tingkat: **Akun baru** / **Riwayat akurasi rendah** / **Riwayat baik** — bukan angka mentah |
| FR-9.3 | Trust tier pelapor ditampilkan kepada relawan pada notifikasi (alarm maupun standar), sebagai konteks tambahan sebelum menerima/menolak |
| FR-9.4 | Nomor HP pelapor ditampilkan tersamar (masked) di antarmuka manapun ia muncul |

### 2.10 Kontak & Penerusan ke Instansi Resmi

| ID | Requirement |
|---|---|
| FR-10.1 | Sistem menyarankan lembaga resmi paling relevan & urgent berdasarkan jenis kejadian dan lokasi (mis. kebakaran di Jakarta → 112) |
| FR-10.2 | Tombol "Call" pada saran utama langsung membuka opsi telepon ke nomor yang disarankan (native `tel:` URI) |
| FR-10.3 | Pengguna dapat melihat opsi lembaga lain di luar saran utama, diurutkan berdasarkan relevansi & urgensi |
| FR-10.4 | Sistem tidak menganggap instansi resmi telah menangani hanya karena tombol call ditekan; status penanganan resmi tetap memerlukan konfirmasi manual terpisah |

---

## 3. Non-Functional Requirements (NFR)

### Performa

| ID | Requirement |
|---|---|
| NFR-1 | Hasil ekstraksi AI tersedia dalam target waktu wajar (mis. <5 detik) |
| NFR-2 | Perhitungan trust score & skor kecocokan kandidat instan (<1 detik) |
| NFR-3 | Perubahan status & eskalasi batch terlihat dalam rentang singkat (mis. 5–10 detik) tanpa refresh manual |

### Usability

| ID | Requirement |
|---|---|
| NFR-4 | Antarmuka pelapor minim langkah (tap/klik sesedikit mungkin) mengingat kondisi darurat |
| NFR-5 | Kontras warna & ukuran teks cukup terbaca di kondisi lapangan (cahaya rendah, layar kecil) |
| NFR-6 | Speech-to-text punya fallback ke input teks manual jika gagal/tidak didukung perangkat |
| NFR-7 | Notifikasi "alarm" harus jelas terasa berbeda dari notifikasi standar (visual & audio), tidak sekadar beda teks |
| NFR-8 | Tombol "Call" (FR-10.2) menggunakan mekanisme panggilan native perangkat (`tel:` URI); tidak butuh integrasi API pihak ketiga untuk MVP |

### Reliability & Ketahanan

| ID | Requirement |
|---|---|
| NFR-9 | Ada fallback jika API AI eksternal lambat/tidak merespons saat demo |
| NFR-10 | Kegagalan ekstraksi AI tidak memblokir pelapor mengirim laporan |
| NFR-11 | Kegagalan layanan reverse-geocoding (FR-3.6) tidak memblokir alur; sistem lanjut tanpa konteks area (FR-4.5) |
| NFR-12 | Jika notifikasi bertingkat gagal menemukan kandidat sama sekali, sistem menampilkan kebutuhan sebagai terbuka, bukan gagal diam-diam |
| NFR-13 | Durasi timeout eskalasi batch dapat dikonfigurasi (bukan hardcoded) |

### Keamanan & Privasi

| ID | Requirement |
|---|---|
| NFR-14 | Data pribadi pengguna (terutama nomor HP) disimpan & ditampilkan dengan masking di UI |
| NFR-15 | Relawan hanya dapat melihat data pelapor yang relevan dengan tugas yang ditawarkan padanya |

### Skalabilitas (scoped untuk MVP)

| ID | Requirement |
|---|---|
| NFR-16 | Sistem cukup menangani skala data 1 skenario simulasi |

### Maintainability

| ID | Requirement |
|---|---|
| NFR-17 | Repo disertai panduan instalasi jelas sesuai ketentuan pengumpulan babak final |
| NFR-18 | Riwayat commit mencerminkan progres bertahap, selaras checkpoint panitia tiap 6 jam |

---

## 4. Algoritma Prioritas & Pencocokan Relawan

Prinsip utama: kompetensi dan jarak adalah faktor dominan; riwayat pengalaman adalah faktor pendukung.

### 4.1 Availability (Hard Filter)

Bentuk data: ON / OFF. Bukan komponen skor. `Availability = 1 (ON)` atau `0 (OFF)`. Jika 0, relawan tidak eligible untuk masuk proses matching maupun menerima notifikasi.

### 4.2 Skill / Competency

`Skill = {Skill Type, Evidence Type, Verified Experience}`

**Skill Type** — jenis kemampuan relawan (P3K, Evakuasi, Logistik, dst). Basic hard filter: `SkillMatch = 1` jika Required Skill ada di daftar skill relawan, selain itu `0`. MVP tidak menggunakan supporting skill, multi-skill kompleks, atau similarity antar-skill.

**Evidence Type** — self-declared atau certified, keduanya tetap boleh jadi kandidat (MVP tidak mensyaratkan Certified saja):

| Evidence Type | Evidence Score |
|---|---|
| Self-declared | 0,70 |
| Certified | 1,00 |

Evidence Type berkontribusi 60% terhadap Competency Score (efektif 24% terhadap Priority Score total).

**Verified Experience** — jumlah pengalaman pada skill tertentu yang tercatat lewat ReliefSync, dihitung per skill (bukan total tugas). Diperbarui setelah bencana selesai lewat collective confirmation; untuk Relawan Utama, skill terdaftar pada tugas tersebut +1. Diminishing return, cap efektif 10:

```
VE = ln(1 + min(x, 10)) / ln(11)
```

Berkontribusi 40% terhadap Competency Score (efektif 16% terhadap Priority Score total).

**Competency Score**: `C = 0,60E + 0,40VE` — bobot total 40% pada Priority Score.

### 4.3 Distance (Hard Filter + Ranking Variable)

Jarak relawan ke lokasi kejadian dalam km, dari koordinat relawan dan lokasi bencana. Maximum Distance = **5 km**; di luar itu tidak masuk kandidat. Radius tidak diperluas otomatis jika kandidat tidak tersedia. ETA tidak digunakan pada MVP.

```
D = 1 - (d / 5), untuk 0 <= d <= 5 km
```

Berkontribusi **40%** terhadap Priority Score (bobot terbesar).

### 4.4 Completion History

Jumlah tugas yang telah diselesaikan relawan lewat ReliefSync (integer 0, 1, 2, ...). Untuk Relawan Utama, +1 setelah bencana dinyatakan selesai. Ranking variable sekunder, diminishing return, cap efektif 10:

```
CH = ln(1 + min(c, 10)) / ln(11)
```

Berkontribusi 10% terhadap Priority Score.

### 4.5 Similar Disaster Experience

Jumlah kejadian dengan jenis bencana yang sama yang pernah diikuti relawan (integer per jenis bencana, mis. Kebakaran = 3, Banjir = 1). Bertambah +1 per kejadian (bukan per aktivitas) setelah selesai, berlaku untuk Relawan Utama maupun Bantuan Tambahan yang tercatat terlibat. Diminishing return, cap efektif 10:

```
SD = ln(1 + min(s, 10)) / ln(11)
```

Berkontribusi 10% terhadap Priority Score.

### 4.6 Active Workload

**Tidak digunakan** sebagai hard filter maupun komponen Priority Score. ReliefSync tidak mencoba merekam seluruh aktivitas nyata relawan di lapangan; pembaruan data hanya berdasarkan keterlibatan yang tercatat di platform.

### 4.7 Hard Filter & Priority Score (Formula Final)

Relawan masuk ranking hanya jika seluruh hard filter terpenuhi:

- `Availability = ON`
- `SkillMatch = 1`
- `Distance <= 5 km`

Metode final ranking: Weighted Scoring.

```
Priority = 0,30E + 0,10VE + 0,40D + 0,10CH + 0,10SD
```

| Komponen | Proporsi efektif |
|---|---|
| Evidence Type | 24% |
| Verified Experience | 16% |
| Distance | 40% |
| Completion History | 10% |
| Similar Disaster Experience | 10% |
| **Total** | **100%** |

### 4.8 Fairness

Bukan bobot baru; hanya berlaku pada kandidat dengan Priority Score sangat dekat. Selection Count menyimpan berapa kali relawan sebelumnya terpilih/diberi tugas. Near-tie threshold = **0,02**.

```
|Score_A - Score_B| <= 0,02 -> prioritaskan Selection Count yang lebih rendah
```

Fairness tidak boleh mengalahkan perbedaan skor yang signifikan.

### 4.9 Tie-Break

Jika dua atau lebih relawan punya Priority Score sama, urutan penentu:

1. Distance lebih dekat
2. Jika sama, Competency Score lebih tinggi
3. Jika masih sama, Selection Count lebih rendah
4. Jika seluruhnya identik: fallback sederhana (first available timestamp atau random)

### 4.10 Mekanisme Batch Alarm

- Jumlah Relawan Utama yang dibutuhkan berasal dari hasil identifikasi kebutuhan.
- **Batch 1** mengirim alarm ke kandidat sebanyak jumlah relawan yang dibutuhkan (`Required Need`). Alarm aktif **30 detik**.
- **Jendela Respons Lanjutan**: total **5 menit** sejak alarm dikirim. Setelah 30 detik, alarm berhenti dan berubah jadi notifikasi biasa selama sisa 4 menit 30 detik.
  - Menerima dalam Jendela Respons Lanjutan → tetap jadi **Bantuan Utama**.
  - Menerima setelah 5 menit → dikategorikan **Bantuan Tambahan**.
  - Menolak lalu berubah pikiran → masuk **Bantuan Tambahan**.
- Jika seluruh kandidat Batch 1 menolak, Batch 2 tetap mengikuti sisa kebutuhan dari Batch 1 (tidak ada eskalasi khusus karena reject).
- **Batch 2** memanggil kandidat sebanyak `Remaining Need`.
- Jika kebutuhan belum terpenuhi setelah Batch 2, batch berikutnya berkembang secara eksponensial, dibatasi kandidat eligible yang masih tersedia:

```
Batch 1 = Required Need
Batch 2 = Remaining Need
Mulai Batch 3: BatchSize = min(RemainingNeed x 2^k, CandidatesRemaining), k = 1, 2, 3, ...
```

- Maximum candidate = seluruh relawan eligible dalam radius 5 km.

**Catatan implementasi FR-5.5 vs Section 4.10**: FR-5.5/5.6 menyebut batch tetap berisi 5 kandidat per batch dengan peringkat 1–5 sebagai batch alarm pertama; Section 4.10 (dokumen algoritma) mendefinisikan Batch 1 = sebesar kebutuhan (Required Need), bukan tetap 5. Selaraskan angka batch size ini dengan tim sebelum implementasi — kemungkinan `Required Need` menggantikan angka tetap "5" sebagai ukuran default batch.

### 4.11 Bantuan Utama vs Bantuan Tambahan

- **Bantuan Utama** = relawan yang menerima tawaran sistem dalam alarm 30 detik atau Jendela Respons Lanjutan 5 menit.
- Jika jumlah penerima melebihi kebutuhan awal, kelebihan penerima tetap boleh jadi Bantuan Utama; sistem tidak menurunkan mereka jadi Bantuan Tambahan.
- Setelah kebutuhan terpenuhi dan sistem berhenti mengirim alarm, relawan lain masih bisa membantu proaktif sebagai Bantuan Tambahan.
- Relawan yang pernah reject lalu berubah pikiran selalu masuk Bantuan Tambahan.
- **Relawan tidak punya fitur membatalkan keterlibatan setelah accept.** Pengelolaan/pelepasan relawan dilakukan oleh pelapor lewat fitur terpisah.

### 4.12 Pembaruan Experience Setelah Bencana Selesai

| Status Relawan | Verified Experience (Skill) | Completion History | Similar Disaster Experience |
|---|---|---|---|
| Bantuan Utama | +1 pada skill yang terdaftar | +1 | +1 pada jenis bencana |
| Bantuan Tambahan | Tidak bertambah | Tidak bertambah | +1 pada jenis bencana |

Seluruh pembaruan dilakukan **setelah** bencana dinyatakan selesai, bukan selama penanganan berlangsung.

### 4.13 Collective Confirmation Penyelesaian Bencana

Tidak ada voting dua arah, hanya aksi **Konfirmasi Selesai**. Yang berhak: pelapor dan seluruh relawan yang tercatat pada kejadian tersebut. Tidak semua orang wajib konfirmasi; threshold menurun proporsional seiring jumlah orang terlibat membesar.

```
T(N) = N                         untuk 1-3 orang
T(N) = ceil(0,70N)               untuk 4-10 orang
T(N) = ceil(0,60N)               untuk 11-20 orang
T(N) = max(12, ceil(0,50N))      untuk 21-50 orang
T(N) = max(25, ceil(0,40N))      untuk 51-100 orang
```

Tabel referensi threshold (Orang → Threshold), 1–100 orang:

```
1→1   11→7   21→12  31→16  41→21  51→25  61→25  71→29  81→33  91→37
2→2   12→8   22→12  32→16  42→21  52→25  62→25  72→29  82→33  92→37
3→3   13→8   23→12  33→17  43→22  53→25  63→26  73→30  83→34  93→38
4→3   14→9   24→12  34→17  44→22  54→25  64→26  74→30  84→34  94→38
5→4   15→9   25→13  35→18  45→23  55→25  65→26  75→30  85→34  95→38
6→5   16→10  26→13  36→18  46→23  56→25  66→27  76→31  86→35  96→39
7→5   17→11  27→14  37→19  47→24  57→25  67→27  77→31  87→35  97→39
8→6   18→11  28→14  38→19  48→24  58→25  68→28  78→32  88→36  98→40
9→7   19→12  29→15  39→20  49→25  59→25  69→28  79→32  89→36  99→40
10→7  20→12  30→15  40→20  50→25  60→25  70→28  80→32  90→36  100→40
```

Setelah threshold tercapai, status bencana berubah jadi **Selesai** dan pembaruan experience/history dilakukan (lihat 4.12).

Mekanisme UI untuk ini (popup periodik "Apakah bencana ini sudah teratasi?", AFK handling, batas waktu 24 jam) ada di Section 6.10 (dari UI/UX Spec) — angka kuorum di sana (min 3 orang / 50%) berbeda dari tabel proporsional T(N) di atas; **ini perlu diselaraskan sebagai bagian dari Open Item #2**, karena kedua dokumen sumber memberi formula kuorum yang tidak identik.

### 4.14 Ringkasan Struktur Final

| Tahap | Komponen |
|---|---|
| Hard Filter | Availability ON; SkillMatch = 1; Distance <= 5 km |
| Ranking | Weighted Scoring: 24% Evidence, 16% Verified Experience, 40% Distance, 10% Completion, 10% Similar Disaster Experience |
| Fairness | Near-tie <= 0,02 → Selection Count lebih rendah |
| Tie-Break | Distance → Competency → Selection Count → fallback |
| Alarm | 30 detik per batch; Jendela Respons Lanjutan total 5 menit |
| Batch | Batch 1 = kebutuhan; Batch 2 = sisa kebutuhan; Batch 3+ = 2x, 4x, 8x sisa kebutuhan |
| Penyelesaian Bencana | Collective Confirmation oleh pelapor + relawan tercatat; threshold berdasarkan jumlah orang |
| Update Riwayat | Dilakukan setelah bencana berstatus Selesai |

Semua angka bobot, radius 5 km, near-tie 0,02, timeout 30 detik, Jendela Respons Lanjutan 5 menit, dan threshold collective confirmation di atas adalah parameter desain MVP yang dipilih untuk implementasi/prototipe dan bisa dievaluasi ulang setelah pengujian. Mekanisme kombinasi laporan manusia dan hasil ekstraksi AI untuk menentukan kondisi, jenis kebutuhan, dan jumlah relawan masih perlu dirancang di bagian sistem ekstraksi/identifikasi kebutuhan; kategori bencana dan mapping kebutuhan juga belum dibahas.

---

## 5. UI/UX Spec

### 5.1 Autentikasi

**Register** — halaman pertama pengguna baru. Field: nama lengkap, nomor HP, password. Verifikasi nomor HP via OTP (disimulasikan untuk MVP).

**Login** — field: nomor HP, password. Setelah berhasil, langsung masuk sebagai Pengguna Terdaftar dengan role dasar Pelapor (FR-1.1, FR-1.2).

### 5.2 Dashboard

Dashboard Relawan adalah superset dari dashboard Pelapor: semua elemen Pelapor tetap ada, ditambah satu widget khusus relawan.

**Dashboard Pelapor**: widget peta ringkas (preview, tap untuk buka peta penuh); widget "laporan sekitar" (detail Section 5.7); tombol ke Profile; tombol ke Peta penuh; tombol tambah laporan; widget tambahan lain belum diputuskan.

**Dashboard Relawan** (tambahan): widget "permintaan relawan" — daftar notifikasi/alarm yang masuk, menunggu direspons.

### 5.3 Profile

**Profile Pelapor**: nama; nomor HP terdaftar; opsi "jadi relawan" (jika belum aktif); info trust factor ditampilkan (perhitungan skornya di Section 2.9/4, tampilan persis menyusul).

**Profile Relawan** (tambahan di atas Pelapor): status relawan aktif/nonaktif (toggle, nonaktifkan = berhenti menerima permintaan sementara, FR-1.6); daftar skill (chip, tambah/hapus); statistik hitungan tiap skill yang pernah dibutuhkan pada bencana yang diambil; jumlah bencana yang sudah dipartisipasi; completion rate (selesai tanpa AFK dibanding selesai di lokasi).

Catatan: radius jangkauan **bukan** atribut yang di-declare relawan di profile; dihitung otomatis sebagai faktor skor jarak saat matching (Section 4.3).

### 5.4 Peta

Peta scrollable, mendukung pinch zoom/widen. Icon menandai tiap laporan bencana aktif. Tap icon → detail: deskripsi laporan, durasi sejak pertama dilaporkan. Tap icon juga menampilkan tombol konfirmasi "saya melihat kejadian ini" (mengisi FR-2.7/FR-8.4, verifikasi kolektif komunitas). Tombol kontak instansi resmi tersedia dari detail icon ini juga (Section 5.6).

Khusus sisi Relawan: tap icon juga menampilkan opsi "partisipasi sebagai relawan" untuk laporan yang belum ia tangani.

### 5.5 Alur Lapor Bencana

1. Text area deskripsi bebas, dengan indikator dictation (fitur dictation bawaan keyboard OS, bukan speech-to-text custom).
2. Opsi alternatif: isi form terstruktur langsung, skip teks bebas.
3. Field lokasi terpisah sejak awal (**bukan** hasil ekstraksi AI), otomatis via GPS atau diset manual di peta.
4. Setelah teks disubmit: satu kali panggilan LLM → mengekstrak `jenis_kejadian`, `kondisi_akses`, `kebutuhan_dinyatakan`.
5. Tiap field hasil ekstraksi disertai cuplikan teks asli sebagai bukti dan skor confidence; field tanpa bukti pendukung ditampilkan "belum diketahui", tidak dikarang.
6. Hasil ekstraksi ditampilkan sebagai form terstruktur untuk dikonfirmasi/dikoreksi pelapor sebelum submit final.
7. Setelah submit final: masuk ke status page (Section 5.6).

### 5.6 Status Bencana — Sisi Pelapor

- Floating button kontak instansi resmi: selalu tampil sejak mulai lapor → sudah lapor → menunggu relawan, tidak pernah hilang selama laporan masih aktif. Sistem menyarankan instansi paling relevan & urgent (mis. kebakaran di Jakarta → 112), tombol Call langsung buka dialer; opsi lihat instansi lain di luar saran utama.
- Jumlah total relawan yang sedang dihubungi/menawarkan bantuan.
- Widget scrollable: daftar relawan yang menerima (nama, status otw/sampai/dst., jarak dalam angka), tap untuk lihat di peta (redirect ke peta, menunjukkan titik lokasi relawan tersebut).
- Jumlah user lain yang sudah konfirmasi "melihat kejadian ini" (dari Section 5.4/5.7) — tampilan informasi saja.

### 5.7 Widget Laporan Sekitar

Muncul di dashboard Pelapor maupun Relawan. Radius bisa dikonfigurasi pengguna (mis. 1 km, 3 km, 5 km). Dua section terpisah:

1. Laporan yang masuk radius dan dinotifikasi ke pengguna ini.
2. Laporan umum di sekitar (general, tidak terikat radius notifikasi).

Tap notifikasi ATAU tap item di widget → popup konfirmasi "saya melihat kejadian ini juga". Konfirmasi ini **murni tampilan** (menunjukkan berapa orang sudah konfirmasi); tidak memengaruhi trust score sistem — trust score tetap murni dari hasil konfirmasi pasca-tugas (FR-7.3).

### 5.8 Onboarding Jadi Relawan

Bisa diaktifkan langsung saat registrasi (opsional), atau kapan pun setelahnya dari Profile. Input skill sebagai chip/label, ikon plus untuk menambah, tap chip untuk menghapus. Ketersediaan diatur lewat toggle status relawan di Profile/setting (nonaktifkan = berhenti menerima permintaan sementara, tanpa menghapus profil relawan). Radius jangkauan **tidak** diminta di sini, sistem menghitung jarak otomatis saat matching. Setelah aktif jadi relawan: popup izin notifikasi (untuk alarm dan permintaan relawan) muncul di dashboard.

### 5.9 Alarm dan Notifikasi Relawan

**Alarm** (batch prioritas tinggi, FR-5.6): notifikasi dengan suara khas, beda dari notifikasi biasa. Tap notifikasi → redirect ke dashboard dengan popup deskripsi bencana, menunjukkan skill mana dari relawan yang cocok untuk kasus ini. Tombol Accept / Deny:
- Deny: tetap tersimpan di "daftar permintaan", bisa di-accept ulang kapan saja selama status kebutuhan belum "tertangani penuh".
- Accept: koordinat live relawan langsung dibagikan ke aplikasi untuk tracking, relawan masuk ke halaman status tugas aktif (Section 5.10).

**Notifikasi standar** (batch berikutnya, FR-5.7/5.8): sama seperti alarm tapi tanpa suara khas. Relawan bisa langsung Accept proaktif kapan saja, tidak perlu menunggu gilirannya kena alarm. Tetap masuk "daftar permintaan" jika belum direspons.

### 5.10 Halaman Tugas Aktif Relawan

Tombol ganti status: masih di jalan / sudah sampai / sudah teratasi. "Sudah teratasi" adalah trigger yang **sama** dengan vote di popup periodik (Section 5.11); begitu ditekan di sini, popup tidak muncul lagi ke relawan tersebut. Tombol tunjukkan lokasi bencana membuka aplikasi maps di perangkat (redirect keluar aplikasi, bukan peta internal). Keterangan: relawan ke berapa untuk kebutuhan ini (mis. "relawan ke-3"), dan skill apa yang ia penuhi.

### 5.11 Mekanisme Konfirmasi Selesai (UI)

Berlaku untuk pelapor maupun relawan yang terlibat di satu laporan. Jawaban atas mekanisme crowd-confirm yang menggantikan peran koordinator (FR-7.2/7.3).

- Mulai dari relawan pertama sampai lokasi, popup binary muncul periodik: "Apakah bencana ini sudah teratasi?" — Ya / Belum.
- Menekan "sudah teratasi" di halaman tugas (Section 5.10) terhitung sebagai vote yang sama, popup berhenti muncul ke orang itu.
- Tidak menekan sama sekali dalam satu periode waktu → orang tersebut dirender **AFK** dan **dikeluarkan** dari populasi kuorum (bukan dihitung sebagai bagian pembagi maupun sebagai "tidak setuju").
- Kuorum penyelesaian, dihitung dari partisipan aktif (bukan AFK):
  - Populasi aktif < 4 orang: minimal 3 orang harus menyatakan selesai.
  - Populasi aktif ≥ 4 orang: minimal 50% harus menyatakan selesai.
- Batas waktu maksimum: 24 jam sejak pertama dilaporkan → status otomatis jadi selesai.

> Lihat catatan di Section 4.13: kuorum UI ini (3 orang / 50%) berbeda dari tabel threshold proporsional T(N) di spek algoritma — selaraskan sebelum implementasi.

### 5.12 Catatan UI — Sudah Dikunci

- Lokasi adalah field terpisah sejak awal, bukan hasil ekstraksi LLM.
- Radius jangkauan relawan dihapus dari FR-5.1, jadi cuma faktor skor jarak otomatis.
- Konfirmasi "melihat kejadian" murni tampilan, tidak memengaruhi trust score.
- "Sudah teratasi" di halaman tugas = vote yang sama dengan popup periodik.

### 5.13 Masih Perlu Diselaraskan Tim (di luar cakupan UI/UX Spec)

- Arsitektur final: Capacitor vs React Native.
- Siapa yang memegang backend, dan pilihan framework/hosting-nya.
- Mekanisme update status: socket vs polling.
- Statistik profile relawan (skill bincount, completion rate): MVP wajib atau stretch goal?
- Sistem kredibilitas/trust score: dikerjakan terpisah oleh anggota tim lain.

---

## 6. Prioritas Implementasi (MoSCoW Kasar)

- **Must**: Section 2.1, 2.2 (FR-2, kecuali FR-2.4 jika waktu mepet), 2.3 (FR-3, kecuali FR-3.6), 2.4 (FR-4, kecuali FR-4.4), 2.5 (FR-5), 2.6 (FR-6), 2.8 (FR-8), 2.9 (FR-9).
- **Ditahan sampai Open Item #2 selesai**: Section 2.7 (FR-7.2, FR-7.3) — **jangan mulai coding sebelum mekanisme crowd-confirm diputuskan**.
- **Should/Could (stretch goal)**: FR-3.6 & FR-4.4 (konteks lokasi AI), FR-2.4 (lokasi manual, tergantung Open Item #1), Section 2.10 (kontak instansi resmi) jika waktu memungkinkan setelah pipeline inti jalan.

---

## 7. Open Items (Belum Diputuskan)

1. **Provider geocoding untuk pencarian lokasi manual** (FR-2.4) — forward geocoding beda kebutuhan dari reverse geocoding yang sudah dipilih (Nominatim). Opsi: Google Places Autocomplete (akurat, berbayar) vs Nominatim (gratis, kurang presisi untuk alamat informal Indonesia seperti gang/RT/RW).
2. **Mekanisme crowd-confirm status "selesai"** (FR-7.2/7.3) — siapa yang berhak konfirmasi, berapa banyak dibutuhkan, cara menangani konflik jawaban. **Prioritas tertinggi**, memblokir implementasi Section 2.7 dan basis trust score di Section 2.9. Catatan: dua sumber (Section 4.13 dan Section 5.11 dokumen ini) memberi formula kuorum yang belum identik dan perlu disatukan.
3. **Angka/aturan jumlah relawan dibutuhkan per tipe kasus** (FR-4.3) — tanggung jawab tuning rule-based/AI tim, bukan sesuatu yang ditentukan di tahap perencanaan.
4. **Data referensi lembaga resmi per wilayah & jenis kejadian** (FR-10.1) — kemungkinan dikurasi manual untuk 1 skenario kebakaran area Jakarta saja, bukan database nasional lengkap.
5. **Siapa yang bisa akses fitur kontak instansi resmi** (Section 2.10) — hanya saat pelapor lapor, hanya relawan yang menerima tugas, atau keduanya kapan saja.
6. Target waktu ekstraksi AI (asumsi awal 5 detik, NFR-1).
7. Rumus & bobot skor kecocokan kandidat (FR-5.2) dan cara normalisasinya — *sebagian sudah dijawab oleh Section 4 dokumen algoritma; verifikasi bahwa versi itu final.*
8. Nilai ambang skor minimum untuk masuk top X (FR-5.3).
9. Batas maksimal X (total kandidat top X).
10. Durasi timeout eskalasi per batch (saran awal 60–90 detik, perlu divalidasi terhadap angka 30 detik/5 menit di Section 4.10 — *kemungkinan sudah terjawab, verifikasi*).
11. Sumber data reverse-geocoding untuk FR-3.6: Google Maps vs OpenStreetMap Nominatim.
12. Ambang minimum jumlah laporan sebelum trust tier berubah dari "Akun baru".
13. Radius jangkauan lokasi (FR-5.1) dalam satuan km — *sudah terjawab di Section 4.3 sebagai 5 km hard filter; verifikasi bahwa ini final dan konsisten di semua dokumen.*
14. **Ketidaksesuaian ukuran batch**: FR-5.5/5.6 menyebut batch tetap 5 kandidat per batch; Section 4.10 mendefinisikan Batch 1 sebesar `Required Need` (jumlah kebutuhan). Perlu diputuskan mana yang final sebelum implementasi notifikasi bertingkat.

---

## 8. Catatan Traceability

- **Model peran berlapis**: "Pelapor" dan "Relawan" adalah fungsi yang bisa dijalankan bersamaan oleh satu akun, bukan dua jenis akun eksklusif.
- **Dua jenis "verifikasi" yang terpisah**: konfirmasi pelapor (FR-3.4) = kualitas data ekstraksi; konfirmasi pasca-tugas (FR-7.3) = kebenaran laporan, basis trust score.
- **Kuota multi-relawan** (FR-5.11–5.14) mengganti model lama "1 kebutuhan = 1 relawan, auto-cancel begitu ada yang terima"; sekarang tetap buka sampai kuota terpenuhi, dengan pembedaan Responden Utama vs Tenaga Tambahan.
- **Untuk sesi tanya-jawab final**: exsum yang sudah disubmit menekankan human-in-the-loop lewat koordinator. Sistem sekarang full-otomatis di titik itu, dengan verifikasi kolektif komunitas menggantikan verifikasi tunggal koordinator. Siapkan penjelasan singkat soal ini untuk PERUBAHAN.md dan Q&A.
