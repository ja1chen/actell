# ProviderKit

English | [简体中文](README.zh-CN.md)

ProviderKit separates model protocols from session history and device execution.
`ProviderCore` provides requests, events, ordered replay items, usage, scopes and
capability contracts without an SDK dependency. `OpenAIAdapter` implements Chat
Completions and Responses encoding, stream assembly, terminal validation and
explicit native compaction. AgentKit supplies complete prepared requests and owns
history, context revisions, retention, continuation heads and durable commits.
Providers never reconstruct a session or write a continuation checkpoint.

The adapter depends on the remote Swift package
[MacPaw/OpenAI 0.5.2](https://github.com/MacPaw/OpenAI/tree/0.5.2).
No SDK source is copied or patched, and SDK DTOs stay inside the adapter. The
package requires Swift 6.2, iOS 16 or macOS 13; the App maintains its own platform
baseline. SDK constructors handle common fields, while explicit protocol objects
preserve supported replay and gateway extension fields.

## Requests and replay

`ProviderReplayScope` identifies the provider, canonical endpoint, account
reference, project, model and persistent session. Attempts, turns and context
epochs do not change this service scope. Opaque reasoning, Chat reasoning blocks,
compaction items and response IDs cannot cross scopes. Credentials never become
scope or cache identities. `ProviderScope` is the existing domain spelling for
the same stable scope.

Responses defaults to stateless replay with `store=false`. Explicit response-chain
requests use `store=true`, a scoped previous response ID and newly supplied input.
The caller chooses the complete input or incremental continuation; the adapter
never infers it from UI messages. Missing or rejected remote handles are surfaced
without automatically replaying accepted requests. Background generation,
Conversations, hosted tools and verified remote cancellation are unsupported.
Compatibility endpoints must explicitly advertise response-chain support.

`ModelInputProjection` is a pure message-to-input conversion and never trims
images or history. Media retention belongs to AgentKit. Images use copy-on-write
Data or file references until serialization. User attachments and tool results
remain separate facts. A server chain can retain images remotely even after they
leave the local window; `store=false` is not a guarantee about vendor logs.

## Streaming and failure handling

The ephemeral HTTP transport disables cookies/cache, rejects redirects and cancels
operation tasks on parser failure or consumer termination. Cancelling active tasks
does not invalidate the transport for subsequent requests. Request bodies are
limited to 24 MiB, responses to 4 MiB, SSE lines/events to 256 KiB, image bytes to
8 MiB and JSON nesting to 48. No request or response payload is logged by this
package.

Responses completion must match every fully assembled output item. Tool IDs,
arguments, item addresses, scope and terminal states are validated before dispatch.
Repeated identical stream sequences are ignored; conflicting or reordered
sequences fail. EOF without a valid terminal fails without automatic retry.
Chat streaming handles interleaved argument fragments, explicit readable reasoning
and late usage frames. Ordered gateway `reasoning_details` is scoped replay state;
only explicit readable fields enter presentation.

Unknown stream extensions are credential-redacted diagnostic attachments, never
replay inputs or execution authority. Retention is bounded to 128 events and
512 KiB per response; excess diagnostics are omitted without rejecting a valid
response. Executable unknown output remains unsupported. Stream checkpoints are
in-memory assembly snapshots, not persistent continuation owners.

## Compaction, caching and usage

Chat continuation fields are separate from readable reasoning. The official
[DeepSeek thinking-mode contract](https://api-docs.deepseek.com/guides/thinking_mode/)
requires original `reasoning_content` from prior assistant turns when tools are
included. The adapter preserves that raw field in scoped durable replay state;
the App enables replay only for the verified official DeepSeek Chat endpoint.
Requests without tools omit it. Unknown gateways do not inherit this capability,
and display text is never used to reconstruct the original field.

`ModelCompactingProvider` is an optional capability. The OpenAI Responses adapter
supports the documented [compact endpoint](https://developers.openai.com/api/docs/guides/compaction)
when explicitly enabled. Compaction accepts no tools, returns a complete canonical
input window, and keeps retained input messages/results plus a typed scoped opaque
compaction item. The caller atomically adopts the entire validated window.
Unsupported retained content fails candidate validation without changing history.
Compatible Responses services do not acquire compact support automatically. The
App currently enables this capability only for the official OpenAI Responses
endpoint; compatible custom endpoints use portable summary compaction.

ChatGPT subscription HTTP inference follows the official
[Sign in with ChatGPT limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations):
`store=false`, `stream=true`, the effective input window and no `previous_response_id`.
AgentKit supplies that window, using a committed summary plus retained items after
compaction; the full JSONL archive remains local. WebSocket continuation is limited
to the same authenticated connection and is not persistent conversation storage;
this App uses HTTP/SSE.
Persistent server continuation and the native compact route are not advertised
for this grant. A caller may use tool-free summary inference to compact locally;
it must not present that as server continuation or native compaction.

Prompt cache key and optional retention fields are explicit request policy.
Subscription inference omits unsupported retention fields. Stable request JSON
preserves input order and sorts object keys. Usage keeps input, output, cached,
cache-write and reasoning tokens separately; missing values remain unknown.
Cache hits require actual server usage evidence and are not inferred from hashes.

## Validation

```sh
swift test --package-path ios-app/ProviderKit
bash ios-app/scripts/test_core.sh <isolated simulator UDID>
```

On hosts using standalone command-line tools, select a complete Xcode toolchain
for XCTest. Package tests use synthetic data and need no credentials. App tests
retain device authorization, session isolation, unknown results and stop/release
coverage. Offline tests do not establish real endpoint support, cache hits,
remote cancellation or physical-device acceptance.
