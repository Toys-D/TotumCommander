import Foundation

/// Место рядом с панелью, где живут просмотр и правка. Оно ОДНО.
///
/// Раньше это правило нигде не было записано, и каждый открывался сам по себе: F4 из
/// просмотра клала редактор поверх просмотрщика — заголовки двоились, первый Escape закрывал
/// невидимый просмотрщик, и только второй спрашивал про сохранение. Человек при этом был
/// уверен, что первый Escape «ничего не сделал».
enum PanelSlot {

    /// Кто сейчас занимает место.
    enum Occupant: Equatable { case nobody, viewer, editor }

    /// Что сделать перед тем, как открыть новое.
    enum Step: Equatable {
        /// Место свободно (или там то же самое) — открывать сразу.
        case openNow
        /// Сначала закрыть редактор — и не напрямую: он может спросить про сохранение.
        case closeEditorFirst
        /// Сначала закрыть просмотрщик. Ему терять нечего, закрывается молча.
        case closeViewerFirst
    }

    nonisolated static func step(opening: Occupant, current: Occupant) -> Step {
        switch (opening, current) {
        case (.viewer, .editor):  return .closeEditorFirst
        case (.editor, .viewer):  return .closeViewerFirst
        default:                  return .openNow
        }
    }

    /// Возвращать ли просмотр после того, как правка закрылась.
    ///
    /// Да — если просмотр ради неё и отступил: человек нажал F4 из просмотра, поправил,
    /// вышел — и должен оказаться там, откуда ушёл. Нет — если правку открыли из панели:
    /// возвращать тогда не к чему.
    nonisolated static func restoresViewer(steppedAside: Bool) -> Bool { steppedAside }
}
