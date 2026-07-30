# QuestCast

![QuestCast cover](StoreAssets/QuestCast-Cover-Landscape-2560x1440.png)

QuestCast is an experimental, low-latency casting system for showing a Meta Quest 3 headset view on an Apple TV over a local network. It is built as two small native applications with no PC, cloud service, account, or relay in the middle.

**Project site:** [regularadrian.github.io/QuestCast](https://regularadrian.github.io/QuestCast/)

> [!IMPORTANT]
> QuestCast is an independent community project. It is not affiliated with, endorsed by, or sponsored by Meta or Apple. Meta Quest, Apple TV, tvOS, and their respective marks belong to their owners.

## How it works

```text
Meta Quest 3 -- Wi-Fi --> local access point -- Ethernet/Wi-Fi --> Apple TV --> television
     MediaProjection      H.264 access units over UDP       VideoToolbox
```

The Quest sender captures the user-approved display surface with Android `MediaProjection`, encodes H.264 in hardware, and fragments each access unit into small UDP datagrams. The Apple TV receiver advertises itself with Bonjour, reassembles complete access units, decodes with VideoToolbox, and renders the newest available frame without a playback queue.

This design prioritises responsiveness over perfect delivery: incomplete or late frames are discarded instead of delaying subsequent frames.

## Features

- No PC required after building and installing the apps
- Automatic Apple TV discovery with Bonjour (`_questcast._udp`)
- H.264 hardware encoding and decoding
- 1920 x 1080 at a 60 fps target
- Zero-buffer receiver path designed for low latency
- Video stays on the local network, no cloud or internet services involved
- Optional diagnostics overlay on Apple TV using the Play/Pause button
- Apple TV screensaver remains available while the receiver is idle
- Optional experimental 48 kHz stereo playback audio, off by default

## Downloads

Prebuilt Quest sender APKs are published on [GitHub Releases](https://github.com/RegularAdrian/QuestCast/releases). A downloaded APK is installed as a sideloaded application; Meta release-channel and Store builds remain subject to Meta's distribution process.

Some Meta Quest 3 users can also join the alpha channel on the Meta Quest App Store to easily install the Sender app on their Quest device here: [https://www.meta.com/s/4PVHdWsca](https://www.meta.com/s/4PVHdWsca)

The Apple TV receiver app must currently be built and signed with the user's own Apple Developer team in Xcode, as at the moment I am not a paying member of the Apple Developer programme.

Both the Sender and the Receiver app must be installed on the Meta Quest 3 and Apple TV respectively for this casting to work. Both devices must also be on the same local network.

## Repository layout

- `QuestSender/` — native Android sender for Meta Horizon OS
- `QuestCastTV/` — SwiftUI tvOS receiver sources
- `QuestCastTV.xcodeproj/` — Xcode project for Apple TV
- `Shared/protocol.md` — versioned UDP wire protocol
- `StoreAssets/` — artwork and representative screenshots

## Requirements

- Meta Quest 3 or compatible Horizon OS headset with Developer Mode enabled for local deployment
- Apple TV running tvOS 17 or later
- Xcode with the tvOS SDK
- Android Studio with Android SDK 35 (if building the Sender app)
- A local network that permits Bonjour/mDNS and direct UDP traffic between the headset and Apple TV
- Television Game Mode recommended

## Build the Apple TV Receiver App

1. Open `QuestCastTV.xcodeproj` in Xcode.
2. Select the `QuestCastTV` target.
3. Choose your Apple Developer team and use a unique bundle identifier if Xcode requests one.
4. Select your paired Apple TV as the run destination.
5. Build and run, then leave QuestCast open on the Apple TV.

The receiver listens on UDP port `49152` and publishes `QuestCast TV` through Bonjour.

## Build the Quest Sender App

1. Open `QuestSender/` in Android Studio.
2. Allow Gradle to sync.
3. Connect the headset over USB and approve USB debugging.
4. Run the `app` configuration on the headset.
5. Open QuestCast, select the discovered Apple TV, and approve Horizon OS screen capture.
6. Switch to the experience you want to show.

For a command-line debug build:

```bash
cd QuestSender
./gradlew :app:assembleDebug
```

The resulting APK is written under `QuestSender/app/build/outputs/apk/debug/`.

## Using QuestCast

1. Start QuestCast on the Apple TV.
2. Start QuestCast on the headset.
3. Select **Cast to QuestCast TV**.
4. Approve the system capture prompt.
5. Before starting, optionally enable **Include headset audio**. This requests playback-audio permission; the microphone is not captured.
6. Press Play/Pause on the Siri Remote during casting to toggle technical diagnostics.

![QuestCast sender interface](StoreAssets/QuestCast-Screenshot-01-2560x1440.png)

## Current transport settings

- Codec: H.264/AVC
- Capture target: 1920 x 1080 at 60 fps
- Bit rate: 16 Mbps
- Keyframe interval: one second
- Datagram size: no more than 1200 bytes
- Incomplete-frame expiry: 80 ms
- Receiver playback/jitter buffer: none
- Optional audio: PCM 16-bit, 48 kHz stereo in 10 ms chunks
- Audio startup buffer: approximately 30 ms, capped at approximately 100 ms

H.265 may reduce bandwidth, but H.264 is the current default because its hardware path is widely supported and predictable. A future H.265 mode should be measured end-to-end rather than assumed to be faster.

## Security and privacy

- Capture starts only after the user accepts the Horizon OS `MediaProjection` prompt.
- Playback audio is captured only when the user enables it and grants permission. The microphone is not included.
- QuestCast does not upload, store, analyse, or relay the video through an external service.
- The current UDP protocol is intentionally minimal and does **not** provide authentication or encryption.
- Use it only on a trusted local network. Do not expose UDP port `49152` to the internet.
- Protected video surfaces may appear black by platform design.

## Measuring latency

Network ping does not measure capture-to-display latency. For a useful test, show a fast-changing counter or alternating black/white surface in the headset, film the headset and television together at a high frame rate, and count the frames between matching transitions. Compare results with television Game Mode both enabled and disabled.

## Known limitations

- Playback audio capture depends on Horizon OS and the foreground app allowing it; protected or opted-out apps may be silent
- No authentication, encryption, retransmission, or forward-error correction
- Packet loss can discard a complete encoded frame
- Tested primarily with Meta Quest 3 and Apple TV on the same local network
- Store-distributed builds require the publisher's own signing and platform review

Contributions and reproducible latency measurements are welcome.

## Disclaimer
This software is completely without warranty, and the author does not assume any responsibility for damage, the security risks or losses caused by the use of this software.

Anyone using or installing this software does so at their own risk.

This app has primarily been built with AI (OpenAI Codex).

## Licence

QuestCast is open-source software released under the [MIT Licence](LICENSE).
