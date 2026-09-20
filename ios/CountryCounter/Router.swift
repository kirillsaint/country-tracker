import Foundation
import Observation

// Переходы из уведомлений: делегат уведомлений кладёт маршрут сюда, RootView его показывает.
// Через синглтон, потому что делегат живёт вне SwiftUI и может сработать до появления экранов.
enum DeepLink: Identifiable, Equatable {
    /// условия въезда (с черновиком помощника, если он готов)
    case regime(country: String, passportId: String?)
    /// "как въехали?" для текущего пребывания
    case entryBasis(country: String)

    var id: String {
        switch self {
        case .regime(let c, let p): return "regime|\(c)|\(p ?? "")"
        case .entryBasis(let c): return "entry|\(c)"
        }
    }
}

@MainActor
@Observable
final class Router {
    static let shared = Router()
    var pending: DeepLink?
}
