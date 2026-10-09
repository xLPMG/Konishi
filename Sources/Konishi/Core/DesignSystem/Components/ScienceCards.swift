import SwiftUI

struct ChemicalElement: Equatable, Identifiable {
    let atomicNumber: Int
    let symbol: String
    let name: String
    let group: Int
    let period: Int
    let shells: [Int]

    var id: Int { atomicNumber }

    static let all: [ChemicalElement] = records.split(separator: "\n").compactMap { row in
        let fields = row.split(separator: "|")
        guard fields.count == 6,
              let atomicNumber = Int(fields[0]),
              let group = Int(fields[3]),
              let period = Int(fields[4])
        else { return nil }
        let shells = fields[5].split(separator: ".").compactMap { Int($0) }
        guard !shells.isEmpty else { return nil }
        return ChemicalElement(
            atomicNumber: atomicNumber,
            symbol: String(fields[1]),
            name: String(fields[2]),
            group: group,
            period: period,
            shells: shells
        )
    }

    static func lookup(_ identifier: String) -> ChemicalElement? {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let number = Int(key) { return all.first { $0.atomicNumber == number } }
        return all.first { $0.symbol.lowercased() == key || $0.name.lowercased() == key }
    }

    private static let records = """
    1|H|Hydrogen|1|1|1
    2|He|Helium|18|1|2
    3|Li|Lithium|1|2|2.1
    4|Be|Beryllium|2|2|2.2
    5|B|Boron|13|2|2.3
    6|C|Carbon|14|2|2.4
    7|N|Nitrogen|15|2|2.5
    8|O|Oxygen|16|2|2.6
    9|F|Fluorine|17|2|2.7
    10|Ne|Neon|18|2|2.8
    11|Na|Sodium|1|3|2.8.1
    12|Mg|Magnesium|2|3|2.8.2
    13|Al|Aluminium|13|3|2.8.3
    14|Si|Silicon|14|3|2.8.4
    15|P|Phosphorus|15|3|2.8.5
    16|S|Sulfur|16|3|2.8.6
    17|Cl|Chlorine|17|3|2.8.7
    18|Ar|Argon|18|3|2.8.8
    19|K|Potassium|1|4|2.8.8.1
    20|Ca|Calcium|2|4|2.8.8.2
    21|Sc|Scandium|3|4|2.8.9.2
    22|Ti|Titanium|4|4|2.8.10.2
    23|V|Vanadium|5|4|2.8.11.2
    24|Cr|Chromium|6|4|2.8.13.1
    25|Mn|Manganese|7|4|2.8.13.2
    26|Fe|Iron|8|4|2.8.14.2
    27|Co|Cobalt|9|4|2.8.15.2
    28|Ni|Nickel|10|4|2.8.16.2
    29|Cu|Copper|11|4|2.8.18.1
    30|Zn|Zinc|12|4|2.8.18.2
    31|Ga|Gallium|13|4|2.8.18.3
    32|Ge|Germanium|14|4|2.8.18.4
    33|As|Arsenic|15|4|2.8.18.5
    34|Se|Selenium|16|4|2.8.18.6
    35|Br|Bromine|17|4|2.8.18.7
    36|Kr|Krypton|18|4|2.8.18.8
    37|Rb|Rubidium|1|5|2.8.18.8.1
    38|Sr|Strontium|2|5|2.8.18.8.2
    39|Y|Yttrium|3|5|2.8.18.9.2
    40|Zr|Zirconium|4|5|2.8.18.10.2
    41|Nb|Niobium|5|5|2.8.18.12.1
    42|Mo|Molybdenum|6|5|2.8.18.13.1
    43|Tc|Technetium|7|5|2.8.18.13.2
    44|Ru|Ruthenium|8|5|2.8.18.15.1
    45|Rh|Rhodium|9|5|2.8.18.16.1
    46|Pd|Palladium|10|5|2.8.18.18
    47|Ag|Silver|11|5|2.8.18.18.1
    48|Cd|Cadmium|12|5|2.8.18.18.2
    49|In|Indium|13|5|2.8.18.18.3
    50|Sn|Tin|14|5|2.8.18.18.4
    51|Sb|Antimony|15|5|2.8.18.18.5
    52|Te|Tellurium|16|5|2.8.18.18.6
    53|I|Iodine|17|5|2.8.18.18.7
    54|Xe|Xenon|18|5|2.8.18.18.8
    55|Cs|Cesium|1|6|2.8.18.18.8.1
    56|Ba|Barium|2|6|2.8.18.18.8.2
    57|La|Lanthanum|3|6|2.8.18.18.9.2
    58|Ce|Cerium|3|6|2.8.18.19.9.2
    59|Pr|Praseodymium|3|6|2.8.18.21.8.2
    60|Nd|Neodymium|3|6|2.8.18.22.8.2
    61|Pm|Promethium|3|6|2.8.18.23.8.2
    62|Sm|Samarium|3|6|2.8.18.24.8.2
    63|Eu|Europium|3|6|2.8.18.25.8.2
    64|Gd|Gadolinium|3|6|2.8.18.25.9.2
    65|Tb|Terbium|3|6|2.8.18.27.8.2
    66|Dy|Dysprosium|3|6|2.8.18.28.8.2
    67|Ho|Holmium|3|6|2.8.18.29.8.2
    68|Er|Erbium|3|6|2.8.18.30.8.2
    69|Tm|Thulium|3|6|2.8.18.31.8.2
    70|Yb|Ytterbium|3|6|2.8.18.32.8.2
    71|Lu|Lutetium|3|6|2.8.18.32.9.2
    72|Hf|Hafnium|4|6|2.8.18.32.10.2
    73|Ta|Tantalum|5|6|2.8.18.32.11.2
    74|W|Tungsten|6|6|2.8.18.32.12.2
    75|Re|Rhenium|7|6|2.8.18.32.13.2
    76|Os|Osmium|8|6|2.8.18.32.14.2
    77|Ir|Iridium|9|6|2.8.18.32.15.2
    78|Pt|Platinum|10|6|2.8.18.32.17.1
    79|Au|Gold|11|6|2.8.18.32.18.1
    80|Hg|Mercury|12|6|2.8.18.32.18.2
    81|Tl|Thallium|13|6|2.8.18.32.18.3
    82|Pb|Lead|14|6|2.8.18.32.18.4
    83|Bi|Bismuth|15|6|2.8.18.32.18.5
    84|Po|Polonium|16|6|2.8.18.32.18.6
    85|At|Astatine|17|6|2.8.18.32.18.7
    86|Rn|Radon|18|6|2.8.18.32.18.8
    87|Fr|Francium|1|7|2.8.18.32.18.8.1
    88|Ra|Radium|2|7|2.8.18.32.18.8.2
    89|Ac|Actinium|3|7|2.8.18.32.18.9.2
    90|Th|Thorium|3|7|2.8.18.32.18.10.2
    91|Pa|Protactinium|3|7|2.8.18.32.20.9.2
    92|U|Uranium|3|7|2.8.18.32.21.9.2
    93|Np|Neptunium|3|7|2.8.18.32.22.9.2
    94|Pu|Plutonium|3|7|2.8.18.32.24.8.2
    95|Am|Americium|3|7|2.8.18.32.25.8.2
    96|Cm|Curium|3|7|2.8.18.32.25.9.2
    97|Bk|Berkelium|3|7|2.8.18.32.27.8.2
    98|Cf|Californium|3|7|2.8.18.32.28.8.2
    99|Es|Einsteinium|3|7|2.8.18.32.29.8.2
    100|Fm|Fermium|3|7|2.8.18.32.30.8.2
    101|Md|Mendelevium|3|7|2.8.18.32.31.8.2
    102|No|Nobelium|3|7|2.8.18.32.32.8.2
    103|Lr|Lawrencium|3|7|2.8.18.32.32.8.3
    104|Rf|Rutherfordium|4|7|2.8.18.32.32.10.2
    105|Db|Dubnium|5|7|2.8.18.32.32.11.2
    106|Sg|Seaborgium|6|7|2.8.18.32.32.12.2
    107|Bh|Bohrium|7|7|2.8.18.32.32.13.2
    108|Hs|Hassium|8|7|2.8.18.32.32.14.2
    109|Mt|Meitnerium|9|7|2.8.18.32.32.15.2
    110|Ds|Darmstadtium|10|7|2.8.18.32.32.16.2
    111|Rg|Roentgenium|11|7|2.8.18.32.32.17.2
    112|Cn|Copernicium|12|7|2.8.18.32.32.18.2
    113|Nh|Nihonium|13|7|2.8.18.32.32.18.3
    114|Fl|Flerovium|14|7|2.8.18.32.32.18.4
    115|Mc|Moscovium|15|7|2.8.18.32.32.18.5
    116|Lv|Livermorium|16|7|2.8.18.32.32.18.6
    117|Ts|Tennessine|17|7|2.8.18.32.32.18.7
    118|Og|Oganesson|18|7|2.8.18.32.32.18.8
    """
}

struct PhysicsParticle: Equatable, Identifiable {
    let name: String
    let symbol: String
    let family: String
    let charge: String
    let restMass: String
    let spin: String

    var id: String { name }

    static func lookup(_ identifier: String) -> PhysicsParticle? {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.name.lowercased() == key || $0.symbol.lowercased() == key }
    }

    private static let all: [PhysicsParticle] = [
        .init(name: "Electron", symbol: "e⁻", family: "Lepton", charge: "−1 e", restMass: "0.511 MeV/c²", spin: "1/2 ħ"),
        .init(name: "Positron", symbol: "e⁺", family: "Antilepton", charge: "+1 e", restMass: "0.511 MeV/c²", spin: "1/2 ħ"),
        .init(name: "Proton", symbol: "p⁺", family: "Baryon", charge: "+1 e", restMass: "938.272 MeV/c²", spin: "1/2 ħ"),
        .init(name: "Neutron", symbol: "n⁰", family: "Baryon", charge: "0", restMass: "939.565 MeV/c²", spin: "1/2 ħ"),
        .init(name: "Photon", symbol: "γ", family: "Gauge boson", charge: "0", restMass: "0", spin: "1 ħ"),
        .init(name: "Muon", symbol: "μ⁻", family: "Lepton", charge: "−1 e", restMass: "105.658 MeV/c²", spin: "1/2 ħ"),
    ]
}

enum ScienceCard: Equatable {
    case element(ChemicalElement)
    case particle(PhysicsParticle)

    static func parseDirective(_ line: String) -> ScienceCard? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        let identifier = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        switch parts[0] {
        case ":::element":
            guard let element = ChemicalElement.lookup(identifier) else { return nil }
            return .element(element)
        case ":::particle":
            guard let particle = PhysicsParticle.lookup(identifier) else { return nil }
            return .particle(particle)
        default:
            return nil
        }
    }
}

struct ScienceCardView: View {
    let card: ScienceCard
    let baseSize: Double

    var body: some View {
        Group {
            switch card {
            case let .element(element):
                ElementCardView(element: element, baseSize: baseSize)
            case let .particle(particle):
                ParticleCardView(particle: particle, baseSize: baseSize)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.09), lineWidth: 0.7)
        }
        .padding(.vertical, 2)
    }
}

private struct ElementCardView: View {
    let element: ChemicalElement
    let baseSize: Double

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .accessibilityElement(children: .combine)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 10) {
            periodicTile
            elementDetails.fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            diagramColumn(size: 112)
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                periodicTile
                elementDetails.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer(minLength: 0)
                diagramColumn(size: 128)
                Spacer(minLength: 0)
            }
        }
    }

    private var periodicTile: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(element.atomicNumber)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
            Spacer(minLength: 0)
            Text(element.symbol)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .padding(7)
        .frame(width: 64, height: 72, alignment: .leading)
        .background(groupColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(groupColor).frame(width: 3)
        }
    }

    private var elementDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(element.name)
                .font(.system(size: baseSize + 2, weight: .semibold))
            Text(periodicPosition)
                .font(.system(size: baseSize - 1))
                .foregroundStyle(.secondary)
            Text("Shells  \(element.shells.map(String.init).joined(separator: " · "))")
                .font(.system(size: baseSize - 1, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(element.atomicNumber > 108 ? "Neutral atom · predicted shells" : "Neutral atom · ground-state shells")
                .font(.system(size: baseSize - 2))
                .foregroundStyle(.secondary)
        }
    }

    private func diagramColumn(size: CGFloat) -> some View {
        BohrDiagram(element: element)
            .frame(width: size, height: size)
            .frame(width: size + 12)
    }

    private var groupColor: Color {
        switch element.group {
        case 1: .orange
        case 2: .yellow
        case 3: .pink
        case 4...12: .teal
        default: .cyan
        }
    }

    private var periodicPosition: String {
        switch element.atomicNumber {
        case 57...71: "Lanthanide series · Period \(element.period)"
        case 89...103: "Actinide series · Period \(element.period)"
        default: "Group \(element.group) · Period \(element.period)"
        }
    }
}

private struct BohrDiagram: View {
    let element: ChemicalElement

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerRadius = min(size.width, size.height) * 0.44
            let innerRadius = min(size.width, size.height) * 0.13
            let shellCount = element.shells.count

            for (shellIndex, electronCount) in element.shells.enumerated() {
                let fraction = shellCount == 1 ? 1.0 : Double(shellIndex) / Double(shellCount - 1)
                let radius = innerRadius + (outerRadius - innerRadius) * fraction
                let orbit = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: orbit), with: .color(.secondary.opacity(0.25)), lineWidth: 1)

                for electronIndex in 0..<electronCount {
                    let angle = -Double.pi / 2 + 2 * Double.pi * Double(electronIndex) / Double(electronCount)
                    let point = CGPoint(
                        x: center.x + radius * cos(angle),
                        y: center.y + radius * sin(angle)
                    )
                    let dot = CGRect(x: point.x - 2.4, y: point.y - 2.4, width: 4.8, height: 4.8)
                    context.fill(Path(ellipseIn: dot), with: .color(.blue))
                }
            }

            let nucleusRadius = min(size.width, size.height) * 0.105
            let nucleus = CGRect(
                x: center.x - nucleusRadius,
                y: center.y - nucleusRadius,
                width: nucleusRadius * 2,
                height: nucleusRadius * 2
            )
            context.fill(Path(ellipseIn: nucleus), with: .color(.orange))
            context.draw(
                Text("+\(element.atomicNumber)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.white),
                at: center
            )
        }
        .accessibilityLabel("Schematic Bohr shell diagram for \(element.name), \(element.shells.map(String.init).joined(separator: ", ")) electrons per shell")
    }
}

private struct ParticleCardView: View {
    let particle: PhysicsParticle
    let baseSize: Double

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(particle.symbol)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .frame(width: 64, height: 64)
                .background(Color.blue.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(particle.name)
                    .font(.system(size: baseSize + 2, weight: .semibold))
                Text(particle.family)
                    .font(.system(size: baseSize - 1))
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    fact("Charge", particle.charge)
                    fact("Rest mass", particle.restMass)
                    fact("Spin", particle.spin)
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: baseSize - 4, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: baseSize - 2, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}