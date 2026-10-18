# ProviderKit

Package directory and SPM package name are both `ProviderKit`. Its two products,
targets and source directories are `ProviderCore` and `OpenAIAdapter`.

`ProviderCore` has no SDK dependency. App and SwiftAgentKit consume its
`ModelProvider`, requests/events, ordered native output, typed content, usage,
errors and scoped context. Portable Agent messages are a projection, not the
canonical Responses replay envelope. No SDK DTO or typealias crosses this boundary.

`OpenAIAdapter` depends on **remote Swift Package Manager**
[MacPaw/OpenAI 0.5.2](https://github.com/MacPaw/OpenAI/tree/0.5.2), commit
`975fff8a1e1ef92fc7fc04097b0cfe253b840cb7`. No SDK source is copied or patched.
The tag requires Swift 5.10 and iOS 13; this package requires Swift 6.2/iOS 16,
within the app's Xcode 27/iOS 27 baseline. Its SDK dependencies are locked by
the app's checked-in Package.resolved.

The adapter uses MacPaw's public ChatQuery constructors, CreateModelResponseQuery,
InputItem/Item/Tool and OutputItem/ChatResult codecs. A narrow local transport
protects both paths: MacPaw 0.5.2's streaming client constructs its own default
session, so injecting an ephemeral session does not cover streaming. This
transport uses an ephemeral session without cookies/cache, rejects redirects,
cancels each stream task on parser/consumer failure, limits request bodies to
24 MiB, responses to 4 MiB and SSE lines/events to 256 KiB, and never logs payloads.
Individual image bytes are limited to 8 MiB, JSON nesting to 48, and stream
consumer buffers are bounded. The SDK's raw DEBUG parser logging is not invoked.

SDK-specific adaptations stay here: construct InputItem.item for native replay
(the facade discriminator does not select function/reasoning directly); normalize
omitted output_text.logprobs to an empty array for schema validation. These do
not invent tool IDs, arguments, terminal states or reasoning. Unknown executable
items fail closed. Unknown stream events are credential-redacted and retained as scoped response
attachments after sequence and response-scope validation; they cannot supply
output or authorize tools. Per-response limits are 128 events and 512 KiB; overflow
fails explicitly. Attachments persist separately from replay in stream checkpoints
and bounded committed response history, and are never sent back to the model. A
completed terminal snapshot must still match every completed output item before
success or tool dispatch. `ping`, `keepalive`, and `vendor.metrics.*` need no
sequence. Duplicate sequence/content is ignored; conflicts
and reordered sequences fail. Sequence numbers need not be consecutive.

## Context and storage

Settings default to the existing Chat Completions route. Selecting Responses is
an explicit endpoint choice, not discovery-derived evidence of remote support.
There is no protocol downgrade. Anthropic/Gemini remain discovery only; OpenRouter and Ollama keep their existing Chat route by default. Explicit Responses
is available for OpenAI-compatible and OpenRouter profiles. `ProviderKind` identifies
the service/discovery policy; `ProviderProfile` owns endpoint/account/model settings;
`InferenceAPI`/`OpenAIWireProtocol` selects the wire format. Legacy `protocolKind`
JSON keys/raw values are retained for configuration migration. OpenRouter is a
service, not a separate wire protocol. Its Responses endpoint is stateless only: the
editor hides response-chain selection and both configuration and codec boundaries
reject store=true/previous_response_id locally. Per-model vision/tools/text support
is checked when known; unknown capabilities and catalogue entries do not prove
Responses support. See [OpenRouter Responses](https://openrouter.ai/docs/api_reference/responses/overview). Background, Conversations, compaction,
hosted tools and remote cancel/resume are unsupported.

Responses defaults to `stateless`/`store=false`. A runtime-owned, per-run
ContextCoordinator replays native ordered output, including final encrypted
reasoning, separately from UI transcript and the existing device journal. Each
request carries current instructions. Responses disables the legacy runtime message/token trimming; overflow fails
explicitly at the provider boundary rather than discarding a native dependency
group. Only explicit response-chain selection
uses `store=true`; subsequent requests carry a scoped previous_response_id and
only newly supplied input/results. IDs and opaque reasoning are bound to the
provider, endpoint, account reference, model, run and branch. A missing remote
handle is surfaced, never silently regenerated or downgraded.

Completed output, pending call set, branch revision and head are persisted in one
atomic protected domain checkpoint before tools become dispatchable. A CAS
rejects competing commits and a cancel epoch fences late results. Existing
RunLifecycleCoordinator remains the durable device dispatch/outcome journal;
its stop fence precedes network cancellation. A separate, versioned
StreamCheckpoint records scoped assembly/sequence on terminal, failure and every
32 events; it is diagnostic evidence, not a resume/dispatch authorization. No provider checkpoint enables
automatic action resumption after restart. Foreground local cancellation does
not claim verified remote cancellation.

Screenshots use copy-on-write Data or file references until wire serialization.
Old device image content is removed without breaking call/result pairs; user
attachments remain. Local replay retains native output and needed tool results.
A response chain may still contain old screenshots remotely; reducing upload
does not delete them. `store=false` is not a promise about all vendor logs.

## Validation

The app's default test target includes Responses and transport fixtures alongside
all existing protocol/permission/session/checkpoint/stop tests. Run
`bash ios-app/scripts/test_core.sh <isolated simulator UDID>` and use
`RUN_UI_TESTS=1` for UI. Tests never need real credentials or paid API calls.

Real endpoint/model compatibility, encrypted-state availability, real network
cancellation/redirect behavior, device memory and physical device acceptance
must be verified separately. These fixtures are not live API end-to-end evidence.

## OpenRouter Chat compatibility

Chat `reasoning_details` is retained as exact, ordered JSON blocks, including
signatures, encrypted data and unknown noncritical fields. Stream blocks are
concatenated in received order, following the [official reasoning contract](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens).
A scoped opaque domain state crosses the Agent message seam and is echoed only
within its original provider/endpoint/account/model/run/branch. UI receives only
the existing readable reasoning projection. Usage-only terminal chunks may have
nonempty choices and repeat the same finish_reason; they update totals once and
do not emit a second tool batch. Conflicting terminal states still fail.

Existing model IDs, base URL prefixes, auth references and supported parameter
fields are retained. New routing, session_id, vendor-specific reasoning controls,
provider selection, hosted tools and all-model compatibility are not promised.
No session_id is used as a history store. No paid/online model request verifies
any of these fixtures. Redacted gateway blocks are preserved as received; local
code cannot reconstruct withheld signatures or encrypted content.

## Service and wire boundaries

- `PhoneAgent/Models/ProviderModels.swift`: `ProviderKind` identifies services
  (OpenAI-compatible/OpenRouter/Ollama/Anthropic/Gemini) but also owns default URL,
  URL normalization, inference/state capability policy and parameter policy.
  `InferenceAPI` is the persisted Chat Completions/Responses choice.
- `PhoneAgent/Storage/ProviderStore.swift`: `ProviderProfile` is the current
  endpoint/account/model configuration; legacy `protocolKind` is kept for
  decoding old settings. There is currently no type named `EndpointProfile`.
  The store and profile validate combinations and model capability exclusions.
- `PhoneAgent/Agent/Providers.swift`: `PrivateVisionProvider` combines service
  policy, explicit parameter mapping, transport/codec selection and runtime
  context orchestration. It applies Ollama's tool-parallel field exclusion and
  supplies service-specific response-chain capabilities to the codec.
- `PhoneAgent/Agent/ModelDiscovery.swift`: discovery path/header/pagination and
  model metadata switches remain service-specific in the App layer.
- `OpenAIAdapter/OpenAIWireCodec.swift`: `OpenAIWireProtocol` selects the wire
  grammar; the codec owns SDK query/output mapping and scope checks. It consumes
  externally supplied endpoint capabilities. Its default capability value is
  not evidence that an arbitrary compatible service supports response chains.
- `ProviderCore/NativeItems.swift` and `ModelTypes.swift`: `ProviderScope`,
  `ProviderCapabilities`, `ProviderConfiguration` and `ModelProvider` are domain
  boundaries. Scope identity currently uses service kind plus endpoint/account/
  model/run/branch, rather than a dedicated ProviderIdentity type.
