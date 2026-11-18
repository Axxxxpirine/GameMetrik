import Foundation

/// Shares provider reads within one synchronization: each key is fetched once,
/// even when several games ask for it at the same time. Failures are shared too, but not a cancellation:
/// a read is cancelled only once every caller waiting for it has given up, then fetched again on the next request.
actor SyncMemo {
    private var tasks: [String: Task<any Sendable, Error>] = [:]
    private var waiters: [String: Set<UUID>] = [:]
    func value<T: Sendable>(_ key: String, _ make: @escaping @Sendable () async throws -> T) async throws -> T {
        let task: Task<any Sendable, Error>
        if let existing = tasks[key] { task = existing }
        else { task = Task { try await make() }; tasks[key] = task }
        let waiter = UUID()
        waiters[key, default: []].insert(waiter)
        defer { leave(key, waiter, task: task, abandoned: false) }
        let value: any Sendable
        do {
            value = try await withTaskCancellationHandler { try await task.value } onCancel: {
                Task { await self.leave(key, waiter, task: task, abandoned: true) }
            }
        } catch {
            if task.isCancelled, tasks[key] == task { tasks[key] = nil }
            throw error
        }
        guard let typed = value as? T else { throw ReportFormats.invalid() }
        return typed
    }
    private func leave(_ key: String, _ waiter: UUID, task: Task<any Sendable, Error>, abandoned: Bool) {
        guard waiters[key]?.remove(waiter) != nil else { return }
        guard waiters[key]?.isEmpty == true else { return }
        waiters[key] = nil
        if abandoned, tasks[key] == task { task.cancel(); tasks[key] = nil }
    }
}
/// One Apple Sales summary covers the whole vendor account, not a single game.
enum AppleDayFile: Sendable { case noSales, missing, unreadable, file(Data) }
struct AdMobApp: Sendable { var id: String; var store: String? }

struct NativeReports: Sendable {
    var http: HTTPClient
    var tokens: ServiceAccountTokens
    var memo = SyncMemo()
    static let appleConcurrency = 4
    static let adMobTokenReuse: TimeInterval = 50 * 60
    // Retry only transient reads; no provider payload or credential appears in errors.
    func send(_ request: URLRequest) async throws -> Data {
        for attempt in 0..<3 {
            do {
                let (data, _) = try await http.send(request)
                guard data.count <= ReportFormats.limit else { throw ReportFormats.invalid() }
                return data
            } catch GameMetrikError.http(let status) where [429,500,502,503,504].contains(status) && attempt < 2 {
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw GameMetrikError.message("Le fournisseur ne répond pas après plusieurs essais.")
    }
    func request(_ url: URL, token: String, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer "+token, forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    func object(_ request: URLRequest) async throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: await send(request)) as? [String: Any] else { throw ReportFormats.invalid() }; return object
    }
    func admob(game: Game, connections: PersonalConnections, window: SyncWindow) async throws -> ProviderReport {
        var report = ProviderReport(gameID: game.id, provider: "admob", title: "AdMob", note: "Revenus estimés en CHF, fuseau du compte AdMob. Journée en cours provisoire.")
        guard !window.days.isEmpty else { return report }
        do {
            guard let config = connections.admob else { throw GameMetrikError.message("Connexion AdMob absente.") }
            let base = "https://admob.googleapis.com/v1/accounts/"+config.publisherID
            // Token, time zone and app list are account-wide: read once per synchronization. An access token lasts an
            // hour; a long studio sync asks for a new one every 50 minutes instead of sending an expired one.
            let tokenPeriod = Int(Date().timeIntervalSince1970 / Self.adMobTokenReuse)
            let token: String = try await memo.value("admob/token/"+config.publisherID+"/\(tokenPeriod)") {
                let tokenData = try await send(HTTPClient.post(URL(string: "https://oauth2.googleapis.com/token")!, form: ["client_id":config.clientID,"client_secret":config.clientSecret,"refresh_token":config.refreshToken,"grant_type":"refresh_token"]))
                struct Token: Decodable { var access_token: String }
                return try JSONDecoder().decode(Token.self, from: tokenData).access_token
            }
            let timezone: String = try await memo.value("admob/timezone/"+config.publisherID) {
                let account = try await object(request(URL(string: base)!, token: token))
                guard let timezone = account["reportingTimeZone"] as? String, TimeZone(identifier: timezone) != nil else { throw ReportFormats.invalid() }
                return timezone
            }
            guard let zone = TimeZone(identifier: timezone) else { throw ReportFormats.invalid() }
            report.timezone = timezone
            let apps: [AdMobApp] = try await memo.value("admob/apps/"+config.publisherID) {
                var apps: [AdMobApp] = [], cursor: String?, seen: Set<String> = []
                repeat {
                    var url = URLComponents(string: base+"/apps")!; url.queryItems = [.init(name:"pageSize",value:"1000")]
                    if let cursor { url.queryItems?.append(.init(name:"pageToken",value:cursor)) }
                    let page = try await object(request(url.url!, token: token))
                    for app in page["apps"] as? [[String: Any]] ?? [] {
                        guard let id = app["appId"] as? String else { continue }
                        let linked = app["linkedAppInfo"] as? [String: Any]
                        apps.append(AdMobApp(id: id, store: linked?["appStoreId"] as? String))
                    }
                    cursor = page["nextPageToken"] as? String
                    if let cursor { guard seen.insert(cursor).inserted, seen.count < 100 else { throw ReportFormats.invalid() } }
                } while cursor != nil
                return apps
            }
            var ids = Set((game.integrations.admobAppIds ?? []) + [game.integrations.admobAppId].compactMap { $0 })
            let knownIDs = Set(apps.map(\.id))
            if ids.isEmpty {
                for app in apps where app.store != nil && (app.store == game.integrations.appleAppId || app.store == game.integrations.googlePackageName) { ids.insert(app.id) }
            }
            guard !ids.isEmpty, ids.isSubset(of: knownIDs), ids.allSatisfy({ $0.range(of: #"^ca-app-pub-\d+~\d+$"#, options: .regularExpression) != nil }) else { throw GameMetrikError.message("Aucune application AdMob rattachée à ce jeu. Associe son identifiant de boutique dans AdMob.") }
            let today = Dates.day(window.now, timezone: zone)
            report.pendingDays = Set(window.days.filter { $0 >= today })
            // Small chunks cover the entire chosen history, independent of the old lookback.
            for chunk in try Self.contiguousChunks(window.days) {
                try Task.checkCancellation()
                let days = chunk.filter { $0 <= today }
                guard let first = days.first, let last = days.last else { continue }
                // Omit timeZone to use the account default; only an explicit America/Los_Angeles override is supported.
                let spec: [String: Any] = ["dateRange":["startDate":SyncWindow.object(first),"endDate":SyncWindow.object(last)],"dimensions":["DATE","APP","COUNTRY","PLATFORM"],"metrics":["ESTIMATED_EARNINGS","IMPRESSIONS"],"dimensionFilters":[["dimension":"APP","matchesAny":["values":ids.sorted()]]],"localizationSettings":["currencyCode":"CHF","languageCode":"fr-FR"],"maxReportRows":100000]
                let data = try await send(request(URL(string: base+"/networkReport:generate")!, token: token, body:["reportSpec":spec]))
                let values = try Self.admobRows(data, requestedDays: days, appIDs: ids, completedBefore: today)
                report.days.merge(values) { _, new in new }
            }
        } catch { try Task.checkCancellation(); report.hasError = true; report.note += " "+NativeDashboardSync.safe(error) }
        return report
    }
    static func contiguousChunks(_ days: [String]) throws -> [[String]] {
        var chunks: [[String]] = []
        for day in days {
            let date = try SyncWindow.date(day)
            if let last = chunks.last?.last, chunks[chunks.count - 1].count < 28,
               date.timeIntervalSince(try SyncWindow.date(last)) == 86400 {
                chunks[chunks.count - 1].append(day)
            } else { chunks.append([day]) }
        }
        return chunks
    }
    static func admobRows(_ data: Data, requestedDays: [String], appIDs: Set<String>, completedBefore: String) throws -> [String: FinancialDay] {
        guard let messages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let header = messages.first?["header"] as? [String: Any], let footer = messages.last?["footer"] as? [String: Any],
              let locale = header["localizationSettings"] as? [String: Any], locale["currencyCode"] as? String == "CHF" else { throw ReportFormats.invalid() }
        guard let dateRange = header["dateRange"] as? [String: [String: Int]], let first = requestedDays.first, let last = requestedDays.last,
              dateRange["startDate"] == SyncWindow.object(first), dateRange["endDate"] == SyncWindow.object(last) else { throw ReportFormats.invalid() }
        let rows = messages.compactMap { $0["row"] as? [String: Any] }
        let rowCount = (footer["matchingRowCount"] as? String).flatMap(Int.init) ?? (footer["matchingRowCount"] as? Int) ?? (rows.isEmpty ? 0 : nil)
        guard rowCount == rows.count, (footer["warnings"] as? [Any] ?? []).isEmpty else { throw GameMetrikError.message("AdMob signale un rapport tronqué ou des données retardées. Le bloc concerné n’a pas été comptabilisé.") }
        var result = Dictionary(uniqueKeysWithValues: requestedDays.filter { $0 < completedBefore }.map { ($0, FinancialDay(adImpressions: 0, allocations: [])) })
        var seen: Set<String> = []
        for row in rows {
            guard let dimensions = row["dimensionValues"] as? [String: [String: String]], let raw = dimensions["DATE"]?["value"], raw.count == 8, raw.allSatisfy(\.isNumber), let app = dimensions["APP"]?["value"], appIDs.contains(app), let metrics = row["metricValues"] as? [String: [String: String]] else { throw ReportFormats.invalid() }
            let date = String(raw.prefix(4))+"-"+raw.dropFirst(4).prefix(2)+"-"+raw.suffix(2)
            _ = try SyncWindow.date(date)
            let country = dimensions["COUNTRY"]?["value"], platform = dimensions["PLATFORM"]?["value"]
            let identity = [date, app, country ?? "", platform ?? ""].joined(separator: "|")
            guard requestedDays.contains(date), seen.insert(identity).inserted else { throw ReportFormats.invalid() }
            let amount = try ReportFormats.decimal(metrics["ESTIMATED_EARNINGS"]?["microsValue"])/1_000_000
            guard let rawCount = metrics["IMPRESSIONS"]?["integerValue"],
                  !rawCount.isEmpty, rawCount.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let count = Int(rawCount) else { throw ReportFormats.invalid() }
            var value = result[date] ?? FinancialDay(adImpressions: 0, allocations: [])
            let (total, overflow) = (value.adImpressions ?? 0).addingReportingOverflow(count)
            guard !overflow else { throw ReportFormats.invalid() }
            value.adImpressions = total
            try value.add(amount, currency:"CHF", purchase:false)
            value.allocate(amount, currency: "CHF", country: country, platform: platform)
            result[date] = value
        }
        return result
    }
    func apple(game: Game, connections: PersonalConnections, window: SyncWindow, progress: @escaping @Sendable (String) async -> Void) async throws -> ProviderReport {
        var report = ProviderReport(gameID:game.id, provider:"apple",title:"Apple",note:"Recettes développeur dans les devises du rapport ; nouvelles acquisitions hors mises à jour et retéléchargements. Journées Apple (Pacifique).",supportsInstalls:true,supportsIAP:true)
        let today = Dates.day(window.now, timezone:TimeZone(identifier:"America/Los_Angeles")!)
        report.timezone = "America/Los_Angeles"
        if connections.apple?.hasKey == true, connections.apple?.vendor?.isEmpty == false, game.integrations.appleAppId != nil {
            report.pendingDays = Set(window.days.filter { $0 >= today })
        }
        guard window.days.contains(where: { $0 < today }) else { return report }
        do {
            guard let config = connections.apple, config.hasKey else { throw GameMetrikError.message("Clé Apple .p8 manquante : ajoute-la dans Réglages → Connexions.") }
            guard let vendor = config.vendor, !vendor.isEmpty else { throw GameMetrikError.message("Numéro vendeur Apple manquant dans la connexion.") }
            guard let id = game.integrations.appleAppId, id.allSatisfy(\.isNumber), !id.isEmpty else { throw GameMetrikError.message("Identifiant App Store du jeu absent.") }
            let app = try await object(request(URL(string:"https://api.appstoreconnect.apple.com/v1/apps/"+id+"?fields%5Bapps%5D=sku")!, token:config.assertion()))
            guard let entry = app["data"] as? [String: Any], let attributes = entry["attributes"] as? [String: Any], let sku = attributes["sku"] as? String, !sku.isEmpty else { throw ReportFormats.invalid() }
            var missing = 0, unreadable = 0, noSales = 0, done = 0
            var pending = window.days.filter { $0 < today }[...]
            let total = pending.count
            // A few reports in flight; each vendor day is downloaded once for every game of the sync.
            try await withThrowingTaskGroup(of: (String, AppleDayFile).self) { group in
                func start() {
                    guard let day = pending.popFirst() else { return }
                    group.addTask { (day, try await appleDayFile(day: day, vendor: vendor, config: config)) }
                }
                for _ in 0..<Self.appleConcurrency { start() }
                while let (day, outcome) = try await group.next() {
                    switch outcome {
                    case .noSales: report.days[day] = FinancialDay(appleIAPNetUnits: 0, allocations: []); noSales += 1
                    case .missing: missing += 1
                    case .unreadable: unreadable += 1
                    case .file(let file):
                        do { report.days[day] = try Self.appleDay(file, appID:id, sku:sku) }
                        catch { try Task.checkCancellation(); unreadable += 1 }
                    }
                    done += 1; await progress("\(game.name) · Apple · \(done)/\(total) jours")
                    start()
                }
            }
            report.hasError = missing > 0 || unreadable > 0
            if missing > 0 { report.note += " \(missing) rapport(s) non publié(s) ou non disponible(s) chez Apple." }
            if unreadable > 0 { report.note += " \(unreadable) rapport(s) illisible(s), laissés inconnus ; les autres journées ont été conservées." }
            if noSales > 0 { report.note += " \(noSales) journée(s) sans ventes confirmées par Apple." }
        } catch { try Task.checkCancellation(); report.hasError = true; report.note += " "+NativeDashboardSync.safe(error) }
        return report
    }
    func appleDayFile(day: String, vendor: String, config: PersonalApple) async throws -> AppleDayFile {
        try await memo.value("apple/"+vendor+"/"+day) {
            var url = URLComponents(string:"https://api.appstoreconnect.apple.com/v1/salesReports")!
            url.queryItems = ["frequency":"DAILY","reportDate":day,"reportSubType":"SUMMARY","reportType":"SALES","vendorNumber":vendor,"version":"1_0"].map { .init(name:"filter[\($0.key)]",value:$0.value) }
            do {
                guard let data = try await appleReport(request(url.url!, token:config.assertion())) else { return AppleDayFile.noSales }
                do {
                    guard let file = try ReportFormats.files(data).first else { throw ReportFormats.invalid() }
                    return .file(file)
                } catch { try Task.checkCancellation(); return .unreadable }
            } catch GameMetrikError.http(404) { return .missing }
        }
    }
    // A 404 is a known zero only when Apple explicitly confirms the absence of sales.
    // Other 404s (unpublished/unavailable reports) remain unknown. Never surface raw errors.
    func appleReport(_ request: URLRequest) async throws -> Data? {
        for attempt in 0..<3 {
            do {
                let (data, response) = try await http.send(request, acceptingStatusCodes: [404])
                guard data.count <= ReportFormats.limit else { throw ReportFormats.invalid() }
                if response.statusCode == 404 {
                    struct Failure: Decodable {
                        struct Entry: Decodable { var code: String; var detail: String }
                        var errors: [Entry]
                    }
                    if let failure = try? JSONDecoder().decode(Failure.self, from: data), failure.errors.count == 1,
                       failure.errors[0].code == "NOT_FOUND",
                       failure.errors[0].detail.trimmingCharacters(in: .whitespacesAndNewlines) == "There were no sales for the date specified." { return nil }
                    throw GameMetrikError.http(404)
                }
                return data
            } catch GameMetrikError.http(let status) where [429,500,502,503,504].contains(status) && attempt < 2 {
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw GameMetrikError.message("Apple ne répond pas après plusieurs essais.")
    }
    static func appleDay(_ data: Data, appID: String, sku: String) throws -> FinancialDay {
        let rows = try ReportFormats.table(data, separator:"\t", required:["Apple Identifier","Parent Identifier","Product Type Identifier","Units","Developer Proceeds","Currency of Proceeds"])
        var result = FinancialDay(appleIAPNetUnits: 0, allocations: [])
        let acquisitions: Set<String> = ["1","1F","1T","F1","1-B"]
        for row in rows where row["Apple Identifier"] == appID || row["Parent Identifier"] == sku {
            let type = row["Product Type Identifier"] ?? ""
            let purchase = type.hasPrefix("IA") && type != "IA3" || ["FI1","1AY","1A"].contains(type)
            guard let units = Int(row["Units"] ?? "") else { throw ReportFormats.invalid() }
            if purchase {
                let (count, overflow) = (result.appleIAPNetUnits ?? 0).addingReportingOverflow(units)
                guard !overflow else { throw ReportFormats.invalid() }
                result.appleIAPNetUnits = count
            }
            if acquisitions.contains(type) { result.installs += max(0,units) }
            if acquisitions.contains(type) || purchase {
                let amount = try ReportFormats.decimal(row["Developer Proceeds"]) * Decimal(units)
                let currency = (row["Currency of Proceeds"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Free acquisitions can have zero proceeds and a blank currency in Apple's TSV.
                // A known zero needs no currency conversion; nonzero proceeds still require one.
                if amount != 0 || !currency.isEmpty {
                    try result.add(amount,currency:currency,purchase:purchase)
                    result.allocate(amount, currency: currency, country: row["Country Code"], platform: row["Device"])
                }
            }
        }
        return result
    }
    func google(game: Game, connections: PersonalConnections, window: SyncWindow, progress: @escaping @Sendable (String) async -> Void) async throws -> [ProviderReport] {
        var installs = ProviderReport(gameID:game.id,provider:"google-installs",title:"Google Play · installations",note:"Installations utilisateurs par pays, jours publiés uniquement. Les exports peuvent arriver plusieurs jours après les événements.",supportsMoney:false,supportsInstalls:true)
        var earnings = ProviderReport(gameID:game.id,provider:"google-earnings",title:"Google Play · recettes",note:"Rapports mensuels de recettes en devise marchand, frais et remboursements inclus. Le mois courant peut ne pas être publié.",supportsIAP:true)
        guard !window.days.isEmpty else { return [installs, earnings] }
        let token: String, bucket: String, package: String
        do {
            guard let account = connections.googlePlay, let rawBucket = connections.googlePlayReportBucket else { throw GameMetrikError.message("Compte Google ou bucket de rapports Google Play absent.") }
            bucket = rawBucket.replacingOccurrences(of:"gs://",with:"").trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            guard bucket.range(of:#"^[A-Za-z0-9._-]+$"#,options:.regularExpression) != nil,
                  let name = game.integrations.googlePackageName, name.range(of:#"^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$"#,options:.regularExpression) != nil else { throw GameMetrikError.message("Bucket de rapports ou nom de package Google Play invalide.") }
            package = name
            token = try await tokens.token(account:account,scopes:["https://www.googleapis.com/auth/devstorage.read_only"],http:http)
        } catch { try Task.checkCancellation(); installs.hasError = true; installs.note += " "+NativeDashboardSync.safe(error); earnings.hasError = true; earnings.note += " "+NativeDashboardSync.safe(error); return [installs,earnings] }
        var installsBlocked = false, earningsBlocked = false
        for month in window.months {
            await progress("\(game.name) · Google Play · \(month)")
            if !installsBlocked { do {
                let data = try await download(bucket:bucket, object:"stats/installs/installs_\(package)_\(month)_country.csv",token:token)
                let values = try Self.googleInstalls(data, package:package, days:window.days.filter { $0.replacingOccurrences(of:"-",with:"").hasPrefix(month) })
                installs.days.merge(values) { _, new in new }
            } catch { try Task.checkCancellation(); installs.hasError = true; installs.note += " \(month) : "+NativeDashboardSync.safe(error); installsBlocked = (error as? GameMetrikError) == .http(401) || (error as? GameMetrikError) == .http(403) } }
            if !earningsBlocked { do {
                let files = try await earningsFiles(bucket:bucket,month:month,token:token)
                let parsed = try Self.googleEarningsParse(files,package:package,days:window.days.filter { $0.replacingOccurrences(of:"-",with:"").hasPrefix(month) },completedMonth:month < String(Dates.day(window.now, timezone: .gmt).prefix(7)).replacingOccurrences(of:"-",with:""))
                earnings.days.merge(parsed.days) { _, new in new }
                if !parsed.unknownTypes.isEmpty {
                    earnings.note += " \(month) : type(s) de produit non reconnu(s) comptés dans les revenus mais pas dans les achats intégrés : " + parsed.unknownTypes.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value) ligne(s))" }.joined(separator: ", ") + "."
                }
            } catch { try Task.checkCancellation(); earnings.hasError = true; earnings.note += " \(month) : "+NativeDashboardSync.safe(error); earningsBlocked = (error as? GameMetrikError) == .http(401) || (error as? GameMetrikError) == .http(403) } }
        }
        return [installs,earnings]
    }
    func earningsFiles(bucket: String, month: String, token: String) async throws -> [Data] {
        let prefix = "earnings/earnings_"+month
        var cursor: String?, seen: Set<String> = [], names: Set<String> = []
        repeat {
            var url = URLComponents(string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o")!
            url.queryItems = [.init(name: "prefix", value: prefix), .init(name: "maxResults", value: "1000"), .init(name: "fields", value: "items(name),nextPageToken")]
            if let cursor { url.queryItems?.append(.init(name: "pageToken", value: cursor)) }
            let page = try await object(request(url.url!, token: token))
            for item in page["items"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String, name.hasPrefix(prefix) else { throw ReportFormats.invalid() }
                if name == prefix+".zip" || (name.hasPrefix(prefix+"_") && name.hasSuffix(".zip")) { names.insert(name) }
            }
            cursor = page["nextPageToken"] as? String
            if let cursor { guard seen.insert(cursor).inserted, seen.count <= 100 else { throw ReportFormats.invalid() } }
        } while cursor != nil
        guard !names.isEmpty else { throw GameMetrikError.message("Rapport mensuel de recettes pas encore publié ou absent du bucket.") }
        var files: [Data] = [], size = 0
        for name in names.sorted() {
            let parts = try ReportFormats.files(await download(bucket: bucket, object: name, token: token))
            size += parts.reduce(0) { $0+$1.count }
            guard size <= ReportFormats.limit else { throw ReportFormats.invalid() }
            files += parts
        }
        return files
    }
    func download(bucket: String, object: String, token: String) async throws -> Data {
        let encoded = object.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn:"-._~")))!
        return try await send(request(URL(string:"https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(encoded)?alt=media")!,token:token))
    }
    static func googleInstalls(_ data: Data, package: String, days: [String]) throws -> [String: FinancialDay] {
        var result: [String: FinancialDay] = [:]; var seen: Set<String> = []; var published: String?
        for file in try ReportFormats.files(data) {
            let rows = try ReportFormats.table(file,required:["Date","Package Name","Country","Daily User Installs"])
            for row in rows where row["Package Name"] == package {
                guard let day = row["Date"] else { throw ReportFormats.invalid() }; _ = try SyncWindow.date(day)
                published = max(published ?? day, day)
                guard days.contains(day) else { continue }
                guard seen.insert(day+"/"+(row["Country"] ?? "")).inserted, let count = Int(row["Daily User Installs"] ?? ""), count >= 0 else { throw ReportFormats.invalid() }
                result[day,default:FinancialDay()].installs += count
            }
        }
        // The export covers the month up to its latest row: an earlier day without rows had no installs.
        // Without this zero, such a day would look missing and its whole month would be downloaded again.
        if let published { for day in days where day <= published && result[day] == nil { result[day] = FinancialDay() } }
        return result
    }
    static func googleEarnings(_ data: Data, package: String, days: [String], completedMonth: Bool) throws -> [String: FinancialDay] {
        try googleEarningsFiles(ReportFormats.files(data), package: package, days: days, completedMonth: completedMonth)
    }
    static func googleEarningsFiles(_ files: [Data], package: String, days: [String], completedMonth: Bool) throws -> [String: FinancialDay] {
        try googleEarningsParse(files, package: package, days: days, completedMonth: completedMonth).days
    }
    /// A new Google product type must not hide a whole month: its amount stays in revenue, outside IAP.
    static func googleEarningsParse(_ files: [Data], package: String, days: [String], completedMonth: Bool) throws -> (days: [String: FinancialDay], unknownTypes: [String: Int]) {
        var result = completedMonth ? Dictionary(uniqueKeysWithValues:days.map { ($0,FinancialDay(allocations: [])) }) : [:]
        var unknownTypes: [String: Int] = [:]
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = .gmt; formatter.dateFormat = "MMM d, yyyy"; formatter.isLenient = false
        for file in files {
            let rows = try ReportFormats.table(file,required:["Transaction Date","Package ID","Product Type","Merchant Currency","Amount (Merchant Currency)"])
            for row in rows where row["Package ID"] == package {
                guard let rawDate = row["Transaction Date"] else { throw ReportFormats.invalid() }
                let day: String
                if (try? SyncWindow.date(rawDate)) != nil { day = rawDate }
                else if let date = formatter.date(from:rawDate) { day = Dates.day(date,timezone:.gmt) } else { throw ReportFormats.invalid() }
                guard days.contains(day) else { continue }
                let type = row["Product Type"] ?? ""
                let purchase = ["Subscription","One-time product","In-app product","In-app"].contains(type)
                if !purchase && type != "Paid app" { unknownTypes[type.isEmpty ? "(vide)" : type, default: 0] += 1 }
                let amount = try ReportFormats.decimal(row["Amount (Merchant Currency)"])
                let currency = row["Merchant Currency"] ?? ""
                var value = result[day] ?? FinancialDay(allocations: [])
                try value.add(amount,currency:currency,purchase:purchase)
                value.allocate(amount, currency: currency, country: row["Buyer Country"], platform: "android")
                result[day] = value
            }
        }
        return (result, unknownTypes)
    }
}
