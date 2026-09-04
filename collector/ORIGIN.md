# Origin

Copied from `sapira-blueprints/blueprints/otel-collector` @ `4240da83f6af8bb2586811f47711a59e4dc21b00`
on `2026-09-04`.

Per [ENG-STD-0021 §7](https://github.com/ai-sapira-poc/sapira-standards/blob/main/departments/engineering/standards/ENG-STD-0021-reusable-code-declares-its-reuse-form.md),
this file is the only obligation a blueprint carries. Divergence is expected and needs no note.

**One line beyond that.** The `redaction/secrets` block is a vendored artifact of
`@ai-sapira/otel-redaction`, so `ENG-STD-0021 §5` applies to it inside this copy: record the exact
source version it came from. A blueprint may go stale; a redaction pattern may not, and this stamp
is what makes a pattern update a push to this deployment rather than something the copy misses.

- Redaction patterns from `@ai-sapira/otel-redaction` version: `0.2.0`

**Why this stamp earned its keep, 2026-09-04.** At `0.1.0` this file recorded a version for a block
that had been pasted incomplete: the generator emits `redaction/secrets` *and* `transform/mask-values`,
and only the first was here. The stamp is what made it a one-line question -- diff what 0.1.0
generates against what this file contains -- rather than a reading of the whole config. A stamp that
records a version does not by itself prove the copy is faithful to it; see
`acceptance/credential-in-url.sh`, which does.

## Divergence worth pushing back

Everything here is allowed to drift except one thing, which is a **defect in the blueprint** rather
than an adaptation of it: the blueprint's two trace pipelines both read `[otlp]`, and a receiver
fans out to every pipeline that lists it, so each span went down both. That is fixed here with a
`routing` connector and should be fixed at the source. See `README.md`.
