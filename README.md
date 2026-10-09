# EventKit offline kit (pendrive)

For attendees who can't download several gigabytes at home. You build the kit once on a machine with internet and copy it to a USB drive. Attendees run one script from the drive. It installs EventKit and the whole Flutter toolchain without internet, skipping anything that is already installed and good enough.

The script puts every tool where the EventKit app would put it (`C:\dev\toolchain` or `~/dev/toolchain`). When the attendee opens EventKit and signs in, setup finds these tools and reuses them. Only the small, machine-specific steps are left for the app: Dart packages and the Gradle warm-up.

## Get the payload (this repo)

This repo is a ready-built kit for **Flutter Build Day**: Flutter 3.44.6 and EventKit 0.1.3, built on 2026-10-09 from the production manifest. Git holds the scripts and the index under `payload/`. The big files, about 13 GB for all five platforms, are assets of the [`kit-2026-10-09` release](../../releases/tag/kit-2026-10-09).

```sh
gh auth login            # once, with an account that can see this private repo
git clone https://github.com/chitrakshbotwala/eventkit-offline-kit
cd eventkit-offline-kit
node download-payload.mjs                                    # all platforms
node download-payload.mjs --targets windows-x64,macos-arm64  # only some
```

GitHub caps release assets at 2 GiB, so the macOS Flutter archives are stored in parts. The script joins them again. It checks every file's SHA-256 against `payload/assets.tsv`, and you can re-run it after an interruption. Then copy the whole folder to the USB drive.

These scripts come from `offline-kit/` in the main EventKit repo. When the manifest changes, run `node build-kit.mjs` there to refresh the kit, then publish a new release here.

## What's on the drive

| Component                                                          | Windows | macOS                                        | Linux                                  |
| ------------------------------------------------------------------ | ------- | -------------------------------------------- | -------------------------------------- |
| EventKit app                                                       | yes     | yes                                          | yes (`.deb`, `.rpm`, pacman, AppImage) |
| Flutter SDK (the event's pinned version)                           | yes     | yes                                          | yes                                    |
| Temurin JDK 17                                                     | yes     | yes                                          | yes                                    |
| Android SDK (cmdline-tools, platform-tools, platform, build-tools) | yes     | yes                                          | yes                                    |
| Google Chrome                                                      | yes     | yes                                          | `.deb` / `.rpm` (Arch: use Chromium)   |
| VS Code + Dart and Flutter extensions                              | yes     | yes                                          | yes                                    |
| Starter project                                                    | yes     | yes                                          | yes                                    |
| Git                                                                | yes     | no: Xcode Command Line Tools come from Apple | no: from your distribution             |
| Linux build packages (clang, cmake, GTK headers, ...)              | n/a     | n/a                                          | no: from your distribution             |

The script tells the attendee about anything in the "no" cells. It installs those when the laptop is online, and otherwise the EventKit app installs them later.

## 1. Build the kit (organizer, needs internet)

Node.js 22 or newer. Nothing else: the script has no dependencies.

```sh
node offline-kit/build-kit.mjs --dry-run                # check the manifests, list the files
node offline-kit/build-kit.mjs                          # all platforms into offline-kit/payload
node offline-kit/build-kit.mjs --out E:\                # straight onto a USB drive
node offline-kit/build-kit.mjs --targets windows-x64,macos-arm64,linux-x64
```

| Option                  | Default                                                                |
| ----------------------- | ---------------------------------------------------------------------- |
| `--out <dir>`           | `offline-kit` (this folder)                                            |
| `--targets <list>`      | `windows-x64,windows-arm64,macos-arm64,macos-x64,linux-x64`            |
| `--server <url>`        | `EVENTKIT_SERVER_URL` or `https://darted.gdgkiit.in`                   |
| `--pubkeys <keys>`      | `EVENTKIT_MANIFEST_PUBKEYS` or the production key (`d6880dc0b37be84b`) |
| `--app-version <x.y.z>` | latest GitHub release                                                  |
| `--skip-app`            | bundle the EventKit installers                                         |

All five targets come to about 14 GB, roughly 3 GB per platform. Re-running only downloads what changed. A file that is already in the kit is kept when its hash still matches.

Build the kit after the manifest is final (Admin → Settings → Manifest). The kit contains the exact versions in the manifest, so it goes stale if you change the Flutter version later. In that case, run the build again.

The drive can be exFAT, NTFS or FAT32 (every file is under 4 GB). Copy the whole folder: `README.md`, the install scripts and `payload/`.

### What gets checked

- The server's manifest must carry a valid Ed25519 signature from a trusted key. This is the same check the desktop app makes, so a kit can't be built from a tampered server response.
- Every toolchain file must match the manifest's SHA-256. Android SDK packages must match Google's SHA-1 from `repository2-3.xml`, and the EventKit installers must match the release's `SHA256SUMS.txt`.
- On the attendee's laptop, the install script checks every file's SHA-256 again before using it. This catches a corrupted copy or a bad drive.

## 2. Install (attendee, no internet needed)

**Windows.** Open the drive and double-click `install-windows.cmd`. No administrator rights needed.

```powershell
install-windows.cmd -SkipApp            # tools only
install-windows.cmd -Only flutter,android
install-windows.cmd -Root D:\dev\toolchain
```

**macOS / Linux.** Open a terminal in the drive's folder:

```sh
bash install.sh
bash install.sh --skip-app
bash install.sh --only flutter,android
bash install.sh --root ~/dev/toolchain
```

Use `bash install.sh`, not `./install.sh`, because USB drives often drop the executable bit. On Linux, only the EventKit and Chrome packages ask for the sudo password. Without sudo, EventKit falls back to the AppImage.

Then **open EventKit and sign in with Google**. This needs internet once, but only a few kilobytes. Setup then shows most components as already done.

Re-running the script is safe. It skips whatever is already installed. It never deletes the attendee's projects: an old starter project is renamed to `…-backup-<date>`.

## How the script decides what to install

| Component                 | Kept when                                                                                           |
| ------------------------- | --------------------------------------------------------------------------------------------------- |
| Flutter                   | `flutter` on PATH, in `FLUTTER_ROOT` or in the toolchain folder is stable and the event's version   |
| Java                      | `JAVA_HOME`, Android Studio's bundled JDK or `java` on PATH is 17–21                                |
| Android SDK               | `ANDROID_HOME`, `ANDROID_SDK_ROOT` or Android Studio's SDK exists. Missing packages are added to it |
| Git                       | 2.30 or newer                                                                                       |
| Chrome, VS Code, EventKit | already installed in the usual place                                                                |

These are the same rules the app's setup uses (`apps/desktop/src/main/setup/components/existing.ts`). PATH, `JAVA_HOME`, `ANDROID_HOME` and `ANDROID_SDK_ROOT` are saved for new terminals. On Windows they go to the user environment. On macOS and Linux they go into the same managed block of `~/.profile`, `~/.bashrc` and `~/.zshrc` that the app maintains. Pass `-NoEnv` or `--no-env` to skip this.

Accepting the Android SDK license is recorded the way `sdkmanager --licenses` records it. If Google changes the license text, run `flutter doctor --android-licenses` once while online.

## Files

| File                         | Purpose                                                                          |
| ---------------------------- | -------------------------------------------------------------------------------- |
| `build-kit.mjs`              | Builds `payload/` from the signed manifests (organizer)                          |
| `install-windows.cmd`        | Double-click launcher for the PowerShell installer                               |
| `install-windows.ps1`        | Windows installer (Windows PowerShell 5.1, built into Windows 10 and 11)         |
| `install.sh`                 | macOS and Linux installer (bash 3.2 or newer)                                    |
| `payload/kit.json`           | Index per target: build date, manifest, app version, every file with its SHA-256 |
| `payload/targets/*.tsv`      | What the install scripts read: one row per file (kind, path, SHA-256, argument)  |
| `payload/manifests/`         | The signed manifests the kit was built from                                      |
| `payload/files/`             | Toolchain files, named like the app's download cache (`<sha256[:12]>-<name>`)    |
| `payload/android/`           | Android SDK packages per host OS                                                 |
| `payload/vscode-extensions/` | `.vsix` files                                                                    |
| `payload/app/`               | EventKit installers                                                              |

`payload/` is git-ignored. Hand out the drive, not the repository.
