import Foundation

enum InputCoordinates {
    static func normalized(pixel: Int, dimension: Int) throws -> Int {
        guard dimension > 1, pixel >= 0, pixel < dimension else { throw AppError.invalid(String(localized: "Coordinates are outside the current screenshot")) }
        return Int((Double(pixel) / Double(dimension - 1) * 65_535).rounded())
    }
}