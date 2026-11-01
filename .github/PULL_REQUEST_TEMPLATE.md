<!-- Thanks for contributing! Small pull requests are welcome and easy to review. -->

## What does this change?

<!-- One or two sentences. Link the issue it closes, e.g. "Closes #123". -->

## Type of change

- [ ] Catalog entry (a new or corrected cache location)
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] Build, CI or tooling

## How did you check it?

<!-- Say what you ran and what you saw. Delete the lines that do not apply. -->

- [ ] `./build.sh` (Zig core)
- [ ] `./make-app.sh` and opened the app (UI changes)
- [ ] `./test-incremental.sh` (scanning changes)
- [ ] `./test-git.sh` (git check changes)
- [ ] Compared `dev-cache-clean scan` with `find` and `du` on a folder I can spare

## Catalog changes only

<!-- Skip this section if you did not touch src/catalog.zig or src/targets.zig. -->

- [ ] I checked that the path exists (link to docs, the tool's source, or `du -sh` output below)
- [ ] The category and risk are right: `careful` for anything holding history, sessions or work the user may want back
- [ ] The "what you lose" text is plain and true
- [ ] The path holds no credentials, tokens or settings, only data the tool can rebuild or history
- [ ] I updated `docs/CATALOG.md`

## Safety

- [ ] Nothing here can delete a file the user did not select
- [ ] Removal still goes through the Trash or an explicit confirmation that says it is permanent
- [ ] The app still makes no network requests

## Screenshots

<!-- For UI changes. Use example data, not your real paths or project names. -->

## Notes for the reviewer

<!-- Anything you were unsure about, or that could not be tested (for example Linux or Windows). -->
