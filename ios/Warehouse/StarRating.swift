import SwiftUI

/// five stars with half-star steps, mirroring the web app's rating control;
/// tap or drag across to set, from half a star up to five
struct StarRating: View {
    @Binding var stars: Double

    static let starCount = 5
    private static let starSize: CGFloat = 22
    private static let spacing: CGFloat = 4
    private static let width = CGFloat(starCount) * starSize + CGFloat(starCount - 1) * spacing

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(1...Self.starCount, id: \.self) { index in
                Image(systemName: Self.symbol(forStar: index, stars: stars))
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.starSize, height: Self.starSize)
                    .foregroundStyle(.yellow)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { stars = Self.stars(atFraction: $0.location.x / Self.width) })
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(stars.formatted()) stars")
    }

    /// the half-star value for a horizontal position across the control:
    /// each tenth of the width is another half star
    static func stars(atFraction fraction: Double) -> Double {
        let halves = (fraction * Double(starCount) * 2).rounded(.up)
        return min(Double(starCount), max(0.5, halves / 2))
    }

    /// the sf symbol for one of the five star slots at the given value
    static func symbol(forStar index: Int, stars: Double) -> String {
        if stars >= Double(index) { return "star.fill" }
        if stars >= Double(index) - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}
