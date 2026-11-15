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

## First-frame material and avatar readiness

Information cards and music use ContactsUICore's `ContactCardStyleProvider.defaultBackgroundMaterial`
on iOS 26+. The earlier `lightweightThin` provider looked dense in the isolated comparison and is not used for cards. The system framework
is loaded once and retained while SwiftUI owns its material provider. This is a private system entry
point, resolved dynamically; if unavailable, the public ultra-thin material is used instead. No Apple
binary is bundled. Reduce Transparency retains an opaque accessible background.

The native card material has no added tint. Its color scheme follows the application theme and does
not change during scroll. The effect stays at alpha one; an independent application-theme fill covers
it as the profile collapses. Material and clipped rows are siblings, so animating a business-hours row
does not clip or flatten the backdrop effect. Profile tabs likewise sit above the glass rather than
inside its optical clip. The track disables whole-plate scale/alpha highlighting.

An isolated card comparison ran on the user's iOS 27.0.1 VM, using the system getter in both color
schemes. The user accepted its direction. Captured frame: external validation directory,
`contacts-material-lab/vibrant-native.jpg`. This verifies the material in isolation, not the complete
profile or its scrolling animation; integrated recorded-frame checks remain required.

The backdrop starts with the decoded round avatar while a gallery photo is unavailable. Blur is
prepared off-main at a 256-pixel maximum edge and cached with a 4 MiB/12-entry limit, without retaining
the source photos. A bounded thumbnail color provides the initial fill; arriving images and tone
changes crossfade over 0.22 seconds. A separate 5.5% black shade gently dims the decorative backdrop;
the full-screen shade and the card tint have independent roles and do not share an appearance switch.

The build16 avatar changes were rejected on device: the lower background ended in a visible horizontal
edge, the photo appeared cut, and the gallery motion regressed. Avatar/backdrop geometry, masks,
image preparation and scroll palette application are restored to the November 14 revision `77f9ef704`.
The native card material and music press fix remain. This restores the previously working baseline;
it does not claim that the baseline's original photo/blur seam is solved. Future changes must be
compared against recorded full-profile frames before replacing that baseline.

Before visual acceptance, record cold/warm profile opens, delayed gallery-image loading, avatar
expansion, gift covers and scroll-to-theme in both themes. Expect no pale first card, abrupt material
switch, late full-screen photo pop or row relayout on image completion. Cached opens should reuse
the prepared blur; unavailable images should retain a stable placeholder until a smooth handoff.
