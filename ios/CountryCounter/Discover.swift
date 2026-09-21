import Foundation
import SwiftUI

// «Чем заняться»: модели рекомендаций, категории и параметры оценки

enum DiscoverCategory: String, CaseIterable, Identifiable, Codable {
    case eat, coffee, walk, culture, nightlife, kids, shop, rainy, any
    var id: String { rawValue }

    var title: String {
        switch self {
        case .eat: return String(localized: "Eat")
        case .coffee: return String(localized: "Coffee")
        case .walk: return String(localized: "Walk")
        case .culture: return String(localized: "Culture")
        case .nightlife: return String(localized: "Nightlife")
        case .kids: return String(localized: "With kids")
        case .shop: return String(localized: "Shopping")
        case .rainy: return String(localized: "Rainy day")
        case .any: return String(localized: "Surprise me")
        }
    }

    var systemImage: String {
        switch self {
        case .eat: return "fork.knife"
        case .coffee: return "cup.and.saucer.fill"
        case .walk: return "figure.walk"
        case .culture: return "building.columns.fill"
        case .nightlife: return "moon.stars.fill"
        case .kids: return "figure.and.child.holdinghands"
        case .shop: return "bag.fill"
        case .rainy: return "cloud.rain.fill"
        case .any: return "sparkles"
        }
    }
}

struct PlacePhoto: Codable, Hashable {
    let url: String
    let author: String?
}

struct PlaceUserState: Codable, Hashable {
    var stars: Int?
    var saved: Bool
}

/// Место из справочника + пояснение модели + состояние пользователя
struct Recommendation: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let address: String?
    let lat: Double
    let lon: Double
    let rating: Double?
    let ratingCount: Int?
    let priceLevel: Int?
    let primaryType: String?
    let types: [String]
    let openNow: Bool?
    let hours: [String]
    let website: String?
    let mapsUrl: String?
    let phone: String?
    let summary: String?
    var distanceM: Int?
    var reason: String?
    var tags: [String]?
    let photoUrls: [PlacePhoto]
    var user: PlaceUserState

    var priceText: String? {
        guard let priceLevel, priceLevel > 0 else { return nil }
        return String(repeating: "$", count: priceLevel)
    }

    var distanceText: String? {
        guard let d = distanceM else { return nil }
        return d < 1000 ? String(localized: "\(d) m") : String(localized: "\(String(format: "%.1f", Double(d) / 1000)) km")
    }

    /// Какие параметры спрашивать при оценке — по типу места
    var facets: [RatingFacet] {
        let t = Set(types + [primaryType ?? ""])
        if !t.isDisjoint(with: ["restaurant", "meal_takeaway", "food", "bakery"]) { return [.food, .service, .value, .noise] }
        if !t.isDisjoint(with: ["cafe", "coffee_shop"]) { return [.coffee, .atmosphere, .value, .work] }
        if !t.isDisjoint(with: ["bar", "night_club", "wine_bar", "pub"]) { return [.atmosphere, .music, .crowd, .value] }
        if !t.isDisjoint(with: ["park", "tourist_attraction", "hiking_area", "garden", "beach", "natural_feature"]) { return [.scenery, .crowd, .ease] }
        if !t.isDisjoint(with: ["museum", "art_gallery", "historical_landmark", "performing_arts_theater"]) { return [.interest, .crowd, .value] }
        if !t.isDisjoint(with: ["amusement_park", "zoo", "aquarium", "playground", "water_park"]) { return [.kids, .crowd, .value] }
        return [.atmosphere, .value]
    }
}

/// Необязательные параметры оценки (1–5), помогают настроить рекомендации
enum RatingFacet: String, CaseIterable, Identifiable, Codable {
    case food, service, value, noise, coffee, atmosphere, work, music, crowd, scenery, ease, interest, kids
    var id: String { rawValue }

    var title: String {
        switch self {
        case .food: return String(localized: "Food")
        case .service: return String(localized: "Service")
        case .value: return String(localized: "Value for money")
        case .noise: return String(localized: "Quiet")
        case .coffee: return String(localized: "Coffee")
        case .atmosphere: return String(localized: "Atmosphere")
        case .work: return String(localized: "Good for working")
        case .music: return String(localized: "Music")
        case .crowd: return String(localized: "Not crowded")
        case .scenery: return String(localized: "Scenery")
        case .ease: return String(localized: "Easy to get around")
        case .interest: return String(localized: "Interesting")
        case .kids: return String(localized: "Good for kids")
        }
    }
}

struct PlaceRating: Codable, Identifiable, Hashable {
    var id: String { placeId }
    let placeId: String
    var name: String
    var countryCode: String?
    var city: String?
    var category: String?
    var stars: Int
    var facets: [String: Int]
    var tags: [String]
    var note: String?
    var wouldReturn: Bool?
    var visitedAt: String?
    var createdAt: String?
    var updatedAt: String?
}

struct PlaceSave: Codable, Identifiable, Hashable {
    var id: String { placeId }
    let placeId: String
    let name: String
    let lat: Double
    let lon: Double
    let countryCode: String?
    let city: String?
    let savedAt: String
}

struct DiscoverResult: Codable {
    let recommendations: [Recommendation]
    let summary: String?
    let source: String
}

/// Быстрые теги в оценке
let ratingTags: [String] = ["cozy", "romantic", "family", "loud", "touristy", "hidden gem", "overpriced", "great view", "slow service", "would return"]

func ratingTagTitle(_ tag: String) -> String {
    switch tag {
    case "cozy": return String(localized: "cozy")
    case "romantic": return String(localized: "romantic")
    case "family": return String(localized: "family-friendly")
    case "loud": return String(localized: "loud")
    case "touristy": return String(localized: "touristy")
    case "hidden gem": return String(localized: "hidden gem")
    case "overpriced": return String(localized: "overpriced")
    case "great view": return String(localized: "great view")
    case "slow service": return String(localized: "slow service")
    case "would return": return String(localized: "would return")
    default: return tag
    }
}
