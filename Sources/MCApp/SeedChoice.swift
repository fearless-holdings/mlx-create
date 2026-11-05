/// Which seed the next job uses. `fixed` and `increment` read ``AppModel/seedText``.
public enum SeedChoice: Sendable, Equatable, CaseIterable {
    case random, fixed, increment
}
