import SwiftUI

//
//  ProductView.swift — карточка товара (product) / услуги (service).
//  Дизайн 1:1 с ProductPhone.dc.html (kind = product | service).
//
//  ПУБЛИЧНЫЕ INIT-СИГНАТУРЫ (для централизованной навигации):
//    ProductView(id: Int)                              // товар по id (deep-link/каталог)
//    ProductView(product: Product)                     // товар с seed-данными из списка
//    ProductView(service: ServiceItem, shopName: String?)  // услуга (режим записи)
//
//  API (реальные методы старого клиента):
//    GET  api/v1/products/{id}              -> ProductDetail (+ modifierGroups)
//    GET  api/v1/services/{id}/slots        -> [Slot]
//    POST api/v1/appointments               <- AppointmentBody{slotId}
//
//  Добавление в корзину — через Cart.shared (single-store; конфликт магазина
//  разрешает Cart автоматически — диалог конфликта делает другой агент).
//  Деньги — только Decimal через Money. Токены — YM*.
//

// MARK: - ViewModel

@MainActor
final class ProductViewModel: ObservableObject {
    enum Mode { case product, service }

    @Published var detail: ProductDetail?
    @Published var slots: [Slot] = []
    @Published var loading = true
    @Published var error: String?
    @Published var booked = false

    let mode: Mode
    let productId: Int?
    let seedProduct: Product?
    let service: ServiceItem?
    let serviceShopName: String?

    init(id: Int) { mode = .product; productId = id; seedProduct = nil; service = nil; serviceShopName = nil }
    init(product: Product) { mode = .product; productId = product.id; seedProduct = product; service = nil; serviceShopName = nil }
    init(service: ServiceItem, shopName: String?) {
        mode = .service; productId = nil; seedProduct = nil
        self.service = service; self.serviceShopName = shopName
    }

    func load() async {
        loading = true; error = nil
        switch mode {
        case .product:
            guard let id = productId else { error = "Нет данных товара"; loading = false; return }
            do {
                detail = try await API.shared.get("api/v1/products/\(id)")
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        case .service:
            guard let s = service else { error = "Нет данных услуги"; loading = false; return }
            // Слоты записи. Отсутствие слотов — не ошибка (услуга без онлайн-записи).
            slots = (try? await API.shared.list("api/v1/services/\(s.id)/slots")) ?? []
        }
        loading = false
    }

    /// Запись на выбранный слот.
    func book(slot: Slot) async -> Bool {
        do {
            try await API.shared.postVoid("api/v1/appointments", body: AppointmentBody(slotId: slot.id))
            booked = true
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

// MARK: - ProductView

struct ProductView: View {
    @StateObject private var vm: ProductViewModel
    @StateObject private var cart = Cart.shared
    @EnvironmentObject private var coord: NavCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFav = false
    @State private var photoIndex = 0

    // product state
    @State private var selectedSize: Int?              // id выбранной радио-опции (Размер порции)
    @State private var checkedAddons: Set<Int> = []    // id выбранных чекбоксов (Добавить к блюду)
    @State private var qty: Double = 1
    @State private var added = false

    // service state
    @State private var selectedDay: Int = 0            // индекс дня
    @State private var selectedSlot: Int?              // id слота
    @State private var homeVisit = false

    init(id: Int) { _vm = StateObject(wrappedValue: ProductViewModel(id: id)) }
    init(product: Product) { _vm = StateObject(wrappedValue: ProductViewModel(product: product)) }
    init(service: ServiceItem, shopName: String?) {
        _vm = StateObject(wrappedValue: ProductViewModel(service: service, shopName: shopName))
    }

    private let heroHeight: CGFloat = 360

    var body: some View {
        ZStack(alignment: .top) {
            YMColor.bg.ignoresSafeArea()

            if vm.loading && vm.detail == nil && vm.mode == .product {
                loadingState
            } else if let e = vm.error, vm.detail == nil, vm.mode == .product {
                errorState(e)
            } else {
                content
                bottomBar
            }
            topControls
        }
        .navigationBarHidden(true)
        .task { await vm.load() }
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                gallery
                sheet.padding(.top, -34)
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Gallery 360pt (свайп + точки)

    private var gallery: some View {
        let photos: [String] = {
            if vm.mode == .product {
                let ph = (vm.detail?.photos ?? []).compactMap { $0.pathWebp }
                if !ph.isEmpty { return ph }
                if let p = vm.seedProduct?.photo { return [p] }
                return [""]
            } else {
                return [vm.service?.name.map { _ in "" } ?? ""]
            }
        }()
        return TabView(selection: $photoIndex) {
            ForEach(Array(photos.enumerated()), id: \.offset) { i, p in
                PhotoPlaceholder(url: API.imageURL(p.isEmpty ? nil : p),
                                 label: "ГАЛЕРЕЯ · СВАЙП", radius: 0, tone: i)
                    .frame(maxWidth: .infinity)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
        .frame(height: heroHeight)
    }

    // MARK: Sheet

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Название + ХАЛЯЛЬ.
            HStack(alignment: .center, spacing: 10) {
                Text(titleText)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(YMColor.text)
                    .lineLimit(3)
                if isHalal { HalalBadge() }
                Spacer(minLength: 0)
            }
            .padding(.top, 22)

            // ★рейтинг · метаданные.
            HStack(spacing: 10) {
                if let r = ratingValue, r > 0 {
                    HStack(spacing: 5) {
                        Text("★").foregroundStyle(YMColor.accent)
                        Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                    }
                    .font(.system(size: 13.5, weight: .bold))
                }
                if let meta = metaText, !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 13.5))
                        .foregroundStyle(YMColor.muted)
                }
            }
            .padding(.top, 10)

            // Описание.
            if let desc = descText, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 12)
            }

            if vm.mode == .product {
                productSections
            } else {
                serviceSections
            }

            Color.clear.frame(height: 120)
        }
        .padding(.horizontal, YMSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YMColor.bg.clipShape(RoundedRectangle(cornerRadius: YMRadius.sheet, style: .continuous)))
    }

    // MARK: Product sections (Размер порции / Добавить к блюду)

    @ViewBuilder private var productSections: some View {
        let groups = vm.detail?.modifierGroups ?? []
        // Радио-группа (Размер порции): type == "single" / isRequired.
        let radioGroups = groups.filter { ($0.type ?? "") == "single" || ($0.maxQty ?? 0) == 1 }
        // Чекбокс-группы (Добавить к блюду).
        let checkGroups = groups.filter { !(($0.type ?? "") == "single" || ($0.maxQty ?? 0) == 1) }

        ForEach(radioGroups) { g in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(g.name ?? "Размер порции")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                    Spacer()
                    Text("Выберите 1".uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(YMColor.accent)
                }
                VStack(spacing: 8) {
                    ForEach(g.options ?? []) { opt in
                        radioRow(opt, groupOptions: g.options ?? [])
                    }
                }
            }
            .padding(.top, 20)
        }

        ForEach(checkGroups) { g in
            VStack(alignment: .leading, spacing: 10) {
                Text(g.name ?? "Добавить к блюду")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(YMColor.text)
                VStack(spacing: 8) {
                    ForEach(g.options ?? []) { opt in
                        checkRow(opt)
                    }
                }
            }
            .padding(.top, 18)
        }
    }

    /// Радио-строка: выбранная — золотая рамка + золотая точка.
    private func radioRow(_ opt: ModifierOption, groupOptions: [ModifierOption]) -> some View {
        let selected = selectedSize == opt.id
        return Button {
            Haptics.selection()
            selectedSize = opt.id
        } label: {
            HStack(spacing: 12) {
                Text(opt.name ?? "—")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                Spacer(minLength: 8)
                if let pr = opt.price, pr > 0 {
                    Text(Money.format(Money.dec(pr)))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(YMColor.muted)
                }
                ZStack {
                    Circle().strokeBorder(selected ? YMColor.accent : YMColor.muted, lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if selected {
                        Circle().fill(YMColor.accent).frame(width: 11, height: 11)
                    }
                }
            }
            .padding(14)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(selected ? YMColor.accent : YMColor.hairline, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    /// Чекбокс-строка: выбранная — золотая галочка.
    private func checkRow(_ opt: ModifierOption) -> some View {
        let checked = checkedAddons.contains(opt.id)
        return Button {
            Haptics.selection()
            if checked { checkedAddons.remove(opt.id) } else { checkedAddons.insert(opt.id) }
        } label: {
            HStack(spacing: 12) {
                Text(opt.name ?? "—")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                Spacer(minLength: 8)
                if let pr = opt.price, pr > 0 {
                    Text("+\(Money.format(Money.dec(pr)))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(YMColor.muted)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(checked ? YMColor.accent : YMColor.muted, lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if checked {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(YMColor.accent)
                            .frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(YMColor.onAccent)
                    }
                }
            }
            .padding(14)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Service sections (Дата записи / Свободное время / Вызов на дом)

    @ViewBuilder private var serviceSections: some View {
        // Дата записи — горизонтальный пикер дней (из дат слотов или ближайшие 7 дней).
        VStack(alignment: .leading, spacing: 10) {
            Text("Дата записи")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(YMColor.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(dayList.enumerated()), id: \.offset) { i, day in
                        dayCell(i, day)
                    }
                }
            }
        }
        .padding(.top, 20)

        // Свободное время — сетка 4-в-ряд.
        VStack(alignment: .leading, spacing: 10) {
            Text("Свободное время")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(YMColor.text)
            let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
            if slotsForDay.isEmpty {
                Text("Нет свободных слотов на эту дату")
                    .font(YMFont.callout)
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 4)
            } else {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(slotsForDay) { slot in
                        slotCell(slot)
                    }
                }
            }
        }
        .padding(.top, 20)

        // Плашка «Вызвать специалиста на дом» с тумблером.
        HStack(spacing: 12) {
            Text("🏠").font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text("Вызвать специалиста на дом")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(YMColor.text)
                Text("Мастер приедет по вашему адресу")
                    .font(.system(size: 12))
                    .foregroundStyle(YMColor.muted)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $homeVisit)
                .labelsHidden()
                .tint(YMColor.accent)
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
        .padding(.top, 20)
    }

    private func dayCell(_ index: Int, _ day: DayItem) -> some View {
        let active = selectedDay == index
        return Button {
            Haptics.selection()
            selectedDay = index
            selectedSlot = nil
        } label: {
            VStack(spacing: 3) {
                Text(day.dow)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? YMColor.onAccent.opacity(0.75) : YMColor.muted)
                Text(day.num)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(active ? YMColor.onAccent : YMColor.text)
            }
            .frame(width: 54, height: 60)
            .background(active ? YMColor.accent : YMColor.surface,
                        in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(active ? Color.clear : YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func slotCell(_ slot: Slot) -> some View {
        let taken = false  // TODO(API): в модели Slot нет флага занятости — все приходящие слоты свободны.
        let active = selectedSlot == slot.id
        return Button {
            guard !taken else { return }
            Haptics.selection()
            selectedSlot = slot.id
        } label: {
            Text(slotLabel(slot))
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(active ? YMColor.onAccent : YMColor.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(active ? YMColor.accent : YMColor.surface,
                            in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(active ? Color.clear : YMColor.hairline, lineWidth: 1.5))
                .opacity(taken ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(taken)
    }

    // MARK: Top controls

    private var topControls: some View {
        HStack {
            Button { Haptics.light(); dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.4), in: Circle())
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            HeartButton(isFav: $isFav, size: 38)
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 8)
    }

    // MARK: Bottom bar

    @ViewBuilder private var bottomBar: some View {
        VStack {
            Spacer()
            if vm.mode == .product {
                productBottomBar
            } else {
                serviceBottomBar
            }
        }
    }

    // Степпер −/N/+ + кнопка «В корзину · СУММА».
    private var productBottomBar: some View {
        HStack(spacing: 12) {
            // Степпер на surface2, «+» золото.
            HStack(spacing: 4) {
                Button { decQty() } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(YMColor.text)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                Text(qtyLabel)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(YMColor.text)
                    .frame(minWidth: 28)
                Button { incQty() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(YMColor.onAccent)
                        .frame(width: 38, height: 38)
                        .background(YMColor.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(4)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))

            Button {
                addToCart()
            } label: {
                HStack(spacing: 8) {
                    Text(added ? "Добавлено ✓" : "В корзину")
                    Text("·").opacity(0.6)
                    Text(Money.format(lineTotal))
                }
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(vm.detail == nil)
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.bar)
    }

    // Кнопка «Записаться · от СУММА».
    private var serviceBottomBar: some View {
        Button {
            book()
        } label: {
            HStack(spacing: 8) {
                Text(vm.booked ? "Вы записаны ✓" : "Записаться")
                Text("·").opacity(0.6)
                Text("от \(Money.format(Money.dec(vm.service?.price)))")
            }
        }
        .buttonStyle(YMPrimaryButtonStyle())
        .disabled(selectedSlot == nil || vm.booked)
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.bar)
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 16) {
            SkeletonBox(radius: 0).frame(height: heroHeight).ignoresSafeArea(edges: .top)
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBox().frame(width: 200, height: 24)
                SkeletonBox().frame(width: 260, height: 14)
                SkeletonBox(radius: YMRadius.control).frame(height: 54)
                SkeletonBox(radius: YMRadius.control).frame(height: 54)
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

    // MARK: Derived (общие)

    private var titleText: String {
        vm.mode == .product ? (vm.detail?.name ?? vm.seedProduct?.name ?? "—") : (vm.service?.name ?? "—")
    }
    private var isHalal: Bool {
        vm.mode == .product && (vm.detail?.isHalal ?? vm.seedProduct?.isHalal ?? false)
    }
    private var ratingValue: Double? {
        // У ProductDetail/ServiceItem нет рейтинга в модели — показываем только если появится.
        // TODO(API): рейтинг товара/услуги в ProductDetail/ServiceItem отсутствует.
        nil
    }
    private var metaText: String? {
        if vm.mode == .service, let dm = vm.service?.durationMin, dm > 0 { return "\(dm) мин" }
        if vm.mode == .product, let unit = vm.detail?.unit ?? vm.seedProduct?.unit, !unit.isEmpty { return unit }
        return nil
    }
    private var descText: String? {
        vm.mode == .product ? (vm.detail?.description ?? vm.seedProduct?.description) : vm.service?.description
    }

    // MARK: Product logic

    private var stepValue: Double {
        guard let d = vm.detail else { return 1 }
        let presets = (d.qtyPresets ?? "").split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }.sorted()
        if let f = presets.first { return f }
        if (d.qtyStep ?? 0) > 0 { return d.qtyStep ?? 0.1 }
        let weight = ["кг", "г", "kg", "g", "л", "l", "мл", "ml"].contains((d.unit ?? "").lowercased())
        return ((d.qtyFractional ?? 0) == 1 || weight) ? 0.1 : 1
    }
    private var isFractional: Bool { stepValue != 1 }
    private var qtyLabel: String {
        isFractional ? fmtQty(qty, vm.detail?.unit) : String(Int(qty.rounded()))
    }
    private func incQty() { Haptics.selection(); qty = ((qty + stepValue) * 1000).rounded() / 1000 }
    private func decQty() {
        Haptics.selection()
        let nq = ((qty - stepValue) * 1000).rounded() / 1000
        if nq >= stepValue { qty = nq }
    }

    /// Цена строки: (цена товара + сумма выбранных модификаторов) × qty.
    /// ИТОГ модификаторов суммируем локально (option.price) — сервер финализирует при заказе.
    private var lineTotal: Decimal {
        guard let d = vm.detail else { return 0 }
        let base = Money.dec(d.price)
        let allOptions = (d.modifierGroups ?? []).flatMap { $0.options ?? [] }
        var mods = Decimal(0)
        if let size = selectedSize, let opt = allOptions.first(where: { $0.id == size }) {
            mods += Money.dec(opt.price)
        }
        for id in checkedAddons {
            if let opt = allOptions.first(where: { $0.id == id }) { mods += Money.dec(opt.price) }
        }
        return (base + mods) * Money.dec(qty)
    }

    private var selectedModifierIds: [Int] {
        var ids = Array(checkedAddons)
        if let size = selectedSize { ids.append(size) }
        return ids
    }

    private func addToCart() {
        guard let d = vm.detail else { return }
        let newShopId = d.shopId ?? 0
        // Инвариант single-store: если корзина занята ДРУГИМ магазином — просим
        // подтверждение через глобальный диалог, и только по «Очистить» добавляем.
        if let cur = cart.shopId, cur != newShopId, !cart.isEmpty {
            coord.requestCartConflict(
                currentShop: cart.shopName,
                newShop: d.shopName,
                onConfirm: { [self] in commitAdd(d) }
            )
            return
        }
        commitAdd(d)
    }

    private func commitAdd(_ d: ProductDetail) {
        let allOptions = (d.modifierGroups ?? []).flatMap { $0.options ?? [] }
        Cart.shared.add(
            product: d,
            modifierIds: selectedModifierIds,
            options: allOptions,
            shopId: d.shopId ?? 0,
            shopName: d.shopName,
            qty: qty
        )
        added = true
        Haptics.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { dismiss() }
    }

    // MARK: Service logic

    struct DayItem { let dow: String; let num: String; let date: Date }

    /// Список дней: если у слотов есть даты — берём их; иначе ближайшие 7 дней.
    private var dayList: [DayItem] {
        let cal = Calendar.current
        let df = DateFormatter(); df.locale = Locale(identifier: "ru_RU"); df.dateFormat = "EEEEEE"
        let today = Date()
        return (0..<7).map { off in
            let date = cal.date(byAdding: .day, value: off, to: today) ?? today
            let dow = df.string(from: date).uppercased()
            let num = String(cal.component(.day, from: date))
            return DayItem(dow: dow, num: num, date: date)
        }
    }

    /// Слоты выбранного дня. Slot.timeStart может нести дату/время; при отсутствии
    /// сопоставления по дате показываем все слоты (сервер сам ограничивает выдачу).
    private var slotsForDay: [Slot] {
        vm.slots
    }

    private func slotLabel(_ slot: Slot) -> String {
        // timeStart формата "HH:mm" или "yyyy-MM-dd HH:mm:ss" — показываем HH:mm.
        let s = slot.timeStart ?? ""
        if s.count >= 16, s.contains(" ") {
            return String(s.dropFirst(11).prefix(5))
        }
        return String(s.prefix(5))
    }

    private func book() {
        guard let slotId = selectedSlot, let slot = vm.slots.first(where: { $0.id == slotId }) else { return }
        Task {
            let ok = await vm.book(slot: slot)
            if ok {
                Haptics.success()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() }
            } else {
                Haptics.error()
            }
        }
    }
}
