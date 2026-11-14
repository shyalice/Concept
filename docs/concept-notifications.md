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
