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

private func BlankLayer(size: CGSize, position: CGPoint, name: String) -> SKSpriteNode {
    let blankLayer = SKSpriteNode(color: UIColor.clear, size: size)
    // Even though this node is transparent, we want its children be visible:
    blankLayer.blendMode = .add
    blankLayer.position = position
    blankLayer.name = name
    // In general we want objects to be placed in this node relative to the lower left corner:
    blankLayer.anchorPoint = CGPoint(x: 0, y: 0)
    return blankLayer
}

final class GlucoseChartScene: SKScene {
    
    // Scale factors for converting from plotted quantities (glucose vs. time)
    // to points in the scene coordinate system.
    var graphXScale: CGFloat = 1.0
    var graphYScale: CGFloat = 1.0
    // The graph x duration will always be a fixed length, so go ahead and set
    // the x scaling factor from seconds to points here:
    let graphPastHours: CGFloat = 2.0 // hours of past glucose data to show
    // If this is changed to a non-integer, be sure to change number formatting of label below
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

        let graphMiddle = CGPoint(x: size.width/2, y: size.height/2)
        let zeroPoint = CGPoint(x: 0, y:0)
        self.anchorPoint = zeroPoint

        // Draw the frame, which will always be present:
        let graphFrame = SKShapeNode(rectOf: size)

        graphFrame.lineWidth = 2
        graphFrame.fillColor = .clear
        graphFrame.strokeColor = .gray
        graphFrame.position = graphMiddle
        self.addChild(graphFrame)

        // Scale in points per hour of time:
        self.graphXScale = size.width / (graphPastHours + graphFutureHours)
        
        // Draw the line for the current time:
        let nowPath = CGMutablePath()
        let xNow = graphPastHours*self.graphXScale
        nowPath.move(to: CGPoint(x: xNow, y: 0))
        nowPath.addLine(to: CGPoint(x: xNow, y: size.height))
        let nowLine = SKShapeNode(path: nowPath.copy(dashingWithPhase: 0, lengths: [3, 3]))
        nowLine.strokeColor = .gray
        nowLine.lineWidth = 2
        self.addChild(nowLine)
        
        // Now define some other layers to which we will add points, labels, ranges, and
        // predictions.  These aren't visible, but having these as separate layers
        // lets us easily remove these parts of the graph for redrawing. We give them
        // string names so they can easily be found by name later.
        let labelLayer = BlankLayer(size: size, position: zeroPoint, name: "labelLayer")
        self.addChild(labelLayer)
        let pointsLayer = BlankLayer(size: size, position: zeroPoint, name: "pointsLayer")
        self.addChild(pointsLayer)
        self.addChild(BlankLayer(size: size, position: zeroPoint, name: "predictionLayer"))
        self.addChild(BlankLayer(size: size, position: zeroPoint, name: "rangeLayer"))
 
        let tempLabel = SKLabelNode(text: "No data yet")
        tempLabel.alpha = 1.0
        tempLabel.fontColor = .yellow
        tempLabel.fontSize = 24
        tempLabel.position = graphMiddle
        tempLabel.verticalAlignmentMode = .center
        tempLabel.horizontalAlignmentMode = .center
        labelLayer.addChild(tempLabel)
        
        // Add labels for the time, the max BG, and the min BG, even if we
        // don't yet know what all of the values will be.  We can later change the
        // label text by addressing the labels by name:
 
        // Maybe there's a way to specify these attributes only once?
        // But can't quite figure it out yet.  Could do a class but
        // seems like a bit of overkill here.
        let labelFontSize: CGFloat = 12
        
        // Make labels a little transparent to see points behind...
        let labelAlpha: CGFloat = 0.8
        
        let maxBGLabel = SKLabelNode(text: "--")
        maxBGLabel.position = CGPoint(x: 14, y: size.height - 15)
        maxBGLabel.fontSize = labelFontSize
        maxBGLabel.fontName = "HelveticaNeue"
        maxBGLabel.fontColor = .white
        maxBGLabel.alpha = labelAlpha
        maxBGLabel.name = "maxBGLabel"
        self.addChild(maxBGLabel)
    
        let minBGLabel = SKLabelNode(text: "--")
        minBGLabel.position = CGPoint(x: 14, y: 4)
        minBGLabel.fontSize = labelFontSize
        minBGLabel.fontName = "HelveticaNeue"
        minBGLabel.fontColor = .white
        minBGLabel.alpha = labelAlpha
        minBGLabel.name = "minBGLabel"
        self.addChild(minBGLabel)
        
        let formatter = NumberFormatter()
        // Change this if setting graph hours to non-integer
        formatter.maximumFractionDigits = 0
        let timeLabelText = "+" + formatter.string(from: Double(graphFutureHours))! + "h"
        let timeLabel = SKLabelNode(text: timeLabelText)
        timeLabel.position = CGPoint(x: size.width - 15, y: size.height - 15)
        timeLabel.fontSize = labelFontSize
        timeLabel.fontName = "HelveticaNeue"
        timeLabel.fontColor = .white
        timeLabel.alpha = 1
        timeLabel.name = "timeLabel"
        self.addChild(timeLabel)
        
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
        // the graph for subsequent plotting, and the labeling of the y axis. 
        
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
        
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        
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

        if let minBGLabel = childNode(withName: "minBGLabel") as! SKLabelNode? {
            minBGLabel.text = formatter.string(from: Double(self.graphBGMin))
        }
        
        if let maxBGLabel = childNode(withName: "maxBGLabel") as! SKLabelNode? {
            maxBGLabel.text = formatter.string(from: Double(self.graphBGMax))
        }
        
        // Set the y scale of the graph in points per unit of BG.
        self.graphYScale = self.size.height/(self.graphBGMax - self.graphBGMin)
    }
    
    /*
     // Could possibly use this to animate the points to move between glucose updates
    override func update(_ currentTime: TimeInterval) {
        // Do updating of the scene here.
        if let pointsLayer = childNode(withName: "pointsLayer") {
     // Move the points to the current time:
            if pointsLayer.children.count > 0 {
                // Move existing points, using their "time" property
            }
        }
    }
    */
}
