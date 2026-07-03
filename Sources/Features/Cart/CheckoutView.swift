import SwiftUI

//
//  CheckoutView.swift — экран оформления (screen: checkout). Дизайн 1:1 с CheckoutPhone.dc.html.
//
//  ПУБЛИЧНАЯ INIT-СИГНАТУРА (для централизованной навигации):
//    CheckoutView(onSuccess: (OrderCreateResult) -> Void, onBack: () -> Void)
//      onSuccess — заказ создан; родитель пушит SuccessView(order:).
//      onBack    — «‹ Оформление» назад к корзине.
//
//  API — реальные методы старого клиента (контракт НЕ меняется):
//    POST api/v1/delivery/quote            -> DeliveryQuote   (расчёт доставки по адресу)
//    GET  api/v1/profile/addresses         -> [Address]       (сохранённые адреса)
//    GET  api/v1/shops/{slug}              -> ShopDetail      (сервисный сбор)
//    POST api/v1/orders                    -> OrderCreateResult (создание заказа)
//
//  Зона доставки определяется на сервере СКРЫТО по координатам адреса (клиент видит
//  только результат — цену/недоступность). Выбор зоны НЕ показываем.
//  Деньги — только Decimal через Money.format(Money.parse(...)). Токены — YM*.
//

// ── Тело создания заказа (контракт как в старом клиенте, snake_case) ──
private struct OrderItemBody: Encodable {
    let productId: Int; let qty: Double; let modifiers: [Int]?
    enum CodingKeys: String, CodingKey { case productId = "product_id", qty, modifiers }
}
private struct OrderBody: Encodable {
    let shopId: Int; let items: [OrderItemBody]; let deliveryType: String
    let paymentType: String; let address: String?; let comment: String?
    let deliveryPrice: Double?
    let lat: Double?; let lng: Double?
    enum CodingKeys: String, CodingKey {
        case shopId = "shop_id", items, deliveryType = "delivery_type", paymentType = "payment_type",
             address, comment, deliveryPrice = "delivery_price", lat, lng
    }
}
// Тело расчёта доставки (совпадает со старым клиентом).
private struct QuoteBody: Encodable { let shopId: Int; let lat: Double; let lng: Double; let subtotal: Double
    enum CodingKeys: String, CodingKey { case shopId = "shop_id", lat, lng, subtotal } }

// Способ получения (в макете 3 сегмента; delivery/pickup + за столик = dine_in).
private enum Fulfillment: String, CaseIterable, Hashable {
    case delivery, pickup, dineIn
    var apiValue: String { self == .dineIn ? "dine_in" : rawValue }
    var title: String {
        switch self {
        case .delivery: return "Доставка"
        case .pickup:   return "Самовывоз"
        case .dineIn:   return "За столик"
        }
    }
}

struct CheckoutView: View {
    var onSuccess: (OrderCreateResult) -> Void = { _ in }
    var onBack: () -> Void = {}

    @ObservedObject private var cart = Cart.shared

    @State private var fulfillment: Fulfillment = .delivery
    @State private var addresses: [Address] = []
    @State private var selectedAddress: Address?
    @State private var shop: ShopDetail?
    @State private var quote: DeliveryQuote?
    @State private var comment = ""
    @State private var placing = false
    @State private var errorText: String?
    @State private var showAddressPicker = false

    // MARK: - Деньги (всё Decimal)

    private var subtotal: Decimal { Money.parse(cart.total) }

    // Стоимость доставки — ТОЛЬКО из серверного расчёта по адресу. До адреса / при
    // недоступности / для самовывоза-и-стола → 0.
    private var deliveryCost: Decimal {
        guard fulfillment == .delivery, let q = quote, q.available else { return 0 }
        return Money.parse(q.deliveryPrice ?? 0)
    }
    private var serviceFee: Decimal { Money.parse(Fees.service(subtotal: cart.total, shop: shop)) }
    private var grandTotal: Decimal { max(0, subtotal + deliveryCost + serviceFee) }

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                scrollContent
                bottomCTA
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showAddressPicker) { addressPicker }
        .task {
            await loadAddresses()
            if let slug = cart.shopSlug {
                shop = try? await API.shared.get("api/v1/shops/\(slug)")
            }
        }
        .onChange(of: fulfillment) { _ in Task { await quoteDelivery() } }
    }

    // MARK: - Header «‹ Оформление»

    private var header: some View {
        HStack(spacing: YMSpace.md) {
            Button(action: { Haptics.light(); onBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 38, height: 38)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text("Оформление")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)
            Spacer()
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.xs)
        .padding(.bottom, YMSpace.md)
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                storeBanner
                    .padding(.bottom, YMSpace.md)

                SectionKicker("Способ получения").padding(.top, YMSpace.xs).padding(.bottom, YMSpace.sm)
                YMSegmented(options: Fulfillment.allCases, selection: $fulfillment) { $0.title }

                if fulfillment == .delivery {
                    addressCard.padding(.top, YMSpace.md)
                }

                SectionKicker("Ваш заказ").padding(.top, YMSpace.lg).padding(.bottom, YMSpace.md)
                VStack(spacing: YMSpace.md) {
                    ForEach(cart.lines) { line in CheckoutRow(line: line) }
                }

                commentField.padding(.top, YMSpace.lg)

                totalsCard.padding(.top, YMSpace.lg)

                if let e = errorText {
                    Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, YMSpace.md)
                }
                Color.clear.frame(height: YMSpace.lg)
            }
            .padding(.horizontal, YMSpace.xl)
        }
    }

    private var storeBanner: some View {
        HStack(spacing: YMSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(YMColor.surface2)
                Text(monogram).font(.system(size: 17, weight: .heavy)).foregroundStyle(YMColor.accent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(cart.shopName ?? "Магазин").font(.system(size: 14.5, weight: .bold)).foregroundStyle(YMColor.text)
                Text("\(cart.count) поз. в заказе").font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var monogram: String {
        let s = (cart.shopName ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "•" : String(s.prefix(1)).uppercased()
    }

    // Карточка адреса. Зона доставки определяется молча (сервер) — не показываем выбор зоны.
    private var addressCard: some View {
        Button(action: { Haptics.light(); showAddressPicker = true }) {
            HStack(spacing: YMSpace.md) {
                Text("📍").font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    if let a = selectedAddress {
                        Text(a.display.isEmpty ? "Адрес" : a.display)
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(YMColor.text)
                            .lineLimit(1)
                        Text(zoneSubtitle(a))
                            .font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(1)
                    } else {
                        Text("Выберите адрес доставки")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(YMColor.text)
                        Text("Зона доставки определится автоматически")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                }
                Spacer()
                Text(selectedAddress == nil ? "Выбрать" : "Изм.")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(YMColor.accent)
            }
            .padding(14)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // Подпись под адресом: зона определена + признак недоступности/минимума.
    private func zoneSubtitle(_ a: Address) -> String {
        var parts: [String] = []
        if let ent = a.entrance, !ent.isEmpty { parts.append("Подъезд \(ent)") }
        if let fl = a.floor, !fl.isEmpty { parts.append("этаж \(fl)") }
        if let q = quote {
            if !q.available { parts.append(q.reason ?? "доставка недоступна") }
            else { parts.append("зона доставки определена") }
        } else {
            parts.append("зона доставки определена")
        }
        return parts.joined(separator: " · ")
    }

    private var commentField: some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "square.and.pencil").font(.system(size: 15)).foregroundStyle(YMColor.muted)
            TextField("Комментарий к заказу…", text: $comment, axis: .vertical)
                .font(.system(size: 13.5))
                .foregroundStyle(YMColor.text)
                .tint(YMColor.accent)
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(YMColor.hairline)
        )
    }

    // Итоги: Товары / Доставка / Сервисный сбор.
    private var totalsCard: some View {
        VStack(spacing: 9) {
            totalRow("Товары (\(cart.count))", Money.format(subtotal))
            if fulfillment == .delivery {
                totalRow("Доставка", deliveryLabel)
            }
            if serviceFee > 0 {
                totalRow("Сервисный сбор", Money.format(serviceFee))
            }
        }
        .padding(YMSpace.lg)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var deliveryLabel: String {
        guard let q = quote else { return "уточняется" }
        if !q.available { return "недоступна" }
        return deliveryCost <= 0 ? "бесплатно" : Money.format(deliveryCost)
    }

    private func totalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
            Spacer()
            Text(value).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(YMColor.muted)
        }
    }

    // MARK: - Bottom CTA «Оформить заказ · СУММА»

    private var bottomCTA: some View {
        VStack(spacing: YMSpace.md) {
            HStack {
                Text("Итого").font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
                Spacer()
                Text(Money.format(grandTotal)).font(.system(size: 22, weight: .heavy)).foregroundStyle(YMColor.text)
            }
            Button(action: placeOrder) {
                HStack(spacing: YMSpace.sm) {
                    if placing { ProgressView().tint(YMColor.onAccent) }
                    Text(placing ? "Оформляем…" : "Оформить заказ · \(Money.format(grandTotal))")
                }
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(placing || cart.isEmpty)
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.top, YMSpace.lg)
        .padding(.bottom, YMSpace.xxl)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) { YMColor.hairline.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Address picker (нижняя шторка)

    private var addressPicker: some View {
        NavigationStack {
            List {
                if addresses.isEmpty {
                    Text("Нет сохранённых адресов. Добавьте адрес в профиле.")
                        .font(YMFont.body).foregroundStyle(YMColor.muted)
                }
                ForEach(addresses) { a in
                    Button {
                        selectedAddress = a
                        showAddressPicker = false
                        Task { await quoteDelivery() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.label?.isEmpty == false ? a.label! : "Адрес")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(YMColor.text)
                                Text(a.display).font(YMFont.caption).foregroundStyle(YMColor.muted)
                            }
                            Spacer()
                            if selectedAddress?.id == a.id {
                                Image(systemName: "checkmark").foregroundStyle(YMColor.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Адрес доставки")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Загрузка / расчёт

    private func loadAddresses() async {
        do {
            let list: [Address] = try await API.shared.list("api/v1/profile/addresses")
            await MainActor.run {
                addresses = list
                // По умолчанию — основной адрес (с координатами) → сразу считается доставка.
                selectedAddress = list.first(where: { $0.isDefaultBool }) ?? list.first
            }
            await quoteDelivery()
        } catch {
            // graceful: адресов нет — покажем плейсхолдер, доставка = уточняется.
        }
    }

    // Серверный расчёт доставки по координатам адреса. shop_id — из корзины.
    private func quoteDelivery() async {
        guard fulfillment == .delivery,
              let a = selectedAddress, let la = a.lat, let lo = a.lng,
              let sid = cart.shopId else {
            await MainActor.run { quote = nil }
            return
        }
        let q: DeliveryQuote? = try? await API.shared.post(
            "api/v1/delivery/quote",
            body: QuoteBody(shopId: sid, lat: la, lng: lo, subtotal: cart.total)
        )
        await MainActor.run { quote = q }
    }

    // Полный адрес курьеру: город/улица/дом + доп. поля из выбранного адреса.
    private func composedAddress() -> String? {
        guard let a = selectedAddress else { return nil }
        var parts: [String] = []
        if let c = a.city, !c.isEmpty { parts.append(c) }
        if let st = a.street, !st.isEmpty {
            var line = st
            if let h = a.house, !h.isEmpty { line += ", д. \(h)" }
            parts.append(line)
        }
        if let ap = a.apartment, !ap.isEmpty { parts.append("кв. \(ap)") }
        if let en = a.entrance, !en.isEmpty { parts.append("подъезд \(en)") }
        if let fl = a.floor, !fl.isEmpty { parts.append("этаж \(fl)") }
        if let ic = a.intercom, !ic.isEmpty { parts.append("домофон \(ic)") }
        let s = parts.joined(separator: ", ")
        return s.isEmpty ? a.display : s
    }

    // MARK: - Создание заказа

    private func placeOrder() {
        guard let shopId = cart.shopId, !cart.isEmpty else { errorText = "Корзина пуста"; return }
        if fulfillment == .delivery {
            if selectedAddress == nil { errorText = "Выберите адрес доставки"; return }
            if let q = quote, !q.available { errorText = q.reason ?? "Доставка по этому адресу недоступна"; return }
            if let q = quote, q.belowMin == true {
                errorText = "Минимальная сумма заказа: \(Money.format(Money.parse(q.minOrder ?? 0)))"; return
            }
        }
        Haptics.medium()
        placing = true; errorText = nil

        let items = cart.lines.map {
            OrderItemBody(productId: $0.productId, qty: $0.qty,
                          modifiers: $0.modifierIds.isEmpty ? nil : $0.modifierIds)
        }
        let dp = fulfillment == .delivery ? NSDecimalNumber(decimal: deliveryCost).doubleValue : nil
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = OrderBody(
            shopId: shopId, items: items,
            deliveryType: fulfillment.apiValue,
            // TODO(API): выбор способа оплаты в этом блоке не показывается (по макету).
            // Значение "cash" — безопасный дефолт; оплата уточняется на следующем шаге.
            paymentType: "cash",
            address: fulfillment == .delivery ? composedAddress() : nil,
            comment: trimmed.isEmpty ? nil : trimmed,
            deliveryPrice: dp,
            lat: fulfillment == .delivery ? selectedAddress?.lat : nil,
            lng: fulfillment == .delivery ? selectedAddress?.lng : nil
        )

        Task {
            do {
                let r: OrderCreateResult = try await API.shared.post("api/v1/orders", body: body)
                await MainActor.run {
                    Haptics.success()
                    cart.clear()
                    placing = false
                    onSuccess(r)
                }
            } catch {
                await MainActor.run {
                    Haptics.error()
                    errorText = error.localizedDescription
                    placing = false
                }
            }
        }
    }
}

// MARK: - Строка товара (read-only, без степпера — как в макете checkout)

private struct CheckoutRow: View {
    let line: CartLine
    private var lineTotal: Decimal { Money.parse(line.unitPrice) * Decimal(line.qty) }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            PhotoPlaceholder(url: API.imageURL(line.photo), label: "ФОТО", radius: 14, tone: line.productId)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(YMColor.text).lineLimit(1)
                let sub = subtitle
                if !sub.isEmpty {
                    Text(sub).font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(1)
                }
            }
            Spacer(minLength: YMSpace.sm)
            Text(quantityLabel).font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.muted)
            Text(Money.format(lineTotal)).font(.system(size: 14.5, weight: .heavy)).foregroundStyle(YMColor.text).fixedSize()
        }
    }

    private var subtitle: String {
        if !line.modsLabel.isEmpty { return line.modsLabel }
        if let u = line.unit, !u.isEmpty { return u }
        return ""
    }
    private var quantityLabel: String {
        line.isFractional ? fmtQty(line.qty, line.unit) : "× \(Int(line.qty.rounded()))"
    }
}
