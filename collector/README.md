# collector

The OpenTelemetry collector for `hermes-agent-service`: the one door telemetry leaves through
([ENG-STD-0018 §4](https://github.com/ai-sapira-poc/sapira-standards/blob/main/departments/engineering/standards/ENG-STD-0018-telemetry-leaves-an-application-through-one-door.md)).
Redaction, sampling and project routing are decided here, so none of them live in application
code — which matters more than usual on this box, because the application code is **upstream
Hermes** and we do not own it.

Copied from the `otel-collector` blueprint; see [`ORIGIN.md`](ORIGIN.md).
Destination decided by `ENG-ADR-0007`: Arize Phoenix, self-hosted, reached over the private network.

```
hermes ──OTLP──▶ collector ──▶ Phoenix
                     │           project "default"       30d
                     └──▶       project "sapira-ledger"  180d
```

## Deployment record

`ENG-STD-0021 §8` wants a service's persistent state, ports and configuration written down, and
`§9` wants the pinned tag recorded where it can be inventoried.

| | |
|---|---|
| **Image** | `otel/opentelemetry-collector-contrib:0.160.0` — pinned, bumped deliberately |
| **Persistent state** | **None.** The collector buffers in memory and forwards; a restart loses at most one batch. Nothing here is worth a volume, and that is a property to preserve. |
| **Ports** | 4317 OTLP/gRPC · 4318 OTLP/HTTP · 13133 health. None public — reached only over Railway's private network. |
| **Signals** | **Traces only.** Metrics are rejected at the receiver; see below. |
| **Deployed by** | `railway up ./collector --path-as-root --service collector`. **Not** git-connected: `railway add --repo` returns Unauthorized and the CLI has no root-directory flag, so a redeploy is re-running that command from a checkout of `main`, not a push. |

## Configuration

| Variable | Value in this deployment |
|---|---|
| `SAPIRA_OTLP_ENDPOINT` | `http://phoenix.railway.internal:6006` |
| `SAPIRA_OTLP_AUTH_HEADER` | `Bearer <PHOENIX_ADMIN_SECRET>` — the **complete** header, not a bare token |

A bare token in `SAPIRA_OTLP_AUTH_HEADER` produces a 401 that reads like a broken endpoint rather
than a malformed header, which is a long afternoon.

## What was changed from the blueprint, and why

**A `routing` connector, because the blueprint duplicates every span.** A receiver fans out to every
pipeline that lists it, and the blueprint's `traces` and `traces/ledger` both read `[otlp]`. Posting
one span to a stock 0.160.0 with the blueprint config verbatim produced **two exports of one span**.
Both halves of the design fail at once: the sampler is bypassed, because all traffic still reaches
the store down the unsampled ledger path, and every ledger entry is duplicated into the sampled one.
One ingress pipeline now receives and routes; each span reaches exactly one egress.

**Receivers bind `[::]`, not `0.0.0.0`.** Railway's private network is IPv6-only and a Linux listener
on `0.0.0.0` does not accept IPv6. The collector would start, pass every check, and refuse every
connection Hermes made to it.

**Sampling is 100%, not 10%.** One agent, and the open question is whether anything arrives at all.
A rate that drops nine spans in ten is indistinguishable from a broken exporter. Turn it down once
the pipeline is boring.

**A `health_check` extension**, so a crash-looping collector does not read as healthy. Telemetry
that fails silently is worse than none.

## What zero-code gets wrong, and what it cannot know

Auto-instrumentation instruments the **SDK**, not the system. Two consequences, and they are
repaired in different places because only one of them is repairable.

**`gen_ai.provider.name` is wrong on every span, and repaired here.** openai-v2 reports the SDK, so
a call Hermes routes to Anthropic through OpenRouter arrives labelled `openai`. A panel grouped by
provider would have been wrong in the worst way: populated, plausible, never questioned. The
`transform/genai` processor derives it from `server.address` instead — the thing we actually
observe — and keeps the SDK's own claim on `sapira.gen_ai.provider.reported` rather than
overwriting it silently.

| `server.address` | `gen_ai.provider.name` |
|---|---|
| `openrouter.ai` | `openrouter` |
| `omniroute-production-f03d.up.railway.app` | `omni-route` |
| anything else | left as the SDK reported it |

Behind `omni-route` the upstream vendor is chosen per request by the gateway and is **not
observable from here**. `gen_ai.request.model` carries a vendor prefix (`anthropic/claude-opus-5`),
but that is what was *asked for*, not proof of who served it — treating it as the latter would
reintroduce exactly the false confidence this fixes.

Every clause is guarded on `gen_ai.operation.name`. Without that guard the httpx instrumentation's
span for the *same* request picks up a `gen_ai.*` attribute it has no business carrying, and the
store fills with GenAI-shaped rows that are not model calls.

**`sapira.run.id` and `sapira.ledger.key` are absent, and stay absent.** They mean "which agent run"
and "which ledger entry", and nothing at this layer knows either. Setting them here would put a
fabricated join key into a store people trust, which is worse than a missing column: a missing
column is visible. **For zero-code sources the correlation key is the trace id.** Closing this
properly needs P01 inside the application, which is not available for code we do not own.

`sapira.semconv.version` *is* stamped, as `zero-code-openai-v2@2.4b0`. It deliberately fails P01's
`isPinned()` regex rather than borrowing the authority of `sapira-otel@<version>+genai.<commit>`,
which asserts names hand-checked against a pinned upstream registry. These spans have no such claim
behind them, and a dashboard can now tell the two sources apart.

## Metrics have no store

Phoenix is a **trace** store. It answers `/v1/metrics` with `405`, so for the first four minutes
after Hermes was armed the collector exported metrics, was refused, and dropped them — 35 points,
and a permanent error loop that would have buried every error worth reading.

Both ends are now off: Hermes defaults `OTEL_METRICS_EXPORTER=none`, and this collector has no
metrics pipeline, so the OTLP receiver **rejects** metrics outright. That is the loud version of the
same truth, and better than a pipeline that looks configured and discards.

The gap is real, not a decision to leave metrics behind: `ENG-STD-0018` covers metrics and
`ENG-STD-0020 §2` floors them at 90 days. `ENG-ADR-0007` chose a *trace* store; nothing has chosen a
metrics store. Restore both ends with that decision, not before it.

## The ledger route is not reachable yet

`traces/ledger` routes on `instrumentation_scope.name == "@ai-sapira/action-ledger"`, and **no span
has ever carried that scope**. `@ai-sapira/action-ledger` writes to a `LedgerStore`, not to OTLP, so
the package that would produce those spans does not emit telemetry at all.

The route is here anyway, because the pipeline it protects is here and the alternative is a config
that silently sends ledger entries down the sampled path the day the ledger does start emitting.
It is a contract stated in advance, not a feature claimed. What is genuinely open is whether the
scope name is the right discriminator — `sapira.ledger.key` is not, because
[P01](https://github.com/ai-sapira-poc/sapira-blueprints/tree/main/packages/otel-sdk-ts) sets it on
ordinary spans to link them to their entry.

## Verified locally, not just validated

`otelcol-contrib validate` accepts the blueprint's broken config too — the fan-out is legal YAML and
a legal pipeline graph. What caught it was running 0.160.0 and counting exports. Both results:

| | Blueprint config | This config |
|---|---|---|
| 1 span in | **2 exports** | 1 export |
| app span | — | `openinference.project.name=default`, `api_key` → `****` |
| ledger-scope span | — | `openinference.project.name=sapira-ledger`, unsampled |

And end to end against the deployed Phoenix, with the zero-code instrumentation the Hermes side
uses: an `openai` SDK call produced `chat <model>` carrying `gen_ai.operation.name`,
`gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.usage.input_tokens` and
`gen_ai.usage.output_tokens`, all readable back out of Phoenix under those exact names. A planted
content canary appeared nowhere.
