# Dictate

A tiny macOS menu bar app for dictation. Hold Right Option, speak, let go: the text is pasted where your cursor is, and your old clipboard comes back. For longer talks, press Option+Space, speak hands-free, then tap Option (or press Option+Space again) to finish.

Speech to text is [ElevenLabs Scribe](https://elevenlabs.io/speech-to-text) (model `scribe_v2`). The language is detected automatically, so English, Persian and mixed speech all work.

## Features

- Hold-to-talk (Right Option) and hands-free mode (Option+Space).
- A small floating pill at the bottom of the screen with live sound bars. Follows light and dark mode.
- Recent: the last 100 dictations, click one to copy it again. Stored only on your Mac in `~/Library/Application Support/Dictate/history.json`.
- Dictionary: words you want spelled right are sent to Scribe as key terms, and "it came out as X, write Y" fixes are applied after. Stored in iCloud Drive at `Dictate/dictionary.json` (with a local cached copy), so other devices can use the same list.
- Open at Login toggle.

## Requirements

- macOS 14 or later.
- Xcode or the Xcode Command Line Tools (`xcode-select --install`) for `swiftc`.
- An ElevenLabs API key with Speech to Text access. A separate key with only that permission is a good idea.

## Build on a Mac

```bash
git clone <this repo>
cd dictate-mac
./build.sh              # builds build/Dictate.app
./build.sh --install    # builds and copies it to /Applications
open /Applications/Dictate.app
```

There is no Xcode project: `build.sh` compiles the single file `Sources/main.swift` with `swiftc` and signs the app.

### Bundle id

The bundle id is `com.example.dictate`. Change it to your own reverse domain (for example `com.yourname.dictate`) in `Info.plist` under `CFBundleIdentifier`. `build.sh` reads it from there, so that is the only place to change.

### Signing (optional, recommended)

By default the app is signed ad hoc. That works, but macOS treats every rebuild as a new app, so you have to grant Accessibility again after each build.

To avoid that, sign with the same certificate every time:

1. Open Keychain Access, then Certificate Assistant, Create a Certificate. Give it a name, set Certificate Type to Code Signing, and create it in your login keychain.
2. Build with that name:

```bash
SIGN_IDENTITY="your-certificate-name" ./build.sh --install
```

## Set the ElevenLabs key

The key is stored only in the macOS Keychain (a generic password with service name `dictate.elevenlabs`). It is never written to a file.

- On first launch, if no key is found, Dictate asks for it.
- Any time later: click the mic icon in the menu bar, then **Set ElevenLabs Key...**, paste the key and press Save. Saving again replaces the old key.

To remove it, delete the `dictate.elevenlabs` item in Keychain Access.

## Permissions

Dictate needs two permissions. Grant both, then quit and reopen the app if the hotkey does not respond.

| Permission | Why | Where |
|---|---|---|
| Microphone | To record while you talk. macOS asks on first launch. | System Settings, Privacy and Security, Microphone |
| Accessibility | To see the Option key globally and to paste the text (it sends Cmd+V). Dictate opens the prompt on launch. | System Settings, Privacy and Security, Accessibility |

The Keychain may also ask once whether Dictate can read its own key: choose Always Allow.

## Configuration

Dictate has no runtime environment variables. The only optional setting is for the build:

| Variable | Used by | Meaning |
|---|---|---|
| `SIGN_IDENTITY` | `build.sh` | Name of a code signing certificate in your login keychain. Empty means ad hoc signing. |

## Access and privacy

There is no server and no account. Audio is recorded to a temporary file and sent only to the ElevenLabs API with your own key. History and the dictionary stay on your Mac (and your iCloud Drive for the dictionary).

## Checks without a microphone

```bash
mkdir -p /tmp/pills && build/Dictate.app/Contents/MacOS/Dictate --render /tmp/pills   # PNGs of the pill and the Add Word dialog, light and dark
build/Dictate.app/Contents/MacOS/Dictate --fix-test "I met win today"   # runs a sample fix list
```

## License

MIT, see [LICENSE](LICENSE).

Built by Sahand Sorouri, https://sahand.sorouri.com
