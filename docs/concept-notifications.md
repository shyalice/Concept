# Local notifications

The default-enabled switch in Concept → Notifications keeps MTProto updates running using silent
audio and a wakeup-manager lease. Audio belongs to Telegram's ManagedAudioSession: calls, recording
and playback take precedence, and activation/deactivation callbacks start/stop the silent player.
The service stops on foreground entry or when disabled. There is no ntfy client or relay.
A shared application-level owner subscribes to every signed-in account, not just the selected UI
account. Stable account subscriptions survive primary-account switches. Background network leases
track the full eligible account set as accounts are added/removed; hidden accounts stay excluded.
The local service uses its own global switch, regardless of the legacy selected-account preference.

Messages are claimed transactionally using Telegram's read/mute/mention/topic rules. Hidden
accounts/chats, restricted content and technical service events are suppressed. An accepted system
handoff commits the displayed marker shared with the extension; errors release it, abandoned claims
expire. BGAppRefreshTask remains a bounded best-effort fallback.

Content uses localized Telegram descriptions: group title, author subtitle, message body once.
Channels use their channel identity. Account/topic IDs partition threads and communication intents.
Tap/reply use the existing account/peer/thread/message payload and app-lock routing.

Communication intents put sender images on `sender`, group avatars on `speakableGroupName`, following
[Apple's communication notification guide](https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications).
Uncached small photos are fetched concurrently with a two-second deadline; initials are the fallback.
Photos are keyed by resource identity. Hidden previews and a locked app do not disclose names/images/
text through communication metadata. Delivery never moves media out of Telegram's cache.

Static inspection of the supplied Whitegram IPA found its silent WAV, AVAudioPlayer keepalive classes,
background modes and settings. This implementation uses that background-audio principle without
executing or incorporating its binaries. iOS can suspend/terminate an app; force quit requires a
relaunch. Local delivery is not an APNs guarantee. Native APNs/VoIP and the extension remain supported
when provider credentials are configured for the app ID.

Host tests cover authorization, registration retries and completion/cancellation races. Full builds
check integration. Actual avatars, group mentions, topics, tap/reply, audio interruptions and long
background delivery need a signed device run; a synthetic banner cannot validate MTProto delivery.

## Routing, filtering and read-state cleanup

Ordinary group replies never supply a topic id. Only forums, monoforums and forum bots keep one;
the account/peer/message identity remains explicit in every local payload. Group communication
intents use the cached accurate recipient count and the group avatar parameter. If membership
is unknown, the plain chat/author notification remains preferable to donating a false direct message.

One database-backed tracker per eligible account observes the messages and read counters represented
by pending/delivered notifications. Forum topics use their own incoming read cursor. This covers local
reads and incoming read updates from another client while Concept can synchronize. Startup, foreground
entry and accepted notification deliveries reconcile the OS notification center; cached read results
also remove a late delivery after its read update. Reading an older message does not clear a newer
unread notification or a different account's conversation. iOS cannot run this cleanup instantly while
the app is force-quit; reconciliation resumes when the app runs again.

The optional blocked-user filter removes blocked authors from history before grouping and strips
associated reply previews/quotes. Core notification selection and the extension use the same cached
block state. The delivery path checks again after avatar preparation; existing blocked-author
notifications are removed when the block state or filter changes. Pinned/mention/reply actions and
per-chat exceptions use one Foundation policy shared by local delivery and the extension.

Notification taps recheck hidden-account/chat state before switching accounts. Inline replies also
require an unlocked app and recheck visibility after peer lookup. Hidable conversations do not donate
Siri interactions, and newly hidden targets remove pending/delivered notifications and old donations.
The extension no longer logs decrypted payloads or rendered message contents.

Run the Foundation routing/presentation and delivery lifecycle tests with
`swift test --package-path submodules/ConceptNotifications`.

Validation: those Foundation tests, the extension host
suite, full app builds and strict app/extension signature verification. These are not a signed-device
multi-account delivery/read test. Keep that distinction when reporting results.
