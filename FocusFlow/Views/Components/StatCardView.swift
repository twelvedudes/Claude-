import SwiftUI

struct StatCardView: View {
    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let color: Color

    @EnvironmentObject var themeManager: ThemeManager

    init(title: String, value: String, subtitle: String? = nil, icon: String, color: Color = .accentColor) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(themeManager.textColor)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(themeManager.secondaryTextColor)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(color)
                }
            }
        }
        .padding(16)
        .background(themeManager.cardColor.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }
}

struct MiniBarChart: View {
    let data: [Int]
    let maxValue: Int
    let barColor: Color

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(data.indices, id: \.self) { index in
                let height = maxValue > 0
                    ? CGFloat(data[index]) / CGFloat(maxValue)
                    : 0.0

                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        index == data.count - 1
                            ? barColor
                            : barColor.opacity(0.4)
                    )
                    .frame(height: max(2, height * 40))
            }
        }
        .frame(height: 44)
    }
}

struct StreakBadge: View {
    let streak: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))

            Text("\(streak)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)

            Text("day streak")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
        .clipShape(Capsule())
    }
}
