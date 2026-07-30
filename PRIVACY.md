# QuestCast privacy policy

Effective date: 28 July 2026

QuestCast is a local-network video and optional playback-audio casting utility composed of a Meta Quest sender and an Apple TV receiver.

## Data processed

When the user explicitly starts casting and accepts the system screen-capture prompt, the Quest application processes the visible headset display as a video stream. The stream is sent directly to the QuestCast receiver selected on the same local network.

If the user separately enables **Include headset audio** and grants the system audio permission, QuestCast also processes compatible audio being played by the headset. This option is off by default. QuestCast does not intentionally capture microphone input.

QuestCast does not require an account and does not collect names, email addresses, identifiers, precise location, contacts, advertising data, or payment information.

## Data transmission and retention

- Video and any user-enabled playback audio are transmitted directly between the user's headset and Apple TV over the local network.
- The project does not operate a cloud server, relay, analytics service, or advertising service.
- Video frames and playback-audio chunks are processed in memory for immediate presentation and are not intentionally recorded or retained by QuestCast.
- QuestCast does not send captured video or usage information to the developer.

## Permissions

The Quest application uses Android `MediaProjection` only after the user approves the system capture prompt. Optional playback capture also requires Android's `RECORD_AUDIO` permission, despite QuestCast not requesting microphone input. The application uses internet and local-network capabilities to discover and communicate with the Apple TV receiver.

## Security

The current experimental protocol does not provide transport encryption or receiver authentication. QuestCast should be used only on a trusted local network. Users should not expose its UDP receiver port to the internet.

## Children's privacy

QuestCast is a general-purpose developer utility and is not directed to children. The project does not knowingly collect personal information from children.

## Changes

Material changes to this policy will be recorded in the project's source history with an updated effective date.

## Contact

Questions about this policy can be raised through the project's GitHub issue tracker. Security-sensitive reports should use GitHub's private vulnerability-reporting feature rather than a public issue.
