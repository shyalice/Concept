# Chat presentation and Files import

Build 22 message and reaction extracted menus retain their own material without requesting a
full-screen background blur. View-once privacy menus and navigation previews keep their existing
blur policy. The existing bubble template now uses a curved tail at normal corner radii, with its
mirroring, stretch caps, media masks and shadows retained; small corner-radius themes retain the
previous path. Ordinary message spacing increases slightly, including a one-point gap between merged
items. These changes compile in the full app but still need recorded frames of actual chat menus,
text/media tails and send/scroll transitions in both themes before visual acceptance.

The chat attachment and audio import pickers request copied files. Import metadata uses a retained
security-scoped owner and an NSFileCoordinator reading intent on a bounded worker queue, instead of
waiting indefinitely for an NSMetadataQuery result. Readable app-local copies remain valid even when
startAccessingSecurityScopedResource returns false. The existing file-size/send checks remain; import
failure now produces an existing localized error rather than silently doing nothing.

A native isolated Files probe confirmed delegate callback, bookmark creation and reads for both
in-place scoped URLs and local copied URLs. The subsequent coordinated import path has compiled,
but an end-to-end provider selection and send in the authenticated client has not yet been verified.

## Follow-up after build 23

Message and reaction menus request a mild eight-point backdrop blur with reduced dimming and no
saturation boost. Other extracted sources, including view-once, retain their existing blur policy.
The backdrop plate is recreated only when switching between sources with different blur radii;
its hit-test contents and placement stay intact. The legacy controller fallback retains its existing
system effect; the normal extracted presentation uses the configurable radius.

Lifted bubble backdrops use opaque theme colors while the context preview is extracted, preserving
the bubble mask and its incoming/outgoing gradient. Wallpaper portal sampling resumes on dismissal.
Deleted-message dimming is suspended for the extracted preview and restored in the history afterwards;
album-item extraction follows the same rule. Text, media and message content are not globally faded.

Expected device frames: the selected bubble is solid before and throughout its lift, the background
remains recognizable under light blur, and dismissal restores wallpaper/deletion styling without a
flash or seam. Verify incoming/outgoing text, media, deleted messages and album extraction, open and
close, in both themes. No authenticated iOS frames have been captured for this follow-up; VM transport
is unavailable and XcodeBuildMCP is not exposed in the session.
