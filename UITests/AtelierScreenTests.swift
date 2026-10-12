import XCTest

final class AtelierScreenTests: XCTestCase {
    @MainActor func testPrimaryScreens() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["НОВЕ ЗАМОВЛЕННЯ"].waitForExistence(timeout: 20))
        capture("01-Головна", app: app)

        app.buttons["НОВЕ ЗАМОВЛЕННЯ"].tap()
        XCTAssertTrue(app.textFields["Ім’я"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Назва одягу"].exists)
        capture("02-Нове-замовлення", app: app)

        // Введення та повторне відкривання мають залишатися чутливими після автозбереження.
        app.textFields["Ім’я"].tap()
        app.textFields["Ім’я"].typeText("Тест чернетки")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["НОВЕ ЗАМОВЛЕННЯ"].tap()
        XCTAssertTrue(app.textFields["Ім’я"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Ім’я"].value as? String, "Ім’я")

        app.tabBars.buttons["Підсумки"].tap()
        XCTAssertTrue(app.staticTexts["Отримано"].waitForExistence(timeout: 10))
        capture("03-Підсумки-дня", app: app)
        app.buttons["Місяць"].tap()
        capture("04-Підсумки-місяця", app: app)

        app.tabBars.buttons["Меню"].tap()
        XCTAssertTrue(app.buttons["Резервна копія"].waitForExistence(timeout: 10))
        capture("05-Меню", app: app)
        app.buttons["Резервна копія"].tap()
        XCTAssertTrue(app.secureTextFields["Пароль копії, від 8 символів"].waitForExistence(timeout: 10))
        capture("06-Резервна-копія", app: app)
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
