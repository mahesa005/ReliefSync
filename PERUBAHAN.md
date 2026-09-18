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
