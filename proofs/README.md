# proofs/ — falsification probes (the PROVE step)

Before building on an idea that could be wrong, write the smallest runnable thing
that could show it is wrong, and run it. That artifact lives here.

## Why this exists
The cost of a wrong abstraction scales with how much you have built on it before
you find out. A probe moves that discovery as early and as cheap as possible —
tens of lines, before any real structure. This is falsification (Popper): you
make progress by trying to break an idea, not by accumulating support for it.

## What a probe is
- Tiny and standalone (a few dozen lines), runnable on its own.
- Tests the PRINCIPLE, not the implementation — so a survival result holds for
  every later implementation, in any language.
- Written to genuinely try to break the idea. A probe written to pass teaches
  nothing.

## What a probe is for
- If the idea survives: you may build on it, and the probe stays here as the
  record of WHY the idea is sound.
- If the idea dies: you just saved the cost of building the monolith on a bad
  abstraction. Delete it or keep it as a record of the dead end.

## Why probes are also the best teacher (andragogy)
A probe is not only risk-control — it is the most powerful learning artifact in
the project. A comment teaches a settled idea (pedagogy); a probe teaches the act
of *earning* an idea by trying to break it (andragogy — learning by testing a
belief against reality). To write an honest probe you must answer "what would
make this false?", and answering that is what turns acceptance into
understanding. The surviving probe is knowledge you watched being earned, and a
worked example of the method for the next reader. See the "probe as a learning
practice" section of docs/COMMENTING_STANDARD.md.

## Naming
`proofs/<idea>.<ext>` — e.g. `proofs/rhythm.mjs`. One probe per idea. Put a
comment at the top stating the idea at risk and how the probe tries to kill it.
