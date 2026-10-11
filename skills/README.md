# Claude Code skills

Copied from upstream [chasers/smolquery](https://github.com/chasers/smolquery)
`skills/`, because this repo plans in the same tracker: the smolsqls
database upstream dogfoods. This repo's rows are the project
`topology-examples` (`P-4`); its design doc is plan `PL-75`.

`.claude/` is git-ignored, so linking a skill in is a one-time local step:

```sh
./skills/install.sh            # link into ./.claude/skills (this repo)
./skills/install.sh --global   # link into ~/.claude/skills (any directory)
```

The tracker's credentials come from the environment, auto-loaded from the
git-ignored `.claude/smolquery-pm.env` (see `smolquery-pm/SKILL.md`). Get
them from the project owner; never commit them.

- **`query-db`**: the Elixir CLI that runs SQL against any smolsqls database.
- **`smolquery-pm`**: the tracker: projects, plans, tasks. Scope queries here
  to `p.slug = 'topology-examples'`.
