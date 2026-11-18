## Unreleased

- Content-free pushes fetch their content from Relay by default (`RelayApiPushContentSource`).
- Device registration reports interruption permissions; `RelayInterruptionCapabilities` now holds `DeviceInterruptionPermission` values.
- The preference center shows consents read-only, with an optional link to change them in Access.
- The inbox list shows the agent label, waitpoint states and response options, and links approval items to the Access approval surface.
- Opt-in reporting of displayed notifications as identifier digests (`reportDisplayedNotifications`, `RelayClient.reportDisplayedNotification`).

## 0.1.0

- First release: inbox, realtime, push devices, receipts, device status, preferences and native widgets.
