import SwiftUI

// MARK: - HomeViewModel

/// Модель Главной. Тянет данные ровно теми же вызовами/типами, что старый клиент
/// (см. 3 IOS-client HomeView): cities, banners, popular ([CatalogItem]),
/// организации ([Shop]) через /organizations|/shops. Деньги — Decimal (Money).
@MainActor
final class HomeViewModel: ObservableObject {
    @Published var banners: [Banner] = []
    @Published var popular: [CatalogItem] = []      // «Популярное в городе»
    @Published var shops: [Shop] = []               // список организаций
    @Published var kind: OrgKind = .all
    @Published var loading = true
    @Published var error: String?

    private var didInitialLoad = false

    /// OrgKind → серверный typeFilter (как в старом клиенте: all|restaurant|store|service).
    private func typeParam(_ k: OrgKind) -> String {
        switch k {
        case .all:         return "all"
        case .restaurants: return "restaurant"
        case .shops:       return "store"
        case .services:    return "service"
        }
    }

    func firstLoad(session: Session) async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        await load(session: session)
    }

    /// Полная загрузка (первый вход и pull-to-refresh).
    func load(session: Session) async {
        loading = true; error = nil
        // Города: если город ещё не выбран (нет id) — берём первый как в старом клиенте.
        if session.cityId == nil,
           let cities: [City] = try? await API.shared.list("api/v1/cities"),
           let first = cities.first {
            session.cityId = first.id
            session.cityName = session.cityName ?? first.name
        }
        async let bannersTask: [Banner] = (try? await API.shared.list("api/v1/banners")) ?? []
        banners = await bannersTask
        await loadSections(session: session)
        await loadShops(session: session)
        loading = false
    }

    /// Смена типа-чипа: перегружаем только зависящие от типа секции/список.
    func changeKind(_ k: OrgKind, session: Session) async {
        kind = k
        loading = true; error = nil
        await loadSections(session: session)
        await loadShops(session: session)
        loading = false
    }

    // «Популярное в городе» — /api/v1/popular (как в старом клиенте), фильтр по type/city.
    private func loadSections(session: Session) async {
        var q: [String: String] = [:]
        if let cid = session.cityId { q["city_id"] = String(cid) }
        if kind != .all { q["type"] = typeParam(kind) }
        popular = (try? await API.shared.list("api/v1/popular", query: q)) ?? []
    }

    // Список организаций. Рестораны/магазины/услуги → /organizations; «Все» → /shops.
    private func loadShops(session: Session) async {
        do {
            var q: [String: String] = [:]
            if let cid = session.cityId { q["city_id"] = String(cid) }
            switch kind {
            case .all:
                shops = try await API.shared.list("api/v1/shops", query: q)
            case .restaurants:
                q["type"] = "restaurant"
                shops = try await API.shared.list("api/v1/organizations", query: q)
            case .shops:
                q["type"] = "store"
                shops = try await API.shared.list("api/v1/organizations", query: q)
            case .services:
                q["type"] = "service"
                shops = try await API.shared.list("api/v1/organizations", query: q)
            }
        } catch is CancellationError {
            // отмена (быстрый повторный запрос) — молча
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm = HomeViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Локальное состояние избранного (сеть избранного — следующая волна).
    @State private var favShops: Set<Int> = []
    @State private var favPopular: Set<String> = []
    @State private var appeared = false

    // Навигация внутри собственного стека таба (флоу как в Discover/Listing).
    @State private var pushedShop: Shop?
    @State private var pushedProduct: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    header
                    SearchField()
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.top, 14)
                        .onTapGesture { router.requestedTab = 1 }   // → вкладка Поиск

                    ChipRow(selected: $vm.kind) { k in
                        Task { await vm.changeKind(k, session: session) }
                    }
                    .padding(.top, 12)

                    PromoBanner()
                        .padding(.top, 12)

                    if vm.loading {
                        loadingSkeleton
                    } else if let e = vm.error, vm.shops.isEmpty, vm.popular.isEmpty {
                        errorState(e)
                    } else {
                        content
                    }

                    Color.clear.frame(height: 24)
                }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await vm.load(session: session) }
            .task { await vm.firstLoad(session: session) }
            // Переходы из карточек: организация → OrgView, популярный товар → ProductView.
            .navigationDestination(isPresented: Binding(
                get: { pushedShop != nil }, set: { if !$0 { pushedShop = nil } }
            )) { if let s = pushedShop { OrgView(shop: s) } }
            .navigationDestination(isPresented: Binding(
                get: { pushedProduct != nil }, set: { if !$0 { pushedProduct = nil } }
            )) { if let id = pushedProduct { ProductView(id: id) } }
        }
    }

    // MARK: Header (kicker «ВАШ ГОРОД» + город ▾ + аватар)

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Ваш город".uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(YMColor.accent)
                Button {
                    Haptics.selection()
                    // TODO: смена города из шапки (шторка выбора) — следующая волна.
                } label: {
                    HStack(spacing: 5) {
                        Text(session.cityName ?? "Москва")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(YMColor.text)
                        Text("▾")
                            .font(.system(size: 12))
                            .foregroundStyle(YMColor.muted)
                            .offset(y: 1)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            avatar
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 6)
    }

    private var avatar: some View {
        let initial = String((session.cityName ?? "Я").prefix(1)).uppercased()
        return Text(initial)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(YMColor.accent)
            .frame(width: 42, height: 42)
            .background(YMColor.surface2, in: Circle())
            .overlay(Circle().strokeBorder(YMColor.accent, lineWidth: 1.5))
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            // «Популярное в городе» — горизонтальная карусель PopularCard.
            if !vm.popular.isEmpty {
                SectionHeader(title: "Популярное в городе", actionTitle: "Все") {
                    router.requestedTab = 1
                }
                .padding(.top, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.md) {
                        ForEach(Array(vm.popular.enumerated()), id: \.element.uid) { idx, item in
                            PopularCard(
                                title: item.name ?? "—",
                                tag: item.category ?? item.shopName,
                                rating: nil,
                                photoURL: API.imageURL(item.photo),
                                tone: idx,
                                isFav: favBinding(popular: item.uid)
                            ) {
                                pushedProduct = item.id   // → карточка товара
                            }
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, 4)
                }
            }

            // «Рестораны» / организации — вертикальный список OrgCard.
            if !vm.shops.isEmpty {
                SectionHeader(title: sectionTitle, actionTitle: "Все") {
                    router.requestedTab = 1
                }
                .padding(.top, 18)
                LazyVStack(spacing: YMSpace.lg) {
                    ForEach(Array(vm.shops.enumerated()), id: \.element.id) { idx, shop in
                        OrgCard(shop: shop, tone: idx, isFav: favBinding(shop: shop.id)) {
                            pushedShop = shop   // → карточка организации
                        }
                        .opacity(appeared || reduceMotion ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 12)
                        .animation(
                            YMMotion.adaptive(YMMotion.spring.delay(Double(idx) * 0.04),
                                              reduceMotion: reduceMotion),
                            value: appeared
                        )
                    }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, 4)
                .onAppear { appeared = true }
            }

            if vm.popular.isEmpty && vm.shops.isEmpty {
                emptyState
            }
        }
    }

    private var sectionTitle: String {
        switch vm.kind {
        case .all, .restaurants: return "Рестораны"
        case .shops:             return "Магазины"
        case .services:          return "Услуги"
        }
    }

    // MARK: States

    private var loadingSkeleton: some View {
        VStack(spacing: YMSpace.lg) {
            // карусель
            HStack(spacing: YMSpace.md) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBox(radius: YMRadius.card).frame(width: 146, height: 104)
                        SkeletonBox().frame(width: 110, height: 12)
                        SkeletonBox().frame(width: 70, height: 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // крупные карточки
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBox(radius: YMRadius.card).frame(height: 150)
                    SkeletonBox().frame(width: 160, height: 16)
                    SkeletonBox().frame(width: 200, height: 12)
                }
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 20)
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
            Button("Повторить") { Task { await vm.load(session: session) } }
                .buttonStyle(YMSecondaryButtonStyle())
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
        .padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("Пока пусто")
                .font(YMFont.title3)
                .foregroundStyle(YMColor.text)
            Text("В вашем городе для выбранного раздела пока нет заведений.")
                .font(YMFont.callout)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
        .padding(.top, 50)
    }

    // MARK: Fav bindings (локально)

    private func favBinding(shop id: Int) -> Binding<Bool> {
        Binding(get: { favShops.contains(id) },
                set: { if $0 { favShops.insert(id) } else { favShops.remove(id) } })
    }
    private func favBinding(popular uid: String) -> Binding<Bool> {
        Binding(get: { favPopular.contains(uid) },
                set: { if $0 { favPopular.insert(uid) } else { favPopular.remove(uid) } })
    }
}
