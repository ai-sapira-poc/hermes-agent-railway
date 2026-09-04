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
