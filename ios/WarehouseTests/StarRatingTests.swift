import Testing
@testable import Warehouse

@Suite("StarRating")
struct StarRatingTests {
    @Test("positions across the control map to half stars")
    func starsAtFraction() {
        #expect(StarRating.stars(atFraction: -0.2) == 0.5)
        #expect(StarRating.stars(atFraction: 0) == 0.5)
        #expect(StarRating.stars(atFraction: 0.05) == 0.5)
        #expect(StarRating.stars(atFraction: 0.15) == 1)
        #expect(StarRating.stars(atFraction: 0.5) == 2.5)
        #expect(StarRating.stars(atFraction: 0.55) == 3)
        #expect(StarRating.stars(atFraction: 0.95) == 5)
        #expect(StarRating.stars(atFraction: 1.2) == 5)
    }

    @Test("star slots show filled, half & empty symbols")
    func symbols() {
        #expect(StarRating.symbol(forStar: 1, stars: 3.5) == "star.fill")
        #expect(StarRating.symbol(forStar: 3, stars: 3.5) == "star.fill")
        #expect(StarRating.symbol(forStar: 4, stars: 3.5) == "star.leadinghalf.filled")
        #expect(StarRating.symbol(forStar: 5, stars: 3.5) == "star")
        #expect(StarRating.symbol(forStar: 1, stars: 0) == "star")
        #expect(StarRating.symbol(forStar: 5, stars: 5) == "star.fill")
    }
}
