## What this changes

<!-- One paragraph. What behaviour is different after this than before it? -->

## Why

<!-- What problem does it solve? If it fixes an issue, link it. -->

## How it was tested

<!-- Be specific. "Tested on my server" is not a test; "restored 40 vehicles into the Pillbox
     underground car park on qb-core, 39 exact and 1 nudged 1.25m" is. -->

- Framework:
- Database driver:
- Game build:
- What was actually run:

## Checklist

- [ ] `python tools/check.py` passes
- [ ] No resource name appears outside `bridge/` or `config.lua`
- [ ] User-facing text is in **both** `locales/en.lua` and `locales/fr.lua`, key for key
- [ ] New config values have a comment saying what they cost to change
- [ ] `CHANGELOG.md` updated, if a server operator would notice this
- [ ] `ERROR_LOG.md` updated, if this fixes a non-trivial bug
- [ ] No version number was changed (releases are cut by the maintainer)
- [ ] No AI or assistant attribution anywhere in the diff
- [ ] No personal information in the diff or in the commit messages

## Anything else

<!-- Trade-offs you made, things you were unsure about, things a reviewer should look at hardest. -->
