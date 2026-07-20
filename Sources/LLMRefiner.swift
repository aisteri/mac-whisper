import Foundation

/// Refines transcribed text via an OpenAI-compatible chat-completions API. The system
/// prompt is deliberately conservative and language-neutral: it only fixes obvious
/// speech-recognition errors (homophones, mis-transcribed technical terms) and otherwise
/// returns the input unchanged, preserving the speaker's original language.
enum LLMRefiner {

    private static let basePrompt = """
    You are a speech-recognition post-editor. Your only task is to fix obvious \
    speech-recognition errors. Never paraphrase, rewrite, embellish, expand, or shorten.

    Strict rules:
    1. Only correct clear speech-recognition mistakes, such as homophones / near-homophones \
    and technical terms that were mis-transcribed.
    2. If the input already looks correct, return it unchanged.
    3. Never change the speaker's meaning, tone, wording, or language. Keep the text in the \
    exact same language it was spoken in — do not translate.
    4. Never add any explanation, prefix, suffix, quotation marks, or commentary.
    5. Output only the corrected text itself, nothing else.
    """

    /// System prompt, extended with the user's glossary when one is attached.
    /// The glossary biases corrections toward the speaker's domain terms —
    /// names, products, jargon — that recognizers habitually get wrong.
    private static var systemPrompt: String {
        let glossary = Settings.shared.glossaryText
        guard !glossary.isEmpty else { return basePrompt }
        return basePrompt + """


        Glossary — terms this speaker actually uses. When a word in the input sounds like \
        (or is a plausible mis-transcription of) a glossary term, replace it with the exact \
        glossary spelling. Lines of the form "wrong -> right" map a frequent \
        mis-transcription directly to the preferred term. Never insert glossary terms that \
        were not plausibly spoken.

        \(glossary)
        """
    }

    struct RefineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// System prompt for turning a raw meeting transcript into formal,
    /// detailed minutes. The glossary is appended so domain terms come out
    /// right. `meetingDate` (the recording timestamp) fills the 일시 field.
    /// `attendees` is what the user typed when prompted after the recording;
    /// empty means they declined or the prompt timed out, in which case the
    /// minutes must stay free of speaker identity (the transcript has none).
    /// Rule 2 when the user gave no attendee list: the transcript alone carries
    /// no speaker identity, so none may appear in the minutes.
    private static let noRosterRule = """
        2. The transcript carries no reliable speaker identity, so the minutes must \
        contain none. Do not list attendees or participants, do not attribute any \
        statement to a named person, and do not assign an owner to an action item. \
        Write the discussion impersonally ("…하기로 함", "…라는 의견이 있었음"). A \
        person's name belongs in the minutes only where it was the subject the meeting \
        talked about, never as the source of a remark.
        """

    /// Rule 2 when the user supplied a roster. The roster is authoritative for
    /// *who was there* — but the transcript is still un-diarized, so it grants
    /// no license to guess who said which line.
    private static func rosterRule(_ roster: String) -> String {
        """
        2. The user supplied the attendee list below. Reproduce it in the overview \
        as given — do not add, drop, or re-spell names, and never promote a name \
        found elsewhere (the transcript, the glossary) into the attendee list.

        \(roster)

        The transcript itself is not speaker-labelled, so knowing who was in the room \
        does not tell you who said a given line. Attribute a statement, or name the \
        owner of an action item, only where the transcript says so outright ("제가 \
        하겠습니다" next to a name, "○○님이 맡기로"). Everywhere else write \
        impersonally ("…하기로 함", "…라는 의견이 있었음"). Do not add a \
        per-attendee section or split action items by person.
        """
    }

    static func meetingNotesPrompt(meetingDate: String, attendees: String = "") -> String {
        let roster = attendees.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = """
        You are a professional minute-taker. Turn the raw speech-to-text transcript of a \
        meeting into meeting minutes (회의록), written in the SAME language as the \
        transcript (do not translate). Localize all headings and labels to that language.

        Minimum required content — always include, as far as the transcript supports it:
        - A title and a meeting overview: date/time (use "\(meetingDate)")\(roster.isEmpty ? "" : ", the attendees listed below") and the \
        agenda items that were discussed.
        - The discussion itself: what was talked about, with the reasons, trade-offs, \
        numbers, dates, examples, and concerns that were actually raised.
        - Decisions that were made, and action items (with a due date when one was \
        mentioned).

        Beyond that minimum, choose the structure, depth, and length that best fit this \
        particular meeting. A decision meeting, a brainstorm, a status sync, and a \
        design review each deserve differently shaped minutes — organize accordingly.

        Length is not a constraint, in either direction — never shorten the minutes to \
        be tidy. Do not summarize away substance: a reader who missed the meeting must \
        be able to follow each discussion — what was raised, why, what was weighed, and \
        how it landed. When in doubt whether a point is substantive, include it. Leave \
        out only filler, small talk, and verbatim repetition.

        Use visual aids where they genuinely clarify: when the discussion describes a \
        process or workflow, a system structure, a decision tree, a sequence of \
        interactions, or a timeline/plan, render it as a Mermaid diagram in a \
        ```mermaid code block (flowchart, sequenceDiagram, timeline, …) alongside the \
        prose; use Markdown tables for comparisons and option matrices. Only diagram \
        what was actually discussed — never decorate for its own sake.

        Rules:
        1. The transcript comes from speech recognition and contains mis-recognized \
        words; silently correct them from context. Never invent content — attendees, \
        decisions, dates — that the transcript does not support.
        \(roster.isEmpty ? Self.noRosterRule : Self.rosterRule(roster))
        3. Output Markdown, and only the document itself — no preamble or commentary.
        """
        let glossary = Settings.shared.glossaryText
        if !glossary.isEmpty {
            prompt += """


            Glossary — terms the speakers actually use. When a word in the transcript \
            sounds like (or is a plausible mis-recognition of) a glossary term, use the \
            exact glossary spelling. Lines of the form "wrong -> right" map a frequent \
            mis-recognition to the preferred term.

            The glossary is a spelling aid only — it is not a roster. A name appearing \
            here is no evidence that its bearer attended or spoke.

            \(glossary)
            """
        }
        return prompt
    }

    /// Refine `text`. On any failure the completion receives the original text so injection
    /// can still proceed.
    static func refine(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let settings = Settings.shared
        request(
            text: text,
            baseURL: settings.llmBaseURL,
            apiKey: settings.llmAPIKey,
            model: settings.llmModel,
            proto: settings.llmProtocol,
            completion: completion
        )
    }

    /// Generate meeting notes via `claude -p`, piping the prompt + transcript
    /// through stdin (avoids ARG_MAX on long transcripts). Runs on a background
    /// queue; the completion fires on that queue — callers bounce to main.
    static func generateMeetingNotesViaClaude(
        from transcript: String,
        meetingDate: String,
        attendees: String = "",
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let prompt = meetingNotesPrompt(meetingDate: meetingDate, attendees: attendees)
        let input = prompt + "\n\n" + transcript
        DispatchQueue.global(qos: .userInitiated).async {
            let claudePath = Self.claudeCLIPath()
            guard let claudePath else {
                completion(.failure(RefineError(message: "claude CLI not found — install Claude Code and sign in")))
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = ["-p", "--output-format", "text"]
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
                if let data = input.data(using: .utf8) {
                    stdin.fileHandleForWriting.write(data)
                }
                stdin.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0,
                   let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    completion(.success(output))
                } else {
                    let errMsg = String(data: errData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                    completion(.failure(RefineError(message: "claude CLI failed: \(errMsg)")))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Returns `true` when the `claude` CLI is installed and appears to be
    /// signed in (exits 0 on `claude --version`).
    static func isClaudeAvailable() -> Bool {
        claudeCLIPath() != nil
    }

    private static func claudeCLIPath() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/Applications/cmux.app/Contents/Resources/bin/claude",
            ProcessInfo.processInfo.environment["HOME"].map { $0 + "/.claude/local/claude" },
        ].compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Pre-flights the translation path when an interpreter session starts:
    /// a throwaway request refreshes the OAuth token, loads the Codex
    /// instructions cache, and opens the shared HTTP/2 connection — so the
    /// first real sentence doesn't pay for any of it.
    static func warmUpTranslation(to language: String) {
        translate("Hello.", to: language) { _ in }
    }

    /// One re-translation request for the live-translation engine: translate
    /// the CURRENT text of one utterance, whole, from scratch. Deliberately
    /// lightweight — no glossary, tiny prompt, zero reasoning effort — because
    /// latency matters more than polish here. The immediately preceding
    /// utterance (and its translation, when known) is passed as context so
    /// pronouns and terminology stay consistent. `previousTranslation` is the
    /// hypothesis currently on screen; instructing the model to reuse it
    /// verbatim keeps consecutive hypotheses prefix-stable, which is what
    /// local agreement needs to commit words early.
    static func translate(
        _ text: String,
        to language: String,
        from sourceLanguage: String? = nil,
        context: String? = nil,
        contextTranslation: String? = nil,
        isFragment: Bool = false,
        previousTranslation: String? = nil,
        effort: String = "none",
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let settings = Settings.shared
        // Name the source only when the user pinned one; "Auto"/nil lets the
        // model detect it (right for mixed-language meetings).
        let fromClause: String
        if let sourceLanguage, !sourceLanguage.isEmpty,
           sourceLanguage != TranslationLanguage.autoSource {
            fromClause = "from \(sourceLanguage) "
        } else {
            fromClause = ""
        }
        var prompt = """
        You are a simultaneous interpreter. Translate the user's text \(fromClause)into \(language). \
        The text comes from live speech recognition: it may contain filler sounds \
        (uh, 어, 음, 那个, 呃), false starts, and recognition noise. Translate the \
        intended meaning into clean, natural \(language) and drop the fillers. \
        Output ONLY the translation — no quotes, no notes, no commentary.
        """
        if let context {
            prompt += "\n\nPreceding source (context only — do NOT include it in the output): \(context)"
            if let contextTranslation {
                prompt += "\nIts translation (match its tone and terminology): \(contextTranslation)"
            }
        }
        if isFragment {
            prompt += "\n\nThe text is an unfinished utterance still being spoken; translate it naturally as-is, without completing it."
        }
        // The TRANSLATION glossary (separate from the meeting/STT one) rides
        // only on the quality pass (effort > none): the live loop is
        // latency-critical and its output gets replaced anyway.
        if effort != "none", let targetColumn = Settings.glossaryColumn(promptName: language) {
            let pairs = settings.translationGlossaryPairs(
                sourceColumn: Settings.glossaryColumn(promptName: settings.interpreterSourceLanguage),
                targetColumn: targetColumn)
            if !pairs.isEmpty {
                let lines = pairs.map { "\($0.0) -> \($0.1)" }.joined(separator: "\n")
                prompt += """


                Glossary — when the source contains the term on the left, translate it as the \
                term on the right. Apply only when the term actually appears.

                \(lines.prefix(2000))
                """
            }
        }
        if let previousTranslation {
            prompt += """


            Your previous translation of this same, still-growing utterance (shown live on screen): \
            \(previousTranslation)
            The source has grown since. FIRST check that the previous translation actually \
            translates this source: if it does not (mistranslation, unrelated text, garbled early \
            guess), DISCARD it entirely and translate the source correctly — accuracy always beats \
            stability. If it is correct, reuse its wording verbatim as the beginning of your output \
            and extend it to cover the new material; never rephrase correct text for style, tone, \
            or flow.
            """
        }
        request(
            text: text,
            baseURL: settings.llmBaseURL,
            apiKey: settings.llmAPIKey,
            model: settings.translationLLMModel, // translation has its own model pick
            proto: settings.llmProtocol,
            systemPrompt: prompt,
            reasoningEffort: effort,
            completion: completion
        )
    }

    /// Generate formal meeting minutes from a raw long-form transcript,
    /// using the configured provider and the user's glossary. `meetingDate`
    /// is the recording timestamp shown in the 회의 개요 table.
    static func generateMeetingNotes(from transcript: String, meetingDate: String, attendees: String = "", completion: @escaping (Result<String, Error>) -> Void) {
        let settings = Settings.shared
        request(
            text: transcript,
            baseURL: settings.llmBaseURL,
            apiKey: settings.llmAPIKey,
            model: settings.llmModel,
            proto: settings.llmProtocol,
            systemPrompt: meetingNotesPrompt(meetingDate: meetingDate, attendees: attendees),
            reasoningEffort: "medium",
            completion: completion
        )
    }

    /// Used by refinement, meeting notes, and the Settings "Test" button.
    static func request(
        text: String,
        baseURL: String,
        apiKey: String,
        model: String,
        proto: LLMProtocol = .openai,
        systemPrompt: String? = nil,
        reasoningEffort: String = "low",
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let prompt = systemPrompt ?? self.systemPrompt
        switch proto {
        case .openai:
            requestOpenAI(text: text, baseURL: baseURL, apiKey: apiKey, model: model, systemPrompt: prompt, reasoningEffort: reasoningEffort, completion: completion)
        case .anthropic:
            requestAnthropic(text: text, baseURL: baseURL, apiKey: apiKey, model: model, systemPrompt: prompt, completion: completion)
        case .chatgpt:
            requestChatGPT(text: text, model: model, systemPrompt: prompt, reasoningEffort: reasoningEffort, completion: completion)
        }
    }

    // MARK: - ChatGPT subscription (Codex backend, OAuth)

    /// Calls the ChatGPT backend Responses endpoint using the subscription OAuth
    /// token. The backend requires the Codex CLI system prompt in `instructions`
    /// and store=false + stream=true; our refinement prompt rides along as a
    /// developer message in `input`.
    private static func requestChatGPT(
        text: String,
        model: String,
        systemPrompt: String,
        reasoningEffort: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        ChatGPTOAuth.shared.withFreshToken { tokenResult in
            switch tokenResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                CodexInstructions.fetch(for: model) { instructions in
                    guard let instructions else {
                        completion(.failure(RefineError(message: "Could not load Codex instructions (network required on first use)")))
                        return
                    }
                    sendChatGPT(text: text, model: model, instructions: instructions,
                                systemPrompt: systemPrompt, reasoningEffort: reasoningEffort,
                                access: token.access, accountID: token.accountID,
                                completion: completion)
                }
            }
        }
    }

    private static func sendChatGPT(
        text: String,
        model: String,
        instructions: String,
        systemPrompt: String,
        reasoningEffort: String,
        access: String,
        accountID: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let url = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [
                ["type": "message", "role": "developer",
                 "content": [["type": "input_text", "text": systemPrompt]]],
                ["type": "message", "role": "user",
                 "content": [["type": "input_text", "text": text]]],
            ],
            "store": false,
            "stream": true,
            "include": ["reasoning.encrypted_content"],
            "reasoning": ["effort": reasoningEffort, "summary": "auto"],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(RefineError(message: "Failed to build request: \(error.localizedDescription)")))
            return
        }

        send(req, original: text) { data in
            parseSSEOutputText(data)
        } completion: { completion($0) }
    }

    /// Extracts the assistant's final text from a Responses-API SSE stream.
    /// Prefers the terminal response.completed/response.done payload; falls back
    /// to accumulated response.output_text.delta events.
    private static func parseSSEOutputText(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        var finalText: String?
        var deltas = ""
        for line in raw.split(separator: "\n") {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                if let d = obj["delta"] as? String { deltas += d }
            case "response.completed", "response.done":
                guard let resp = obj["response"] as? [String: Any],
                      let output = resp["output"] as? [[String: Any]] else { continue }
                var texts: [String] = []
                for item in output where (item["type"] as? String) == "message" {
                    for part in (item["content"] as? [[String: Any]] ?? [])
                    where (part["type"] as? String) == "output_text" {
                        if let t = part["text"] as? String { texts.append(t) }
                    }
                }
                if !texts.isEmpty { finalText = texts.joined() }
            default:
                break
            }
        }
        return finalText ?? (deltas.isEmpty ? nil : deltas)
    }

    // MARK: - OpenAI-compatible

    private static func requestOpenAI(
        text: String,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        reasoningEffort: String = "low",
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = endpoint(from: baseURL, suffix: "chat/completions") else {
            completion(.failure(RefineError(message: "Invalid API Base URL")))
            return
        }

        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        // Reasoning models burn seconds thinking about a one-line translation
        // unless told not to; measured on gpt-5.4-nano, effort "none" cuts a
        // 1.9 s response to ~0.7 s. Non-reasoning models reject the field, so
        // only send it where it applies.
        if model.hasPrefix("gpt-5") {
            body["reasoning_effort"] = reasoningEffort
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(RefineError(message: "Failed to build request: \(error.localizedDescription)")))
            return
        }

        send(req, original: text) { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }
            return content
        } completion: { completion($0) }
    }

    // MARK: - Anthropic Messages

    private static func requestAnthropic(
        text: String,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = endpoint(from: baseURL, suffix: "messages") else {
            completion(.failure(RefineError(message: "Invalid API Base URL")))
            return
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16384,
            "temperature": 0,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(RefineError(message: "Failed to build request: \(error.localizedDescription)")))
            return
        }

        send(req, original: text) { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let textValue = first["text"] as? String else {
                return nil
            }
            return textValue
        } completion: { completion($0) }
    }

    // MARK: - Shared transport

    /// Sends a prepared request, validates the HTTP status, and extracts the assistant
    /// text via `parse`. Falls back to the original text when the model returns empty.
    private static func send(
        _ req: URLRequest,
        original: String,
        parse: @escaping (Data) -> String?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(RefineError(message: "No response")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(RefineError(message: "HTTP \(http.statusCode): \(detail)")))
                return
            }
            guard let data, let content = parse(data) else {
                completion(.failure(RefineError(message: "Unexpected response format")))
                return
            }
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(.success(cleaned.isEmpty ? original : cleaned))
        }
        task.resume()
    }

    /// Build the endpoint URL, tolerating base URLs with or without the full path.
    /// Rejects non-HTTPS schemes (except for localhost) so the API key and
    /// transcript are never sent over plaintext.
    private static func endpoint(from base: String, suffix: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        let candidateString: String
        if trimmed.hasSuffix("/" + suffix) {
            candidateString = trimmed
        } else {
            candidateString = trimmed + "/" + suffix
        }
        guard let url = URL(string: candidateString) else { return nil }
        switch url.scheme?.lowercased() {
        case "https":
            return url
        case "http":
            let host = url.host?.lowercased() ?? ""
            return (host == "localhost" || host == "127.0.0.1") ? url : nil
        default:
            return nil
        }
    }
}
