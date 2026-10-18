# ChatGPT subscription integration

## Implemented behavior

- Add-provider order: OpenAI, OpenRouter, ChatGPT subscription, Custom (last). Service kind and wire remain distinct; formats use OpenAI Chat Completions / OpenAI Responses labels. Existing provider keys are preserved.
- Subscription fixes official destinations and stateless Responses. No API key or arbitrary base is accepted. Continue with ChatGPT saves the profile and starts a foreground system authentication browser plus an HTTP `127.0.0.1:{port}/auth/callback` listener. Cancel, timeout, view dismissal and stale browser completions release/fence the attempt.
- Cryptographic state, nonce, PKCE S256 and stable host UUID; exact redirect and one-time callback consumption. Issued client ID is persisted before code exchange. Initial dynamic registration uses the actual app name Actell; later sign-in reuses the selected registration. An explicit Enable plan usage action requests consent; routine sign-in does not force it.
- ID-token JWS signature verification against the fixed official JWKS; RS256/RSA and ES256/P-256 only, unique matching kid, algorithm/key constraints, exact issuer, issued-client audience/azp, expiry, iat/nbf, nonce and optional at_hash. Unsupported algorithms fail closed. Returning registration must match its verified identity. No JWT header URL controls key fetching.
- Non-synchronizing Keychain vault, WhenUnlockedThisDeviceOnly, app-private service namespace; separate records keyed by issued-client-ID + verified issuer + subject. Tokens never enter provider defaults, logs, checkpoints or UI. Stable host and provisional registration are durable before authorization/exchange. Whole-vault SecItemUpdate/initial Add makes rotated access/refresh/scopes/expiry replacement atomic. App Intents do not expose these APIs.
- Account/workspace picker; account changes invalidate model cache and configured model. In-flight requests also bind to the account and a profile selection generation, so switching away and back does not restore an old request. A signed identity without both resource.invoke and chatgpt.tokens.use.direct remains connected with plan usage disabled.
- Shared actor serializes refreshes by account, retains temporary-failure credentials, clears unusable refresh tokens, preserves registration for reauthorization and stops use after rotation persistence failure. No automatic inference replay or billing fallback.
- Logout stops use first and follows the trusted revocation_endpoint published by official OIDC discovery when present. Local secrets are cleared and registration retained. If revocation is not confirmed, UI explicitly says so and points users to ChatGPT Settings; it does not claim server permission was revoked.
- Account-specific model discovery uses visible slug/display_name entries from /v1/models in server order. Catalogs include a non-secret account hash in their scope. Runtime requires a model from that account's catalog.
- Dedicated subscription request adapter fixes POST /v1/responses, stream=true/store=false, history array and instructions. Unsupported sampling/output/background/storage fields are omitted/rejected. Functions use an actell namespace; responses must match that namespace and a known local tool. Existing codec/reducer and ContextCoordinator preserve local native output/reasoning/tool replay and only commit complete, executable terminal snapshots. Failed/incomplete/EOF/unknown namespace/cancellation never release tools for execution. No previous_response_id and no hosted tools.
- Reasoning effort is provider/model scoped and validated against declared capabilities before Responses reasoning.effort mapping. Exact gpt-6.1-sol on official Responses has a documented low/medium/high/xhigh/max, medium-default fallback. Unknown/proxy models get no guessed list. Switching models retains only their own settings. Subscription rejects other model parameter values.

## Official contract and practical limits

[Open-source plan usage](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt) allows eligible local OSS/personal tools. Commercial/remote hosting needs separate access. Identity is not plan permission, and neither every model nor unlimited usage is promised. Other providers retain their own billing.

[Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions), [token reference](https://developers.openai.com/siwc/token-sharing-open-source/token-reference) and [OIDC/JWKS](https://developers.openai.com/siwc/website) define the authorization, identity and renewable-session contract. Tokens/registration were not acquired during development.

[Models/inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [preview limits](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations), [errors](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery) and [function namespaces](https://developers.openai.com/api/docs/guides/function-calling) define the implemented HTTP subset. No Codex client ID, cookies, private backend API or API-key-as-subscription shortcut is used.

[Reasoning](https://developers.openai.com/api/docs/guides/reasoning) and [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol) describe reasoning parameters. Effort metadata fields in model discovery are optional extensions, not guaranteed fields in the documented direct-route catalog.

No actual OAuth, dynamic registration, real token read/refresh/revocation, inference, account/model eligibility or subscription billing was exercised. User authorization occurs only when the user presses the production button. Physical-device and long-duration sign-in behavior are not verified. iOS 27 simulator mock proves three viable HTTP callback directions (ASWebAuthenticationSession with nil callback scheme, embedded system Safari, external Safari with recorded background transition), not an official custom-scheme/mobile contract or indefinite background lifetime. Production uses the foreground system authentication browser route.

## Stream and context compatibility

The subscription adapter validates terminal snapshots before releasing tools. Missing function status is normalized only at a completed item/response boundary. An explicitly empty terminal output may use already validated completed items from the same response only when all indexes, IDs, namespaces and completion states agree. Preview deltas, argument fragments, previous turns and conflicting nonempty output never qualify.

A missing Content-Type can be accepted only after a bounded, valid SSE prefix is recognized. Failed/incomplete streams, wrong namespaces, unknown tools and incomplete arguments still reject without retry or billing fallback.

Portable tool arguments use canonical JSON object encoding before context hashing. Key ordering and whitespace do not change identity; changed values, tool names, call IDs, receipts or account scope still invalidate the context. Native response replay and coordinator guards remain intact.

## Diagnostics and verification boundaries

The shared `LLMDiagnostics` logger uses category `LLM`. It records attempt IDs, fixed stages, structural metadata and allowlisted error codes; unknown labels are fingerprinted. It excludes credentials, account details, message/response bodies, reasoning, images and tool arguments. TLS errors are classified only within known security domains, and a connection label alone cannot identify the failing destination.

Signed synthetic identity tests cover OAuth claims, one-time callbacks, account isolation, refresh rotation, revocation outcomes and cancellation. Local image tests validate PNG/JPEG wire construction and tool correlation, not a model's actual vision support. Reproduced stream/context failures establish local compatibility fixes, not the cause of every reported device failure. Real account eligibility, authorization, billing and full device behavior require separate acceptance.
