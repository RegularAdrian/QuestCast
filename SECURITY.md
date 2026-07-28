# Security policy

QuestCast is an experimental local-network utility. Its current UDP protocol is deliberately small and does not authenticate the sender or encrypt video traffic. Treat every device on the same reachable network as potentially able to observe or inject traffic.

## Safe deployment

- Use QuestCast only on a trusted private LAN.
- Do not forward or expose UDP port `49152` to the internet.
- Keep untrusted clients isolated from the headset and Apple TV VLAN where practical.
- Stop casting when the receiver is no longer in use.

## Reporting a vulnerability

Please use GitHub's private vulnerability-reporting feature for security-sensitive findings. Do not include private video, network credentials, signing material, or personal information in a public issue.

