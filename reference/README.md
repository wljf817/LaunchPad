# Reference

Measured facts about the macOS 15 Launchpad, which this project reproduces. Every visual constant or animation parameter in the code cites an entry here by ID in a comment, for example `// REF-OVERLAY-003`. Specs cite the same IDs.

## What belongs here

- Facts and numbers only: values with units, animation timing parameters, class and method names, file paths, preference keys, observed behavior.
- Never Apple code, decompiled output, pseudocode, disassembly, or assets taken from Apple binaries (images, sounds, nibs, string tables). Those stay in the local, untracked `research/` directory.

## IDs

IDs have the form `REF-<AREA>-<NNN>`:

- `AREA` is one of the areas in the table below.
- `NNN` is a three-digit number, assigned in order within the area, starting at `001`.
- IDs are permanent. Never renumber or reuse one. When a value is re-measured, update the entry in place and say so in Notes.

| Area | File | Covers |
|---|---|---|
| `ENV` | `environment.md` | Reference environment: system version, virtualization, instrumentation |
| `ARCH` | `arch.md` | Where and how the original is implemented: binaries, processes, classes |
| `OVERLAY` | `overlay.md` | Opening and closing, the full-screen overlay, the background |
| `GRID` | `grid.md` | App grid layout |
| `PAGING` | `paging.md` | Pages, the page indicator, switching pages |
| `SEARCH` | `search.md` | Search field and results |
| `LAUNCH` | `launch.md` | Launching an app |
| `KEYBOARD` | `keyboard.md` | Keyboard navigation |
| `EDIT` | `edit.md` | Edit mode, dragging and reordering |
| `FOLDER` | `folder.md` | Folders |
| `LAYOUT` | `layout.md` | Saved layout, installed and removed apps, importing the macOS 15 layout |
| `DEV` | `deviations.md` | Known deviations (see below) |

An area's file is created together with its first entry. To add an area, add a row to this table first.

## Entries

Each entry is a level-2 heading with the ID and a short name, followed by these fields in this order:

- **Status:** `measured` or `TODO(measure)`.
- **Value:** the fact, with units. Use a list or a table when it has several parts. `TODO(measure)` until measured, never a guess.
- **Source:** how it was obtained: the method (Frida dump, static analysis, frame measurement of a recording, `defaults read`, observation), the tool or script under `tools/`, and where the raw evidence sits in `research/`.
- **Environment:** the REF-ENV entries it was measured under, such as `REF-ENV-001`. `—` on REF-ENV entries themselves.
- **Date:** the measurement date as `YYYY-MM-DD`. `—` while `TODO(measure)`.
- **Notes:** optional. Caveats and re-measurement history.

An entry with status `TODO(measure)` reserves its ID, so a spec can cite a value before it is measured. When only some parts of a value are measured, the unmeasured parts read `TODO(measure)`, the status stays `TODO(measure)` and the date stays `—`; Notes say when the measured parts were taken.

Example of a reserved entry (`NNN` stands for the next free number):

```markdown
## REF-OVERLAY-NNN Overlay fade-in duration

- **Status:** TODO(measure)
- **Value:** TODO(measure)
- **Source:** Frida dump of the open animation (`tools/re/…`), evidence in `research/macos-<version>-<build>/…`
- **Environment:** REF-ENV-001, REF-ENV-003
- **Date:** —
```

## Known deviations

Differences from the original that cannot be removed are entries in `deviations.md`, with IDs `REF-DEV-<NNN>` and these fields in this order:

- **Affects:** the REF IDs involved.
- **Original:** what macOS 15 does, as facts.
- **LaunchPad:** what this project does instead.
- **Reason:** why the difference cannot be removed.
- **Date:** the date it was recorded, as `YYYY-MM-DD`.
