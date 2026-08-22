## Sapira standards

This project is governed by the Sapira corpus: <https://github.com/ai-sapira-poc/sapira-standards>.

**The charter decides what applies.** Read `sapira.project.json` at the repo root first. Its `tier`,
`operating_model`, `lifecycle` and `control` decide which standards bind this repository at all —
reporting a violation of a standard the project never adopted is worse than reporting nothing
(`ENG-STD-0002`, `GEN-ADR-0003`).

**Before you open a pull request**, resolve the binding set rather than guessing at it:

```bash
# from a checkout of the corpus, against this repo's diff
node scripts/standards-for.mjs --charter <path-to-this-repo>/sapira.project.json \
                               --files "$(git diff --name-only --merge-base origin/main | paste -sd,)"
```

Or invoke the `review-against-standards` skill, which does this and then reviews the diff.

**Rules that hold regardless of the charter:**

- **Secrets never enter a file, a prompt, or a transcript** (`GEN-STD-0001`). The one standard with
  no exception path.
- **Cite by id and clause** — "violates `ENG-STD-0001` §3", never "violates our migration standard".
  Ids are stable and greppable; titles are not.
- **Never invent a standard.** If no standard covers something, say it is not covered. A fabricated
  `ENG-STD-` reference is worse than no review at all.
- **Never report a violation of a standard the resolver did not return.**
