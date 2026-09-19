# Perubahan dari Executive Summary

Executive summary yang kami kirim sebelumnya menempatkan **koordinator manusia** sebagai
*human-in-the-loop*: koordinator memverifikasi hasil AI, memilih relawan, dan menutup kejadian.
Di versi final, peran koordinator **dihapus**. Verifikasinya tidak hilang, tapi dipindahkan
ke orang-orang yang paling dekat dengan kejadian.

## Apa yang berubah

| Sebelumnya (koordinator) | Sekarang |
|---|---|
| Koordinator memeriksa hasil ekstraksi AI | **Pelapor sendiri** memeriksa dan mengoreksi ringkasan AI sebelum relawan dihubungi. Setiap field wajib punya cuplikan bukti dari teks asli; yang tanpa bukti ditulis "belum diketahui". |
| Koordinator memilih relawan | **Skor prioritas transparan** (jarak 40%, bukti kompetensi 24%, pengalaman terverifikasi 16%, riwayat penyelesaian 10%, pengalaman bencana serupa 10%) + aturan fairness, lalu **alarm bertingkat** ke kandidat teratas. |
| 1 kebutuhan = 1 relawan | Satu kebutuhan bisa diisi beberapa relawan: **Bantuan Utama** dan **Bantuan Tambahan**, sesuai kuota. |
| Koordinator menyatakan kejadian selesai | **Konfirmasi selesai bersama** oleh pelapor dan semua relawan yang terlibat, dengan ambang yang mengecil proporsional terhadap jumlah orang. Tidak pernah dari satu sumber saja. Orang yang tidak merespons (AFK) dikeluarkan dari hitungan, dan ada batas otomatis 24 jam. |
| Kontak instansi resmi hanya dicatat | Tombol **Call** langsung ke instansi yang disarankan (mis. 112 untuk kebakaran di Jakarta), tanpa menganggap instansi sudah menangani. |
| Akun pelapor dan relawan terpisah | **Satu akun**. Status relawan adalah lapisan opsional yang bisa dinyalakan/dimatikan. |

## Kenapa

1. **Kecepatan.** Pada kebakaran permukiman, menit pertama paling menentukan. Antrean menunggu koordinator
   menjadi titik lambat dan titik gagal tunggal (koordinator tidur, sibuk, atau kewalahan saat banyak laporan).  
2. **Yang paling tahu adalah yang di lokasi.** Pelapor paling tahu apakah ringkasan AI sesuai ceritanya.
   Relawan dan pelapor di lapangan paling tahu apakah api sudah padam.
3. **Lebih sulit disalahgunakan.** Keputusan "selesai" dari satu orang, baik koordinator maupun relawan, rawan
   human error dan manipulasi. Konfirmasi kolektif dengan ambang minimal dua sumber mengurangi risiko itu.
4. **Skalabel tanpa menambah staf.** Sistem tetap berjalan saat laporan bertambah banyak.

## Pengaman yang menggantikan koordinator

- **AI tidak pernah bekerja sendirian:** hasil ekstraksi selalu dikonfirmasi pelapor (FR-3.4/3.5). Jika AI lambat
  atau mati, sistem memakai ekstraksi berbasis aturan sehingga laporan tidak pernah terblokir (NFR-9/10).
- **Relawan tetap memilih:** alarm hanya undangan. Relawan bebas menerima atau menolak, dan penolakan tidak
  mengganggu kandidat lain.
- **Pelapor tetap memegang kendali:** pelapor bisa melepas relawan dari laporannya.
- **Kredibilitas pelapor:** setelah kejadian selesai, relawan menilai apakah kondisi lapangan sesuai laporan.
  Hasilnya menjadi *trust tier* pelapor (Akun baru / Riwayat akurasi rendah / Riwayat baik) yang ditampilkan
  ke relawan sebelum mereka menerima tugas.
- **Semua ambang bisa diatur** (`app_config`) tanpa mengubah kode, jika hasil uji lapangan menunjukkan perlu disesuaikan.

Ringkasnya: koordinator tunggal diganti oleh **verifikasi berlapis**, yaitu pelapor untuk kualitas data,
skor transparan untuk pemilihan relawan, dan komunitas yang terlibat untuk status selesai.

---

# Entri Perubahan (Format Ketentuan Panitia Poin 4)

> Dibandingkan langsung antara teks *executive summary* yang disubmit di babak penyisihan dan `FITUR_DOKUMENTASI.md` (disusun dari pembacaan kode sumber). Bagian di atas ini adalah catatan naratif tim tentang penghapusan peran koordinator; entri di bawah memformalkan **seluruh** perbedaan yang ditemukan — termasuk yang sudah disinggung di atas — ke format wajib panitia, plus perbedaan lain yang belum tercatat di narasi sebelumnya. Tidak ada entri untuk bagian exsum yang implementasinya sudah sesuai.

## 1. Platform aplikasi

- **Kondisi di proposal:** "ReliefSync dirancang sebagai aplikasi web dengan tiga peran: pelapor menyampaikan kejadian, koordinator memeriksa kebutuhan dan menyetujui tugas, serta penolong terdaftar mengonfirmasi ketersediaan dan memperbarui status."
- **Hal yang diubah:** Dibangun sebagai aplikasi **mobile (Flutter, Android)**, bukan aplikasi web. Seluruh alur (lapor, terima alarm, update status perjalanan, konfirmasi) dirancang di sekitar kemampuan perangkat mobile: kamera untuk foto, GPS untuk lokasi & tracking relawan live, dan push notification (FCM) untuk alarm layar-penuh saat aplikasi tertutup.
- **Alasan perubahan:** PERLU DIISI TIM (tidak ada catatan eksplisit di kode/dokumentasi soal kapan/kenapa keputusan platform berubah dari web ke mobile).
- **Dampak terhadap masalah inti:** Netral-ke-positif untuk masalah inti (struktur akuntabilitas kebutuhan-ke-relawan) — perpindahan platform tidak mengubah model data/alur kerja, tapi alarm push & GPS live di mobile justru memperkuat kecepatan penugasan darurat dibanding web. Risiko: klaim "aplikasi web" di proposal tidak lagi akurat untuk deskripsi produk ke penilai/pengguna baru.

## 2. Peran koordinator dihapus dari seluruh alur (verifikasi, persetujuan kandidat, tinjauan penyelesaian)

- **Kondisi di proposal:** Tiga peran pengguna eksplisit — pelapor, **koordinator** (memeriksa/mengoreksi hasil ekstraksi AI, mencatat dasar verifikasi, menyetujui kandidat sebelum ditawari tugas, meninjau penyelesaian dan kebutuhan terbuka), dan penolong terdaftar. MVP disebut dibatasi pada "tiga peran pengguna".
- **Hal yang diubah:** Peran koordinator **dihapus sepenuhnya**. Verifikasi hasil AI dipindah ke pelapor sendiri (wajib dikonfirmasi sebelum relawan dihubungi). Persetujuan kandidat dihapus — sistem otomatis mengirim alarm bertingkat ke kandidat teratas berdasar skor tanpa gerbang persetujuan manusia. Tinjauan penyelesaian diganti konfirmasi kolektif (kuorum) oleh pelapor + semua relawan terlibat, bukan keputusan satu koordinator. Hasilnya cuma **satu akun** dengan lapisan relawan opsional (bukan 3 jenis peran/akun terpisah).
- **Alasan perubahan:** Didokumentasikan eksplisit di bagian atas file ini ("Kenapa"): kecepatan (koordinator jadi titik lambat/gagal tunggal saat kebakaran), pihak paling tahu kondisi adalah yang di lokasi (bukan koordinator jarak jauh), keputusan satu-orang rawan disalahgunakan, dan sistem perlu skalabel tanpa menambah staf koordinator.
- **Dampak terhadap masalah inti:** Berubah signifikan namun *diklaim* tetap menjawab masalah inti (struktur pertanggungjawaban) — verifikasi tidak hilang, hanya berpindah dari satu koordinator ke verifikasi berlapis (pelapor + skor transparan + komunitas). Risiko yang perlu diakui ke penilai: proposal awal menjadikan koordinator sebagai *satu-satunya* pemegang akuntabilitas eksplisit ("siapa yang bertanggung jawab atas apa" adalah akar masalah yang diangkat exsum) — menghapusnya berarti akuntabilitas kini implisit/terdistribusi (skor algoritmik + kuorum komunitas), bukan lagi satu peran manusia yang bisa dimintai pertanggungjawaban langsung.

## 3. Verifikasi berbasis bukti/cuplikan teks asli (evidence-anchoring) tidak lagi berfungsi

- **Kondisi di proposal:** "Setiap keluaran disertai cuplikan pendukung dari teks asli. Kolom tanpa bukti diisi belum diketahui." — dijanjikan sebagai mekanisme inti supaya koordinator (kini pelapor) bisa memverifikasi tiap field ekstraksi AI terhadap kutipan asli laporan.
- **Hal yang diubah:** Field `evidence` (kutipan) di setiap hasil ekstraksi kini **selalu `None`** dan `confidence` **selalu biner 0.0/1.0** (bukan skor bertingkat) — diverifikasi langsung di kode backend (`reports.py:257-286`). Layar konfirmasi di aplikasi masih punya UI untuk menampilkan "Bukti dari teks: ..." dan "Keyakinan XX%", tapi kontennya tidak pernah benar-benar terisi lagi — sisa dari skema ekstraksi versi lama yang sudah diganti total.
- **Alasan perubahan:** Terdokumentasi eksplisit sebagai keputusan sengaja tim (`docs/spec-vs-implementation-alignment.md:12,49`): mekanisme evidence-anchoring lama (FR-3.2/3.3 di spesifikasi internal tim) sengaja dihapus saat ekstraksi diganti total ke pendekatan LLM berbasis katalog skill — judul/deskripsi kini ringkasan buatan LLM, bukan lagi potongan teks yang diekstrak-dengan-bukti.
- **Dampak terhadap masalah inti:** Melemahkan salah satu jaminan kualitas data yang dijanjikan exsum untuk tahap "Penataan dan verifikasi". Pelapor tetap bisa mengoreksi field secara manual (jaminan alur kerja tetap ada), tapi tanpa cuplikan bukti otomatis, koreksi jadi murni mengandalkan ingatan/kejujuran pelapor, bukan dibantu tampilan bukti tekstual seperti dijanjikan — mengurangi kekuatan argumen "AI diverifikasi manusia berbasis bukti" di proposal.

## 4. Identifikasi kebutuhan: dari "aturan terbatas yang ditinjau praktisi" menjadi AI yang langsung mengusulkan jumlah personel

- **Kondisi di proposal:** "Rekomendasi kebutuhan memakai daftar aturan terbatas untuk skenario kebakaran yang harus ditinjau praktisi sebelum uji lapangan. AI tidak membuat SOP baru, **menentukan jumlah personel secara mandiri**, atau mengesahkan kompetensi."
- **Hal yang diubah:** AI (Groq LLM) kini **langsung mengusulkan angka kuota (jumlah personel) per skill** dalam satu panggilan yang sama dengan ekstraksi, bukan sekadar memetakan ke kategori kemampuan lewat aturan tetap. Sistem menambahkan *hard floor* deterministik dari jumlah korban yang disebutkan (bukan diserahkan penuh ke penilaian AI), tapi angka awal yang diajukan tetap keluaran AI, bukan aturan statis. Tidak ditemukan bukti "ditinjau praktisi" di kode/dokumentasi manapun.
- **Alasan perubahan:** PERLU DIISI TIM untuk soal "ditinjau praktisi". Untuk pergeseran ke AI-menentukan-kuota: terdokumentasi sebagai perbaikan atas bug nyata (`docs/extraction-tuning-report.md` baris 68-84) — kasus "5 orang bahaya jatuh dari genteng" awalnya menghasilkan kuota 1, diperbaiki dengan menjadikan jumlah korban sebagai *hard floor* eksplisit di kode Python, bukan permintaan tekstual ke model.
- **Dampak terhadap masalah inti:** Berpotensi memperkuat penyelesaian masalah inti (kebutuhan tanpa penanggung jawab karena salah taksir jumlah relawan) — floor deterministik mengurangi risiko under-provisioning yang lebih berbahaya untuk aplikasi tanggap bencana. Tapi ini bertentangan literal dengan klaim eksplisit exsum bahwa "AI tidak menentukan jumlah personel secara mandiri" — klaim itu tidak lagi akurat untuk versi final.

## 5. Jumlah korban (`victim_count`) tidak ditampilkan sebagai field yang bisa dikonfirmasi pelapor

- **Kondisi di proposal:** "AI menampilkan informasi yang benar-benar disebutkan dan menandai jumlah korban sebagai belum diketahui apabila tidak tersedia" — mengisyaratkan jumlah korban adalah salah satu field yang ditampilkan eksplisit ke koordinator/pelapor untuk diperiksa, sama seperti field lain.
- **Hal yang diubah:** `victim_count` diekstrak AI dan disimpan, tapi **hanya dipakai secara internal** untuk menghitung floor kuota kebutuhan — bukan salah satu dari field yang ditampilkan sebagai kartu yang bisa diedit di layar konfirmasi (hanya `title` dan `description` yang ditampilkan sebagai field, diverifikasi dari `extraction.FIELDS = ["title", "description"]`). Pelapor tidak pernah melihat atau mengoreksi angka jumlah korban yang "dipahami" sistem secara eksplisit.
- **Alasan perubahan:** PERLU DIISI TIM.
- **Dampak terhadap masalah inti:** Berisiko kecil terhadap masalah inti — kalau AI salah menaksir jumlah korban dari teks, pelapor tidak diberi kesempatan mengoreksinya secara langsung (hanya bisa terlihat tidak langsung lewat kuota kebutuhan yang dihasilkan), berbeda dari janji transparansi "AI menampilkan informasi yang benar-benar disebutkan" yang mengesankan tiap fakta terekstrak diperlihatkan untuk diverifikasi.

## 6. Alasan rekomendasi kandidat tidak ditampilkan ke pengguna

- **Kondisi di proposal:** "Sistem menyaring kandidat yang memenuhi syarat, tersedia, dan berada dalam cakupan; **alasan rekomendasi ditampilkan**." (ke koordinator, sebelum menyetujui kandidat)
- **Hal yang diubah:** Breakdown skor komponen (bukti kompetensi, pengalaman terverifikasi, jarak, riwayat penyelesaian, pengalaman bencana serupa) hanya tersedia lewat satu endpoint **debug/admin** (`GET /needs/{need_id}/candidates`), bukan ditampilkan ke pengguna dalam alur normal. Karena peran koordinator sudah dihapus (lihat entri #2), memang tidak ada lagi pihak yang secara desain seharusnya melihat breakdown ini sebelum kandidat dihubungi — proses jadi sepenuhnya otomatis tanpa tampilan alasan ke siapa pun di alur utama.
- **Alasan perubahan:** PERLU DIISI TIM (kemungkinan konsekuensi langsung dari penghapusan koordinator di entri #2, tapi tidak ada catatan eksplisit yang mengaitkan keduanya).
- **Dampak terhadap masalah inti:** Mengurangi transparansi yang dijanjikan proposal untuk tahap pencocokan. Skor tetap dihitung dan dipakai (jadi pencocokan tetap "bisa dijelaskan" secara teknis), tapi tidak ada lagi pihak manusia dalam alur normal yang benar-benar melihat alasan itu sebelum penugasan terjadi.

## 7. Cakupan jenis kejadian melebihi batas MVP yang dijanjikan

- **Kondisi di proposal:** "Ruang lingkup awal dibatasi pada koordinasi dukungan komunitas dalam satu skenario kebakaran permukiman" (diulang beberapa kali, termasuk di bagian Kelayakan MVP: "satu skenario kebakaran permukiman ... penanganan banyak jenis bencana berada di luar MVP").
- **Hal yang diubah:** Implementasi final mendukung **7 kategori jenis kejadian**: kebakaran, banjir, longsor, bangunan_roboh, kecelakaan, akses_terputus, lainnya — bukan hanya skenario kebakaran permukiman tunggal seperti dijanjikan. (Catatan terkait: kategori "gempa bumi" yang muncul di beberapa contoh sektor bencana pada proposal justru **tidak ada** di 7 kategori ini — lihat `FITUR_DOKUMENTASI.md` bagian 3.)
- **Alasan perubahan:** PERLU DIISI TIM.
- **Dampak terhadap masalah inti:** Ini adalah **perluasan cakupan melampaui janji**, bukan pengurangan — berpotensi positif untuk generalisasi solusi, tapi berarti klaim "MVP dibatasi satu skenario" di proposal (dipakai untuk membenarkan validitas evaluasi terbatas) tidak lagi menggambarkan cakupan aktual sistem yang dibangun.

## 8. Pelacakan GPS langsung diimplementasikan meski dinyatakan di luar MVP

- **Kondisi di proposal:** "Integrasi langsung 112, PetaBencana, dan WhatsApp, **pelacakan GPS langsung**, serta penanganan banyak jenis bencana berada di luar MVP."
- **Hal yang diubah:** Pelacakan lokasi relawan **live** justru diimplementasikan penuh — dua mekanisme berjalan bersamaan (heartbeat tetap tiap 30 detik + update berbasis perubahan jarak 15 meter), ditampilkan sebagai posisi bergerak tiap relawan di peta status laporan milik pelapor.
- **Alasan perubahan:** PERLU DIISI TIM.
- **Dampak terhadap masalah inti:** Positif untuk masalah inti (pemantauan status/pertanggungjawaban) — pelacakan live justru memperkuat traceability yang jadi inti masalah yang diangkat proposal (tahu siapa mengerjakan apa dan sejauh mana progresnya). Tapi sekali lagi ini kontradiksi literal dengan batasan MVP yang dinyatakan eksplisit di proposal.

## 9. Kosakata status berbeda dari yang dijanjikan, dan tidak ada status "batal" yang setara

- **Kondisi di proposal:** "Status ditampilkan sebagai **ditawarkan, diterima, dikerjakan, selesai, atau batal**. Koordinator meninjau penyelesaian dan kebutuhan yang masih terbuka."
- **Hal yang diubah:** Status tersebar di beberapa entitas dengan istilah berbeda dari proposal — `Report.status` (draft/active/resolved), `Need.status` (belum_ada/sebagian/penuh/selesai), `Assignment.status` (aktif/selesai/dilepas), status tawaran (pending/accepted/rejected). **Tidak ada status "batal" yang eksplisit dan setara** untuk laporan maupun kebutuhan — yang paling dekat adalah "dilepas" (assignment relawan tertentu dilepas pelapor), bukan pembatalan laporan/kebutuhan secara keseluruhan. Tinjauan status juga bukan lagi oleh koordinator (lihat entri #2) melainkan otomatis via kuorum.
- **Alasan perubahan:** PERLU DIISI TIM.
- **Dampak terhadap masalah inti:** Netral secara fungsional (status tetap tercatat dan bisa ditelusuri, memenuhi kebutuhan inti "status harus eksplisit"), tapi model status yang lebih terfragmentasi (per-entitas, bukan satu status tunggal per tugas seperti dijanjikan) berarti dokumentasi/pelatihan pengguna baru perlu disesuaikan dari yang dijanjikan di proposal.

## 10. Metodologi evaluasi yang direncanakan tidak dijalankan seperti dijanjikan

- **Kondisi di proposal:** "Evaluasi direncanakan pada 30 laporan simulasi berlabel dan enam skenario koordinasi. Bandingkan dua kondisi: pesan grup dengan lembar kerja dan ReliefSync. Gunakan tiga sampai lima calon koordinator... Ambang awal yang diusulkan adalah ketepatan ekstraksi sekurang-kurangnya 90% pada kolom yang memang terisi dalam acuan, tanpa pelanggaran syarat kelayakan pada seluruh kasus uji, dan seluruh transisi tugas tercatat."
- **Hal yang diubah:** Tidak ditemukan bukti evaluasi formal 30-laporan-berlabel/6-skenario/3-5-calon-koordinator maupun pengukuran ambang akurasi ≥90% di kode atau dokumentasi manapun. Yang ada adalah `backend/scripts/tune_extraction.py`, harness manual dengan 16-17 kasus uji per-kasus (bukan bagian dari test suite otomatis), berfokus pada pemeriksaan kualitatif tiap guardrail (mis. "apakah skill tidak diwariskan otomatis", "apakah gibberish ditolak") — bukan pengukuran skor akurasi persentase per kolom seperti dijanjikan. Uji banding terhadap "calon koordinator" juga sudah tidak relevan sejak peran koordinator dihapus (entri #2).
- **Alasan perubahan:** PERLU DIISI TIM.
- **Dampak terhadap masalah inti:** Melemahkan kekuatan bukti empiris yang dijanjikan proposal untuk mendukung klaim efektivitas solusi. Pengujian kualitatif yang ada tetap berguna (menemukan dan memperbaiki bug nyata, misalnya kuota tidak skala dengan jumlah korban), tapi tidak memenuhi kriteria penerimaan kuantitatif (≥90% akurasi, nol pelanggaran syarat kelayakan di seluruh kasus uji) yang secara eksplisit dijanjikan sebagai tolok ukur MVP.

## 11. Cross-skill credit pada pencocokan relawan — fitur baru, tidak disebut di proposal

- **Kondisi di proposal:** Tidak disebutkan sama sekali. Proposal hanya membicarakan "kandidat" secara umum dan "satu kebutuhan bisa diisi beberapa relawan" (Bantuan Utama/Tambahan, sudah tercatat di tabel atas).
- **Hal yang diubah:** Relawan yang diterima di satu kebutuhan, jika kebetulan punya skill lain yang juga dibutuhkan kebutuhan lain di laporan yang sama, otomatis "dikreditkan" ke kebutuhan itu tanpa alarm/tawaran terpisah — satu relawan bisa menutup dua kebutuhan sekaligus.
- **Alasan perubahan:** PERLU DIISI TIM.
- **Dampak terhadap masalah inti:** Positif untuk masalah inti — mengurangi risiko "kebutuhan tanpa penanggung jawab" dan mempercepat pemenuhan kebutuhan dengan relawan terbatas, konsisten dengan tujuan proposal soal ketertelusuran penanggung jawab (kredit tetap tercatat by-name, bukan tersembunyi).

## 12. Sistem kredibilitas (trust pelapor & trust verifikator) — fitur baru, tidak disebut di proposal

- **Kondisi di proposal:** Tidak disebutkan sama sekali. Proposal hanya bicara soal "penyaringan kandidat" berbasis kapasitas/ketersediaan yang terdaftar, tidak ada konsep riwayat akurasi atau skor kepercayaan berjalan waktu untuk pelapor maupun penolong.
- **Hal yang diubah:** Ditambahkan dua sistem skor independen: **trust pelapor** (3 tingkat, dari riwayat kesesuaian laporan dengan kondisi lapangan) dan **trust verifikator** (5 tingkat, poin akumulatif dari akurasi konfirmasi "saya melihat kejadian ini"), ditampilkan sebagai badge di profil dan di setiap tempat identitas pelapor terlihat pengguna lain.
- **Alasan perubahan:** PERLU DIISI TIM.
- **Dampak terhadap masalah inti:** Positif dan relevan langsung ke masalah inti — proposal secara eksplisit menyebut "penugasan ganda dan kebutuhan tanpa penanggung jawab sulit terdeteksi" sebagai akar masalah; sistem kredibilitas menambah lapisan akuntabilitas historis (siapa yang laporannya/konfirmasinya bisa dipercaya) yang tidak ada sama sekali di proposal awal, memperkuat argumen "struktur pertanggungjawaban komunitas" yang jadi tujuan utama produk.

## 13. Verifikasi komunitas via "saya melihat kejadian ini" (crowd sighting) — fitur baru, tidak disebut di proposal

- **Kondisi di proposal:** Tidak disebutkan. Proposal hanya bicara notifikasi kepada penolong terdaftar untuk tugas, tidak ada mekanisme melibatkan warga/pengguna umum di sekitar lokasi untuk mengonfirmasi keberadaan kejadian.
- **Hal yang diubah:** Ditambahkan notifikasi terpisah ke semua pengguna (relawan atau bukan) dalam radius tertentu dari lokasi kejadian, mengajak konfirmasi "Apakah Anda melihat kejadian ini?" — hasilnya jadi input untuk sistem trust verifikator (entri #12) dan ditampilkan sebagai jumlah "warga melihat kejadian" di status laporan.
- **Alasan perubahan:** PERLU DIISI TIM.
- **Dampak terhadap masalah inti:** Tidak berkaitan langsung dengan masalah inti (kebutuhan-vs-kapasitas relawan), tapi menambah sinyal verifikasi independen dari komunitas sekitar — mendukung tema besar produk soal "verifikasi berlapis" yang disebut di narasi atas dokumen ini.

## 14. Panel admin/konfigurasi runtime tanpa pengecekan peran — fitur baru, tidak disebut di proposal

- **Kondisi di proposal:** Tidak disebutkan. Proposal tidak membicarakan kebutuhan panel konfigurasi teknis apa pun untuk parameter matching/kuorum.
- **Hal yang diubah:** Ditambahkan endpoint untuk melihat & mengubah ~25 parameter sistem (bobot skor matching, radius, ambang kuorum, durasi alarm, dst) saat runtime tanpa deploy ulang. Endpoint pengubahan (`PUT /config/{key}`) **tidak punya pengecekan role admin** — hanya butuh login biasa, sehingga secara teknis setiap pengguna yang login bisa mengubah parameter inti sistem.
- **Alasan perubahan:** PERLU DIISI TIM — perlu dikonfirmasi apakah tidak adanya role-check ini disengaja untuk kebutuhan demo tertutup (semua akun "terpercaya") atau memang celah yang belum sempat ditambal.
- **Dampak terhadap masalah inti:** Netral terhadap masalah inti secara fungsional (mempercepat iterasi tim, bukan bagian dari pengalaman pengguna akhir), tapi absennya pengecekan role adalah risiko keamanan nyata yang perlu diungkap ke penilai jika sistem ini dianggap siap diuji lebih luas di luar tim sendiri.

---

**Catatan penutup:** entri di atas fokus pada perbedaan yang bisa ditelusuri balik ke teks proposal dan kode sumber secara konkret. Daftar penambahan/pengurangan fitur yang lebih lengkap (termasuk yang tidak menyentuh isi proposal secara langsung, seperti loop mesin latar belakang, simulasi data demo, dan penyimpanan foto) ada di `FITUR_DOKUMENTASI.md` bagian 11 dan 12, untuk referensi tim saat mengisi kolom "PERLU DIISI TIM" di atas.
