import XCTest
import CoreGraphics

final class GamepadPreviewUITests: XCTestCase {
    func testControlsAndLayouts() {
        continueAfterFailure=true
        XCUIDevice.shared.orientation = .landscapeLeft
        let app=XCUIApplication();app.launch()
        XCUIDevice.shared.orientation = .landscapeRight
        if PreviewFixture.isNativeDuo {
            if app.frame.width<900 || app.frame.height<600 { print("HENGE_DUO_UNFOLD_REQUIRED") }
            let unfolded=NSPredicate { _,_ in app.frame.width>=900 && app.frame.height>=600 }
            guard XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:unfolded,object:nil)],timeout:90) == .completed else {
                XCTFail("Duo app did not reach the unfolded inner-screen window");return
            }
            let geometry=XCTAttachment(string:"Native Duo app window: \(app.frame)");geometry.name="Verified unfolded native Duo window";geometry.lifetime = .keepAlways;add(geometry)
        }
        let surface=app.otherElements["gamepad-surface"].firstMatch
        guard surface.waitForExistence(timeout:15) else { XCTFail("Production gamepad surface missing");return }
        if PreviewFixture.profile == "duo-unfolded" && !PreviewFixture.isNativeDuo {
            XCTAssertEqual(surface.frame.width,951,accuracy:1,"Duo alternative must test the actual unfolded viewport width")
        }
        var proofs=0
        func capture(_ name: String) {
            let camera=app.buttons["capture-window-proof"]
            // Modal settings cover the fixture toolbar; its image is already
            // represented by the preceding/following direct window captures.
            if !name.hasSuffix("-settings") {
                XCTAssertTrue(camera.isHittable,"Direct window capture must be reachable outside the settings sheet")
                camera.tap();proofs += 1
                XCTAssertEqual(app.staticTexts["window-proof-status"].value as? String,String(proofs))
                print("HENGE_WINDOW_PROOF \(proofs) \(name)")
            }
            let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot());attachment.name=name+"-display";attachment.lifetime = .keepAlways;add(attachment)
            let window=XCTAttachment(screenshot:app.screenshot());window.name=name+"-app";window.lifetime = .keepAlways;add(window)
        }
        func tap(_ control: PadControl,portrait:Bool = false) {
            let size=surface.frame.size
            let r=PadLayout(bounds:CGRect(origin:.zero,size:size),size:1,portrait:portrait).rect(control)
            surface.coordinate(withNormalizedOffset:CGVector(dx:r.midX/size.width,dy:r.midY/size.height)).tap()
        }
        app.buttons["show-home"].tap()
        let launch=app.buttons["launch-mac"]
        XCTAssertTrue(launch.waitForExistence(timeout:5))
        XCTAssertTrue(launch.isHittable)
        capture("\(PreviewFixture.profile)-home-ready-dark")
        launch.tap()
        XCTAssertEqual(app.staticTexts["home-actions"].label,"Actions: 1")
        app.buttons["home-state"].tap()
        XCTAssertTrue(app.staticTexts["Resume Mac"].exists || launch.label.contains("Resume Mac"))
        capture("\(PreviewFixture.profile)-home-resume")
        app.buttons["home-theme"].tap()
        capture("\(PreviewFixture.profile)-home-light")
        app.buttons["home-state"].tap()
        XCTAssertTrue(app.staticTexts["Enable JIT"].exists || launch.label.contains("Enable JIT"))
        launch.tap()
        XCTAssertEqual(app.staticTexts["home-actions"].label,"Actions: 2")
        capture("\(PreviewFixture.profile)-home-setup")
        app.buttons["home-state"].tap()
        XCTAssertTrue(app.staticTexts["Continue Mac"].exists || launch.label.contains("Continue Mac"))
        capture("\(PreviewFixture.profile)-home-paused")
        app.buttons["show-home"].tap()
        XCTAssertTrue(surface.waitForExistence(timeout:5))
        capture("\(PreviewFixture.profile)-local-default")
        let bounds=XCTAttachment(string:app.debugDescription);bounds.name="Initial production UI bounds";bounds.lifetime = .keepAlways;add(bounds)
        tap(.a)
        XCTAssertEqual(app.staticTexts["a-count"].label,"A presses: 1")
        XCTAssertEqual(app.staticTexts["buttons"].label,"Buttons: 0")
        let size=surface.frame.size,r=PadLayout(bounds:CGRect(origin:.zero,size:size),size:1).rect(.move)
        let origin=surface.coordinate(withNormalizedOffset:CGVector(dx:r.midX/size.width,dy:r.midY/size.height))
        origin.press(forDuration:0.1,thenDragTo:origin.withOffset(CGVector(dx:r.width,dy:0)))
        let maximum=app.staticTexts["left-max"]
        XCTAssertTrue(maximum.waitForExistence(timeout:5))
        let touchTrace=XCTAttachment(string:surface.value as? String ?? "no touch trace");touchTrace.name="Production touch trace after drag";touchTrace.lifetime = .keepAlways;add(touchTrace)
        capture("\(PreviewFixture.profile)-after-stick-drag")
        let motion=NSPredicate { _,_ in (Int(maximum.value as? String ?? "") ?? -1)>20000 }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:motion,object:nil)],timeout:5),.completed,"Stick movement did not reach the production callback")
        XCTAssertEqual(app.staticTexts["buttons"].label,"Buttons: 0")
        // UIKeyInput is reported as TextView by legacy AX and Other by modern
        // AX on the installed runtime. Match its unique native identifier.
        func pointingSurface(_ id:String)->XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
        let gamepadPad=pointingSurface("gamepad-touchpad")
        XCTAssertTrue(gamepadPad.waitForExistence(timeout:5))
        let padCenter=gamepadPad.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        padCenter.press(forDuration:0.1,thenDragTo:padCenter.withOffset(CGVector(dx:40,dy:8)))
        XCTAssertGreaterThan(Int(app.staticTexts["moves"].value as? String ?? "") ?? -1,0,"Gamepad touchpad must use the production pointer callback")
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Gamepad settings"].waitForExistence(timeout:5))
        XCTAssertTrue(app.sliders["Movement sensitivity"].exists)
        app.sliders["Movement sensitivity"].adjust(toNormalizedSliderPosition:0.7)
        let sensitivity=app.sliders["Touchpad movement speed"]
        app.swipeUp()
        XCTAssertTrue(sensitivity.waitForExistence(timeout:5))
        sensitivity.adjust(toNormalizedSliderPosition:0.6)
        XCTAssertTrue(app.sliders["Touchpad scrolling speed"].exists)
        capture("\(PreviewFixture.profile)-settings")
        app.buttons["Done"].tap()
        app.buttons["switch-layout"].tap()
        XCTAssertTrue(surface.waitForExistence(timeout:5))
        capture("\(PreviewFixture.profile)-wireless-gamepad")
        app.buttons["Touchpad"].tap()
        let input=pointingSurface("wireless-input-surface")
        XCTAssertTrue(input.waitForExistence(timeout:5))
        let center=input.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        center.press(forDuration:0.1,thenDragTo:center.withOffset(CGVector(dx:80,dy:20)))
        XCTAssertGreaterThan(Int(app.staticTexts["moves"].value as? String ?? "") ?? -1,0)
        capture("\(PreviewFixture.profile)-wireless-touchpad")
        app.buttons["Keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5))
        app.typeText("abc")
        XCTAssertGreaterThanOrEqual(Int(app.staticTexts["keys"].value as? String ?? "") ?? -1,3)
        capture("\(PreviewFixture.profile)-wireless-keyboard")
        app.buttons["Gamepad"].tap()
        XCTAssertTrue(surface.waitForExistence(timeout:5))
        if PreviewFixture.profile == "duo-unfolded" {
            app.buttons["Controller layout"].tap()
            app.buttons["Tabletop"].tap()
            let tabletop=pointingSurface("tabletop-touchpad")
            XCTAssertTrue(tabletop.waitForExistence(timeout:5))
            XCTAssertLessThan(tabletop.frame.maxY,surface.frame.minY,"The hinge gap must separate the touchpad and controller")
            tap(.a)
            let before=Int(app.staticTexts["moves"].value as? String ?? "") ?? 0
            let topCenter=tabletop.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
            topCenter.press(forDuration:0.1,thenDragTo:topCenter.withOffset(CGVector(dx:40,dy:8)))
            XCTAssertGreaterThan(Int(app.staticTexts["moves"].value as? String ?? "") ?? -1,before)
            capture("duo-tabletop-gamepad")
            app.buttons["Controller layout"].tap();app.buttons["Automatic"].tap()
            app.buttons["fold"].tap()
            XCTAssertTrue(gamepadPad.waitForExistence(timeout:5))
            XCTAssertGreaterThan(gamepadPad.frame.height,100,"Portrait must use the large touchpad above full-size controls")
            tap(.a,portrait:true)
            XCTAssertEqual(app.staticTexts["buttons"].label,"Buttons: 0")
            capture("duo-portrait-gamepad")
            app.buttons["video"].tap()
            let video=app.staticTexts["video-fixture"]
            XCTAssertTrue(video.waitForExistence(timeout:5))
            XCTAssertLessThan(video.frame.maxY,surface.frame.minY,"Portrait video stays above the controller deck")
            capture("duo-portrait-ds-video")
            app.buttons["fold"].tap()
            XCTAssertTrue(video.waitForExistence(timeout:5))
            XCTAssertGreaterThan(surface.frame.width,600,"Unfolding restores the landscape overlay")
            capture("duo-landscape-fullscreen-video")
            app.buttons["video"].tap();capture("duo-unfolded-restored")
        }
        app.terminate()
    }
}
