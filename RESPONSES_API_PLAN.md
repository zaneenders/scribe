# OpenCode API migration plan

## Goal

Support the documented APIs for these existing profiles without changing unrelated profiles:

| Profile | Model | API | Endpoint |
| --- | --- | --- | --- |
| `opencode-muse-spark-1.3` | `muse-spark-1.3-contributor-free` | OpenAI Responses | `https://opencode.ai/zen/v1/responses` |
| `opencode-union-alpha` | `union-alpha` | Anthropic Messages | `https://opencode.ai/zen/go/v1/messages` |

OpenCode documents Union Alpha as an Anthropic Messages model, not a Responses model. Do not switch it to Responses without provider confirmation.

Sources: [OpenCode Zen](https://opencode.ai/docs/zen/), [OpenCode Go](https://opencode.ai/docs/go/). Recheck endpoint and model support before implementation.

## Current implementation

- `Sources/ScribeKit/ConfigLoader.swift` accepts `api.type: "codex"`; omitting the type selects Chat Completions.
- `Sources/ScribeCore/Providers/AgentProviderFactory.swift` selects the provider.
- `Sources/ScribeLLMCodex/openapi.yaml` describes the Codex Responses subset.
- `Sources/ScribeCore/Providers/Codex/` already converts conversation history and processes Responses SSE events and tool calls.
- Codex uses subscription credentials, a `/codex/responses` route, and Codex-specific headers. Public Responses must use the profile API key and its own route instead.
- Both requested profiles exist in `~/.scribe/scribe.config.json`.
- Baseline validation: `swift build --target ScribeCore` passed during investigation.

## Phase 1: OpenAI Responses support

### 1. Define the minimal OpenAPI contract

Add a generated client contract for streaming `POST /v1/responses`, following the project's existing OpenAPI generator setup. Keep the configured base URL as `https://opencode.ai/zen`; ensure `/v1` is added exactly once.

Model only what the agent needs:

- Request: model, streaming, storage policy, conversation input, tools, tool choice, temperature, and supported reasoning options.
- Conversation input: instructions/messages, text and existing image input, assistant function calls, and function-call outputs.
- Function tools: name, description, JSON Schema parameters, and any required strictness setting.
- SSE events: text deltas, reasoning events needed by the UI, output items, function-call arguments, completion, failure/incomplete status, and token usage.
- Error responses: preserve HTTP status and bounded error details.

Exclude response retrieval/deletion, background jobs, hosted tools, audio/video, and WebSockets. Use the existing Codex schema as a reference, not as a reason to copy subscription-only fields. Preserve unknown-event tolerance.

### 2. Add configuration and routing

- Accept `api.type: "responses"` in configuration validation.
- Route it explicitly in `AgentProviderFactory`.
- Authenticate with the profile API key; never load Codex OAuth credentials for this provider.
- Preserve the existing OpenCode header behavior and normal retry/cancellation behavior.
- Do not send Codex-specific account or originator headers.
- Leave omitted API types and `api.type: "codex"` behavior unchanged.

### 3. Reuse compatible agent behavior

Inspect the Codex conversion and streaming code before deciding the smallest shared boundary. Reuse compatible processing rather than duplicate the entire agent loop; keep endpoint/authentication differences explicit.

Verify:

- Full conversation replay works with storage disabled.
- Function-call IDs and output IDs survive tool execution and subsequent requests without Codex-only rewriting.
- Tool arguments accumulate correctly across deltas and finalized events.
- Reasoning display and any provider-required replay data are handled correctly.
- Completed, incomplete, failed, malformed, and interrupted streams produce appropriate outcomes; an unfinished stream is not reported as success.
- Usage includes supported cached and reasoning token details.
- Request parameters reflect actual model support. Do not assume Codex reasoning defaults, encrypted-content includes, or temperature combinations are valid for Muse.

### 4. Test before switching Muse

Add focused tests covering:

- Configuration parsing, rejection of unknown API types, and existing-provider compatibility.
- Exact request path, bearer authentication, OpenCode headers, and absence of Codex headers.
- Request encoding for messages, images, tools, tool results, and optional reasoning settings.
- SSE text/reasoning, split tool arguments, multiple tool calls, usage, unknown events, errors, incomplete streams, and cancellation.
- A mocked two-round exchange: function call, tool execution, function-call output, final response.

Run relevant ScribeCore and ScribeKit tests, then build the application using the supported Swift build system. Report any validation blockers explicitly.

### 5. Migrate and verify Muse

After automated validation:

- Change only `api.type` to `"responses"` for `opencode-muse-spark-1.3` in the local configuration.
- Preserve its base URL, model, context limits, temperature, reasoning setting, logging, and OpenCode header setting unless provider validation proves a change necessary.
- Run a minimal live text and tool-round-trip check; avoid sending existing session history or workspace content.
- Confirm successful completion, tool continuation, and usage reporting.

Do not commit local credentials or configuration. Rotate the API key shared in the conversation before live validation, and never include it in tests, fixtures, logs, or this plan.

## Phase 2: Union Alpha via Anthropic Messages

This is separate protocol support, not a second Responses profile migration. Confirm whether to include it in the same implementation or follow up after Muse works.

If included:

1. Add a minimal generated contract for streaming `POST /v1/messages`, using `https://opencode.ai/zen/go` as the base URL.
2. Verify OpenCode's authentication and version-header requirements rather than assuming direct Anthropic defaults.
3. Add an explicit configuration type, proposed as `api.type: "anthropic"`.
4. Convert system instructions, messages, image content, tool definitions, tool-use blocks, and tool-result blocks to the Messages format.
5. Handle content-block deltas, tool JSON accumulation, reasoning/signature data where required, stop reasons, usage, errors, and cancellation.
6. Set required output-token limits independently of the context-window size, based on documented model support.
7. Add equivalent request, streaming, and tool-round-trip tests; build and test before changing the profile.
8. Switch only `opencode-union-alpha` to the new type and perform minimal live verification.

Leave Union unchanged if this phase is deferred. Do not silently fall back to a different protocol.

## Acceptance criteria

- Muse uses the documented Responses endpoint with streaming text and working tool continuation.
- Union either uses tested Messages support or remains unchanged and explicitly deferred.
- Existing Chat Completions and Codex profiles remain compatible.
- OpenAPI definitions contain only the operations and schemas needed by the implementation.
- Relevant automated tests and the application build pass; live checks and any blockers are reported separately.
- No credentials enter version control or test output.

## Rollback

Record only the prior non-secret settings for the two profiles. If live validation fails, restore those settings without overwriting other local profile edits. Keep the new providers opt-in; avoid any automatic migration of unrelated profiles.
