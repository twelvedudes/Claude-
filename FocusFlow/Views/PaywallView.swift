import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProduct: Product?
    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""

    private let features: [(icon: String, title: String, description: String)] = [
        ("slider.horizontal.3", "Custom Timers", "Set focus & break durations to match your workflow"),
        ("paintpalette.fill", "Premium Themes", "6 beautiful themes to personalize your experience"),
        ("speaker.wave.3.fill", "Ambient Sounds", "Rain, ocean, forest & more to help you focus"),
        ("chart.bar.xaxis", "Detailed Analytics", "Category breakdowns and deep productivity insights"),
        ("bell.badge.fill", "Smart Reminders", "Personalized nudges to build your focus habit"),
        ("infinity", "Unlimited History", "Track your entire productivity journey"),
    ]

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color(hex: "0a0a1a"), Color(hex: "1a1a3e")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Close button
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                    // Header
                    VStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 48))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.yellow, .orange],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: .yellow.opacity(0.3), radius: 20)

                        Text("FocusFlow Pro")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Unlock your full potential")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 32)

                    // Features
                    VStack(spacing: 16) {
                        ForEach(features.indices, id: \.self) { index in
                            featureRow(
                                icon: features[index].icon,
                                title: features[index].title,
                                description: features[index].description
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)

                    // Pricing
                    VStack(spacing: 12) {
                        if let yearly = storeManager.yearlyProduct {
                            pricingOption(
                                product: yearly,
                                label: "Yearly",
                                sublabel: "Best Value - Save \(storeManager.yearlySavingsPercent)%",
                                isBestValue: true
                            )
                        }

                        if let monthly = storeManager.monthlyProduct {
                            pricingOption(
                                product: monthly,
                                label: "Monthly",
                                sublabel: nil,
                                isBestValue: false
                            )
                        }

                        if let lifetime = storeManager.lifetimeProduct {
                            pricingOption(
                                product: lifetime,
                                label: "Lifetime",
                                sublabel: "Pay once, own forever",
                                isBestValue: false
                            )
                        }

                        // Fallback if products haven't loaded
                        if storeManager.products.isEmpty {
                            VStack(spacing: 12) {
                                pricingPlaceholder(label: "Yearly", price: "$29.99/year", sublabel: "Best Value", isBestValue: true)
                                pricingPlaceholder(label: "Monthly", price: "$3.99/month", sublabel: nil, isBestValue: false)
                                pricingPlaceholder(label: "Lifetime", price: "$79.99", sublabel: "Pay once", isBestValue: false)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)

                    // Purchase button
                    Button {
                        Task { await purchase() }
                    } label: {
                        HStack {
                            if isPurchasing {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Text("Continue")
                                    .fontWeight(.bold)
                            }
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            LinearGradient(
                                colors: [.yellow, .orange],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .orange.opacity(0.4), radius: 16, y: 8)
                    }
                    .disabled(isPurchasing)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                    // Restore & legal
                    VStack(spacing: 8) {
                        Button("Restore Purchases") {
                            Task { await storeManager.restorePurchases() }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))

                        Text("Cancel anytime. Payment charged to Apple ID.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.3))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .alert("Purchase Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            if let yearly = storeManager.yearlyProduct {
                selectedProduct = yearly
            }
        }
    }

    // MARK: - Feature Row

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()
        }
    }

    // MARK: - Pricing

    private func pricingOption(
        product: Product, label: String, sublabel: String?, isBestValue: Bool
    ) -> some View {
        Button {
            selectedProduct = product
            HapticManager.shared.selection()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)

                        if isBestValue {
                            Text("BEST VALUE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.yellow)
                                .clipShape(Capsule())
                        }
                    }

                    if let sublabel {
                        Text(sublabel)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer()

                Text(product.displayPrice)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(selectedProduct == product ? 0.15 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                selectedProduct == product
                                    ? Color.yellow.opacity(0.6)
                                    : Color.white.opacity(0.1),
                                lineWidth: selectedProduct == product ? 2 : 1
                            )
                    )
            )
        }
    }

    private func pricingPlaceholder(
        label: String, price: String, sublabel: String?, isBestValue: Bool
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)

                    if isBestValue {
                        Text("BEST VALUE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow)
                            .clipShape(Capsule())
                    }
                }

                if let sublabel {
                    Text(sublabel)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            Text(price)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(isBestValue ? 0.15 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isBestValue ? Color.yellow.opacity(0.6) : Color.white.opacity(0.1),
                            lineWidth: isBestValue ? 2 : 1
                        )
                )
        )
    }

    // MARK: - Purchase

    private func purchase() async {
        guard let product = selectedProduct ?? storeManager.yearlyProduct else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let success = try await storeManager.purchase(product)
            if success {
                HapticManager.shared.success()
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
