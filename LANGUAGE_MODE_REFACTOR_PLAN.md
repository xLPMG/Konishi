# Language Mode Refactor Plan

## Purpose

Redesign Learn as a first-class language-learning workspace inside Konishi, the user's AI Workspace. Learn may reuse shared infrastructure such as model requests, speech recognition, text-to-speech, and visual components, but it must not depend on ordinary chat conversations, `ChatView`, or the LLM tool loop for lesson state, quiz progression, grading, or deck writes.

The core principle is:

> The app owns learning state and correctness. The LLM supplies language, examples, explanations, and conversation.

This plan is the implementation source of truth. Keep its requirements and acceptance criteria current as work is completed.

## Current State And Failure Modes

The failure modes below describe the pre-refactor implementation; they are resolved by the completed architecture and checklist below. Learn now routes through a standalone workspace, deterministic practice is app-owned, deck writes require learner action, and legacy `isLanguage` conversations are deleted at startup.

- The old `LanguageView`/`ChatView` coupling and prompt-driven `LanguageSessionKind` workflow have been removed.
- The old `add_vocab`, `add_grammar`, `record_review`, and `ask_multiple_choice` tool flow has been removed from the registry and dispatcher.
- Deterministic exercise grading, skips, review-attempt idempotency, and transactional schedule updates now belong to the language engine/store.
- The existing SQLite profiles/cards and Leitner data are preserved through additive schema migrations.
- Focused language tests now cover the engine, SQLite migration/persistence, workspace progression, vocabulary proposals, and Anki rendering.

Current implementation is under `Sources/Konishi/Features/Language/` with routing in `Sources/Konishi/App/RootView.swift` and focused coverage in `Tests/KonishiTests/Features/Language/`.

## Product And Architecture Decisions

### Workspace boundary

- Keep Learn as a mode inside Konishi, selectable from the existing mode control.
- Route Learn to a standalone `LanguageWorkspaceView`; it must render without a selected `Conversation` or persona.
- Give Learn its own navigation and state: learning home, practice setup/session, deck, study content, and tutor conversation.
- Delete old `isLanguage` conversations on the first app startup after this refactor, including associated traces, documents, generated files, and search-index rows. Keep the marker only to identify pre-refactor files during cleanup.
- Reuse shared infrastructure behind feature-specific APIs. Do not make the language engine depend on `AppModel` chat state or general tool-call continuation.

### Ownership boundaries

- **LanguageStore:** profile, card, review-attempt, and tutor-thread persistence.
- **LanguageLearningEngine:** deterministic card selection, exercise generation, answer evaluation, and session progression. Keep its core functions pure and independently testable.
- **LanguageWorkspaceModel / coordinator:** owns the active Learn screen, activity state, selected profile, in-progress answer, and calls into the engine/store.
- **LanguageTutorService:** bounded LLM tasks for conversation and language-content assistance. It may return suggestions; it must not write the deck or record reviews.
- **Views:** display the workspace and collect learner intent. Views do not implement scheduling or answer truth.

These names are proposed; follow existing repository naming conventions when implementing.

### LLM authority boundary

The LLM must not be the authority for:

- Which cards are due or which item an exercise reviews.
- The correct choice in a deterministic quiz.
- Whether a deterministic answer was correct.
- Updating Leitner/scheduling state or recording review counts.
- Persisting a vocabulary or grammar item without learner approval.
- Advancing or completing an app-owned quiz session.

The LLM is appropriate for:

- Text and voice conversation in the target language.
- Gentle corrections and explanations in the learner's base language.
- Suggesting topics, vocabulary, common synonyms, grammar explanations, and natural examples.
- Creating candidate content for app validation and learner review.
- Explaining an answer after the engine has supplied the question, expected answer, and deterministic result.
- Giving a semantic assessment for an open-ended answer. Such assessment is feedback only; require learner confirmation/self-rating before it changes scheduling.

Normal practice must work with the model server offline.

## Learn Workspace And Activities

### Workspace entry

The Learn home should show the active language profile, due-card count, recent progress, and clear entry points for Review, Study, Deck, and Tutor. Profile setup and switching remain available. Activity setup can select question direction, count, and topic where relevant.

### Deterministic practice activities

1. **Flashcards:** The app selects a card, shows the prompt side, reveals the answer on request, then collects an explicit `Again` or `Remembered` result. Map those outcomes to a deterministic schedule. Do not count dismissal or skip as wrong.
2. **Multiple choice:** Build questions from deck data. The engine owns the item ID, correct answer, and answer options; the UI returns an option ID/index to the engine. Generate distractors from the same profile and avoid identical/ambiguous translations. If there are too few plausible distractors, reduce the option count or use another exercise form.
3. **Word matching:** Build a group of target terms and meanings from the deck. The engine validates every pair and records results against known item IDs.
4. **Typed recall/translation:** Compare using conservative normalization (Unicode canonical normalization, whitespace, and explicitly defined case/punctuation handling) against the card term and any learner-approved accepted answers. Do not silently accept transliterations or semantic equivalents.
5. **Cloze:** When a saved example contains the card term, deterministically blank that occurrence and compare against the known answer. LLM-authored cloze material is a proposal and must be validated/reviewed before it enters the deck.
6. **Session flow:** The app chooses a bounded queue, advances after each recorded result, reports completion, and handles cancellation/restart. A model response is never required to advance a session.

Start with the existing Leitner behavior. If richer `Again/Hard/Good/Easy` scheduling is desired, define and test that scheduling policy as a separate explicit change rather than letting model prose choose intervals.

### LLM-assisted study and vocabulary capture

- Study requests should ask for a small number of structured proposals calibrated to the profile, level, topic, and known deck.
- A `VocabularyProposal` should include target term, translation, reading, part of speech, register, example, notes, and tags as available.
- Validate required fields, normalize whitespace, check duplicates against the active profile, and show each proposal for edit/save/skip. Only the learner's save action writes to `LanguageStore`.
- During tutor conversation, the model may propose an unfamiliar word or a more common synonym. Show a clear save action; do not add items automatically. Query the deck before presenting a synonym as “not learned.”
- Keep free text and voice conversation available. Reuse `ChatService` streaming and `VoiceManager` where suitable, but store tutor threads as language-owned data rather than requiring ordinary `Conversation` state.
- Do not expose deck-mutating `add_vocab`, `add_grammar`, or `record_review` tools in the new Learn flow. If a proposal tool is retained, it may only create a transient proposal for UI confirmation and must never commit directly.

## Review Persistence And Reliability

- Add a review-attempt model containing an attempt UUID, profile/card ID, activity type, outcome, timestamp, and optional submitted answer/session ID.
- Record an attempt and update the card's counters/schedule atomically in a SQLite transaction.
- Enforce uniqueness on attempt UUID so retrying a UI action or recovering state cannot count the same answer twice.
- Return an explicit result from the store. The UI reports an answer as recorded only after persistence succeeds.
- A skipped, cancelled, or dismissed question creates no incorrect review attempt.
- Keep existing card totals and due dates compatible. Introduce a schema version and explicit additive migrations; do not rely on ignored `ALTER TABLE` failures.

## Anki Vocabulary Export

Add an **Export Vocabulary for Anki…** action to the active profile's Deck view.

### Scope and mapping

- Export all vocabulary (`LearnKind.vocab`) for the active profile. Do not include grammar or phrase cards in the first version.
- Use Anki's plain-text import format, UTF-8, tab-separated, with a `.txt` extension for broad importer compatibility. This is an import file, not an `.apkg` package and not an AnkiConnect integration.
- Use the built-in Basic note type with `Front`, `Back`, and per-note `Tags` columns. Include Anki text-import headers for tab separation, HTML handling, named columns, and the tags column.
- `Front`: target-language term.
- `Back`: reading (if present), translation, part of speech, register, examples, and notes (omit empty sections).
- `Tags`: existing card tags, converted to Anki-compatible whitespace-separated tokens. Preserve the original deck unchanged.
- Use escaped HTML for generated line breaks and escape user content (`&`, `<`, `>`, and quotes as needed); never interpret card text as HTML. Escape tab-delimited records and embedded newlines/quotes correctly.
- Anki uses the first field for default duplicate matching. Keep the first field as the canonical target term; explain this behavior in any export preview/help so users can inspect duplicate handling during import.
- Default filename: `Konishi-<language>-vocabulary.txt`, replacing path-invalid characters in the language name.

### Export interaction

- Show the count of vocabulary items to be exported before saving. If the profile has no vocabulary, explain that and do not create an empty file.
- Use `NSSavePanel`, following the existing Markdown export pattern.
- Surface write errors to the user; do not silently ignore failed writes.
- Keep the renderer separate from the save-panel UI so it can be unit-tested.

The format follows the official [Anki text-file import documentation](https://docs.ankiweb.net/importing/text-files.html), including UTF-8 requirements and `#key:value` file headers.

## Proposed File Layout

Keep existing files where they remain suitable; these are destinations, not a requirement to create every file exactly as named.

```text
Sources/Konishi/Features/Language/
  Engine/LanguageLearningEngine.swift
  Models/LanguageActivity.swift
  Models/LanguageQuestion.swift
  Models/LanguageReviewAttempt.swift
  Models/VocabularyProposal.swift
  Services/LanguageTutorService.swift
  Services/AnkiTextExporter.swift
  Store/LanguageStore.swift
  Store/LanguageWorkspaceModel.swift
  Views/LanguageWorkspaceView.swift
  Views/LanguageHomeView.swift
  Views/PracticeSessionView.swift
  Views/FlashcardView.swift
  Views/MatchingView.swift
  Views/TutorConversationView.swift
  Views/DeckView.swift
```

Avoid splitting small, cohesive types into files without a practical reason. Existing profile editor and reusable card-detail UI may be retained and adapted.

## Implementation Checklist

### Phase 1: Characterize current behavior and protect data

- [x] Add language test target coverage for `LearnItem.recordReview` and current SQLite profile/item behavior.
- [x] Add fixtures for a populated profile and cards; verify existing rows still decode after schema migration.
- [x] Define deterministic answer normalization rules and behavior for missing/ambiguous card data.
- [x] Specify review-attempt transaction and idempotency behavior.

### Phase 2: Build deterministic engine and persistence

- [x] Add typed activity/question/answer/result models.
- [x] Implement deterministic due-queue selection with stable ordering and profile scoping.
- [x] Implement distractor selection and safe fallback when there are not enough distinct options.
- [x] Implement answer checking for multiple choice, matching, flashcard self-rating, cloze, and conservative typed recall.
- [x] Add the review-attempt table, schema version, transactional schedule update, and unique attempt ID.
- [x] Test correct/wrong, skips, duplicate submission, profile isolation, malformed questions, distractor collisions, and persistence failure.

### Phase 3: Decouple Learn navigation

- [x] Make the Learn route render independently of `selectedConversationID` and ordinary `ChatView`.
- [x] Add the Learn home and activity setup/session navigation, plus Study, Deck, and Tutor destinations.
- [x] Move profile/session state into the language workspace model; keep the selected profile persisted as today.
- [x] Delete legacy language conversations and their per-conversation artifacts on startup; preserve profiles, cards, and review history.
- [ ] Run a UI smoke check switching between Chat, Voice, and Learn. Routing code keeps Learn independent of the selected chat; `./run.sh` was not run.

### Phase 4: Deliver model-independent practice

- [x] Implement flashcards, deterministic multiple choice, word matching, typed recall, and cloze.
- [x] Add session completion and cancellation. Restart rebuilds from persisted due-card state; the exact in-memory question index is not persisted across app relaunch.
- [x] Confirm review stats refresh from persisted results and skips do not change accuracy or scheduling.
- [x] Cover typed recall and cloze answer acceptance rules with tests.

### Phase 5: Add Anki export

- [x] Implement a pure vocabulary-to-Anki text renderer.
- [x] Add tests for UTF-8/non-Latin text, tags, empty optional fields, HTML escaping, tabs, quotes, and embedded newlines.
- [x] Add export count/empty state and `NSSavePanel` action to Deck view.
- [x] Report write errors; verify headers and three-column TSV against the official format and automated parser.
- [ ] Run the generated file through Anki's import preview. The Anki GUI preview was not run in this environment.

### Phase 6: Add bounded LLM assistance

- [x] Add structured vocabulary proposal models and field/duplicate validation.
- [x] Add explicit edit/save/skip UI for every proposed deck write.
- [x] Add tutor text and native voice input/bilingual speech output, reusing shared services without ordinary chat state.
- [x] Allow non-persistent vocabulary suggestions from tutor replies, with learner-initiated save.
- [x] Keep grading deterministic; flashcard self-rating is explicit. No model semantic grade can change scheduling.
- [x] Remove the old prompt-driven quiz flow and Learn-mode deck-tool dependency after replacement coverage.

## Acceptance Criteria

- Learn opens and functions without an ordinary conversation selected.
- Review, multiple choice, and matching work with the model server offline.
- The engine, not the LLM, selects the reviewed card and owns the correct answer.
- A submitted answer updates the intended card at most once; skip/cancel never counts as wrong.
- The app never claims a review was saved when persistence failed.
- LLM-generated vocabulary and synonyms are proposals; no deck write occurs without learner approval.
- Tutor text/voice conversation remains available and does not control deterministic session state.
- Existing profiles, cards, and review counters survive the migration; legacy language conversations are intentionally deleted.
- Anki output uses the documented UTF-8 text headers, fields, and tags; exporting does not modify the deck. Actual import preview remains unverified.
- `swift build` and all focused language tests pass. Do not run `./run.sh`; the user runs it themselves.

## Verification Notes

- `swift test` passed all 179 tests across 29 suites; `swift build` passed. `./run.sh` was not run.
- The legacy conversation purge runs during `AppModel` startup, before conversation indexing and initial selection; it has not run in this editor process.
- The exporter was cross-checked against Anki's official text-file header and escaping documentation, but was not opened in Anki's import dialog.
- The workspace routing is structurally independent of chat selection; a bundled-app UI smoke test remains for the user to perform with their normal `./run.sh` workflow.