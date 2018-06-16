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
                // If we have glucose values, set up a graph to send to the
                // Watch.
                if glucoseVals.count > 0, let unit = context.preferredGlucoseUnit {
                    var predictedDates: [Date] = []
                    var predictedBGs: [Double] = []
                    
                    // Set the chart to show an hour of past BGs and an hour of future predictions:
                    let dateMin = Date().addingTimeInterval(TimeInterval(minutes: -60))
                    let dateMax = Date().addingTimeInterval(TimeInterval(minutes: 60))

                    // Get predicted BGs within our graph time window:
                    if let predictedGlucose = state.predictedGlucose {
                        for entry in predictedGlucose {
                            if entry.startDate <= dateMax {
                                predictedBGs.append(entry.quantity.doubleValue(for: unit))
                                predictedDates.append(entry.startDate)
                            }
                        }
                    }
                    
                    // Set scale values for graph
                    // Make the max be the larger of the current BG values,
                    // or 175 mg/dl, and force it to be a multiple of 25 mg/dl.
                    // If units are mmol/L, go from 3 to 10 for the default scale,
                    // and round scale to the nearest whole number (so increments
                    // in max scale of the equivalent of 18 mg/dl).
 
                    // OK to force unwrap this since we know inside this if
                    // block that we have at least one value.
                    var dataBGMax = glucoseVals.max()!
                    //  If predicted value exists and is larger, use that to
                    // scale the plot instead:
                    if let predictedBGMax = predictedBGs.max(), predictedBGMax > dataBGMax {
                            dataBGMax = predictedBGMax
                        }
                    // Depending on units we set the graph limits differently:
                    var graphMaxBG: CGFloat
                    var bgMin: CGFloat
                    var graphMaxBGIncrement: Int
                    if unit == HKUnit.millimolesPerLiter() {
                        graphMaxBG = 10
                        bgMin = 3
                        graphMaxBGIncrement = 1
                    } else {
                        graphMaxBG = 175
                        bgMin = 50
                        graphMaxBGIncrement = 25
                    }
                    let roundedBGMax = CGFloat(graphMaxBGIncrement * (1 + (Int(dataBGMax) / graphMaxBGIncrement)))
                    let bgMax = roundedBGMax > graphMaxBG ? roundedBGMax : graphMaxBG
                    
                    let glucoseChartSize = CGSize(width: 270, height: 152)
                    let xMax = glucoseChartSize.width
                    let yMax = glucoseChartSize.height
                    let timeMax: CGFloat = CGFloat(dateMax.timeIntervalSince1970.rawValue)
                    let timeMin: CGFloat = CGFloat(dateMin.timeIntervalSince1970.rawValue)
                    let timeNow: CGFloat = CGFloat(Date().timeIntervalSince1970.rawValue)
                    let yScale = yMax/(bgMax - bgMin)
                    let xScale = xMax/(timeMax - timeMin)
                    let xNow: CGFloat = xScale * (timeNow - timeMin)
                    let pointSize: CGFloat = 8
                    // When we draw points, they are drawn in a rectangle specified
                    // by its corner coords, so often need to shift by half a point:
                    let halfPoint = pointSize / 2
                    
                    var x: CGFloat = 0.0
                    var y: CGFloat = 0.0
                    
                    let pointColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:1)
                    // Target and override are the same, but with different alpha:
                    let rangeColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:0.4)
                    let overrideColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:0.6)
                    // Different color for main range(s) when override is active
                    let rangeOverridenColor = UIColor(red:158/255, green:215/255, blue:245/255, alpha:0.2)
                    let highColor = UIColor(red:158/255, green:158/255, blue:24/255, alpha:1)
                    let lowColor = UIColor(red:158/255, green:58/255, blue:24/255, alpha:1)
                    

                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.alignment = .center
                    // Shadowing could help distinguish labels from points?
                    let shadow : NSShadow = NSShadow()
                    shadow.shadowOffset = CGSize(width: -20.0, height: -20.0)
                    
                    let attrs = [NSAttributedStringKey.font: UIFont(name: "HelveticaNeue", size: 20)!, NSAttributedStringKey.paragraphStyle: paragraphStyle,
                                NSAttributedStringKey.foregroundColor: UIColor.white, NSAttributedStringKey.shadow : shadow]
                    
                    
                    let numberFormatter = NumberFormatter()
                    numberFormatter.numberStyle = .none
                    
                    let bgMaxLabel = numberFormatter.string(from: NSNumber(value: Double(bgMax)))!
                    let bgMinLabel = numberFormatter.string(from: NSNumber(value: Double(bgMin)))!
                    
                    // Now create a graphics renderer so that we can capture
                    //  a PNG snapshot of this view to send to the watch:
                    let renderer = UIGraphicsImageRenderer(size: glucoseChartSize)

                    let glucoseGraphData = renderer.pngData { (imContext) in
                        UIColor.darkGray.setStroke()
                        // Mark the current time with a dashed line:
                        imContext.cgContext.setLineDash(phase: 1, lengths: [6, 6])
                        imContext.cgContext.setLineWidth(3)
                        imContext.cgContext.strokeLineSegments(between: [CGPoint(x: xNow, y: 0), CGPoint(x: xNow, y: yMax - 1)])
                        // Clear the dash pattern:
                        imContext.cgContext.setLineDash(phase: 0, lengths:[])

                        // Set color for glucose points and target range:
                        pointColor.setFill()
                        
                        //  Plot target ranges:
                        if let targetRanges = manager.settings.glucoseTargetRangeSchedule {
                            let chartTargetRanges = targetRanges.between(start: dateMin, end: dateMax)
                                .map {
                                    return DatedRangeContext(
                                        startDate: $0.startDate,
                                        endDate: $0.endDate,
                                        minValue: $0.value.minValue,
                                        maxValue: $0.value.maxValue
                                    )
                            }
                            
                            rangeColor.setFill()

                            // Check for overrides first, since we will color the main
                            // range(s) differently depending on active override:
                            
                            // Override of target ranges.  Overrides that have
                            // expired already can still show up here, so we need
                            // to check and only show if they are active:
                            if let override = targetRanges.override, override.end ?? .distantFuture > Date() {
                                let overrideRange = DatedRangeContext(
                                    startDate: override.start,
                                    endDate: override.end ?? .distantFuture,
                                    minValue: override.value.minValue,
                                    maxValue: override.value.maxValue
                                )
                                overrideColor.setFill()
                                
                                
                                // Top left corner is start date and max value:
                                // Might be off the graph so keep it in:
                                var targetStart = CGFloat(overrideRange.startDate.timeIntervalSince1970.rawValue)
                                // Only show the part of the override that is in the future:
                                if  targetStart < timeNow {
                                    targetStart = timeNow
                                }
                                var targetEnd = CGFloat(overrideRange.endDate.timeIntervalSince1970.rawValue)
                                if  targetEnd > timeMax {
                                    targetEnd = timeMax
                                }
                                x = xScale * (targetStart - timeMin)
                                // Don't let end go off the chart:
                                let xEnd = xScale * (targetEnd - timeMin)
                                let rangeWidth = xEnd - x
                                y = yScale * (bgMax - CGFloat(overrideRange.maxValue))
                                // Make sure range is at least a couple of pixels high:
                                let rangeHeight = max(yScale * (bgMax - CGFloat(overrideRange.minValue)) - y , 3)
                                
                                imContext.cgContext.fill(CGRect(x: x, y: y, width: rangeWidth, height: rangeHeight))
                                // To mimic the Loop interface, add a second box
                                // after this that reverts to original target color:
                                if targetEnd < timeMax {
                                    rangeColor.setFill()
                                    imContext.cgContext.fill(CGRect(x: x+rangeWidth, y: y, width: xMax - (x+rangeWidth), height: rangeHeight))
                                }
                                // Set a lighter color for main range(s) to follow:
                                rangeOverridenColor.setFill()
                            }
                                
                            // chartTargetRanges may be an array, so need to
                            // iterate over it and possibly plot a target change if needed:

                            for targetRange in chartTargetRanges {
                                // Top left corner is start date and max value:
                                // Might be off the graph so keep it in:
                                var targetStart = CGFloat(targetRange.startDate.timeIntervalSince1970.rawValue)
                                if  targetStart < timeMin {
                                    targetStart = timeMin
                                }
                                var targetEnd = CGFloat(targetRange.endDate.timeIntervalSince1970.rawValue)
                                if  targetEnd > timeMax {
                                    targetEnd = timeMax
                                }
                                x = xScale * (targetStart - timeMin)
                                // Don't let end go off the chart:
                                let xEnd = xScale * (targetEnd - timeMin)
                                let rangeWidth = xEnd - x
                                y = yScale * (bgMax - CGFloat(targetRange.maxValue))
                                // Make sure range is at least a couple of pixels high:
                                let rangeHeight = max(yScale * (bgMax - CGFloat(targetRange.minValue)) - y , 3)

                                imContext.cgContext.fill(CGRect(x: x, y: y, width: rangeWidth, height: rangeHeight))
                           }
                        
                        }
               
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
                        // Clear the dash pattern:
                        imContext.cgContext.setLineDash(phase: 0, lengths:[])

                        // Put labels last so they are on top of text or points
                        // in case of overlap.
                        // Add a label for max BG on y axis
                        bgMaxLabel.draw(with: CGRect(x: 6, y: 4, width: 40, height: 40), options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
                        // Add a label for min BG on y axis
                        bgMinLabel.draw(with: CGRect(x: 6, y: yMax-28, width: 40, height: 40), options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
                        let timeLabel = "+1h"
                        timeLabel.draw(with: CGRect(x: xMax - 50, y: 4, width: 40, height: 40), options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
                        // Draw the box
                        UIColor.darkGray.setStroke()
                        imContext.stroke(renderer.format.bounds)
                    }
 
                    context.glucoseGraphImageData = glucoseGraphData
 
                }
                
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
