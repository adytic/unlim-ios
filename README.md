# Unlim — iOS

Port iOS native (SwiftUI) dari **UnLim: Unlimited cloud storage** (Android,
`com.kratosle.unlim`) — penyimpanan cloud tanpa batas memakai **Telegram Saved
Messages** sebagai backend. File diunggah sebagai dokumen ke Saved Messages,
dipecah jadi chunk ~1,9 GB dengan caption yang sama persis dengan klien
Android/web, supaya file yang diunggah dari iOS bisa dibaca klien lain dan
sebaliknya.

> Status: **scaffold**. Belum pernah dikompilasi — tidak ada Mac di lingkungan
> pengembangan ini. Lihat [Yang belum terverifikasi](#yang-belum-terverifikasi).

## Cara kerja

- Login Telegram via TDLib (nomor telepon → kode → password 2FA, atau QR).
- **Saved Messages** adalah chat penyimpanan. Topik (My Notes dan topik
  penulis lain) dibaca lewat `getSavedMessagesTopics`, riwayat per topik lewat
  `getSavedMessagesTopicHistory` (limit ≤ 100).
- **Upload**: file dikirim sebagai `InputMessageDocument` ke Saved Messages.
  File ≥ 2.040.109.465 byte dipecah jadi chunk; chunk 0 memakai nama asli,
  chunk berikutnya `<index><nama>`; caption mengikuti protokol Android
  (`dir--<path>--/dir <chunkId>`, label `1hbas621gs` /
  `28f7sdn2gh3r`). Konfirmasi upload lewat `UpdateMessageSendSucceeded`.
- **Download**: chunk digabungkan kembali (`saveChunks`) ke
  `Documents/Unlim/<Media|Files>`.
- **Antrean**: `SyncStoreModel` dengan state `IN_QUEUE → PRE_PROCESSING →
  SYNCING → SYNCED`, disimpan sebagai JSON di Application Support — sama
  seperti SharedPreferences JSON di Android.
- **Background**: `BGProcessingTask` menjalankan drain antrean yang sama saat
  background (resubmit-first, pekerjaan dibatasi, dibatalkan saat expired).
  Tidak ada background URLSession: TDLib yang memegang socket.

## Setup

### 1. Buat kredensial Telegram sendiri

Buka https://my.telegram.org → **API development tools** → buat aplikasi →
catat `api_id` (angka) dan `api_hash`.

> **Jangan pakai api_id/api_hash milik UnLim atau orang lain.** Kredensial
> tidak pernah di-hardcode dan tidak pernah di-commit.

### 2. Isi file konfigurasi

```sh
cp TelegramConfig.example.plist Sources/Unlim/Resources/TelegramConfig.plist
```

Lalu isi `api_id` dan `api_hash` di file itu. File
`Sources/Unlim/Resources/TelegramConfig.plist` sudah ada di `.gitignore` —
jangan pernah commit file aslinya.

Perhatian: kunci ini tetap masuk ke dalam app bundle (seperti semua kredensial
client-side). Jangan bagikan IPA ke orang lain kalau tidak mau kredensialmu
ikut tersebar.

### 3. Build lokal (butuh Mac + Xcode)

```sh
brew install xcodegen
xcodegen generate
open Unlim.xcodeproj
```

Atau build IPA unsigned untuk SideStore/AltStore:

```sh
./Scripts/make-ipa.sh
```

### 4. Build via GitHub Actions

Push repo ini ke GitHub, lalu jalankan workflow **iOS** (`.github/workflows/ios.yml`):
macos-15, Xcode 16.4, `xcodegen generate`, `xcodebuild
CODE_SIGNING_ALLOWED=NO`, lalu zip `Payload` jadi IPA unsigned. IPA dilampirkan
ke release (kalau push berupa tag) atau sebagai artifact workflow.

## Struktur

| File | Isi |
|---|---|
| `project.yml` | XcodeGen: app SwiftUI, iOS 15.0, SPM TDLibKit (pin exact release), bundle id `com.adit.unlim` (ganti dengan milikmu), tanpa signing |
| `Sources/Unlim/App/UnlimApp.swift` | `@main`, registrasi background task, tampilan fallback kalau konfigurasi belum diisi |
| `Sources/Unlim/App/AppState.swift` | Pemilik client + semua service, observasi update TDLib |
| `Sources/Unlim/App/ContentView.swift` | Root: LoginView sampai auth ready, lalu TabView Topics / Queue / Settings |
| `Sources/Unlim/App/LoginView.swift` | Alur login phone → code → password 2FA, plus QR (CIQRCodeGenerator) |
| `Sources/Unlim/App/TopicsView.swift` | Daftar topik + riwayat pesan + download per pesan |
| `Sources/Unlim/App/QueueView.swift` | Daftar antrean (pause/resume/cancel) + prompt foto belum tersinkron |
| `Sources/Unlim/App/SettingsView.swift` | Opsi sync, album yang disinkronkan, info storage |
| `Sources/Unlim/Models/SyncStoreModel.swift` | Model antrean + state machine (sama seperti Android) |
| `Sources/Unlim/TDLib/TDLibConfig.swift` | Baca api_id/api_hash dari TelegramConfig.plist |
| `Sources/Unlim/TDLib/TelegramClient.swift` | Protokol client + tipe data sendiri (AuthState, ChatMessage, RemoteFile, …) |
| `Sources/Unlim/TDLib/TDLibKitAdapter.swift` | Satu-satunya file yang bicara ke TDLibKit; memetakan update/tipe TDLib |
| `Sources/Unlim/TDLib/UpdateBus.swift` | Satu stream update TDLib dibagikan ke banyak subscriber |
| `Sources/Unlim/TDLib/AuthService.swift` | State machine login |
| `Sources/Unlim/TDLib/SavedMessagesService.swift` | getMe, topik, riwayat |
| `Sources/Unlim/Services/AppDirectories.swift` | Direktori temp/thumbnail/unduhan |
| `Sources/Unlim/Services/CaptionBuilder.swift` | Caption file/chunk/galeri + parsing + grouping chunk |
| `Sources/Unlim/Services/ChunkingService.swift` | Pecah/gabung file, ukuran chunk 2.040.109.465 byte |
| `Sources/Unlim/Services/ThumbnailService.swift` | Thumbnail video JPEG kualitas 60 |
| `Sources/Unlim/Services/SyncStore.swift` | Antrean JSON (actor, atomic write) |
| `Sources/Unlim/Services/SyncService.swift` | Upload file/galeri, drain antrean, konfirmasi kirim |
| `Sources/Unlim/Services/FileDownloadService.swift` | Download dokumen + gabung chunk, progress updateFile |
| `Sources/Unlim/Services/GalleryScanner.swift` | Album PhotoKit sebagai "folder", export asset |
| `Sources/Unlim/Background/BackgroundScheduler.swift` | BGProcessingTask + BGAppRefreshTask |
| `Scripts/make-ipa.sh` | Build IPA unsigned (pola PhotosBackup) |
| `.github/workflows/ios.yml` | CI: test di simulator + build IPA |
| `Tests/UnlimTests/CaptionBuilderTests.swift` | Round-trip caption + grouping chunk |
| `Tests/UnlimTests/ChunkingServiceTests.swift` | Batas chunk 2 GB (sparse file) + round-trip pecah/gabung |
| `TelegramConfig.example.plist` | Template konfigurasi (api_id 0, api_hash placeholder) |

## Yang belum terverifikasi

Semua ini baru bisa dipastikan setelah build pertama di Mac/CI:

1. **Nama API TDLibKit yang sebenarnya.** `TDLibKitAdapter.swift` memakai
   nama yang diturunkan dari nama TL (`TDLibClientManager`, `createClient`,
   `TdApi.SetTdlibParameters`, `TdApi.GetMe`, `TdApi.SendMessage`,
   `TdApi.InputMessageDocument`, `TdApi.DownloadFile`,
   `TdApi.GetSavedMessagesTopics`, `TdApi.GetSavedMessagesTopicHistory`,
   `TdApi.RequestQrCodeAuthentication`, `TdApi.UpdateAuthorizationState`,
   `TdApi.UpdateFile`, `TdApi.UpdateMessageSendSucceeded`, …). Nama-nama ini
   ditandai `TODO` di file itu dan **harus dicocokkan dengan source hasil
   generate TDLibKit setelah SPM resolve pertama** — jangan mengarang.
2. **Deployment target minimum framework.** TDLibKit menargetkan iOS 13+
   menurut riset, tapi minimum deployment target XCFramework Swiftgram yang
   persis belum terverifikasi. Proyek ini menargetkan iOS 15.0.
3. **Build pertama.** Proyek belum pernah dikompilasi. Jalankan workflow
   GitHub Actions dan perbaiki error kompilasi dari log-nya.
4. **Pecah file 2 GB.** Round-trip split/join hanya teruji pada file kecil
   dan join manual; pemecahan file ≥ 2 GB belum teruji end-to-end.

## Yang belum dibangun

- **Download foto.** Pesan foto hanya menampilkan judul; file id ada di
  `PhotoSize` terbesar dan belum dipetakan ke `RemoteFile`.
- **Labeling gambar / face recognition / auto album.** Toggle di Settings
  hanya menyimpan preferensi (seperti `setOptions` Android); fitur
  Vision-nya belum dibangun.
- **Nilai `MEDIASEARCHUNIQID`.** Nilai persis yang dipakai Android untuk
  pencarian media di caption galeri belum tertangkap saat decompile; di
  `CaptionBuilder.swift` ditandai `TODO` dan saat ini diisi placeholder.
- **syncToGallery penuh.** `SyncService` saat ini memakai caption file biasa
  untuk foto galeri (ditandai `TODO`); caption galeri lengkap (tanggal asli,
  hash, label, lokasi) belum dirangkai saat upload.
- **Upload progress.** Progress upload belum dipantau (hanya progress
  download via `updateFile`).

## Sumber

- Model Android: `../unlim-android/ANALYSIS-Storage-Sync.md` (hasil decompile
  jadx APK `com.kratosle.unlim` 1.2.12-Beta).
- Riset TDLib iOS: `../research_notes/tdlib-ios-integration-20261118-1457/report.md`.
- Struktur packaging: https://github.com/g8row/PhotosBackup (hanya pola
  XcodeGen / make-ipa.sh / workflow / Info.plist — tanpa logika Google
  Photos).
