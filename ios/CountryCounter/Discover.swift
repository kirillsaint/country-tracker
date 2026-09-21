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

/// Уточнение внутри категории: заголовок для человека и слова для поиска в Google (по-английски — так надёжнее)
struct DiscoverSubtag: Identifiable, Hashable {
    let id: String
    let title: String
    let query: String
}

extension DiscoverCategory {
    /// Существительное для текстового поиска, к которому приклеиваются подтеги: «Italian restaurant»
    var noun: String {
        switch self {
        case .eat: return "restaurant"
        case .coffee: return "cafe"
        case .walk: return "place to walk"
        case .culture: return "museum or gallery"
        case .nightlife: return "bar"
        case .kids: return "family activity"
        case .shop: return "shopping"
        case .rainy: return "indoor activity"
        case .any: return "things to do"
        }
    }

    var subtags: [DiscoverSubtag] {
        func t(_ id: String, _ title: String, _ q: String) -> DiscoverSubtag { DiscoverSubtag(id: id, title: title, query: q) }
        switch self {
        case .eat: return [
            t("italian", String(localized: "Italian"), "Italian"), t("japanese", String(localized: "Japanese"), "Japanese sushi"),
            t("georgian", String(localized: "Georgian"), "Georgian"), t("arabic", String(localized: "Middle Eastern"), "Lebanese Arabic"),
            t("indian", String(localized: "Indian"), "Indian"), t("asian", String(localized: "Asian"), "Thai Vietnamese Chinese"),
            t("seafood", String(localized: "Seafood"), "seafood"), t("steak", String(localized: "Steak"), "steakhouse grill"),
            t("vegan", String(localized: "Vegan"), "vegan vegetarian"), t("breakfast", String(localized: "Breakfast"), "breakfast brunch"),
            t("street", String(localized: "Street food"), "street food cheap"), t("fine", String(localized: "Fine dining"), "fine dining"),
        ]
        case .coffee: return [
            t("specialty", String(localized: "Specialty"), "specialty coffee"), t("desserts", String(localized: "Desserts"), "desserts pastry"),
            t("work", String(localized: "For working"), "laptop friendly quiet"), t("terrace", String(localized: "Terrace"), "terrace outdoor"),
            t("tea", String(localized: "Tea"), "tea house"), t("bakery", String(localized: "Bakery"), "bakery"),
        ]
        case .walk: return [
            t("park", String(localized: "Park"), "park"), t("water", String(localized: "Waterfront"), "waterfront promenade"),
            t("view", String(localized: "Viewpoint"), "viewpoint scenic"), t("beach", String(localized: "Beach"), "beach"),
            t("old", String(localized: "Old town"), "old town historic streets"), t("hike", String(localized: "Hike"), "hiking trail"),
        ]
        case .culture: return [
            t("museum", String(localized: "Museum"), "museum"), t("gallery", String(localized: "Gallery"), "art gallery"),
            t("history", String(localized: "History"), "historical landmark"), t("theatre", String(localized: "Theatre"), "theatre performing arts"),
            t("architecture", String(localized: "Architecture"), "architecture landmark"), t("religious", String(localized: "Temples"), "mosque church temple"),
        ]
        case .nightlife: return [
            t("rooftop", String(localized: "Rooftop"), "rooftop bar"), t("cocktails", String(localized: "Cocktails"), "cocktail bar"),
            t("live", String(localized: "Live music"), "live music"), t("club", String(localized: "Club"), "night club"),
            t("wine", String(localized: "Wine"), "wine bar"), t("pub", String(localized: "Pub"), "pub craft beer"),
        ]
        case .kids: return [
            t("playground", String(localized: "Playground"), "playground"), t("zoo", String(localized: "Zoo & aquarium"), "zoo aquarium"),
            t("amusement", String(localized: "Amusement"), "amusement park"), t("water", String(localized: "Water park"), "water park"),
            t("science", String(localized: "Science"), "science museum kids"), t("indoor", String(localized: "Indoor play"), "indoor playground"),
        ]
        case .shop: return [
            t("mall", String(localized: "Mall"), "shopping mall"), t("market", String(localized: "Market"), "market bazaar"),
            t("souvenirs", String(localized: "Souvenirs"), "souvenir gift shop"), t("books", String(localized: "Books"), "bookstore"),
            t("fashion", String(localized: "Fashion"), "fashion boutique"), t("electronics", String(localized: "Electronics"), "electronics store"),
        ]
        case .rainy: return [
            t("museum", String(localized: "Museum"), "museum"), t("spa", String(localized: "Spa"), "spa hammam"),
            t("cinema", String(localized: "Cinema"), "cinema"), t("mall", String(localized: "Mall"), "shopping mall"),
            t("bowling", String(localized: "Bowling"), "bowling"), t("escape", String(localized: "Escape room"), "escape room"),
        ]
        case .any: return []
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
        // сначала основной тип, потом остальные: у кофейни в types часто есть и restaurant
        let ordered = [primaryType ?? ""] + types
        let groups: [(Set<String>, [RatingFacet])] = [
            (["cafe", "coffee_shop"], [.coffee, .atmosphere, .value, .work]),
            (["bar", "night_club", "wine_bar", "pub"], [.atmosphere, .music, .crowd, .value]),
            (["restaurant", "meal_takeaway", "food", "bakery"], [.food, .service, .value, .noise]),
            (["park", "tourist_attraction", "hiking_area", "garden", "beach", "natural_feature"], [.scenery, .crowd, .ease]),
            (["museum", "art_gallery", "historical_landmark", "performing_arts_theater"], [.interest, .crowd, .value]),
            (["amusement_park", "zoo", "aquarium", "playground", "water_park"], [.kids, .crowd, .value]),
        ]
        for type in ordered {
            if let g = groups.first(where: { $0.0.contains(type) }) { return g.1 }
        }
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

struct Weather: Codable, Hashable {
    let tempC: Int
    let precipitationMm: Double
    let windKmh: Int
    let code: Int
    let summary: String
    let isRainy: Bool
    let isHot: Bool
    let isCold: Bool

    /// Описание по коду WMO на языке приложения
    var localizedSummary: String {
        switch code {
        case 0: return String(localized: "clear")
        case 1, 2: return String(localized: "partly cloudy")
        case 3: return String(localized: "overcast")
        case 45, 48: return String(localized: "fog")
        case 51...57: return String(localized: "drizzle")
        case 61...67, 80...82: return String(localized: "rain")
        case 71...77, 85, 86: return String(localized: "snow")
        case 95...99: return String(localized: "thunderstorm")
        default: return summary
        }
    }

    var systemImage: String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

/// Ответы мини-теста о вкусах
struct TastePreferences: Codable, Equatable {
    var cuisines: [String] = []
    var vibe: String = "any"
    var budget: String = "any"
    var company: String = "solo"
    var priorities: [String] = []
    var dietary: [String] = []
    var avoid: [String] = []
    var discovery: String = "mix"
    var note: String? = nil
    var updatedAt: String? = nil

    static let cuisineOptions: [(id: String, title: String)] = [
        ("italian", String(localized: "Italian")), ("japanese", String(localized: "Japanese")), ("georgian", String(localized: "Georgian")),
        ("middle eastern", String(localized: "Middle Eastern")), ("indian", String(localized: "Indian")), ("asian", String(localized: "Asian")),
        ("seafood", String(localized: "Seafood")), ("steak", String(localized: "Steak")), ("vegan", String(localized: "Vegan")),
        ("street food", String(localized: "Street food")), ("fine dining", String(localized: "Fine dining")), ("local", String(localized: "Local cuisine")),
    ]
    static let priorityOptions: [(id: String, title: String)] = [
        ("food", String(localized: "Food")), ("coffee", String(localized: "Coffee")), ("nature", String(localized: "Nature")),
        ("culture", String(localized: "Culture")), ("nightlife", String(localized: "Nightlife")), ("shopping", String(localized: "Shopping")),
        ("kids", String(localized: "With kids")), ("photo spots", String(localized: "Photo spots")),
    ]
    static let dietaryOptions: [(id: String, title: String)] = [
        ("vegetarian", String(localized: "Vegetarian")), ("vegan", String(localized: "Vegan")), ("halal", String(localized: "Halal")),
        ("no alcohol", String(localized: "No alcohol")), ("gluten-free", String(localized: "Gluten-free")),
    ]
    static let avoidOptions: [(id: String, title: String)] = [
        ("crowds", String(localized: "Crowds")), ("tourist traps", String(localized: "Tourist traps")), ("loud music", String(localized: "Loud music")),
        ("smoking", String(localized: "Smoking")), ("long queues", String(localized: "Long queues")), ("chains", String(localized: "Chains")),
    ]
}

struct DiscoverResult: Codable {
    let recommendations: [Recommendation]
    let summary: String?
    let source: String
    let weather: Weather?
}

struct ItineraryStop: Codable, Identifiable, Hashable {
    var id: String { place.id }
    let place: Recommendation
    let start: String
    let end: String
}

struct Itinerary: Codable, Hashable {
    let title: String
    let summary: String
    let stops: [ItineraryStop]
    let weather: Weather?

    /// Ответ сервера: остановка — это место с полями start/end; разворачиваем в place + время
    init(from decoder: Decoder) throws {
        struct Raw: Decodable { let title: String; let summary: String; let stops: [RawStop]; let weather: Weather? }
        struct RawStop: Decodable {
            let start: String; let end: String; let place: Recommendation
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                start = try c.decode(String.self, forKey: .start)
                end = try c.decode(String.self, forKey: .end)
                place = try Recommendation(from: decoder)
            }
            enum Key: String, CodingKey { case start, end }
        }
        let raw = try Raw(from: decoder)
        title = raw.title
        summary = raw.summary
        stops = raw.stops.map { ItineraryStop(place: $0.place, start: $0.start, end: $0.end) }
        weather = raw.weather
    }

    func encode(to encoder: Encoder) throws {}

    /// Маршрут по всем остановкам в Google Maps (Apple Maps умеет только одну точку)
    var googleRouteURL: URL? {
        guard let last = stops.last else { return nil }
        let waypoints = stops.dropLast().map { "\($0.place.lat),\($0.place.lon)" }.joined(separator: "|")
        var s = "https://www.google.com/maps/dir/?api=1&destination=\(last.place.lat),\(last.place.lon)&travelmode=walking"
        if !waypoints.isEmpty { s += "&waypoints=\(waypoints)" }
        return URL(string: s)
    }
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
