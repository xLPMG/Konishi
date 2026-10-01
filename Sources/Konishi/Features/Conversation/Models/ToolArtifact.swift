import Foundation

enum ToolArtifact: Equatable {
    case calculation(expression: String, value: String, isError: Bool)
    case process(exitCode: Int, output: String)
    case sources([Source])

    static func make(
        toolName: String,
        arguments: String,
        result: String,
        sources: [Source]
    ) -> ToolArtifact? {
        switch toolName {
        case "calculate":
            guard let data = arguments.data(using: .utf8),
                  let calculation = try? JSONDecoder().decode(ToolArguments.Calculation.self, from: data) else {
                return nil
            }
            if result.hasPrefix("Error:") {
                return .calculation(expression: calculation.expression, value: result, isError: true)
            }
            let prefix = calculation.expression + " = "
            guard result.hasPrefix(prefix) else { return nil }
            return .calculation(
                expression: calculation.expression,
                value: String(result.dropFirst(prefix.count)),
                isError: false
            )
        case "python_exec", "run_shell":
            let lines = result.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let status = lines.first, status.hasPrefix("exit "),
                  let exitCode = Int(status.dropFirst("exit ".count)) else { return nil }
            let output = lines.count > 1 ? String(lines[1]) : ""
            return .process(exitCode: exitCode, output: output)
        case "web_search", "web_research", "web_fetch":
            return sources.isEmpty ? nil : .sources(sources)
        default:
            return nil
        }
    }
}