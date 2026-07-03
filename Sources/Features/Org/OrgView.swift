import SwiftUI
import MapKit

//
//  OrgView.swift — карточка организации (магазин / услуга).
//  Блок: Организация + Товар/Услуга + Листинги. Дизайн 1:1 с OrgPhone.dc.html.
//
//  ПУБЛИЧНЫЕ INIT-СИГНАТУРЫ (для централизованной навигации):
//    OrgView(shop: Shop)             // из списка/карточки — есть базовые данные для hero
//    OrgView(shopSlug: String)       // из deep-link — грузим ShopDetail по slug
//
//  Экран самодостаточен: внутренний переход организация → товар/услуга
//  реализован локально через NavigationLink (флоу живёт внутри своего NavigationStack,
//  если экран открыт как корень; при пуше извне переиспользует внешний стек).
//
//  API (реальные методы старого клиента):
//    GET  api/v1/shops/{slug}            -> ShopDetail
//    GET  api/v1/shops/{slug}/products   -> [Product]
//    GET  api/v1/shops/{slug}/services   -> ServicesResponse (masters/services)
//
//  Деньги — только Decimal через Money. Мини-карта — MapKit. Токены — YM*.
//

// MARK: - ViewModel

@MainActor
final class OrgViewModel: ObservableObject {
    @Published var detail: ShopDetail?
    @Published var products: [Product] = []
    @Published var services: [ServiceItem] = []
    @Published var loading = true
    @Published var error: String?

    /// Slug — единственный ключ загрузки (у Shop и у deep-link он общий).
    let slug: String
    /// Опорные данные для мгновенного hero до прихода detail.
    let seed: Shop?

    init(shop: Shop) { self.slug = shop.slug ?? ""; self.seed = shop }
    init(shopSlug: String) { self.slug = shopSlug; self.seed = nil }

    /// Услуга ли это (есть services и нет products) — определяет набор способов получения.
    var isService: Bool { !services.isEmpty && products.isEmpty }

    func load() async {
        guard !slug.isEmpty else { error = "Нет данных заведения"; loading = false; return }
        loading = true; error = nil
        do {
            async let d: ShopDetail = API.shared.get("api/v1/shops/\(slug)")
            async let p: [Product] = API.shared.list("api/v1/shops/\(slug)/products")
            detail = try await d
            products = (try? await p) ?? []
        } catch is CancellationError {
            // отмена — молча
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        // Услуги догружаем в фоне, не задерживая показ.
        Task { @MainActor in
            if let r: ServicesResponse = try? await API.shared.get("api/v1/shops/\(slug)/services") {
                services = r.services ?? []
            }
        }
    }
}

// MARK: - OrgView

struct OrgView: View {
    @StateObject private var vm: OrgViewModel
    @StateObject private var cart = Cart.shared
    @EnvironmentObject private var coord: NavCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFav = false
    @State private var fulfilIndex = 0
    @State private var activeCat: Int = 0
    @State private var pushedProduct: Int?
    @State private var pushedService: ServiceItem?

    private let heroHeight: CGFloat = 308

    init(shop: Shop) { _vm = StateObject(wrappedValue: OrgViewModel(shop: shop)) }
    init(shopSlug: String) { _vm = StateObject(wrappedValue: OrgViewModel(shopSlug: shopSlug)) }

    var body: some View {
        ZStack(alignment: .top) {
            YMColor.bg.ignoresSafeArea()

            if vm.loading && vm.detail == nil {
                loadingState
            } else if let e = vm.error, vm.detail == nil {
                errorState(e)
            } else {
                content
                // Липкая корзина + чат-FAB поверх контента.
                bottomBar
            }

            topControls
        }
        .navigationBarHidden(true)
        .task { if vm.detail == nil { await vm.load() } }
        // Внутренние переходы флоу (организация → товар / услуга).
        .navigationDestination(isPresented: Binding(
            get: { pushedProduct != nil },
            set: { if !$0 { pushedProduct = nil } }
        )) { if let id = pushedProduct { ProductView(id: id) } }
        .navigationDestination(isPresented: Binding(
            get: { pushedService != nil },
            set: { if !$0 { pushedService = nil } }
        )) { if let s = pushedService { ProductView(service: s, shopName: vm.detail?.name) } }
    }

    // MARK: Content (parallax hero + sheet)

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Параллакс-hero: тянется при оттягивании вниз, уезжает вверх при скролле.
                GeometryReader { geo in
                    let minY = geo.frame(in: .named("scroll")).minY
                    let stretch = max(0, minY)
                    PhotoPlaceholder(
                        url: API.imageURL(vm.detail?.cover ?? vm.detail?.banner ?? seedCover),
                        label: "ОБЛОЖКА · ПАРАЛЛАКС",
                        radius: 0, tone: 0
                    )
                    .frame(width: geo.size.width, height: heroHeight + stretch)
                    .clipped()
                    .overlay(
                        // Градиент-фейд к фону снизу.
                        LinearGradient(
                            colors: [.clear, .clear, YMColor.bg],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .offset(y: reduceMotion ? -min(0, minY) : (minY > 0 ? -minY : -minY * 0.5))
                }
                .frame(height: heroHeight)

                sheet
                    .padding(.top, -34)   // sheet поднимается на hero (нахлёст r28)
            }
        }
        .coordinateSpace(name: "scroll")
        .ignoresSafeArea(edges: .top)
    }

    private var seedCover: String? { vm.seed?.cover ?? vm.seed?.banner ?? vm.seed?.logo }

    // MARK: Sheet (поднятая шторка r28)

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Логотип 72×72 r20 на границе.
            HStack {
                PhotoPlaceholder(url: API.imageURL(vm.detail?.logo ?? vm.seed?.logo),
                                 label: "ЛОГО", radius: 20, tone: 1)
                    .frame(width: 72, height: 72)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.15), radius: 10, y: 4)
                Spacer()
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Название 25/heavy + бейдж «Открыто».
            HStack(alignment: .center, spacing: 10) {
                Text(vm.detail?.name ?? vm.seed?.name ?? "—")
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundStyle(YMColor.text)
                    .lineLimit(2)
                if isOpen {
                    StatusPill(text: "Открыто", kind: .open, solid: false)
                }
                Spacer(minLength: 0)
            }

            // Подзаголовок «Тип · кухня · теги».
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 13.5))
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 6)
            }

            // ★рейтинг · оценки · время.
            HStack(spacing: 12) {
                if let r = rating, r > 0 {
                    HStack(spacing: 5) {
                        Text("★").foregroundStyle(YMColor.accent)
                        Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                        if let rc = vm.seed?.reviewsCount, rc > 0 {
                            Text("· \(rc) оценок").foregroundStyle(YMColor.muted)
                        }
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                }
                if let t = deliveryTime, !t.isEmpty {
                    HStack(spacing: 4) {
                        Text("🕑")
                        Text(t).foregroundStyle(YMColor.muted)
                    }
                    .font(.system(size: 13.5))
                }
            }
            .padding(.top, 10)

            // Сегмент способов получения.
            YMSegmented(options: Array(fulfilOptions.indices), selection: $fulfilIndex) { i in
                fulfilOptions[i]
            }
            .padding(.top, 16)

            // Карточка адреса + мини-карта + маршрут.
            addressCard
                .padding(.top, 16)

            // Услуга или меню.
            if vm.isService {
                servicesSection.padding(.top, 20)
            } else {
                menuSection.padding(.top, 20)
            }

            // Отступ под липкую корзину + FAB.
            Color.clear.frame(height: cart.count > 0 ? 150 : 96)
        }
        .padding(.horizontal, YMSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            YMColor.bg
                .clipShape(RoundedRectangle(cornerRadius: YMRadius.sheet, style: .continuous))
        )
    }

    // MARK: Address card + mini-map

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Мини-карта: золотой пин по lat/lng.
            if let lat = vm.detail?.lat, let lng = vm.detail?.lng {
                OrgMiniMap(lat: lat, lng: lng)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(YMColor.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.detail?.address ?? "Адрес уточняется")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(YMColor.text)
                    if let city = vm.seed?.category { // fallback; при наличии дистанции — покажется тут
                        Text(city)
                            .font(.system(size: 12))
                            .foregroundStyle(YMColor.muted)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    Haptics.light()
                    openRoute()
                } label: {
                    Text("↗ Маршрут")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(YMColor.onAccent)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(YMColor.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(vm.detail?.lat == nil && (vm.detail?.address?.isEmpty ?? true))
            }
            .padding(14)
        }
        .background(YMColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    // MARK: Menu (магазин)

    private var menuSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Липкая навигация по разделам меню — золотое подчёркивание активного.
            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        catTab("Популярное", 0)
                        ForEach(categories) { c in catTab(c.name ?? "—", c.id) }
                    }
                    .padding(.bottom, 4)
                }
            }

            LazyVStack(spacing: 12) {
                ForEach(shownProducts) { p in
                    DishRow(product: p) {
                        Haptics.light()
                        pushedProduct = p.id
                    } onAdd: {
                        pushedProduct = p.id   // «+» ведёт на карточку (модификаторы/степпер там)
                    }
                }
                if shownProducts.isEmpty {
                    Text("В этом разделе пока пусто")
                        .font(YMFont.callout)
                        .foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.top, 12)
        }
    }

    // MARK: Services (услуга)

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Услуги")
                .font(YMFont.title3)
                .foregroundStyle(YMColor.text)
            ForEach(vm.services) { s in
                Button {
                    Haptics.light()
                    pushedService = s
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.name ?? "—")
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(YMColor.text)
                                .lineLimit(2)
                            if let dm = s.durationMin, dm > 0 {
                                Text("\(dm) мин")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(YMColor.muted)
                            }
                        }
                        Spacer(minLength: 8)
                        Text("от \(Money.format(Money.dec(s.price)))")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(YMColor.text)
                        Text("Записаться")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(YMColor.onAccent)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(YMColor.accent, in: Capsule())
                    }
                    .padding(14)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                }
                .buttonStyle(CardPressStyle())
            }
        }
    }

    // MARK: Category tab (золотое подчёркивание)

    private func catTab(_ title: String, _ id: Int) -> some View {
        let active = activeCat == id
        return Button {
            Haptics.selection()
            withAnimation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion)) { activeCat = id }
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14.5, weight: active ? .heavy : .semibold))
                    .foregroundStyle(active ? YMColor.text : YMColor.muted)
                Rectangle()
                    .fill(active ? YMColor.accent : .clear)
                    .frame(height: 2.5)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Top controls (‹ ↗ ♡)

    private var topControls: some View {
        HStack {
            circleControl("chevron.left") { Haptics.light(); dismiss() }
            Spacer()
            HStack(spacing: 10) {
                circleControl("square.and.arrow.up") { share() }
                HeartButton(isFav: $isFav, size: 38)
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 8)
    }

    private func circleControl(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.4), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Bottom bar (StickyCartBar + чат-FAB)

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Spacer()
            // Чат-FAB над корзиной.
            HStack {
                Spacer()
                Button {
                    Haptics.light()
                    // Чат в этом API привязан к заказу — из карточки организации
                    // открываем общий список чатов (диалоги по заказам заведения).
                    coord.openChatList()
                } label: {
                    Text("💬")
                        .font(.system(size: 22))
                        .frame(width: 52, height: 52)
                        .background(YMColor.surface, in: Circle())
                        .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, YMSpace.xl)

            if cart.count > 0 {
                StickyCartBar(count: cart.count, total: Money.dec(cart.total)) {
                    // Открыть глобальный флоу корзины (Корзина → Оформление → Успех).
                    coord.openCart()
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 16) {
            SkeletonBox(radius: 0).frame(height: heroHeight).ignoresSafeArea(edges: .top)
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBox().frame(width: 72, height: 72)
                SkeletonBox().frame(width: 180, height: 24)
                SkeletonBox().frame(width: 240, height: 14)
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBox(radius: YMRadius.card).frame(height: 96)
                }
            }
            .padding(.horizontal, YMSpace.xl)
            Spacer()
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(YMColor.muted)
            Text(message)
                .font(YMFont.callout)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button("Повторить") { Task { await vm.load() } }
                .buttonStyle(YMSecondaryButtonStyle())
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
    }

    // MARK: Derived

    private var isOpen: Bool { vm.seed?.isOpen ?? true }
    private var rating: Double? { vm.detail?.rating ?? vm.seed?.rating }
    private var deliveryTime: String? { vm.detail?.deliveryTime ?? vm.seed?.deliveryTime }
    private var subtitle: String? {
        // «Тип · кухня · теги» — из категории Shop / категорий ShopDetail.
        var parts: [String] = []
        if let cat = vm.seed?.category, !cat.isEmpty { parts.append(cat) }
        if let cats = vm.detail?.categories, !cats.isEmpty {
            parts.append(cats.prefix(2).compactMap { $0.name }.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var categories: [Category] { vm.detail?.categories ?? [] }

    /// Способы получения: услуга → Запись/Вызов на дом; магазин → Доставка/Самовывоз/За столик.
    private var fulfilOptions: [String] {
        vm.isService ? ["Запись", "Вызов на дом"] : ["Доставка", "Самовывоз", "За столик"]
    }

    private var shownProducts: [Product] {
        activeCat == 0 ? vm.products : vm.products.filter { $0.categoryId == activeCat }
    }

    // MARK: Actions

    /// Deep-link в Яндекс.Карты с fallback на web.
    private func openRoute() {
        guard let lat = vm.detail?.lat, let lng = vm.detail?.lng else {
            // Fallback по адресу-строке.
            let addr = vm.detail?.address ?? vm.detail?.name ?? ""
            let q = addr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let web = URL(string: "https://yandex.ru/maps/?text=\(q)") { openURL(web) }
            return
        }
        let appURL = URL(string: "yandexmaps://build_route_on_map/?lat_to=\(lat)&lon_to=\(lng)")
        let webURL = URL(string: "https://yandex.ru/maps/?rtext=~\(lat),\(lng)&rtt=auto")
        if let app = appURL {
            UIApplication.shared.open(app, options: [:]) { ok in
                if !ok, let web = webURL { openURL(web) }
            }
        } else if let web = webURL {
            openURL(web)
        }
    }

    private func share() {
        Haptics.light()
        guard let slug = vm.detail?.slug ?? vm.seed?.slug,
              let url = URL(string: "\(API.base)/shop/\(slug)") else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Presenter из активной сцены (self-contained экран).
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(av, animated: true)
    }
}

// MARK: - DishRow (строка блюда)

/// Строка блюда: фото 88×88, название + ХАЛЯЛЬ, описание, цена, круглая золотая «+».
struct DishRow: View {
    let product: Product
    var onTap: () -> Void = {}
    var onAdd: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(product.name ?? "—")
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(YMColor.text)
                            .lineLimit(1)
                        if product.isHalal == true {
                            HalalBadge()
                        }
                    }
                    if let d = product.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 12.5))
                            .foregroundStyle(YMColor.muted)
                            .lineLimit(2)
                    }
                    Text(Money.format(Money.dec(product.price)))
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                        .padding(.top, 2)
                }
                Spacer(minLength: 8)
                ZStack(alignment: .bottomTrailing) {
                    PhotoPlaceholder(url: API.imageURL(product.photo),
                                     label: "ФОТО", radius: YMRadius.control, tone: product.id)
                        .frame(width: 88, height: 88)
                    // Круглая золотая «+» со свечением.
                    Button {
                        Haptics.light()
                        onAdd()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(YMColor.onAccent)
                            .frame(width: 30, height: 30)
                            .background(YMColor.accent, in: Circle())
                            .shadow(color: YMPalette.gold.opacity(0.5), radius: 10, y: 3)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 8, y: 8)
                }
            }
            .padding(12)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
    }
}

// MARK: - HalalBadge (переиспользуемый бейдж «ХАЛЯЛЬ»)

/// Зелёный бейдж «ХАЛЯЛЬ» — семантика статуса «done» (зелёный), мягкая заливка.
struct HalalBadge: View {
    var body: some View {
        Text("ХАЛЯЛЬ")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(YMColor.statusDone)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(YMColor.statusDone.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - OrgMiniMap (MapKit, золотой пин)

/// Мини-карта организации: неинтерактивная превью с золотым пином по lat/lng.
struct OrgMiniMap: View {
    let lat: Double
    let lng: Double

    struct Pin: Identifiable { let id = UUID(); let coord: CLLocationCoordinate2D }

    var body: some View {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let region = MKCoordinateRegion(center: coord,
                                        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))
        Map(coordinateRegion: .constant(region),
            interactionModes: [],
            annotationItems: [Pin(coord: coord)]) { pin in
            MapAnnotation(coordinate: pin.coord) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(YMColor.accent)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Money.dec (Double → Decimal, точно)

extension Money {
    /// Модели этого клиента хранят деньги как `Double?` (LenientDouble на сервере
    /// отдаёт числа/строки). `Money.parse(_:)` не имеет ветки для Double и вернул бы 0,
    /// поэтому конвертируем через строковое представление — без ошибки плавающей точки
    /// (Decimal(double) даёт мусорные хвосты). nil → 0.
    static func dec(_ value: Double?) -> Decimal {
        guard let v = value else { return 0 }
        // "%g" не годится для больших сумм; печатаем полное десятичное, без экспоненты.
        return Decimal(string: String(format: "%.2f", v)) ?? 0
    }
}
