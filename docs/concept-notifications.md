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
associated reply previews/quotes. In the main chat list, a blocked last author leaves an empty
message preview, including media and sender details, while retaining the chat and its sort index.
Block-state and toggle changes update previews without replaying a navigation request. Core notification selection and the extension use the same cached
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

The chat-list preview mapper was also compiled directly against small data fixtures: blocked latest
messages and archive message previews are removed; allowed latest messages, unknown authors, row
order, drafts and unread counters are retained. An empty blocked set restores the original entries.
This mapper check does not substitute for a signed-device test of the reactive chat list.

## Build 23 lifecycle and background cost

Changing the global switch immediately updates delivery subscriptions and background ownership.
Disabling stops the player, audio lease, recovery and watchdog, releases the network lease, and
cancels queued Concept local notifications. Ordinary Telegram APNs and call notifications have
separate settings; this switch does not disable those. Entering the foreground stops keepalive.
A generation check prevents a delayed authorization or audio activation callback from restarting it.
Eligible accounts and hidden-account changes are observed while backgrounded.

Keepalive retains the native looping player. Audio-session and player callbacks handle normal
interruptions/errors. A safety watchdog checks only player state once a minute, with 15 seconds of
timer tolerance; it neither queries notification content nor polls the network/database. It runs only
while Concept owns its audio lease. Recovery retries back off by 15, 30 and 45 seconds, then release
the lease after repeated failures rather than retrying forever. Calls, recording and media still take
priority. The previous ten-second recurring background-time extension is removed; running audio and
the eligible-account network lease retain their existing responsibilities.

Notification-center reconciliation is event driven: coalesced over 200 ms with one shared pending/
delivered snapshot for all accounts and a coalesced one-second follow-up after message events.
Existing database subscriptions continue observing synchronized read cursors, including remote reads,
when the local-delivery switch is off. There is no periodic read-state polling while idle.

Foundation notification tests and a separate host harness exercise the actual keepalive class body
with audio/application platform doubles: delayed activation after stop, disabled/foreground guards,
interruption, duplicate activation, unreported playback stop and exhausted recovery. These checks do
not measure iPhone energy consumption, background scheduling, APNs timing or Apple Watch dismissal.
Long idle and interrupted-device runs remain necessary to establish those properties.

Reproduce the keepalive host tests with `python3 tools/test_concept_keepalive.py`. The harness copies
the current production class body into external scratch storage and substitutes platform audio/app
objects, leaving application source files untouched. It also runs the Foundation notification suite.

Communication donation metadata no longer advertises mentions/replies to the system renderer, avoiding
extra “mentioned you”/“replied to you” headers. The group recipient count, sender images, chat/author
layout and delivery/mute exception policy are retained. Native-extension rendering did not set these
metadata flags and is unchanged. Existing notifications may retain their old system presentation.
