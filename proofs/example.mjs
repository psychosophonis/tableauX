// example.mjs — a worked falsification probe (the PROVE step, and a learning artifact).
//
// IDEA AT RISK: "a running average can be updated incrementally without keeping
// every past value." If false, code that relies on it would silently drift.
//
// WHAT WOULD FALSIFY IT: if the incremental result and the naive (store-all)
// result disagree on the same data, the idea is dead. Naming this condition is
// the point — you cannot write the probe without first saying what would make
// the idea false, and saying that is what makes you understand the claim.
//
// HOW THIS TRIES TO KILL IT: compute the mean both ways over the same data and
// check they AGREE. Testing the PRINCIPLE (not an implementation) means a
// survival result holds in any language you later build it in.
//
// WHAT IT TEACHES: if it survives, you have *earned* (not assumed) the right to
// store one running figure instead of the whole history — and you watched it be
// earned. Run: node proofs/example.mjs

/**
 * Incremental mean update.
 *
 * Concept: this is a RUNNING / ONLINE mean — each new value adjusts the average
 * by its distance from the current average, scaled by 1/n. The point worth
 * proving is that this is EXACT, not approximate: it equals the naive sum/n, so
 * you never need to store the history. (This is the same shape as one step of
 * Welford's algorithm for online variance.)
 *
 * @param mean - the mean so far
 * @param value - the new value
 * @param n - the new count (including this value)
 * @returns the updated mean
 */
function updateMean(mean, value, n) {
  return mean + (value - mean) / n;
}

const data = [3, 1, 4, 1, 5, 9, 2, 6];

// Naive: sum everything, divide once.
const naive = data.reduce((a, b) => a + b, 0) / data.length;

// Incremental: never hold the history, just the running figure.
let running = 0;
data.forEach((v, i) => { running = updateMean(running, v, i + 1); });

const agree = Math.abs(naive - running) < 1e-12;
console.log(`naive=${naive}  incremental=${running}  agree=${agree}`);
console.log(agree
  ? '\u2713 idea survived: incremental mean is exact — safe to build on.'
  : '\u2717 idea FALSIFIED: the two disagree — do not build on this.');
process.exit(agree ? 0 : 1);
