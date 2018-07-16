//
//  ChartInterfaceController.swift
//  Loop
//
//  Created by Bharat Mediratta on 6/26/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import WatchKit
import WatchConnectivity
import CGMBLEKit
import LoopKit
import SpriteKit


final class ChartHUDController: HUDInterfaceController {
    @IBOutlet weak var basalLabel: WKInterfaceLabel!
    @IBOutlet weak var iobLabel: WKInterfaceLabel!
    @IBOutlet weak var cobLabel: WKInterfaceLabel!
    @IBOutlet weak var glucoseChart: WKInterfaceImage!
    //@IBOutlet weak var glucoseChartScene: WKInterfaceSKScene!
    @IBOutlet var glucoseScene: WKInterfaceSKScene!
    
    private var charts = StatusChartsManager()
    
    override init() {
        super.init()

        loopManager = ExtensionDelegate.shared().loopManager
        NotificationCenter.default.addObserver(forName: .GlucoseSamplesDidChange, object: loopManager?.glucoseStore, queue: nil) { _ in
            DispatchQueue.main.async {
                self.updateGlucoseChart()
            }
        }
    }

    override func awake(withContext context: Any?) {
        if UserDefaults.standard.startOnChartPage {
            self.becomeCurrentPage()

            // For some reason, .didAppear() does not get called when we do this. It gets called *twice* the next
            // time this view appears. Force it by hand now, until we figure out the root cause.
            DispatchQueue.main.async {
                self.didAppear()
            }
            
            // Set the graph size from watch width, then calculate height
            // to get the right aspect ratio
            let currentWatch = WKInterfaceDevice.current()
            let bounds = currentWatch.screenBounds
            let graphSize = CGSize(width: bounds.width, height: bounds.width/1.78)
            let scene = GlucoseChartScene(size: graphSize)
            //let scene = SKScene(size: graphSize)
            scene.scaleMode = .aspectFit
            scene.backgroundColor = .black
            /*
            let tempLabel = SKLabelNode(text: "No data yet")
            tempLabel.fontColor = .green
            tempLabel.fontSize = 24
            tempLabel.position = CGPoint(x: graphSize.width/2, y: graphSize.height/2)
            tempLabel.verticalAlignmentMode = .center
            scene.addChild(tempLabel)
            let graphFrame = SKShapeNode(rectOf: graphSize)
            let graphMiddle = CGPoint(x: graphSize.width/2, y: graphSize.height/2)
            graphFrame.lineWidth = 3
            graphFrame.fillColor = .clear
            graphFrame.strokeColor = .gray
            graphFrame.position = graphMiddle
            scene.addChild(graphFrame)
*/
            // Not really doing animation, so set this as low as possible:
            // self.glucoseScene.preferredFramesPerSecond = 1
            self.glucoseScene.presentScene(scene)

            // still needed?
 //           self.charts.glucoseScene = scene
 
        }
    }

    override func didAppear() {
        super.didAppear()
    }

    override func willActivate() {
        super.willActivate()

        loopManager?.glucoseStore.maybeRequestGlucoseBackfill()
    }

    override func update() {
        super.update()

        guard let activeContext = loopManager?.activeContext else {
            return
        }

        let insulinFormatter: NumberFormatter = {
            let numberFormatter = NumberFormatter()
            
            numberFormatter.numberStyle = .decimal
            numberFormatter.minimumFractionDigits = 1
            numberFormatter.maximumFractionDigits = 1
            
            return numberFormatter
        }()
        
        iobLabel.setHidden(true)
        if let activeInsulin = activeContext.IOB, let valueStr = insulinFormatter.string(from:NSNumber(value:activeInsulin)) {
            iobLabel.setText(String(format: NSLocalizedString(
                "IOB %1$@ U",
                comment: "The subtitle format describing units of active insulin. (1: localized insulin value description)"),
                                       valueStr))
            iobLabel.setHidden(false)
        }
        
        cobLabel.setHidden(true)
        if let carbsOnBoard = activeContext.COB {
            let carbFormatter = NumberFormatter()
            carbFormatter.numberStyle = .decimal
            carbFormatter.maximumFractionDigits = 0
            let valueStr = carbFormatter.string(from:NSNumber(value:carbsOnBoard))
            
            cobLabel.setText(String(format: NSLocalizedString(
                "COB %1$@ g",
                comment: "The subtitle format describing grams of active carbs. (1: localized carb value description)"),
                                      valueStr!))
            cobLabel.setHidden(false)
        }
        
        basalLabel.setHidden(true)
        if let tempBasal = activeContext.lastNetTempBasalDose {
            let basalFormatter = NumberFormatter()
            basalFormatter.numberStyle = .decimal
            basalFormatter.minimumFractionDigits = 1
            basalFormatter.maximumFractionDigits = 3
            basalFormatter.positivePrefix = basalFormatter.plusSign
            let valueStr = basalFormatter.string(from:NSNumber(value:tempBasal))
            
            let basalLabelText = String(format: NSLocalizedString(
                "%1$@ U/hr",
                comment: "The subtitle format describing the current temp basal rate. (1: localized basal rate description)"),
                                      valueStr!)
            basalLabel.setText(basalLabelText)
            basalLabel.setHidden(false)
        }

        updateGlucoseChart()
    }

    func updateGlucoseChart() {
        guard let activeContext = loopManager?.activeContext else {
            return
        }

        charts.predictedGlucose = activeContext.predictedGlucose?.values
        charts.targetRanges = activeContext.targetRanges
        charts.temporaryOverride = activeContext.temporaryOverride
        charts.unit = activeContext.preferredGlucoseUnit

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        loopManager?.glucoseStore.getCachedGlucoseSamples(start: .EarliestGlucoseCutoff) { (samples) in
            self.charts.historicalGlucose = samples
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)

        self.glucoseChart.setHidden(true)
        if let chart = self.charts.glucoseChart() {
            self.glucoseChart.setImage(chart)
            self.glucoseChart.setHidden(false)
        }
        
        if let pointsLayer = self.glucoseScene.scene?.childNode(withName: "pointsLayer") {
            pointsLayer.userData!["glucosePoints"] = self.charts.historicalGlucose
            // Set the flag that will tell the SpriteKit scene to update glucose plot. 
            pointsLayer.userData!["needsUpdating"] = true
        }
    }
}
