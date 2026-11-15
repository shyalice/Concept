import Foundation
import UIKit
import Display
import AsyncDisplayKit
import AccountContext
import TelegramPresentationData

final class PeerInfoScreenItemSectionContainerNode: ASDisplayNode {
    private let backgroundNode: ASDisplayNode
    private let cardNode = ASDisplayNode()
    private let material = ConceptProfileMaterialView()
    private var hasBackdropAppearance = false
    private var materialLayoutGeneration: UInt = 0
    private var lastLayout: (AccountContext, CGFloat, UIEdgeInsets, Bool, [PeerInfoScreenItem], Bool)?

    func updateBackdrop(tintColor: UIColor, targetColor: UIColor, fraction: CGFloat, isDark: Bool, transition: ContainedViewLayoutTransition) {
        let transition: ContainedViewLayoutTransition = self.hasBackdropAppearance ? transition : .immediate
        self.hasBackdropAppearance = true
        self.material.updateAppearance(tintColor: tintColor, targetColor: targetColor, fraction: fraction, isDark: isDark, transition: transition)
    }

    func updateAppearance(presentationData: PresentationData) {
        guard let (context, width, safeInsets, hasCorners, items, glass) = self.lastLayout else { return }
        _ = self.update(context: context, width: width, safeInsets: safeInsets, hasCorners: hasCorners, presentationData: presentationData, items: items, glass: glass, transition: .immediate)
    }
    private let topSeparatorNode: ASDisplayNode
    private let bottomSeparatorNode: ASDisplayNode
    private let itemContainerNode: ASDisplayNode
    
    private var currentItems: [PeerInfoScreenItem] = []
    var itemNodes: [AnyHashable: PeerInfoScreenItemNode] = [:]
    
    override init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        
        self.topSeparatorNode = ASDisplayNode()
        self.topSeparatorNode.isLayerBacked = true
        
        self.bottomSeparatorNode = ASDisplayNode()
        self.bottomSeparatorNode.isLayerBacked = true
        
        self.itemContainerNode = ASDisplayNode()
        self.itemContainerNode.clipsToBounds = true
        
        super.init()
        
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.itemContainerNode)
        self.cardNode.clipsToBounds = true
        self.cardNode.layer.cornerCurve = .continuous
        self.cardNode.layer.cornerRadius = 24.0
        self.material.isUserInteractionEnabled = false
        self.cardNode.view.addSubview(self.material)
        self.itemContainerNode.addSubnode(self.cardNode)
        self.addSubnode(self.topSeparatorNode)
        self.addSubnode(self.bottomSeparatorNode)
    }
    
    func update(context: AccountContext, width: CGFloat, safeInsets: UIEdgeInsets, hasCorners: Bool, presentationData: PresentationData, items: [PeerInfoScreenItem], glass: Bool = false, transition: ContainedViewLayoutTransition) -> CGFloat {
        let useGlass = glass && hasCorners && !UIAccessibility.isReduceTransparencyEnabled
        self.lastLayout = (context, width, safeInsets, hasCorners, items, glass)
        self.cardNode.isHidden = !useGlass
        self.cardNode.backgroundColor = .clear
        self.cardNode.layer.borderWidth = 0.0
        self.cardNode.layer.borderColor = nil
        self.backgroundNode.backgroundColor = useGlass ? .clear : presentationData.theme.list.itemBlocksBackgroundColor
        self.topSeparatorNode.backgroundColor = presentationData.theme.list.itemBlocksSeparatorColor
        self.bottomSeparatorNode.backgroundColor = presentationData.theme.list.itemBlocksSeparatorColor
        
        self.topSeparatorNode.isHidden = hasCorners
        self.bottomSeparatorNode.isHidden = hasCorners
        
        var contentHeight: CGFloat = 0.0
        var contentWithBackgroundHeight: CGFloat = 0.0
        var contentWithBackgroundOffset: CGFloat = 0.0
        
        for i in 0 ..< items.count {
            let item = items[i]
            
            let itemNode: PeerInfoScreenItemNode
            var wasAdded = false
            if let current = self.itemNodes[item.id] {
                itemNode = current
            } else {
                wasAdded = true
                itemNode = item.node()
                self.itemNodes[item.id] = itemNode
                (useGlass && !(item is PeerInfoScreenHeaderItem) && !(item is PeerInfoScreenCommentItem) ? self.cardNode : self.itemContainerNode).addSubnode(itemNode)
                itemNode.bringToFrontForHighlight = { [weak itemNode] in
                    guard let itemNode = itemNode else {
                        return
                    }
                    itemNode.view.superview?.bringSubviewToFront(itemNode.view)
                }
            }
            
            let itemTransition: ContainedViewLayoutTransition = wasAdded ? .immediate : transition
            
            let topItem: PeerInfoScreenItem?
            if i == 0 {
                topItem = nil
            } else if items[i - 1] is PeerInfoScreenHeaderItem {
                topItem = nil
            } else {
                topItem = items[i - 1]
            }
            
            let bottomItem: PeerInfoScreenItem?
            if i == items.count - 1 {
                bottomItem = nil
            } else if items[i + 1] is PeerInfoScreenCommentItem {
                bottomItem = nil
            } else {
                bottomItem = items[i + 1]
            }
            
            let itemHeight = itemNode.update(context: context, width: width, safeInsets: safeInsets, presentationData: presentationData, item: item, topItem: topItem, bottomItem: bottomItem, hasCorners: hasCorners && !useGlass, transition: itemTransition)
            let isCardRow = useGlass && !(item is PeerInfoScreenHeaderItem) && !(item is PeerInfoScreenCommentItem)
            let parent = isCardRow ? self.cardNode : self.itemContainerNode
            if itemNode.supernode !== parent { parent.addSubnode(itemNode) }
            let itemFrame = CGRect(origin: CGPoint(x: 0.0, y: contentHeight - (isCardRow ? contentWithBackgroundOffset : 0.0)), size: CGSize(width: width, height: itemHeight))
            itemTransition.updateFrame(node: itemNode, frame: itemFrame)
            if wasAdded {
                itemNode.alpha = 0.0
                let alphaTransition: ContainedViewLayoutTransition = transition.isAnimated ? .animated(duration: 0.35, curve: .linear) : .immediate
                alphaTransition.updateAlpha(node: itemNode, alpha: 1.0)
            }
            
            if item is PeerInfoScreenCommentItem {
            } else {
                contentWithBackgroundHeight += itemHeight
            }
            contentHeight += itemHeight
            
            if item is PeerInfoScreenHeaderItem {
                contentWithBackgroundOffset = contentHeight
            }
        }
        
        var removeIds: [AnyHashable] = []
        for (id, _) in self.itemNodes {
            if !items.contains(where: { $0.id == id }) {
                removeIds.append(id)
            }
        }
        for id in removeIds {
            if let itemNode = self.itemNodes.removeValue(forKey: id) {
                itemNode.view.superview?.sendSubviewToBack(itemNode.view)
                transition.updateAlpha(node: itemNode, alpha: 0.0, completion: { [weak itemNode] _ in
                    itemNode?.removeFromSupernode()
                })
            }
        }
        
        transition.updateFrame(node: self.itemContainerNode, frame: CGRect(origin: CGPoint(), size: CGSize(width: width, height: contentHeight)))
        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentWithBackgroundOffset), size: CGSize(width: width, height: max(0.0, contentWithBackgroundHeight - contentWithBackgroundOffset))))
        // Animate the one outer clip, keeping the blur's sampling area large enough
        // for both heights. Resizing a live backdrop during this animation flashes a band.
        self.materialLayoutGeneration &+= 1
        let generation = self.materialLayoutGeneration
        let materialSize = self.backgroundNode.frame.size
        let samplingSize = CGSize(width: materialSize.width, height: transition.isAnimated ? max(materialSize.height, self.material.bounds.height) : materialSize.height)
        self.material.frame = CGRect(origin: .zero, size: samplingSize)
        self.material.updateLayout(size: samplingSize, radius: 0.0, transition: .immediate)
        transition.updateFrame(node: self.cardNode, frame: self.backgroundNode.frame, completion: { [weak self] _ in
            guard let self, self.materialLayoutGeneration == generation else { return }
            self.material.frame = CGRect(origin: .zero, size: materialSize)
            self.material.updateLayout(size: materialSize, radius: 0.0, transition: .immediate)
        })
        if !self.hasBackdropAppearance {
            self.material.updateAppearance(color: presentationData.theme.list.itemModalBlocksBackgroundColor, isDark: presentationData.theme.overallDarkAppearance)
        }
        self.cardNode.view.sendSubviewToBack(self.material)
        transition.updateFrame(node: self.topSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentWithBackgroundOffset - UIScreenPixel), size: CGSize(width: width, height: UIScreenPixel)))
        transition.updateFrame(node: self.bottomSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentWithBackgroundHeight), size: CGSize(width: width, height: UIScreenPixel)))
        
        if contentHeight.isZero {
            transition.updateAlpha(node: self.topSeparatorNode, alpha: 0.0)
            transition.updateAlpha(node: self.bottomSeparatorNode, alpha: 0.0)
        } else {
            transition.updateAlpha(node: self.topSeparatorNode, alpha: 1.0)
            transition.updateAlpha(node: self.bottomSeparatorNode, alpha: 1.0)
        }
        
        return contentHeight
    }
    
    func animateErrorIfNeeded() {
        for (_, itemNode) in self.itemNodes {
            if let itemNode = itemNode as? PeerInfoScreenMultilineInputItemNode {
                itemNode.animateErrorIfNeeded()
            }
        }
    }
}
