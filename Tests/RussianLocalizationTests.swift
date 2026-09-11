import XCTest
import AppKit
@testable import Codenotch

final class RussianLocalizationTests: XCTestCase {
    func testRussianCardRowsFitExistingWidth() {
        for (label, value) in [("Всего токенов", "7,22 млрд"), ("Рекорд за день", "369,0 млн"),
                               ("Самый долгий ответ", "10 ч 29 мин"), ("Дней подряд", "16 дн."),
                               ("Рекорд дней подряд", "21 дн."), ("Токены за 30 дней", "2,79 млрд")] {
            let width = (label as NSString).size(withAttributes: [.font: NotchLayout.cardBodyFont]).width
                + (value as NSString).size(withAttributes: [.font: NotchLayout.cardBodyFont]).width
                + Design.px(20)
            XCTAssertLessThanOrEqual(width, NotchLayout.cardTextWidth, label)
        }
    }
    func testCodexCardRussianLabelsAndUnits() {
        let ru = Locale(identifier: "ru")
        XCTAssertEqual(L10n.t("Lifetime tokens", locale: ru), "Всего токенов")
        XCTAssertEqual(L10n.t("Peak tokens", locale: ru), "Рекорд за день")
        XCTAssertEqual(L10n.t("Longest chat", locale: ru), "Самый долгий ответ")
        XCTAssertEqual(L10n.t("Current streak", locale: ru), "Дней подряд")
        XCTAssertEqual(L10n.t("Longest streak", locale: ru), "Рекорд дней подряд")
        XCTAssertEqual(L10n.t("Today", locale: ru), "Сегодня")
        XCTAssertEqual(L10n.t("30-day tokens", locale: ru), "Токены за 30 дней")
        XCTAssertEqual(UsageFormat.duration(seconds: 37740, locale: ru), "10 ч 29 мин")
        XCTAssertEqual(UsageFormat.days(16, locale: ru), "16 дн.")
        XCTAssertEqual(UsageFormat.tokens(7_220_000_000, locale: ru), "7,22 млрд")
        XCTAssertEqual(UsageFormat.tokens(369_000_000, locale: ru), "369,0 млн")
        XCTAssertEqual(UsageFormat.tokens(951_000, locale: ru), "951 тыс.")
        XCTAssertEqual(UsageFormat.tokens(nil, locale: ru), "—")
    }
    func testRussianLanguageIsAvailable() {
        XCTAssertEqual(AppLanguage.russian.rawValue, "ru")
        XCTAssertEqual(AppLanguage.russian.title, "Русский")
        XCTAssertEqual(AppLanguage.russian.locale?.identifier, "ru")
    }

    func testRussianCoreInterface() {
        let ru = Locale(identifier: "ru")
        XCTAssertEqual(L10n.t("Accounts", locale: ru), "Аккаунты")
        XCTAssertEqual(L10n.t("Appearance", locale: ru), "Внешний вид")
        XCTAssertEqual(L10n.t("Notifications", locale: ru), "Уведомления")
        XCTAssertEqual(L10n.t("General", locale: ru), "Общие")
        XCTAssertEqual(L10n.t("Weekly limit", locale: ru), "Недельный лимит")
    }

    func testRussianInterpolatedTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(ElapsedCopy.text(since: now.addingTimeInterval(-360),
            now: now, locale: Locale(identifier: "ru")), "6 мин")
    }
}
