import SwiftUI
import MapKit

//  OrderDetailView.swift
//  Yumurta — premium iOS-клиент. Экран 6 (detail) «Заказ №…».
//
//  Init-сигнатура: OrderDetailView(id: Int, onChat: @escaping (Int) -> Void)
//    id     — orderId.
//    onChat — открыть чат с заведением по этому заказу (навигацию решает вызывающая сторона).
//
//  Данные 1:1 со старым клиентом:
//    GET  api/v1/orders/{id}          → OrderDetail  (status, items, суммы Double?…)
//    GET  api/v1/orders/{id}/track    → TrackData    (courierLat/Lng, courierName/Phone, etaMinutes, status)
//    GET  api/v1/orders/{id}/reorder  → ReorderData  (повтор заказа: shopId/Name/Slug + items)
//  Деньги — Double? → Money.format(Money.parse(x)) (Decimal).
//
//  Таймлайн статусов строится машиной OrderFlow (new→accepted→preparing→ready→in_delivery→done; cancelled).
//  Пин курьера и таймлайн говорят на том же «золотом» визуальном языке, что лента в списке.

// MARK: - CourierPoint (аннотация карты)

private struct CourierPoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - OrderDetailViewModel

@MainActor
final class OrderDetailViewModel: ObservableObject {
    let id: Int
    @Published var order: OrderDetail?
    @Published var track: TrackData?
    @Published var loading = true
    @Published var reorderInFlight = false
    @Published var reorderDone = false     // сервер повторил заказ → корзина обновлена

    private var pollTimer: Timer?

    init(id: Int) { self.id = id }

    func load() async {
        loading = true
        async let o: OrderDetail? = try? await API.shared.get("api/v1/orders/\(id)")
        async let t: TrackData?   = try? await API.shared.get("api/v1/orders/\(id)/track")
        order = await o
        track = await t
        loading = false
    }

    /// Живой опрос трекинга (8с) — только пока заказ активен (в пути / готовится).
    func startTrackingIfActive() {
        guard OrderFlow.isActive(order?.status ?? track?.status) else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if let t: TrackData = try? await API.shared.get("api/v1/orders/\(self.id)/track") {
                    self.track = t
                }
            }
        }
    }

    func stopTracking() { pollTimer?.invalidate(); pollTimer = nil }

    /// Повторить заказ: сервер возвращает состав → кладём в корзину (single-store cart).
    func repeatOrder(cart: Cart) async {
        reorderInFlight = true; defer { reorderInFlight = false }
        // GET api/v1/orders/{id}/reorder → ReorderData (как в старом клиенте: Reorder.perform).
        guard let data: ReorderData = try? await API.shared.get("api/v1/orders/\(id)/reorder"),
              let shopId = data.shopId, let items = data.items, !items.isEmpty else {
            // TODO(API): если эндпоинт reorder отсутствует/пуст — деградируем без падения (ниже баннер).
            Haptics.warning(); return
        }
        // Конвертация ReorderItem → CartLine (single-store: одна корзина = один магазин).
        let lines: [CartLine] = items.compactMap { it in
            guard let pid = it.productId else { return nil }
            return CartLine(key: "reorder-\(pid)",
                            productId: pid,
                            name: it.name ?? "Товар",
                            unitPrice: it.price ?? 0,
                            qty: it.qty ?? 1,
                            modifierIds: [],
                            modsLabel: "",
                            photo: it.photo)
        }
        guard !lines.isEmpty else { Haptics.warning(); return }
        cart.setLines(lines, shopId: shopId, shopName: data.shopName, shopSlug: data.shopSlug)
        Haptics.success()
        reorderDone = true
    }
}

// MARK: - OrderDetailView (screen: detail)

struct OrderDetailView: View {
    let id: Int
    /// Открыть чат с заведением по этому заказу.
    var onChat: (Int) -> Void

    @EnvironmentObject private var cart: Cart
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm: OrderDetailViewModel

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.751, longitude: 37.618),
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))

    init(id: Int, onChat: @escaping (Int) -> Void) {
        self.id = id
        self.onChat = onChat
        _vm = StateObject(wrappedValue: OrderDetailViewModel(id: id))
    }

    private var courierCoord: CLLocationCoordinate2D? {
        guard let lat = vm.track?.courierLat, let lng = vm.track?.courierLng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var body: some View {
        ScrollView {
            if vm.loading && vm.order == nil {
                VStack(spacing: YMSpace.md) {
                    SkeletonBox().frame(height: 200)
                    SkeletonBox().frame(height: 240)
                }
                .padding(YMSpace.xl)
            } else if let o = vm.order {
                VStack(spacing: YMSpace.lg) {
                    if OrderFlow.isActive(o.status), courierCoord != nil {
                        mapCard
                        courierPlate
                    }
                    timelineCard(o)
                    itemsCard(o)
                    actionButtons(o)
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.vertical, YMSpace.lg)
            } else {
                emptyBox
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(); vm.startTrackingIfActive() }
        .onDisappear { vm.stopTracking() }
        .onChange(of: courierCoord?.latitude) { _ in recenter() }
    }

    private var navTitle: String {
        if let n = vm.order?.dailyNumber { return "Заказ №\(n)" }
        return "Заказ №\(id)"
    }

    private func recenter() {
        guard let c = courierCoord else { return }
        // Сглаживание маркера (как в старом TrackView): плавно двигаем центр между опросами.
        withAnimation(.easeInOut(duration: 1.0)) { region.center = c }
    }

    // MARK: Карта с золотым пином курьера

    private var mapCard: some View {
        ZStack {
            Map(coordinateRegion: $region,
                annotationItems: courierCoord.map { [CourierPoint(coordinate: $0)] } ?? []) { p in
                MapAnnotation(coordinate: p.coordinate) {
                    CourierPin()   // золотой пульсирующий пин — единый визуальный язык
                }
            }
            .allowsHitTesting(false)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    // MARK: Плашка курьера

    private var courierPlate: some View {
        HStack(spacing: YMSpace.md) {
            LogoBadge(url: nil,
                      letter: (vm.track?.courierName ?? "К").prefix(1).uppercased(),
                      size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Курьер · \(vm.track?.courierName ?? "в пути")")
                    .font(YMFont.headline).foregroundStyle(YMColor.text)
                HStack(spacing: 6) {
                    StatusDot(color: YMColor.accent, pulsing: true, size: 6)
                    Text(etaLine).font(YMFont.subhead).foregroundStyle(YMColor.accent)
                }
            }
            Spacer(minLength: 8)
            if let phone = vm.track?.courierPhone, !phone.isEmpty {
                Button {
                    Haptics.light()
                    if let url = URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(YMColor.onAccent)
                        .frame(width: 44, height: 44)
                        .background(YMColor.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Позвонить курьеру")
            }
        }
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private var etaLine: String {
        let mins = vm.track?.etaMinutes
        let base = OrderStatus.label(vm.track?.status ?? vm.order?.status)
        if let m = mins, m > 0 { return "\(base) · \(m) мин до вас" }
        return base
    }

    // MARK: Таймлайн статусов

    private func timelineCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Статус заказа")
                .font(YMFont.title3).foregroundStyle(YMColor.text)
                .padding(.bottom, YMSpace.md)

            // Золотая живая лента-резюме над таймлайном (единый язык со списком).
            GoldStatusRibbon(progress: OrderFlow.progress(o.status),
                             pulsing: OrderFlow.isEnRoute(o.status),
                             cancelled: OrderFlow.isCancelled(o.status))
                .padding(.bottom, YMSpace.lg)

            if OrderFlow.isCancelled(o.status) {
                HStack(spacing: YMSpace.sm) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(YMColor.statusCancel)
                    Text("Заказ отменён").font(YMFont.headline).foregroundStyle(YMColor.statusCancel)
                }
            } else {
                let current = OrderFlow.stepIndex(o.status)
                ForEach(Array(OrderFlow.steps.enumerated()), id: \.offset) { idx, key in
                    TimelineRow(
                        title: OrderFlow.stepTitle(key),
                        time: stepTime(idx: idx, current: current, o: o),
                        state: idx < current ? .done : (idx == current ? .active : .todo),
                        isLast: idx == OrderFlow.steps.count - 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    /// Подпись времени шага: для оформления — реальное createdAt; для активного — «сейчас»;
    /// для будущего — ETA (если есть). Детальных штампов по каждому шагу сервер не отдаёт.
    private func stepTime(idx: Int, current: Int, o: OrderDetail) -> String {
        if idx == 0 { return DateFmt.time(o.createdAt) }
        if idx == current { return "сейчас" }
        if idx == OrderFlow.steps.count - 1, let m = vm.track?.etaMinutes, m > 0, current < idx {
            return "ожидается ~\(m) мин"
        }
        // TODO(API): нет per-step timestamps (status_timeline) — время промежуточных шагов не показываем.
        return ""
    }

    // MARK: Состав + суммы

    private func itemsCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Состав").font(YMFont.title3).foregroundStyle(YMColor.text)
                .padding(.bottom, YMSpace.xs)
            ForEach(o.items ?? []) { it in
                HStack(spacing: YMSpace.sm) {
                    Text(qtyLabel(it))
                        .font(.system(size: 14, weight: .heavy)).foregroundStyle(YMColor.accent)
                    Text(it.name ?? "—").font(YMFont.body).foregroundStyle(YMColor.text)
                    Spacer(minLength: 8)
                    Text(Money.format(Money.parse(it.price)))
                        .font(YMFont.body).foregroundStyle(YMColor.muted)
                }
            }
            Divider().overlay(YMColor.hairline).padding(.vertical, YMSpace.xs)
            sumRow("Товары", o.subtotal)
            if let d = o.deliveryPrice, d > 0 { sumRow("Доставка", d) }
            if let f = o.serviceFee, f > 0 { sumRow("Сервисный сбор", f) }
            if let t = o.tip, t > 0 { sumRow("Чаевые курьеру", t) }
            if let d = o.discount, d > 0 {
                sumRow(o.promoCode.map { "Скидка (\($0))" } ?? "Скидка", d, negative: true, green: true)
            }
            if let ps = o.pointsSpent, ps > 0 { sumRow("Оплачено баллами", ps, negative: true, green: true) }
            HStack {
                Text("Итого").font(YMFont.headline).foregroundStyle(YMColor.text)
                Spacer()
                Text(Money.format(Money.parse(o.total)))
                    .font(.system(size: 17, weight: .heavy)).foregroundStyle(YMColor.text)
            }
            .padding(.top, YMSpace.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private func qtyLabel(_ it: OrderItem) -> String {
        let q = it.qty ?? 1
        let n = q == q.rounded() ? String(Int(q)) : String(format: "%g", q)
        return "\(n)×"
    }

    private func sumRow(_ title: String, _ value: Double?, negative: Bool = false, green: Bool = false) -> some View {
        HStack {
            Text(title).font(YMFont.callout).foregroundStyle(YMColor.muted)
            Spacer()
            Text((negative ? "−" : "") + Money.format(Money.parse(value)))
                .font(YMFont.callout)
                .foregroundStyle(green ? YMColor.statusDone : YMColor.muted)
        }
    }

    // MARK: Кнопки действий

    private func actionButtons(_ o: OrderDetail) -> some View {
        VStack(spacing: YMSpace.md) {
            Button {
                Haptics.light(); onChat(id)
            } label: {
                Label("Чат с рестораном", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .buttonStyle(YMPrimaryButtonStyle())

            Button {
                Task {
                    await vm.repeatOrder(cart: cart)
                    if vm.reorderDone { router.requestedTab = 3 }  // открыть таб «Заказы»/корзину
                }
            } label: {
                HStack {
                    if vm.reorderInFlight { ProgressView().tint(YMColor.accent) }
                    else { Label("Повторить заказ", systemImage: "arrow.clockwise") }
                }
                .font(YMFont.headline).foregroundStyle(YMColor.accent)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(YMColor.accent.opacity(0.4), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(vm.reorderInFlight)
        }
    }

    private var emptyBox: some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(YMColor.muted)
            Text("Заказ не найден").font(YMFont.title3).foregroundStyle(YMColor.text)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

// MARK: - TimelineRow (кружки шагов + соединительная линия)

private struct TimelineRow: View {
    enum StepState { case done, active, todo }
    let title: String
    let time: String
    let state: StepState
    let isLast: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: YMSpace.md) {
            VStack(spacing: 0) {
                circle
                if !isLast {
                    Rectangle()
                        .fill(state == .done ? YMColor.accent : YMColor.hairline)
                        .frame(width: 2, height: 34)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: state == .todo ? .regular : .semibold))
                    .foregroundStyle(state == .todo ? YMColor.muted : YMColor.text)
                if !time.isEmpty {
                    Text(time).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .onAppear {
            guard state == .active, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private var circle: some View {
        switch state {
        case .done:
            ZStack {
                Circle().fill(YMColor.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy)).foregroundStyle(YMColor.onAccent)
            }
            .frame(width: 26, height: 26)
        case .active:
            ZStack {
                Circle().fill(YMColor.accent.opacity(0.15))
                Circle().strokeBorder(YMColor.accent, lineWidth: 2)
                Circle().fill(YMColor.accent).frame(width: 9, height: 9)
            }
            .frame(width: 26, height: 26)
            .shadow(color: (pulse && !reduceMotion) ? YMPalette.gold.opacity(0.5) : .clear,
                    radius: pulse ? 8 : 0)
            .scaleEffect((pulse && !reduceMotion) ? 1.06 : 1)
        case .todo:
            Circle()
                .fill(YMColor.surface2)
                .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
                .frame(width: 26, height: 26)
        }
    }
}

// MARK: - CourierPin (золотой пульсирующий пин курьера)

/// Пин курьера на карте — золотой, с мягко пульсирующим кольцом (тот же язык, что лента/точка).
/// Деградирует при Reduce Motion в статичный пин.
struct CourierPin: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(YMPalette.gold.opacity(pulse ? 0 : 0.35))
                    .frame(width: pulse ? 46 : 18, height: pulse ? 46 : 18)
            }
            Circle().fill(YMColor.bg).frame(width: 26, height: 26)
            Circle().fill(YMColor.accent).frame(width: 20, height: 20)
            Image(systemName: "bicycle")
                .font(.system(size: 10, weight: .heavy)).foregroundStyle(YMColor.onAccent)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityLabel("Курьер на карте")
    }
}
