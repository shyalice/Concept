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
