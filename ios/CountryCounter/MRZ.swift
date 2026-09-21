import Foundation

// Машиночитаемая зона документов по ICAO 9303: паспорт (TD3, 2×44), визы (MRV-A 2×44, MRV-B 2×36),
// карты (TD1, 3×30 — ID и ВНЖ). Каждое поле защищено контрольной цифрой, поэтому результат
// можно проверить, а не гадать. Номер документа используется только для проверки и не сохраняется.
enum MRZ {
    enum DocumentType { case passport, visa, card }

    struct Result: Equatable {
        let type: DocumentType
        /// государство выдачи (alpha-2)
        let issuer: String?
        /// гражданство владельца (alpha-2)
        let nationality: String?
        /// срок действия, YYYY-MM-DD
        let expiry: String
    }

    /// Пробует найти и разобрать MRZ среди распознанных строк (порядок и мусор не важны).
    static func parse(lines rawLines: [String]) -> Result? {
        let lines = rawLines.map(normalize).filter { !$0.isEmpty }
        let by44 = lines.filter { $0.count == 44 }
        let by36 = lines.filter { $0.count == 36 }
        let by30 = lines.filter { $0.count == 30 }
        // две строки по 44: паспорт или виза формата A
        for first in by44 where first.hasPrefix("P") || first.hasPrefix("V") {
            for second in by44 where second != first {
                if let r = parseTwoLine(first, second, optionalEnd: first.hasPrefix("P") ? 42 : 44) { return r }
            }
        }
        for first in by36 where first.hasPrefix("V") {
            for second in by36 where second != first {
                if let r = parseTwoLine(first, second, optionalEnd: 36) { return r }
            }
        }
        if by30.count >= 2 {
            for first in by30 where first.hasPrefix("I") || first.hasPrefix("A") || first.hasPrefix("C") {
                for second in by30 where second != first {
                    if let r = parseTD1(first, second) { return r }
                }
            }
        }
        return nil
    }

    /// Убираем пробелы и типичные ошибки распознавания «<»
    private static func normalize(_ s: String) -> String {
        var t = s.uppercased().replacingOccurrences(of: " ", with: "")
        for bad in ["«", "»", "‹", "›", "≤", "К<", "<<"] where bad.count == 1 { t = t.replacingOccurrences(of: bad, with: "<") }
        return t.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "<") }
    }

    // MARK: разбор форматов

    private static func parseTwoLine(_ l1: String, _ l2: String, optionalEnd: Int) -> Result? {
        let type: DocumentType = l1.hasPrefix("P") ? .passport : .visa
        guard let issuer = code(l1, 2, 5) else { return nil }
        // строка 2: номер 0-8 (кц 9), гражданство 10-12, рождение 13-18 (кц 19), пол 20, срок 21-26 (кц 27)
        guard check(l2, 0, 9, digit: 9), check(l2, 13, 19, digit: 19), check(l2, 21, 27, digit: 27) else { return nil }
        if type == .passport {
            // паспорт: кц необязательных данных 42 и общая кц 43
            guard check(l2, 28, 42, digit: 42) else { return nil }
            let composite = slice(l2, 0, 10) + slice(l2, 13, 20) + slice(l2, 21, 43)
            guard checkDigit(composite) == l2[l2.index(l2.startIndex, offsetBy: 43)] else { return nil }
        }
        guard let expiry = date(slice(l2, 21, 27)) else { return nil }
        return Result(type: type, issuer: alpha2(issuer), nationality: alpha2(code(l2, 10, 13) ?? ""), expiry: expiry)
    }

    private static func parseTD1(_ l1: String, _ l2: String) -> Result? {
        // строка 1: тип 0-1, государство 2-4, номер 5-13 (кц 14); строка 2: рождение 0-5 (кц 6), пол 7, срок 8-13 (кц 14), гражданство 15-17
        guard let issuer = code(l1, 2, 5) else { return nil }
        guard check(l1, 5, 14, digit: 14), check(l2, 0, 6, digit: 6), check(l2, 8, 14, digit: 14) else { return nil }
        guard let expiry = date(slice(l2, 8, 14)) else { return nil }
        return Result(type: .card, issuer: alpha2(issuer), nationality: alpha2(code(l2, 15, 18) ?? ""), expiry: expiry)
    }

    // MARK: контрольные цифры (веса 7-3-1; буквы A=10…Z=35, «<»=0)

    static func checkDigit(_ s: String) -> Character {
        let weights = [7, 3, 1]
        var sum = 0
        for (i, ch) in s.enumerated() {
            let v: Int
            if let d = ch.wholeNumberValue { v = d }
            else if ch == "<" { v = 0 }
            else if let a = ch.asciiValue, a >= 65, a <= 90 { v = Int(a) - 55 }
            else { return "?" }
            sum += v * weights[i % 3]
        }
        return Character(String(sum % 10))
    }

    private static func check(_ s: String, _ from: Int, _ to: Int, digit at: Int) -> Bool {
        guard s.count > at else { return false }
        return checkDigit(slice(s, from, to)) == s[s.index(s.startIndex, offsetBy: at)]
    }

    private static func slice(_ s: String, _ from: Int, _ to: Int) -> String {
        let a = s.index(s.startIndex, offsetBy: min(from, s.count))
        let b = s.index(s.startIndex, offsetBy: min(to, s.count))
        return String(s[a..<b])
    }

    private static func code(_ s: String, _ from: Int, _ to: Int) -> String? {
        let c = slice(s, from, to).replacingOccurrences(of: "<", with: "")
        return c.isEmpty ? nil : c
    }

    /// YYMMDD → YYYY-MM-DD; века нет, берём ближайший разумный: до 80 — 2000-е
    private static func date(_ s: String) -> String? {
        guard s.count == 6, s.allSatisfy(\.isNumber) else { return nil }
        let yy = Int(slice(s, 0, 2))!, mm = Int(slice(s, 2, 4))!, dd = Int(slice(s, 4, 6))!
        guard (1...12).contains(mm), (1...31).contains(dd) else { return nil }
        let year = yy <= 80 ? 2000 + yy : 1900 + yy
        return String(format: "%04d-%02d-%02d", year, mm, dd)
    }

    // MARK: коды стран ICAO (alpha-3 плюс спецкоды) → ISO alpha-2

    static func alpha2(_ code: String) -> String? {
        if code.count == 2 { return code }
        return alpha3Table[code]
    }

    private static let alpha3Table: [String: String] = [
        "ABW": "AW", "AFG": "AF", "AGO": "AO", "AIA": "AI", "ALA": "AX", "ALB": "AL", "AND": "AD", "ARE": "AE",
        "ARG": "AR", "ARM": "AM", "ASC": "AC", "ASM": "AS", "ATA": "AQ", "ATF": "TF", "ATG": "AG", "AUS": "AU",
        "AUT": "AT", "AZE": "AZ", "BDI": "BI", "BEL": "BE", "BEN": "BJ", "BES": "BQ", "BFA": "BF", "BGD": "BD",
        "BGR": "BG", "BHR": "BH", "BHS": "BS", "BIH": "BA", "BLM": "BL", "BLR": "BY", "BLZ": "BZ", "BMU": "BM",
        "BOL": "BO", "BRA": "BR", "BRB": "BB", "BRN": "BN", "BTN": "BT", "BVT": "BV", "BWA": "BW", "CAF": "CF",
        "CAN": "CA", "CCK": "CC", "CHE": "CH", "CHL": "CL", "CHN": "CN", "CIV": "CI", "CMR": "CM", "COD": "CD",
        "COG": "CG", "COK": "CK", "COL": "CO", "COM": "KM", "CPT": "CP", "CPV": "CV", "CRI": "CR", "CRQ": "CQ",
        "CUB": "CU", "CUW": "CW", "CXR": "CX", "CYM": "KY", "CYP": "CY", "CZE": "CZ", "D": "DE", "DEU": "DE",
        "DGA": "DG", "DJI": "DJ", "DMA": "DM", "DNK": "DK", "DOM": "DO", "DZA": "DZ", "ECU": "EC", "EGY": "EG",
        "ERI": "ER", "ESH": "EH", "ESP": "ES", "EST": "EE", "ETH": "ET", "EUE": "EU", "FIN": "FI", "FJI": "FJ",
        "FLK": "FK", "FRA": "FR", "FRO": "FO", "FSM": "FM", "FXX": "FX", "GAB": "GA", "GBD": "GB", "GBN": "GB",
        "GBO": "GB", "GBP": "GB", "GBR": "GB", "GBS": "GB", "GEO": "GE", "GGY": "GG", "GHA": "GH", "GIB": "GI",
        "GIN": "GN", "GLP": "GP", "GMB": "GM", "GNB": "GW", "GNQ": "GQ", "GRC": "GR", "GRD": "GD", "GRL": "GL",
        "GTM": "GT", "GUF": "GF", "GUM": "GU", "GUY": "GY", "HKG": "HK", "HMD": "HM", "HND": "HN", "HRV": "HR",
        "HTI": "HT", "HUN": "HU", "IDN": "ID", "IMN": "IM", "IND": "IN", "IOT": "IO", "IRL": "IE", "IRN": "IR",
        "IRQ": "IQ", "ISL": "IS", "ISR": "IL", "ITA": "IT", "JAM": "JM", "JEY": "JE", "JOR": "JO", "JPN": "JP",
        "KAZ": "KZ", "KEN": "KE", "KGZ": "KG", "KHM": "KH", "KIR": "KI", "KNA": "KN", "KOR": "KR", "KWT": "KW",
        "LAO": "LA", "LBN": "LB", "LBR": "LR", "LBY": "LY", "LCA": "LC", "LIE": "LI", "LKA": "LK", "LSO": "LS",
        "LTU": "LT", "LUX": "LU", "LVA": "LV", "MAC": "MO", "MAF": "MF", "MAR": "MA", "MCO": "MC", "MDA": "MD",
        "MDG": "MG", "MDV": "MV", "MEX": "MX", "MHL": "MH", "MKD": "MK", "MLI": "ML", "MLT": "MT", "MMR": "MM",
        "MNE": "ME", "MNG": "MN", "MNP": "MP", "MOZ": "MZ", "MRT": "MR", "MSR": "MS", "MTQ": "MQ", "MUS": "MU",
        "MWI": "MW", "MYS": "MY", "MYT": "YT", "NAM": "NA", "NCL": "NC", "NER": "NE", "NFK": "NF", "NGA": "NG",
        "NIC": "NI", "NIU": "NU", "NLD": "NL", "NOR": "NO", "NPL": "NP", "NRU": "NR", "NZL": "NZ", "OMN": "OM",
        "PAK": "PK", "PAN": "PA", "PCN": "PN", "PER": "PE", "PHL": "PH", "PLW": "PW", "PNG": "PG", "POL": "PL",
        "PRI": "PR", "PRK": "KP", "PRT": "PT", "PRY": "PY", "PSE": "PS", "PYF": "PF", "QAT": "QA", "REU": "RE",
        "RKS": "XK", "ROU": "RO", "RUS": "RU", "RWA": "RW", "SAU": "SA", "SDN": "SD", "SEN": "SN", "SGP": "SG",
        "SGS": "GS", "SHN": "SH", "SJM": "SJ", "SLB": "SB", "SLE": "SL", "SLV": "SV", "SMR": "SM", "SOM": "SO",
        "SPM": "PM", "SRB": "RS", "SSD": "SS", "STP": "ST", "SUR": "SR", "SVK": "SK", "SVN": "SI", "SWE": "SE",
        "SWZ": "SZ", "SXM": "SX", "SYC": "SC", "SYR": "SY", "TAA": "TA", "TCA": "TC", "TCD": "TD", "TGO": "TG",
        "THA": "TH", "TJK": "TJ", "TKL": "TK", "TKM": "TM", "TLS": "TL", "TON": "TO", "TTO": "TT", "TUN": "TN",
        "TUR": "TR", "TUV": "TV", "TWN": "TW", "TZA": "TZ", "UGA": "UG", "UKR": "UA", "UMI": "UM", "URY": "UY",
        "USA": "US", "UZB": "UZ", "VAT": "VA", "VCT": "VC", "VEN": "VE", "VGB": "VG", "VIR": "VI", "VNM": "VN",
        "VUT": "VU", "WLF": "WF", "WSM": "WS", "XKX": "XK", "YEM": "YE", "ZAF": "ZA", "ZMB": "ZM", "ZWE": "ZW",
    ]
}
