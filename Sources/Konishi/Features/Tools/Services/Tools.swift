import Foundation

/// Logical grouping for a tool, used to organise the settings UI.
enum ToolGroup: String, CaseIterable, Identifiable, Sendable {
    case memory
    case files
    case web
    case compute
    case system
    case language
    case interactive
    case vault

    var id: String { rawValue }

    var label: String {
        switch self {
        case .memory: "Memory"
        case .files: "Files"
        case .web: "Web"
        case .compute: "Compute"
        case .system: "System"
        case .language: "Language deck"
        case .interactive: "Interactive"
        case .vault: "Research vault"
        }
    }
}

/// A single tool the assistant can call. `Tools.all` is the single source of truth for
/// which tools exist, how they're grouped, and their default enable / auto-approve state.
struct ToolSpec: Identifiable, Sendable {
    let name: String
    /// Short human label shown in the settings UI.
    let summary: String
    /// Description advertised to the model.
    let description: String
    let parameters: JSONValue
    let group: ToolGroup
    /// Writes to disk or executes commands — flagged in the UI, off auto-approve by default.
    let mutating: Bool
    let defaultEnabled: Bool
    let defaultAutoApprove: Bool

    var id: String { name }
}

/// The tool catalog plus helpers for filtering by enabled set.
enum Tools {
    static let baseSpecs: [ToolSpec] = [
        // MARK: Memory
        ToolSpec(
            name: "memory_list",
            summary: "List saved memory notes",
            description: "List memory note filenames (global + persona scope).",
            parameters: .schema(properties: [:], required: []),
            group: .memory, mutating: false,
            defaultEnabled: true, defaultAutoApprove: true
        ),
        ToolSpec(
            name: "memory_read",
            summary: "Read a memory note",
            description: "Read a memory note.",
            parameters: .schema(
                properties: [
                    "scope": .property("string", "'global' or the persona scope name"),
                    "name": .property("string", "file name, e.g. notes.md")
                ],
                required: ["name"]
            ),
            group: .memory, mutating: false,
            defaultEnabled: true, defaultAutoApprove: true
        ),
        ToolSpec(
            name: "memory_write",
            summary: "Create or overwrite a memory note",
            description: "Create or overwrite a memory note (Markdown).",
            parameters: .schema(
                properties: [
                    "scope": .property("string", "'global' or the persona scope name"),
                    "name": .property("string", "file name, e.g. notes.md"),
                    "content": .property("string", "the full Markdown content")
                ],
                required: ["name", "content"]
            ),
            group: .memory, mutating: true,
            defaultEnabled: true, defaultAutoApprove: false
        ),
        ToolSpec(
            name: "memory_append",
            summary: "Append to a memory note",
            description: "Append Markdown to a memory note (creates if missing).",
            parameters: .schema(
                properties: [
                    "scope": .property("string", "'global' or the persona scope name"),
                    "name": .property("string", "file name, e.g. notes.md"),
                    "content": .property("string", "the Markdown to append")
                ],
                required: ["name", "content"]
            ),
            group: .memory, mutating: true,
            defaultEnabled: true, defaultAutoApprove: false
        ),

        // MARK: Files
        ToolSpec(
            name: "file_read",
            summary: "Read a text file from disk",
            description: "Read a text file. Pass offset/limit to read a line range of a large file.",
            parameters: .schema(
                properties: [
                    "path": .property("string", "absolute or ~-relative path"),
                    "offset": .property("integer", "1-based start line"),
                    "limit": .property("integer", "max lines (default 400)")
                ],
                required: ["path"]
            ),
            group: .files, mutating: false,
            defaultEnabled: false, defaultAutoApprove: false
        ),

        // MARK: Web
        ToolSpec(
            name: "web_search",
            summary: "Search the web",
            description: "Search the web; returns top results.",
            parameters: .schema(
                properties: ["query": .property("string", "the search query")],
                required: ["query"]
            ),
            group: .web, mutating: false,
            defaultEnabled: false, defaultAutoApprove: true
        ),
        ToolSpec(
            name: "web_fetch",
            summary: "Fetch a URL's readable text",
            description: "Fetch an http(s) URL as readable text.",
            parameters: .schema(
                properties: ["url": .property("string", "the URL to fetch")],
                required: ["url"]
            ),
            group: .web, mutating: false,
            defaultEnabled: false, defaultAutoApprove: true
        ),
        ToolSpec(
            name: "web_research",
            summary: "Search and read multiple web sources",
            description: "Search the web, fetch distinct top sources concurrently, and return cleaned readable text with URLs.",
            parameters: .schema(
                properties: [
                    "query": .property("string", "the research query"),
                    "max_sources": .property("integer", "distinct sources to fetch (default 3, maximum 6)")
                ],
                required: ["query"]
            ),
            group: .web, mutating: false,
            defaultEnabled: false, defaultAutoApprove: true
        ),

        // MARK: Compute
        ToolSpec(
            name: "calculate",
            summary: "Evaluate a mathematical expression",
            description: "Evaluate arithmetic deterministically. Supports +, -, *, /, %, ^, parentheses, pi/e/tau, and common math functions.",
            parameters: .schema(
                properties: ["expression": .property("string", "the expression to evaluate")],
                required: ["expression"]
            ),
            group: .compute, mutating: false,
            defaultEnabled: true, defaultAutoApprove: true
        ),
        ToolSpec(
            name: "python_exec",
            summary: "Run Python in the science venv",
            description: """
            Execute Python 3 code in Konishi's managed virtual environment and return combined \
            stdout/stderr. A scientific toolkit is pre-imported — call these directly and print() \
            the result (each returns a JSON string): \(SciTools.catalog). numpy (as np), scipy, sympy, \
            pandas, matplotlib, and arxiv are available. You MUST print() anything you want to see. \
            Plots saved by plot_function/plot_data are shown to you as images automatically on your next turn.
            """,
            parameters: .schema(
                properties: ["code": .property("string", "Python source to execute; print() results")],
                required: ["code"]
            ),
            group: .compute, mutating: true,
            defaultEnabled: false, defaultAutoApprove: false
        ),

        // MARK: System
        ToolSpec(
            name: "run_shell",
            summary: "Run an arbitrary shell command",
            description: "Run a command on the user's system with /bin/zsh -lc and return its exit status and combined output.",
            parameters: .schema(
                properties: [
                    "command": .property("string", "the complete shell command to run"),
                    "working_directory": .property("string", "optional absolute or ~-relative working directory"),
                    "timeout_seconds": .property("integer", "timeout in seconds (default 120, maximum 600)")
                ],
                required: ["command"]
            ),
            group: .system, mutating: true,
            defaultEnabled: false, defaultAutoApprove: false
        )
    ]

    // MARK: Language deck (used in Learn mode; registered so they appear in per-mode settings)

    static let languageSpecs: [ToolSpec] = [
        ToolSpec(
            name: "add_vocab",
            summary: "Add a vocabulary card",
            description: "Add a vocabulary card to the deck.",
            parameters: .schema(
                properties: [
                    "term": .property("string", "word in the target language"),
                    "translation": .property("string", "meaning"),
                    "reading": .property("string", "pronunciation/romanization, if useful"),
                    "part_of_speech": .property("string", "e.g. noun, verb"),
                    "example": .property("string", "a short example sentence"),
                    "register": .property("string", "formal, casual, honorific, slang — if notable"),
                    "notes": .property("string", "brief usage caveat"),
                    "tags": .arrayProperty("topic tags")
                ],
                required: ["term", "translation"]
            ),
            group: .language, mutating: true,
            defaultEnabled: false, defaultAutoApprove: false
        ),
        ToolSpec(
            name: "add_grammar",
            summary: "Add a grammar card",
            description: "Add a grammar point to the deck.",
            parameters: .schema(
                properties: [
                    "point": .property("string", "the grammar point"),
                    "explanation": .property("string", "concise explanation"),
                    "example": .property("string", "a short example sentence"),
                    "notes": .property("string", "brief caveat"),
                    "tags": .arrayProperty("topic tags")
                ],
                required: ["point", "explanation"]
            ),
            group: .language, mutating: true,
            defaultEnabled: false, defaultAutoApprove: false
        ),
        ToolSpec(
            name: "search_deck",
            summary: "Search the deck",
            description: "Search the deck for existing cards before adding a duplicate.",
            parameters: .schema(
                properties: ["query": .property("string", "term or meaning to look up")],
                required: ["query"]
            ),
            group: .language, mutating: false,
            defaultEnabled: false, defaultAutoApprove: false
        ),
        ToolSpec(
            name: "get_due_items",
            summary: "Get cards due for review",
            description: "List cards due for review, with their ids.",
            parameters: .schema(
                properties: ["limit": .property("integer", "max cards (default 10)")],
                required: []
            ),
            group: .language, mutating: false,
            defaultEnabled: false, defaultAutoApprove: false
        ),
        ToolSpec(
            name: "record_review",
            summary: "Record a review result",
            description: "Record whether the user got a card right; updates its schedule.",
            parameters: .schema(
                properties: [
                    "id": .property("string", "the card id"),
                    "correct": .property("boolean", "true if the user was right")
                ],
                required: ["id", "correct"]
            ),
            group: .language, mutating: true,
            defaultEnabled: false, defaultAutoApprove: false
        )
    ]

    // MARK: Interactive (general-purpose; usable in any mode)

    static let interactiveSpecs: [ToolSpec] = [
        ToolSpec(
            name: "ask_multiple_choice",
            summary: "Ask multiple-choice questions",
            description: "Ask the user one or more multiple-choice questions; returns their answers. Questions with an item_id are graded and recorded automatically — never also call record_review for those.",
            parameters: .schema(
                properties: [
                    "questions": .object([
                        "type": .string("array"),
                        "description": .string("one or more questions"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "prompt": .property("string", "the question"),
                                "options": .arrayProperty("answer choices"),
                                "correct_index": .property("integer", "0-based index of the correct option, if known"),
                                "item_id": .property("string", "deck card id this tests, if any")
                            ]),
                            "required": .array([.string("prompt"), .string("options")])
                        ])
                    ])
                ],
                required: ["questions"]
            ),
            group: .interactive, mutating: false,
            defaultEnabled: false, defaultAutoApprove: true
        )
    ]

    static let all: [ToolSpec] = baseSpecs + languageSpecs + interactiveSpecs + vaultSpecs

    // MARK: Research vault (Obsidian) — gated per-persona by Persona.vaultAccessEnabled.

    static let vaultSpecs: [ToolSpec] = [
        ToolSpec(
            name: "vault_search",
            summary: "Search the research vault",
            description: "Semantically search the Obsidian research vault; returns the most relevant note passages with their paths.",
            parameters: .schema(
                properties: [
                    "query": .property("string", "what to look for"),
                    "max_results": .property("integer", "passages to return (default 6, maximum 20)")
                ],
                required: ["query"]
            ),
            group: .vault, mutating: false,
            defaultEnabled: true, defaultAutoApprove: true
        ),
        ToolSpec(
            name: "vault_read",
            summary: "Read a vault note",
            description: "Read a note from the research vault by its vault-relative path or title.",
            parameters: .schema(
                properties: [
                    "note": .property("string", "note path or title, e.g. Literature/Smith2020.md")
                ],
                required: ["note"]
            ),
            group: .vault, mutating: false,
            defaultEnabled: true, defaultAutoApprove: true
        ),
        ToolSpec(
            name: "vault_list",
            summary: "List vault notes",
            description: "List note paths in the research vault, optionally under a folder.",
            parameters: .schema(
                properties: [
                    "folder": .property("string", "optional folder to list under, e.g. Literature/")
                ],
                required: []
            ),
            group: .vault, mutating: false,
            defaultEnabled: true, defaultAutoApprove: true
        ),
        ToolSpec(
            name: "vault_write",
            summary: "Create or overwrite a vault note",
            description: "Create or overwrite a note in the research vault (Markdown). Use a vault-relative path; include YAML frontmatter and [[wikilinks]] where appropriate.",
            parameters: .schema(
                properties: [
                    "note": .property("string", "note path, e.g. Literature/Smith2020.md"),
                    "content": .property("string", "the full Markdown content")
                ],
                required: ["note", "content"]
            ),
            group: .vault, mutating: true,
            defaultEnabled: true, defaultAutoApprove: false
        ),
        ToolSpec(
            name: "vault_append",
            summary: "Append to a vault note",
            description: "Append Markdown to a note in the research vault (creates it if missing).",
            parameters: .schema(
                properties: [
                    "note": .property("string", "note path or title"),
                    "content": .property("string", "the Markdown to append")
                ],
                required: ["note", "content"]
            ),
            group: .vault, mutating: true,
            defaultEnabled: true, defaultAutoApprove: false
        )
    ]

    /// Research-vault tool names, filtered out of a turn unless the persona has vault access.
    static let vaultToolNames: Set<String> = Set(vaultSpecs.map(\.name))

    /// Voice-only control tool. Not part of `all` / the settings registry — it's injected directly
    /// into conversational requests so the model can hang up when the user says goodbye, and it's
    /// unavailable in text chat.
    static let endConversationDef = ToolDef.function(
        name: "end_conversation",
        description: "End the voice conversation and stop listening. Call this only when the user clearly wants to stop talking (says goodbye, 'that's all', 'we're done', etc.).",
        parameters: .schema(properties: [:], required: [])
    )

    static let defaultEnabled: Set<String> = Set((baseSpecs + vaultSpecs).filter(\.defaultEnabled).map(\.name))
    static let defaultAutoApprove: Set<String> = Set(all.filter(\.defaultAutoApprove).map(\.name))

    /// Every deck tool plus the interactive picker — the sensible default toolset for Learn mode.
    static let languageToolNames: Set<String> =
        Set(languageSpecs.map(\.name)).union(interactiveSpecs.map(\.name))

    /// Default enabled tools for a given mode (used until the user customises per-mode settings).
    static func modeEnabledDefaults(_ mode: AppMode) -> Set<String> {
        switch mode {
        case .language: return languageToolNames
        default: return defaultEnabled
        }
    }

    static func modeAutoApproveDefaults(_ mode: AppMode) -> Set<String> {
        switch mode {
        case .language: return languageToolNames
        default: return defaultAutoApprove
        }
    }

    static func spec(_ name: String) -> ToolSpec? { all.first { $0.name == name } }

    /// Specs available for the given enabled set.
    static func active(enabled: Set<String>) -> [ToolSpec] {
        all.filter { enabled.contains($0.name) }
    }

    static func definitions(enabled: Set<String>) -> [ToolDef] {
        active(enabled: enabled).map {
            .function(name: $0.name, description: $0.description, parameters: $0.parameters)
        }
    }

    static func names(enabled: Set<String>) -> [String] {
        active(enabled: enabled).map(\.name)
    }
}
