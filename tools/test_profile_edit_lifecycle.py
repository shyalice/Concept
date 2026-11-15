#!/usr/bin/env python3
"""Exercise the actual profile Edit transition method with host platform doubles.

Checks state restoration and transition ownership, not iOS rendering or gestures.
Swift output is generated in external temporary storage without editing app sources.
"""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift').read_text()
start = s.index('    private func updateProfileEditing(')
brace = s.index('{', start); depth = 1; end = brace + 1
while depth:
    depth += (s[end] == '{') - (s[end] == '}'); end += 1
method = s[start:end]
source = r'''
import Foundation
import CoreGraphics
private enum UIAccessibility { static var isReduceMotionEnabled = false }
private class Node { var isUserInteractionEnabled = true }
private class Layer {
    var bounds = CGRect.zero
    var presented: Layer?
    func presentation() -> Layer? { presented }
}
private class ScrollView {
    var contentOffset = CGPoint.zero
    func setContentOffset(_ offset: CGPoint, animated: Bool) { precondition(!animated); contentOffset = offset }
}
private class ScrollNode: Node { let layer = Layer(); let view = ScrollView(); var offsets: [CGFloat] = [] }
private enum ContainedViewLayoutTransition: Equatable {
    enum Curve { case easeInOut }
    case immediate
    case animated(duration: Double, curve: Curve)
    func animateOffsetAdditive(node: ScrollNode, offset: CGFloat) { if case .animated = self { node.offsets.append(offset) } }
}
private struct State {
    var isEditing = false
    var bio: String? = "draft"
    var birthday: Date? = Date()
    var editingBirthday = true
    var note: String? = "draft"
    func withIsEditing(_ v: Bool) -> Self { var s=self; s.isEditing=v; return s }
    func withUpdatingBio(_ v: String?) -> Self { var s=self; s.bio=v; return s }
    func withUpdatingBirthDate(_ v: Date?) -> Self { var s=self; s.birthday=v; return s }
    func withIsEditingBirthDate(_ v: Bool) -> Self { var s=self; s.editingBirthday=v; return s }
    func withUpdatingNote(_ v: String?) -> Self { var s=self; s.note=v; return s }
}
private class Header {
    var isAvatarExpanded = false
    var galleryIndex = 7
    let regularContentNode = Node()
    let editingContentNode = Node()
    func updateIsAvatarExpanded(_ expanded: Bool, transition: ContainedViewLayoutTransition, resetGallery: Bool = true) {
        isAvatarExpanded = expanded
        if expanded && resetGallery { galleryIndex = 0 }
    }
}
private class ConceptProfileEditTransition {
    var isApplyingChanges = false
    func perform(in view: Node, animated: Bool = true, changes: () -> Void) {
        isApplyingChanges = true; changes(); isApplyingChanges = false
    }
}
private class Harness {
    let view = Node()
    private let profileEditTransition = ConceptProfileEditTransition()
    var state = State()
    let scrollNode = ScrollNode()
    let headerNode = Header()
    let paneContainerNode = Node()
    var conceptAppliedPaletteKeys = [1: 2]
    var ignoreScrolling = false
    var validLayout: (CGSize, CGFloat)? = (CGSize(width: 402, height: 874), 88)
    var layouts: [ContainedViewLayoutTransition] = []
    private var profileBeforeEditing: (expanded: Bool, contentOffset: CGPoint)?
    func containerLayoutUpdated(layout: CGSize, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition, additive: Bool) {
        precondition(ignoreScrolling); precondition(profileEditTransition.isApplyingChanges); precondition(!additive); layouts.append(transition); ignoreScrolling=false
    }
    func run(_ value: Bool) { updateProfileEditing(value) }
METHOD
}
func expect(_ v: @autoclosure () -> Bool, _ message: String) { precondition(v(), message) }
private func testExpandedReturn() {
    let h=Harness(); h.headerNode.isAvatarExpanded=true
    h.run(true)
    expect(h.state.isEditing && !h.headerNode.isAvatarExpanded, "enter stock editing")
    expect(!h.headerNode.regularContentNode.isUserInteractionEnabled && h.headerNode.editingContentNode.isUserInteractionEnabled, "visible editor owns input")
    expect(!h.paneContainerNode.isUserInteractionEnabled && h.conceptAppliedPaletteKeys.isEmpty, "hide pane and invalidate palette")
    h.run(false)
    expect(!h.state.isEditing && h.headerNode.isAvatarExpanded, "restore expanded glass profile")
    expect(h.headerNode.galleryIndex == 7, "preserve the selected avatar")
    expect(h.state.bio == nil && h.state.birthday == nil && h.state.note == nil && !h.state.editingBirthday, "cancel discards drafts")
    expect(h.paneContainerNode.isUserInteractionEnabled && h.headerNode.regularContentNode.isUserInteractionEnabled, "restore profile input")
    expect(h.layouts == [.immediate, .immediate], "complete target layouts are staged behind the outgoing composite")
}
private func testCollapsedScrolledReturnAndDuplicateActions() {
    let h=Harness(); h.scrollNode.view.contentOffset=CGPoint(x:0,y:240)
    h.run(true); h.run(true)
    expect(h.layouts.count == 1 && h.scrollNode.view.contentOffset == .zero, "duplicate edit does not overwrite return position")
    h.run(false); h.run(false)
    expect(h.layouts.count == 2 && h.scrollNode.view.contentOffset.y == 240 && !h.headerNode.isAvatarExpanded, "restore collapsed scroll position once")
    expect(h.scrollNode.offsets.isEmpty, "stock dissolve never animates scroll independently")
}
private func testRepeatedAndRapidCycles() {
    let h=Harness()
    for i in 0..<5 {
        h.headerNode.isAvatarExpanded = i % 2 == 0
        h.scrollNode.view.contentOffset=CGPoint(x:0,y:CGFloat(i*50))
        h.run(true); h.run(false)
        expect(h.headerNode.isAvatarExpanded == (i % 2 == 0) && h.scrollNode.view.contentOffset.y == CGFloat(i*50), "each session restores its own state")
    }
    expect(!h.ignoreScrolling && h.layouts.count == 10, "no stuck scroll guard")
}
private func testReducedMotionAndMissingLayout() {
    UIAccessibility.isReduceMotionEnabled=true; defer { UIAccessibility.isReduceMotionEnabled=false }
    let h=Harness(); h.headerNode.isAvatarExpanded=true
    h.run(true); h.run(false)
    expect(h.layouts == [.immediate,.immediate] && h.scrollNode.offsets.isEmpty, "reduce motion disables animations")
    h.validLayout=nil; h.run(true); h.run(false)
    expect(h.headerNode.isAvatarExpanded && !h.ignoreScrolling, "unlaid out sessions still restore state")
}
private func testPresentationOffsetHandoff() {
    let h=Harness(); h.scrollNode.view.contentOffset=CGPoint(x:0,y:240)
    let layer=Layer(); layer.bounds.origin.y=120; h.scrollNode.layer.presented=layer
    h.run(true)
    expect(h.scrollNode.offsets.isEmpty, "interrupted crossfade does not add a travelling layout")
}
testExpandedReturn();testCollapsedScrolledReturnAndDuplicateActions();testRepeatedAndRapidCycles();testReducedMotionAndMissingLayout();testPresentationOffsetHandoff()
print("Passed five profile edit lifecycle cases against the production transition method; platform rendering is not covered.")
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='concept-profile-edit-host-') as temp:
    file = Path(temp)/'main.swift';file.write_text(source)
    binary=Path(temp)/'tests'
    env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
    subprocess.run(['xcrun','swiftc',str(file),'-o',str(binary)],env=env,check=True)
    subprocess.run([str(binary)],check=True)
