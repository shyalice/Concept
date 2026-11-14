# Concept profiles

Profiles retain Telegram's header, gallery, panes, action handlers, context sources and accessible
labels. The shared backdrop reuses decoded gallery images, computes a bounded blur off-main and
rejects stale results by generation. Gift covers and photo backgrounds fade toward the application
theme as the header collapses. Information/music sections use rounded translucent content material;
actions use GlassBackgroundView (native UIGlassEffect on iOS 26+, Telegram's fallback earlier).
The current gallery/material/palette design includes the accepted UI work preceding this revision.

## Action-button interaction

The action's transparent HighlightTrackingButton and its icon live inside the glass content view.
This lets native interactive glass deform the surface and content together, including tracking a
finger and springing back on release. The former 0.90 scale and 0.75 alpha highlight is removed.
Context gestures still belong to the existing ContextControllerSourceNode; labels remain on the
original accessible control. With Reduce Transparency the icon returns to the original host.

## Recorded-frame expectations

Per AGENTS.md, before claiming the animation visually verified, record and inspect:

- Press/hold/release call, mute, search and More in light/dark profiles. The glass expands and follows
  the finger; icon and surface travel together, then settle. No independent icon, clipped bloom,
  white flash or old dimming/shrinking animation.
- Drag off a button and cancel. No action fires; the surface returns to rest.
- Open mute/More context menus and dismiss them. No duplicate action, stuck expansion or missing icon.
- Repeat after scrolling/collapsing, across a pane change, with Reduce Transparency and VoiceOver.
- Keep the accepted photo-to-blur transition, card clipping, text contrast and normal-theme collapse.

The current Codex session has no XcodeBuildMCP interaction tools or booted authenticated simulator.
Source checks and a release build do not establish that these frame checks passed. A signed device
recording is still needed to judge the new physical interaction and actual frame pacing.
