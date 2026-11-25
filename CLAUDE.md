## Build and test

- `build.ps1` compiles `scripting\*.sp` and `tests\*.sp` into `plugins\` with the local server's `spcomp` (SourceMod 1.12).
- `test.ps1` runs `tests\damagereport_tests.sp` on a srcds test slot; `-WithClient` adds the real-client cases, `-InjectError` must fail. Operating srcds and the client: the `srcds-testing` skill.
- SourceMod sends panels with user-message hooks blocked, so the suite cannot read panel text. Panel cases check `GetClientMenu() == MenuSource_RawPanel`; report content is checked in chat mode, which prints the same text.

## Agent skills

- Issue tracker: GitHub Issues on `Ballganda/SourceMod-DMGreport` via `gh`. See `docs/agents/issue-tracker.md`.
- Triage labels: see `docs/agents/triage-labels.md`.
- Domain docs: see `docs/agents/domain.md`.
- Models: see `docs/agents/models.md`.
- Replies: to the user in chat. First line, when the message gave an instruction, decision or correction beyond a bare "yes": "Understood: <your interpretation>". Next line: the outcome, in one sentence. Then bullets, each a short clause holding exactly one fact; a reason, example or consequence gets its own bullet. Number them when the user answers per item. Each offer of further work is its own numbered item with a recommendation that "yes" accepts, as is each of two or more decisions. Use a table to compare items across attributes, a code block for code. Write prose when the user asks for an explanation. A subagent's Report follows its caller's format.
