import Foundation

/// Logical grouping for a tool, used to organise the settings UI.
enum ToolGroup: String, CaseIterable, Identifiable, Sendable {
    case memory
    case files
    case web
    case compute
    case finance
    case calendar
    case system
    case vault

    var id: String { rawValue }

    var label: String {
        switch self {
        case .memory: "Memory"
        case .files: "Files"
        case .web: "Web"
        case .compute: "Compute"
        case .finance: "Finance"
        case .calendar: "Calendar & Reminders"
        case .system: "System"
        case .vault: "Research vault"
        }
    }
}

/// A single tool the assistant can call. `Tools.all` is the single source of truth for
/// which tools exist, how they're grouped, and their default visibility.
struct ToolSpec: Identifiable, Sendable {
    let name: String
    /// Short human label shown in the settings UI.
    let summary: String
    /// Description advertised to the model.
    let description: String
    let parameters: JSONValue
    let group: ToolGroup
    let defaultEnabled: Bool

    init(
        name: String, summary: String, description: String, parameters: JSONValue,
        group: ToolGroup, defaultEnabled: Bool
    ) {
        self.name = name
        self.summary = summary
        self.description = description
        self.parameters = parameters
        self.group = group
        self.defaultEnabled = defaultEnabled
    }

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
            group: .memory,
            defaultEnabled: true
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
            group: .memory,
            defaultEnabled: true
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
            group: .memory,
            defaultEnabled: true
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
            group: .memory,
            defaultEnabled: true
        ),
        ToolSpec(
            name: "conversation_search",
            summary: "Search past conversations",
            description: "Search summaries of past conversations; returns id, date, title and a snippet for the best matches. Use conversation_read for the full summary.",
            parameters: .schema(
                properties: [
                    "query": .property("string", "what the conversation was about"),
                    "limit": .property("integer", "matches to return (default 5, maximum 15)")
                ],
                required: ["query"]
            ),
            group: .memory,
            defaultEnabled: true
        ),
        ToolSpec(
            name: "conversation_list",
            summary: "List recent conversations",
            description: "List the most recent past conversations (id, date, title, snippet), newest first.",
            parameters: .schema(
                properties: [
                    "days": .property("integer", "only conversations from the last N days"),
                    "limit": .property("integer", "conversations to return (default 10, maximum 30)")
                ],
                required: []
            ),
            group: .memory,
            defaultEnabled: true
        ),
        ToolSpec(
            name: "conversation_read",
            summary: "Read a conversation summary",
            description: "Read the summary of a past conversation by its id (as returned by conversation_search or conversation_list).",
            parameters: .schema(
                properties: ["id": .property("string", "conversation id")],
                required: ["id"]
            ),
            group: .memory,
            defaultEnabled: true
        ),

        // MARK: Files
        ToolSpec(
            name: "file_read",
            summary: "Read a text file from disk",
            description: "Read a text file. Relative paths use the current conversation workspace; absolute or ~ paths read that exact location. Pass offset/limit for a large file.",
            parameters: .schema(
                properties: [
                    "path": .property("string", "workspace-relative, absolute, or ~-relative path"),
                    "offset": .property("integer", "1-based start line"),
                    "limit": .property("integer", "max lines (default 400)")
                ],
                required: ["path"]
            ),
            group: .files,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "file_write",
            summary: "Save a text file",
            description: "Create or overwrite a UTF-8 text file. Relative paths use the current conversation workspace; absolute or ~ paths write to that location and require permission. Parent folders are created. Use python_exec for computed or binary output; do not use shell commands for ordinary text files.",
            parameters: .schema(
                properties: [
                    "path": .property("string", "workspace-relative, absolute, or ~-relative filename"),
                    "content": .property("string", "complete file contents")
                ],
                required: ["path", "content"]
            ),
            group: .files,
            defaultEnabled: true
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
            group: .web,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "web_image_search",
            summary: "Search web images",
            description: "Search DuckDuckGo Images and attach up to 4 images in the conversation. Images display in chat; they are sent to the model only when Settings > Generation > Send images to the model is enabled and the endpoint supports vision.",
            parameters: .schema(
                properties: [
                    "query": .property("string", "what images to find"),
                    "max_results": .property("integer", "number of images, 1 to 4 (default 4)"),
                ],
                required: ["query"]
            ),
            group: .web,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "web_fetch",
            summary: "Fetch a URL's readable text",
            description: "Fetch an http(s) URL as readable text.",
            parameters: .schema(
                properties: ["url": .property("string", "the URL to fetch")],
                required: ["url"]
            ),
            group: .web,
            defaultEnabled: false
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
            group: .web,
            defaultEnabled: false
        ),

        // MARK: Finance
        ToolSpec(
            name: "finance_lookup",
            summary: "Find a security listing",
            description: "Search Yahoo Finance for a ticker, ISIN, or WKN. Use the returned matches to resolve ambiguous listings before quoting.",
            parameters: .schema(
                properties: [
                    "identifier": .property("string", "ticker, ISIN, or WKN"),
                    "identifier_type": .property("string", "optional identifier type: ticker, isin, wkn, or auto")
                ],
                required: ["identifier"]
            ),
            group: .finance,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "finance_quote",
            summary: "Get a security quote",
            description: "Resolve a ticker, ISIN, or WKN and return its latest available quote, currency, exchange, previous close, source, and timestamp. Quotes may be delayed. If multiple listings match, ask the user to confirm the exchange. Market data is informational, not a trading signal.",
            parameters: .schema(
                properties: [
                    "identifier": .property("string", "ticker, ISIN, or WKN"),
                    "identifier_type": .property("string", "optional identifier type: ticker, isin, wkn, or auto"),
                    "exchange": .property("string", "optional exchange name or code to disambiguate listings")
                ],
                required: ["identifier"]
            ),
            group: .finance,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "finance_history",
            summary: "Get daily price history",
            description: "Return daily closing prices for a ticker, ISIN, or WKN over the requested number of days (default 365, maximum 3650). Values include source, currency, and dates; data may be delayed.",
            parameters: .schema(
                properties: [
                    "identifier": .property("string", "ticker, ISIN, or WKN"),
                    "days": .property("integer", "calendar days of history (default 365, maximum 3650)")
                ],
                required: ["identifier"]
            ),
            group: .finance,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "finance_series",
            summary: "Get a macroeconomic series",
            description: "Read observations from a FRED series ID, such as FEDFUNDS, DGS10, CPIAUCSL, UNRATE, or DEXUSEU. Returns dated values and a source link; observations are not forecasts.",
            parameters: .schema(
                properties: [
                    "series_id": .property("string", "FRED series ID"),
                    "days": .property("integer", "calendar days of observations (default 365, maximum 3650)")
                ],
                required: ["series_id"]
            ),
            group: .finance,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "finance_portfolio",
            summary: "Analyze portfolio allocation",
            description: "Calculate allocation weights and concentration from user-supplied market values in one currency. Runs locally; does not fetch prices, save holdings, or send holdings to a provider. This is not a risk forecast.",
            parameters: .schema(
                properties: [
                    "currency": .property("string", "three-letter currency code; all values must use this currency"),
                    "holdings": .object([
                        "type": .string("array"),
                        "description": .string("positions with name, market_value, and optional asset_class"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "name": .property("string", "holding or asset-class name"),
                                "market_value": .property("number", "current value in the supplied currency"),
                                "asset_class": .property("string", "optional category for the holding")
                            ]),
                            "required": .array([.string("name"), .string("market_value")])
                        ])
                    ])
                ],
                required: ["currency", "holdings"]
            ),
            group: .finance,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "finance_scenario",
            summary: "Model an investment scenario",
            description: "Calculate an illustrative monthly-contribution projection from user-supplied return, fee, and inflation assumptions. Deterministic arithmetic only; not a forecast or investment recommendation.",
            parameters: .schema(
                properties: [
                    "currency": .property("string", "three-letter currency code"),
                    "initial_amount": .property("number", "starting amount"),
                    "monthly_contribution": .property("number", "contribution at each month-end"),
                    "years": .property("integer", "horizon from 1 to 80 years"),
                    "annual_return_percent": .property("number", "assumed annual return in percent, e.g. 6 for 6%"),
                    "annual_fee_percent": .property("number", "annual fee in percent"),
                    "inflation_percent": .property("number", "assumed annual inflation in percent")
                ],
                required: ["currency", "initial_amount", "monthly_contribution", "years", "annual_return_percent", "annual_fee_percent", "inflation_percent"]
            ),
            group: .finance,
            defaultEnabled: false
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
            group: .compute,
            defaultEnabled: true
        ),
        ToolSpec(
            name: "python_exec",
            summary: "Run Python in the science venv",
            description: """
            Run Python 3 code in Konishi's managed virtual environment; return combined stdout/stderr. \\
            The scientific toolkit is pre-imported: \(SciTools.catalog). numpy (as np), scipy, sympy, \\
            pandas, matplotlib, and arxiv are available. Print values you want returned. \\
            The current conversation workspace is the working directory; use relative paths to save files there. \\
            Use file_write for ordinary text files. This tool accepts Python source, not shell commands. \\
            Plots created with the toolkit or saved in the conversation folder are attached as images on your next turn.
            """,
            parameters: .schema(
                properties: ["code": .property("string", "Python source code to execute")],
                required: ["code"]
            ),
            group: .compute,
            defaultEnabled: false
        ),

        // MARK: System
        ToolSpec(
            name: "run_shell",
            summary: "Run an arbitrary shell command",
            description: "Run a command on the user's system with /bin/zsh -lc and return its exit status and combined output. By default, the working directory is this conversation's workspace; relative files created there appear in the Files inspector. For an explicitly requested external location, use an absolute path or working_directory, subject to normal tool enablement and approval. Use file_write for ordinary text files in the workspace.",
            parameters: .schema(
                properties: [
                    "command": .property("string", "the complete shell command to run"),
                    "working_directory": .property("string", "optional absolute or ~-relative working directory"),
                    "timeout_seconds": .property("integer", "timeout in seconds (default 120, maximum 600)")
                ],
                required: ["command"]
            ),
            group: .system,
            defaultEnabled: false
        )
    ]

    // MARK: Apple Calendar & Reminders

    static let calendarSpecs: [ToolSpec] = [
        ToolSpec(
            name: "calendar_events",
            summary: "List upcoming calendar events",
            description: "List events from today through the next N days (default 1, maximum 30), optionally limited to an exact calendar name. Includes current local date/time, event IDs, and local timezone. Use before resolving relative event times.",
            parameters: .schema(
                properties: [
                    "days": .property("integer", "number of days ahead, including today (default 1, maximum 30)"),
                    "calendar": .property("string", "optional exact calendar name")
                ],
                required: []
            ),
            group: .calendar,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "calendar_create_event",
            summary: "Create a calendar event",
            description: "Create an event in the default calendar or a named calendar. Dates must be ISO 8601 with timezone offset, e.g. 2026-10-01T14:00:00-07:00. For relative times, call calendar_events first; ask the user if the time is ambiguous.",
            parameters: .schema(
                properties: [
                    "title": .property("string", "event title"),
                    "start_date": .property("string", "ISO 8601 start date/time including UTC offset"),
                    "end_date": .property("string", "ISO 8601 end date/time including UTC offset"),
                    "location": .property("string", "optional location"),
                    "notes": .property("string", "optional event notes"),
                    "calendar": .property("string", "optional exact calendar name; otherwise the default calendar")
                ],
                required: ["title", "start_date", "end_date"]
            ),
            group: .calendar,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "calendar_update_event",
            summary: "Update a calendar event",
            description: "Update an event by its event ID from calendar_events. Supply only fields to change. Dates must be ISO 8601 with timezone offset. Empty location or notes clears that field.",
            parameters: .schema(
                properties: [
                    "event_id": .property("string", "event ID returned by calendar_events"),
                    "title": .property("string", "replacement title"),
                    "start_date": .property("string", "replacement ISO 8601 start date/time including UTC offset"),
                    "end_date": .property("string", "replacement ISO 8601 end date/time including UTC offset"),
                    "location": .property("string", "replacement location; empty string clears it"),
                    "notes": .property("string", "replacement notes; empty string clears them")
                ],
                required: ["event_id"]
            ),
            group: .calendar,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "reminders_list",
            summary: "List upcoming reminders",
            description: "List incomplete reminders that are overdue or due within N days (default 7, maximum 90). Undated reminders are omitted unless include_undated is true. Can filter by title text.",
            parameters: .schema(
                properties: [
                    "days": .property("integer", "number of days ahead, including today (default 7, maximum 90)"),
                    "include_undated": .property("boolean", "include incomplete reminders with no due date (default false)"),
                    "query": .property("string", "optional case-insensitive title substring"),
                    "limit": .property("integer", "maximum results (default 50, maximum 100)")
                ],
                required: []
            ),
            group: .calendar,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "reminder_create",
            summary: "Create a reminder",
            description: "Create a reminder in the default Reminders list. due_date may be YYYY-MM-DD or ISO 8601 with timezone offset. Priority is 0 (none) through 9 (lowest), where 1 is highest.",
            parameters: .schema(
                properties: [
                    "title": .property("string", "reminder title"),
                    "due_date": .property("string", "optional YYYY-MM-DD or ISO 8601 due date/time"),
                    "notes": .property("string", "optional reminder notes"),
                    "priority": .property("integer", "optional priority from 0 to 9; 1 is highest")
                ],
                required: ["title"]
            ),
            group: .calendar,
            defaultEnabled: false
        ),
        ToolSpec(
            name: "reminder_update",
            summary: "Update a reminder",
            description: "Update a reminder by its ID from reminders_list. Supply only fields to change. Set clear_due_date true to remove a due date.",
            parameters: .schema(
                properties: [
                    "reminder_id": .property("string", "reminder ID returned by reminders_list"),
                    "title": .property("string", "replacement title"),
                    "due_date": .property("string", "replacement YYYY-MM-DD or ISO 8601 due date/time"),
                    "clear_due_date": .property("boolean", "remove the existing due date"),
                    "notes": .property("string", "replacement notes; empty string clears them"),
                    "priority": .property("integer", "replacement priority from 0 to 9; 1 is highest"),
                    "completed": .property("boolean", "mark complete or incomplete")
                ],
                required: ["reminder_id"]
            ),
            group: .calendar,
            defaultEnabled: false
        )
    ]

    static let all: [ToolSpec] = baseSpecs + vaultSpecs + calendarSpecs

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
            group: .vault,
            defaultEnabled: true
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
            group: .vault,
            defaultEnabled: true
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
            group: .vault,
            defaultEnabled: true
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
            group: .vault,
            defaultEnabled: true
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
            group: .vault,
            defaultEnabled: true
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

    static let defaultEnabled: Set<String> = Set((baseSpecs + vaultSpecs + calendarSpecs).filter(\.defaultEnabled).map(\.name))

    /// Default enabled tools for a given mode (used until the user customises per-mode settings).
    static func modeEnabledDefaults(_ mode: AppMode) -> Set<String> {
        mode == .language ? [] : defaultEnabled
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
