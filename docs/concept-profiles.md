# Concept profiles

Profiles retain Telegram's header, gallery, panes, action handlers, context sources and accessible
labels. The shared backdrop reuses decoded gallery images, computes a bounded blur off-main and
rejects stale results by generation. Gift covers and photo backgrounds fade toward the application
theme as the header collapses. Information sections use rounded translucent content material;
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

Information cards use ContactsUICore's `ContactCardStyleProvider.defaultBackgroundMaterial`
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
changes crossfade over 0.22 seconds. A separate 5% black shade gently dims the decorative backdrop;
the full-screen shade and the card tint have independent roles and do not share an appearance switch.

The build16 avatar changes were rejected on device: the lower background ended in a visible horizontal
edge, the photo appeared cut, and the gallery motion regressed. Avatar/backdrop geometry, masks,
image preparation and scroll palette application are restored to the November 14 revision `77f9ef704`.
The native card material and music press fix remain. The follow-up below changes only the fade mask and visible-section palette application on this
restored geometry; integrated device animation checks remain outstanding.

Before visual acceptance, record cold/warm profile opens, delayed gallery-image loading, avatar
expansion, gift covers and scroll-to-theme in both themes. Expect no pale first card, abrupt material
switch, late full-screen photo pop or row relayout on image completion. Cached opens should reuse
the prepared blur; unavailable images should retain a stable placeholder until a smooth handoff.

## Follow-up after the avatar rollback

The accepted Contacts card material is unchanged. The music strip uses the existing interactive
GlassBarButtonComponent, with its content inside the native glass control; the old whole-plate scale
and opacity press effects remain disabled. Decorative profile tabs use the same regular dark glass recipe as music and navigation
controls, avoiding the clear-style glass brightness wash. At full collapse they return to the
ordinary application-theme panel. Members panes get the same material behind their list,
positioned from the existing list-background frame rather than from row snapshots.

The gallery frame, image size and native reflection transforms remain at the restored baseline.
Only the gallery's fade mask changes: it ends at the current sharp photo's lower edge, so the sharp
replicated tail cannot reappear below it. A smooth fade covers the last fifth of the photo; it stays
attached throughout collapse. Invalid/empty image geometry uses a full-gallery fade until the decoded image has a valid frame.
Photo blur preparation remains bounded and off-main. Offscreen information sections do not relayout
for every intermediate scroll palette; they catch up when entering the visible region.

The actual mask class was exercised in an isolated iOS 27 VM test. External validation artifact
`profile-photo-fade-frames/sheet.jpg` shows samples #0–#8 (t=0.656–3.123): the head and upper photo keep
their geometry through scale/rounding changes; the new mask removes the sharp tail retained by the old
mask. These are sparse VM captures of the isolated component, not a frame-rate or full-profile test.

A native iOS 27 glass-recipe comparison captures the old clear-style strip beside the music/Edit
recipe and the corrected regular strip. Samples #0–#7 (t=0.000–2.748) in external validation
`profile-tabs-glass-frames/sheet.jpg` show the old brighter wash while the corrected strip matches
the controls through changing backdrop colors. This compares the material recipes, not the full
profile, selected-tab lens, or scroll transition.

The backdrop-only shade is now 5%, up from 3.5%; card material and gallery geometry are unchanged.
External isolated iOS captures `profile-shade-frames/sheet.jpg`, #0–#5 (t=0.000–1.539), compare
the old and new shade over bright photo-like and gift-like color fields. The change is slight
throughout the color sweep. These frames validate the shade layer, not the integrated profile.

## Account badges (build 22)

Settings account rows and account-switcher context rows reserve space for a 16-point Concept badge
beside the existing Premium/emoji status. Badge changes update the row, presentation-theme changes
update its color, and swipe-reveal moves the badge with the title. Scam/fake identities retain the
existing suppression policy. The plain profile butterfly is raised by one physical screen pixel;
rosette roles retain their existing alignment. The accepted card material is unchanged.

The complete app compiled with this batch. Integrated account-switcher/profile frame captures and
layout checks with long names remain outstanding; build success alone does not validate appearance.
