# Notification delivery

`Sources/NotificationService.swift` is the system entry point. It owns a registry
of requests, immutable rendered snapshots, processors on one serial queue and a
watchdog independent of that queue. A new push does not terminate an earlier push.
`NotificationRequestCompletion` atomically owns completion and closes all work;
callbacks and cancellation never run under its state lock.

`NotificationPayloadProcessor` resolves the account, decrypts, classifies the
payload, persists notification previews/message links and synchronizes account
state. Every subscription uses `start(request: ...)`, including nested resource
fetches. `NotificationSignalWork` registers a MetaDisposable before starting, so
synchronous completion cannot leak the disposable returned by the generator.
Native Notification Center callbacks return on the processing queue and reject
results after cancellation.

`NotificationExecutionBudget` starts in `didReceive` and uses monotonic uptime.
Preparation, synchronization, attachments and audio conversion share its 25-second
budget. The system expiry callback finishes every pending request immediately
with its last snapshot. Rendering, database reads and image decoding never run in
the expiry path. Communication interaction donation is scheduled after delivery.

`NotificationRendering` owns presentation, privacy and communication intents;
`NotificationEmoji` owns glyph image encoding; `NotificationSettings` reads user
preferences; `NotificationEnvironment` initializes shared account services.
The two Postbox import exceptions are the original service's access, relocated
to the payload and rendering files during this split. No consumer facade changed.

Normal completion waits for displayed-marker/autosave transactions, then cancels
remaining request work. Expiry can cancel a pending transaction and still deliver
the last snapshot. Do not start an owned transaction and immediately finish its
owner: cancellation can prevent that transaction from committing.

Hidden accounts/chats suppress presentation and keep ordinary synchronization
and the account-scoped archive active; their call pushes never enter CallKit.
Already displayed/read and technical messages are explicitly empty. Removing
delivered notifications must match `accountId` as well as peer/message identity.

Apple's filtering entitlement is required for supported suppression of alert
pushes. Without it the compatibility branch uses a passive empty placeholder
and bounded removal attempts, which are best effort. Do not describe this as
guaranteed suppression, guaranteed background execution or verified corporate
push delivery. Effective signing must grant ordinary APNs and app groups and
preserve the notification extension.

Primary requirements:

- https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension
- https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.filtering

`NotificationPipelineTests` and `NotificationRequestCompletionTests` can run on
macOS against the production Foundation sources and actual SwiftSignalKit using
the external `validation/notifications-host` package. They check ownership,
registration/completion races, independent pushes, expiry, shared budgets,
persistence barriers and account identity. Recipient-name/emoji tests remain iOS
tests. None proves APNs delivery or Notification Center behavior on a signed
device; those require that device and its real profile.
