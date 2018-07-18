//
//  GlucosePoint.swift
//  WatchApp Extension
//
//  Created by Eric L N Jensen on 7/11/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import SpriteKit
import LoopKit
import HealthKit

final class GlucosePoint: SKShapeNode {
    // Class for each point that will be plotted on the glucose graph
    // Note: SKShapeNode has only convenience initializers so we can't
    // inherit them here, and we have to create the required path ourselves
    // by initializing the parent object first and then setting its path property.
    
    var time: Date
    var glucose: HKQuantity
    var unit: HKUnit
    
    init(value: SampleValue, unit: HKUnit) {
        let pointSize: CGFloat = 2.5
        let pointColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:1)

        self.glucose = value.quantity
        self.time = value.startDate
        self.unit = unit
        super.init()
        let pointRect = CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: pointSize, height: pointSize))
        self.path = CGPath(ellipseIn: pointRect, transform: nil)
        self.fillColor = pointColor
        self.strokeColor = .clear
        self.alpha = 1
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func hoursFromNow() -> CGFloat {
        return CGFloat(self.time.timeIntervalSinceNow.hours)
    }
}
