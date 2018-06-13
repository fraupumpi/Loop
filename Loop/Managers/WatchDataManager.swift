//
//  WatchDataManager.swift
//  Loop
//
//  Created by Nathan Racklyeft on 5/29/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import HealthKit
import UIKit
import WatchConnectivity
import CarbKit
import LoopKit
import LoopUI


final class WatchDataManager: NSObject, WCSessionDelegate {

    unowned let deviceDataManager: DeviceDataManager

    init(deviceDataManager: DeviceDataManager) {
        self.deviceDataManager = deviceDataManager

        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(updateWatch(_:)), name: .LoopDataUpdated, object: deviceDataManager.loopManager)

        watchSession?.delegate = self
        watchSession?.activate()
    }

    private var watchSession: WCSession? = {
        if WCSession.isSupported() {
            return WCSession.default
        } else {
            return nil
        }
    }()

    private var lastActiveOverrideContext: GlucoseRangeSchedule.Override.Context?
    private var lastConfiguredOverrideContexts: [GlucoseRangeSchedule.Override.Context] = []

    @objc private func updateWatch(_ notification: Notification) {
        guard
            let rawUpdateContext = notification.userInfo?[LoopDataManager.LoopUpdateContextKey] as? LoopDataManager.LoopUpdateContext.RawValue,
            let updateContext = LoopDataManager.LoopUpdateContext(rawValue: rawUpdateContext),
            let session = watchSession
        else {
            return
        }

        switch updateContext {
        case .tempBasal:
            break
        case .preferences:
            let activeOverrideContext = deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.activeOverrideContext
            let configuredOverrideContexts = deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.configuredOverrideContexts ?? []
            defer {
                lastActiveOverrideContext = activeOverrideContext
                lastConfiguredOverrideContexts = configuredOverrideContexts
            }

            guard activeOverrideContext != lastActiveOverrideContext || configuredOverrideContexts != lastConfiguredOverrideContexts else {
                return
            }
        default:
            return
        }

        switch session.activationState {
        case .notActivated, .inactive:
            session.activate()
        case .activated:
            createWatchContext { (context) in
                if let context = context {
                    self.sendWatchContext(context)
                }
            }
        }
    }

    private var lastComplicationContext: WatchContext?

    private let minTrendDrift: Double = 20
    private lazy var minTrendUnit = HKUnit.milligramsPerDeciliter()

    private func sendWatchContext(_ context: WatchContext) {
        if let session = watchSession, session.isPaired && session.isWatchAppInstalled {
            let complicationShouldUpdate: Bool

            if let lastContext = lastComplicationContext,
                let lastGlucose = lastContext.glucose, let lastGlucoseDate = lastContext.glucoseDate,
                let newGlucose = context.glucose, let newGlucoseDate = context.glucoseDate
            {
                let enoughTimePassed = newGlucoseDate.timeIntervalSince(lastGlucoseDate).minutes >= 30
                let enoughTrendDrift = abs(newGlucose.doubleValue(for: minTrendUnit) - lastGlucose.doubleValue(for: minTrendUnit)) >= minTrendDrift

                complicationShouldUpdate = enoughTimePassed || enoughTrendDrift
            } else {
                complicationShouldUpdate = true
            }

            if session.isComplicationEnabled && complicationShouldUpdate {
                session.transferCurrentComplicationUserInfo(context.rawValue)
                lastComplicationContext = context
            } else {
                do {
                    try session.updateApplicationContext(context.rawValue)
                } catch let error {
                    deviceDataManager.logger.addError(error, fromSource: "WCSession")
                }
            }
        }
    }

    private func createWatchContext(_ completion: @escaping (_ context: WatchContext?) -> Void) {
        let loopManager = deviceDataManager.loopManager!

        let glucose = loopManager.glucoseStore.latestGlucose
        let reservoir = loopManager.doseStore.lastReservoirValue
        
        loopManager.glucoseStore.preferredUnit { (unit, error) in
            loopManager.getLoopState { (manager, state) in
                let eventualGlucose = state.predictedGlucose?.last
                let context = WatchContext(glucose: glucose, eventualGlucose: eventualGlucose, glucoseUnit: unit)
                context.reservoir = reservoir?.unitVolume

                context.loopLastRunDate = state.lastLoopCompleted
                context.recommendedBolusDose = state.recommendedBolus?.recommendation.amount
                context.maxBolus = manager.settings.maximumBolus

                let updateGroup = DispatchGroup()

                updateGroup.enter()
                manager.doseStore.insulinOnBoard(at: Date()) {(result) in
                    // This function completes asynchronously, so below
                    // is a completion that returns a value after eventual
                    // function completion.
                    switch result {
                    case .success(let iobValue):
                        context.IOB = iobValue.value
                    case .failure:
                        context.IOB = nil
                    }
                    updateGroup.leave()
                }
  
                if let cobValue = state.carbsOnBoard {
                    context.COB = cobValue.quantity.doubleValue(for: HKUnit.gram())
                } else {
                // we expect state.carbsOnBoard to be nil if value is zero:
                    context.COB = 0.0
                }
                
                let date = state.lastTempBasal?.startDate ?? Date()
                // Only set this value in the Watch context if there is a temp basal
                // running that hasn't ended yet:
                if let scheduledBasal = manager.basalRateSchedule?.between(start: date, end: date).first,  let lastTempBasal = state.lastTempBasal, lastTempBasal.endDate > Date() {
                    context.lastNetTempBasalDose =  lastTempBasal.unitsPerHour - scheduledBasal.value
                } else {
                    context.lastNetTempBasalDose = nil
                }
                
                let glucoseUpdateGroup = DispatchGroup()
                var glucoseVals: [Double] = []
                var glucoseDates: [Date] = []
                
                glucoseUpdateGroup.enter()
                manager.glucoseStore.getCachedGlucoseValues(start: Date().addingTimeInterval(TimeInterval(minutes: -70))) { (values) in
                    glucoseVals = values.map({
                        return $0.quantity.doubleValue(for: unit!)
                    })
                    glucoseDates = values.map({
                        return $0.startDate
                    })
                    glucoseUpdateGroup.leave()
                }
            
                // Need the above to complete before we can continue
                _ = glucoseUpdateGroup.wait(timeout: .distantFuture)

                if let glucoseTargetRangeSchedule = manager.settings.glucoseTargetRangeSchedule {
                    if let override = glucoseTargetRangeSchedule.override {
                        context.glucoseRangeScheduleOverride = GlucoseRangeScheduleOverrideUserInfo(
                            context: override.context.correspondingUserInfoContext,
                            startDate: override.start,
                            endDate: override.end
                        )
                    }
                    
                    let configuredOverrideContexts = self.deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.configuredOverrideContexts ?? []
                    let configuredUserInfoOverrideContexts = configuredOverrideContexts.map { $0.correspondingUserInfoContext }
                    context.configuredOverrideContexts = configuredUserInfoOverrideContexts
                }
                

                if glucoseVals.count > 0, let unit = context.preferredGlucoseUnit {
                    var predictedDates: [Date] = []
                    var predictedBGs: [Double] = []
                    if let predictedGlucose = state.predictedGlucose {
                         predictedBGs = predictedGlucose.map {
                            $0.quantity.doubleValue(for: unit)
                        }
                        predictedDates = predictedGlucose.map {
                                $0.startDate
                        }
                    }

                    // Now create a graphics renderer so that we can capture
                    //  a PNG snapshot of this view to send to the watch:
                    let glucoseChartSize = CGSize(width: 270, height: 152)
                    let renderer = UIGraphicsImageRenderer(size: glucoseChartSize)
                    // Set scale values for graph
                    // Make the max be the larger of the current BG values,
                    // or 175 mg/dl.  And force it to be a multiple of 25.
                    //  TODO:  Make these values work whether units are
                    // mg/dl or mmol/L.
                    // OK to force unwrap this since we know inside this if
                    // block that we have at least one value.
                    var dataBGMax = glucoseVals.max()!
                    //  If predicted value exists and is larger, use that to
                    // scale the plot instead:
                    if let predictedBGMax = predictedBGs.max(), predictedBGMax > dataBGMax {
                            dataBGMax = predictedBGMax
                        }
                    let roundedBGMax = CGFloat(25 * (1 + (Int(dataBGMax) / 25)))
                    let bgMax = roundedBGMax > 175 ? roundedBGMax : 175
                    let bgMin: CGFloat = 50
                    
                    let xMax = glucoseChartSize.width
                    let yMax = glucoseChartSize.height
                    let dateMin = Date().addingTimeInterval(TimeInterval(minutes: -60))
                    let dateMax = Date().addingTimeInterval(TimeInterval(minutes: 60))
                    let timeMax: CGFloat = CGFloat(dateMax.timeIntervalSince1970.rawValue)
                    let timeMin: CGFloat = CGFloat(dateMin.timeIntervalSince1970.rawValue)
                    let yScale = yMax/(bgMax - bgMin)
                    let xScale = xMax/(timeMax - timeMin)
                    let xNow: CGFloat = xScale * (CGFloat(Date().timeIntervalSince1970.rawValue) - timeMin)
                    let pointSize: CGFloat = 8
                    // When we draw points, they are drawn in a rectangle specified
                    // by its corner coords, so often need to shift by half a point:
                    let halfPoint = pointSize / 2
                    
                    //let glucoseSpan = Float(glucoseDates.max()!.timeIntervalSince(glucoseDates.min()!))/60.0
                    
                    //print("Timespan of glucose data is \(glucoseSpan) minutes.")
                    var x: CGFloat = 0.0
                    var y: CGFloat = 0.0
                    
                    let pointColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:1)
                    let highColor = UIColor(red:158/255, green:158/255, blue:24/255, alpha:1)
                    let lowColor = UIColor(red:158/255, green:58/255, blue:24/255, alpha:1)
                    

                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.alignment = .center
                    
                    let attrs = [NSAttributedStringKey.font: UIFont(name: "HelveticaNeue", size: 20)!, NSAttributedStringKey.paragraphStyle: paragraphStyle,
                                NSAttributedStringKey.foregroundColor: UIColor.white]
                    
                    
                    let numberFormatter = NumberFormatter()
                    numberFormatter.numberStyle = .none
      //              numberFormatter.minimumFractionDigits = 0
       //             numberFormatter.maximumFractionDigits = 0
                    
                    let bgMaxLabel = numberFormatter.string(from: NSNumber(value: Double(bgMax)))!
                    let bgMinLabel = numberFormatter.string(from: NSNumber(value: Double(bgMin)))!
                    let glucoseGraphData = renderer.pngData { (imContext) in
                        // Draw the box
                        UIColor.darkGray.setStroke()
                        imContext.stroke(renderer.format.bounds)
                        // Mark the current time with a dashed line:
                        imContext.cgContext.setLineDash(phase: 1, lengths: [6, 6])
                        imContext.cgContext.setLineWidth(3)
                        imContext.cgContext.strokeLineSegments(between: [CGPoint(x: xNow, y: 0), CGPoint(x: xNow, y: yMax - 1)])
                        // Clear the dash pattern:
                        imContext.cgContext.setLineDash(phase: 0, lengths:[])
                       // Set color for glucose points:
                        pointColor.setFill()
                        // Draw the glucose points:
                        for (date,bg) in zip(glucoseDates, glucoseVals) {
                            let bgFloat = CGFloat(bg)
                            x = xScale * (CGFloat(date.timeIntervalSince1970) - timeMin)
                            y = yScale * (bgMax - bgFloat)
                            if bgFloat > bgMax {
                                // 'high' on graph is low y coords:
                                y = halfPoint
                                highColor.setFill()
                            } else if bgFloat < bgMin {
                                y = yMax - 2
                                lowColor.setFill()
                            } else {
                                pointColor.setFill()
                            }
                            // Start by half a point width back to make
                            // rectangle centered on where we want point center:
                            imContext.cgContext.fillEllipse(in: CGRect(x: x - halfPoint, y: y - halfPoint, width: pointSize, height: pointSize))
                        }
                        pointColor.setStroke()
                        imContext.cgContext.setLineDash(phase: 11, lengths: [10, 6])
                        imContext.cgContext.setLineWidth(3)
                       // Create a path with the predicted glucose values:
                        imContext.cgContext.beginPath()
                        var predictedPoints: [CGPoint] = []
                        if predictedBGs.count > 2 {
                            for (date,bg) in zip(predictedDates, predictedBGs) {
                                let bgFloat = CGFloat(bg)
                                x = xScale * (CGFloat(date.timeIntervalSince1970) - timeMin)
                                y = yScale * (bgMax - bgFloat)
                                predictedPoints.append(CGPoint(x: x, y: y))
                            }
                            // Seems like line is cleaner without the first point:
                            predictedPoints.removeFirst(1)
                            // Add points to the path, then draw it:
                            imContext.cgContext.addLines(between: predictedPoints)
                            imContext.cgContext.strokePath()
                        }
                        // Put labels last so they are on top of text or points
                        // in case of overlap.
                        // Add a label for max BG on y axis
                        bgMaxLabel.draw(with: CGRect(x: 6, y: 4, width: 40, height: 40), options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
                        // Add a label for min BG on y axis
                        bgMinLabel.draw(with: CGRect(x: 6, y: yMax-30, width: 40, height: 40), options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
                        let timeLabel = "+1h"
                        timeLabel.draw(with: CGRect(x: xMax - 50, y: 4, width: 40, height: 40), options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
                        
                    }
                    let graphSizeKB = glucoseGraphData.count/1024
                    print("Graph size is \(graphSizeKB) kB.")

                    context.glucoseGraphImageData = glucoseGraphData
 
                }

                if let trend = self.deviceDataManager.sensorInfo?.trendType {
                    context.glucoseTrendRawValue = trend.rawValue
                }

                updateGroup.notify(queue: DispatchQueue.global(qos: .background)) {
                    completion(context)
                }

            }
        }
    }

    private func addCarbEntryFromWatchMessage(_ message: [String: Any], completionHandler: ((_ units: Double?) -> Void)? = nil) {
        if let carbEntry = CarbEntryUserInfo(rawValue: message) {
            let newEntry = NewCarbEntry(
                quantity: HKQuantity(unit: deviceDataManager.loopManager.carbStore.preferredUnit, doubleValue: carbEntry.value),
                startDate: carbEntry.startDate,
                foodType: nil,
                absorptionTime: carbEntry.absorptionTimeType.absorptionTimeFromDefaults(deviceDataManager.loopManager.carbStore.defaultAbsorptionTimes)
            )

            deviceDataManager.loopManager.addCarbEntryAndRecommendBolus(newEntry) { (result) in
                switch result {
                case .success(let recommendation):
                    AnalyticsManager.shared.didAddCarbsFromWatch(carbEntry.value)
                    completionHandler?(recommendation?.amount)
                case .failure(let error):
                    self.deviceDataManager.logger.addError(error, fromSource: error is CarbStore.CarbStoreError ? "CarbStore" : "Bolus")
                    completionHandler?(nil)
                }
            }
        } else {
            completionHandler?(nil)
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        switch message["name"] as? String {
        case CarbEntryUserInfo.name?:
            addCarbEntryFromWatchMessage(message) { (units) in
                replyHandler(BolusSuggestionUserInfo(recommendedBolus: units ?? 0, maxBolus: self.deviceDataManager.loopManager.settings.maximumBolus).rawValue)
            }
        case SetBolusUserInfo.name?:
            if let bolus = SetBolusUserInfo(rawValue: message as SetBolusUserInfo.RawValue) {
                self.deviceDataManager.enactBolus(units: bolus.value, at: bolus.startDate) { (error) in
                    if error == nil {
                        AnalyticsManager.shared.didSetBolusFromWatch(bolus.value)
                    }
                }
            }

            replyHandler([:])
        case GlucoseRangeScheduleOverrideUserInfo.name?:
            if let overrideUserInfo = GlucoseRangeScheduleOverrideUserInfo(rawValue: message) {
                let overrideContext = overrideUserInfo.context.correspondingOverrideContext

                // update the recorded last active override context prior to enabling the actual override
                // to prevent the Watch context being unnecessarily sent in response to the override being enabled
                let previousActiveOverrideContext = lastActiveOverrideContext
                lastActiveOverrideContext = overrideContext
                let overrideSuccess = deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.setOverride(overrideContext, from: overrideUserInfo.startDate, until: overrideUserInfo.effectiveEndDate)

                if overrideSuccess == false {
                    lastActiveOverrideContext = previousActiveOverrideContext
                }

                replyHandler([:])
            } else {
                lastActiveOverrideContext = nil
                deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.clearOverride()
                replyHandler([:])
            }
        default:
            replyHandler([:])
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        addCarbEntryFromWatchMessage(userInfo)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        switch activationState {
        case .activated:
            if let error = error {
                deviceDataManager.logger.addError(error, fromSource: "WCSession")
            }
        case .inactive, .notActivated:
            break
        }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if let error = error {
            deviceDataManager.logger.addError(error, fromSource: "WCSession")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        // Nothing to do here
    }

    func sessionDidDeactivate(_ session: WCSession) {
        watchSession = WCSession.default
        watchSession?.delegate = self
        watchSession?.activate()
    }
}

fileprivate extension GlucoseRangeSchedule.Override.Context {
    var correspondingUserInfoContext: GlucoseRangeScheduleOverrideUserInfo.Context {
        switch self {
        case .preMeal:
            return .preMeal
        case .workout:
            return .workout
        }
    }
}

fileprivate extension GlucoseRangeScheduleOverrideUserInfo.Context {
    var correspondingOverrideContext: GlucoseRangeSchedule.Override.Context {
        switch self {
        case .preMeal:
            return .preMeal
        case .workout:
            return .workout
        }
    }
}
