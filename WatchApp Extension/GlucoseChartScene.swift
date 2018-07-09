//
//  GlucoseChartScene.swift
//  WatchApp Extension
//
//  Created by Eric L N Jensen on 6/30/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import SpriteKit
import WatchKit

private func BlankLayer(size: CGSize, position: CGPoint, name: String) -> SKShapeNode {
    let blankLayer = SKShapeNode(rectOf: size)
    blankLayer.fillColor = .clear
    blankLayer.strokeColor = .clear
    blankLayer.position = position
    blankLayer.name = name
    // The userData dictionary may be used to get data to this node for drawing later:
    blankLayer.userData = NSMutableDictionary()
    return blankLayer
}

class GlucoseChartScene: SKScene {
    
    // Scale factors for converting from plotted quantities (glucose vs. time)
    // to points in the scene coordinate system.
    var graphXScale: CGFloat = 1.0
    var graphYScale: CGFloat = 1.0
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    override init(size: CGSize) {
        super.init(size: size)

        // Draw the frame, which will always be present:
        let graphFrame = SKShapeNode(rectOf: size)
        let graphMiddle = CGPoint(x: size.width/2, y: size.height/2)
        graphFrame.lineWidth = 3
        graphFrame.fillColor = .clear
        graphFrame.strokeColor = .gray
        graphFrame.position = graphMiddle
        self.addChild(graphFrame)
        /*
        // Now define some other layers to which we will add points, labels, ranges, and
        // predictions.  These aren't visible, but having these as separate layers
        // lets us easily remove these parts of the graph for redrawing. We give them
        // string names so they can easily be found by name later.
        let labelLayer = BlankLayer(size: size, position: graphMiddle, name: "labelLayer")
        addChild(labelLayer)
        let pointsLayer = BlankLayer(size: size, position: graphMiddle, name: "pointsLayer")
        pointsLayer.userData!["needsUpdating"] = false
        addChild(pointsLayer)
        addChild(BlankLayer(size: size, position: graphMiddle, name: "predictionLayer"))
        addChild(BlankLayer(size: size, position: graphMiddle, name: "rangeLayer"))
 */
        let tempLabel = SKLabelNode(text: "No data yet")
        tempLabel.fontColor = .yellow
        tempLabel.fontSize = 24
        tempLabel.position = graphMiddle
        tempLabel.verticalAlignmentMode = .center
//        childNode(withName: "labelLayer")?.addChild(tempLabel)
        self.addChild(tempLabel)
        

        // The graph x duration will always be a fixed length, so go ahead and set
        // the x scaling factor from seconds to points here:
        let graphPastHours: CGFloat = 1.0 // hours of past glucose data to show
        let graphFutureHours: CGFloat = 3.0 // hours of prediction to show
        // Scale in points per second of time:
        graphXScale = size.width / (3600 * (graphPastHours + graphFutureHours))
    }
    
    /*
    override func update(_ currentTime: TimeInterval) {
        // Do updating of the scene here.
        if let pointsLayer = childNode(withName: "pointsLayer") {
            // Move the points to the current time, or draw new ones.
            if pointsLayer.userData!["needsUpdating"] as! Bool {
                // Remove existing points:
                pointsLayer.removeAllChildren()
                // Draw new glucose points
                // Dummy code for now
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                let currentTime = formatter.string(from: Date())
                let testLabel = SKLabelNode(text: "Updated BG pts at " + currentTime)
                testLabel.fontColor = .green
                testLabel.position = pointsLayer.position
                testLabel.fontSize = 8
                pointsLayer.addChild(testLabel)
                // Code here to draw points
                pointsLayer.userData!["needsUpdating"] = false
            } else if pointsLayer.children.count > 0 {
                // Move existing points.
            }
        }
    }
    */
}
