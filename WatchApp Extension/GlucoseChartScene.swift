//
//  GlucoseChartScene.swift
//  WatchApp Extension
//
//  Created by Eric L N Jensen on 6/30/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import SpriteKit
import HealthKit

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

final class GlucoseChartScene: SKScene {
    
    // Scale factors for converting from plotted quantities (glucose vs. time)
    // to points in the scene coordinate system.
    var graphXScale: CGFloat = 1.0
    var graphYScale: CGFloat = 1.0
    // The graph x duration will always be a fixed length, so go ahead and set
    // the x scaling factor from seconds to points here:
    let graphPastHours: CGFloat = 1.0 // hours of past glucose data to show
    let graphFutureHours: CGFloat = 3.0 // hours of prediction to show

    // Values setting the BG range of the y axis
    // These initialization are mg/dl, but get changed to appropriate mmol/L as needed.
    var graphBGMin: CGFloat = 50.0
    var graphBGMax: CGFloat = 175.0
    
    let pointColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:1)
    // Target and override are the same, but with different alpha:
    let rangeColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:0.4)
    let overrideColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:0.6)
    // Different alpha for main range(s) when override is active
    let rangeOverridenColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:0.2)
    let highColor = UIColor(red:158/255, green:158/255, blue:24/255, alpha:1)
    let lowColor = UIColor(red:158/255, green:58/255, blue:24/255, alpha:1)


    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    override init(size: CGSize) {
        super.init(size: size)

        // Draw the frame, which will always be present:
        let graphFrame = SKShapeNode(rectOf: size)
        let graphMiddle = CGPoint(x: size.width/2, y: size.height/2)
        graphFrame.lineWidth = 2
        graphFrame.fillColor = .clear
        graphFrame.strokeColor = .gray
        graphFrame.position = graphMiddle
        self.addChild(graphFrame)

        // Scale in points per hour of time:
        self.graphXScale = size.width / (graphPastHours + graphFutureHours)
        
        // Now define some other layers to which we will add points, labels, ranges, and
        // predictions.  These aren't visible, but having these as separate layers
        // lets us easily remove these parts of the graph for redrawing. We give them
        // string names so they can easily be found by name later.
        let labelLayer = BlankLayer(size: size, position: CGPoint(x: 0, y:0), name: "labelLayer")
        self.addChild(labelLayer)
        let pointsLayer = BlankLayer(size: size, position: graphMiddle, name: "pointsLayer")
        self.addChild(pointsLayer)
        self.addChild(BlankLayer(size: size, position: graphMiddle, name: "predictionLayer"))
        self.addChild(BlankLayer(size: size, position: graphMiddle, name: "rangeLayer"))
 
        let tempLabel = SKLabelNode(text: "No data yet")
        tempLabel.fontColor = .yellow
        tempLabel.fontSize = 24
        tempLabel.position = graphMiddle
        tempLabel.verticalAlignmentMode = .center
//        childNode(withName: "labelLayer")?.addChild(tempLabel)
        labelLayer.addChild(tempLabel)
        
     }
    
    func xCoord(coordTime: Date) -> CGFloat {
        // Return the x coordinate in the scene, in points, given an input time.
        let hoursFromNow = CGFloat(coordTime.timeIntervalSinceNow.hours)
        return ((self.graphPastHours + hoursFromNow)*self.graphXScale)
    }
    
    func yCoord(coordBG: CGFloat) -> CGFloat {
        // Return the y coordinate in the scene, in points, given an input BG.
        return ((coordBG - self.graphBGMin)*self.graphYScale)
    }
    
    func setYScale(dataBGMax: CGFloat, unit: HKUnit) {
        // Sets an appropriate maximum value for the graph, depending on the max
        // BG value passed in and on the unit.  Also updates the y scaling of
        // the graph for subsequent plotting.
        
        // Depending on units we set the graph limits differently:
        var graphMaxBGFloor: CGFloat
        var graphMaxBGIncrement: Int
        var graphYPadding: CGFloat
        
        if unit == HKUnit.millimolesPerLiter {
            graphMaxBGFloor = 10
            self.graphBGMin = 3
            graphMaxBGIncrement = 1
            graphYPadding = 0.1
        } else {
            graphMaxBGFloor = 175
            self.graphBGMin = 50
            graphMaxBGIncrement = 25
            graphYPadding = 2
        }
        
        // Set the maximum value of the graph in discrete steps (25 mg/dl or 1 mmol/L)
        // by doing integer division to get whole number of steps and adding 1 step
        var roundedBGMax = CGFloat(graphMaxBGIncrement * (1 + (Int(dataBGMax) / graphMaxBGIncrement)))
        // The graphYPadding gives a little headroom if max data value is right at the limit.
        if (roundedBGMax - CGFloat(dataBGMax)) <= graphYPadding {
            roundedBGMax += CGFloat(graphMaxBGIncrement)
        }
        // Set the graph max to some default max values if BGs are low, or raise
        // in steps set by the above.
        self.graphBGMax = roundedBGMax > graphMaxBGFloor ? roundedBGMax : graphMaxBGFloor

        // Set the y scale of the graph in points per unit of BG. 
        self.graphYScale = self.size.height/(self.graphBGMax - self.graphBGMin)
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
