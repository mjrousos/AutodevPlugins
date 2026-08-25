/**
 * sample-review — a small Agent Factory, meant to be read.
 *
 * It does one recognisable thing: fan out a few reviewers across different lenses, then have each
 * finding attacked by independent skeptics before it is reported. Findings a majority of skeptics
 * fail to refute are returned as confirmed; the rest are returned as unconfirmed, not deleted.
 *
 * The point is the *shape*, not the review. Every primitive a real factory needs appears exactly
 * once and is commented where it is used:
 *
 *   ctx.step      pin a non-deterministic value so a resumed run replays it        (Intake)
 *   ctx.pipeline  per-item flow with no barrier between stages                     (Review)
 *   ctx.agent     one factory-scoped subagent, with a structured-output schema     (both stages)
 *   ctx.parallel  a barrier fan-out, nested inside a pipeline stage                (verification)
 *   ctx.phase     run-global progress                                              (three times)
 *   ctx.log       an audit trail for everything this factory silently drops        (throughout)
 *
 * The three ways a factory fails *silently* are marked `GOTCHA` below. They are the reason this
 * sample exists. See README.md for the long version.
 *
 * @see https://github.com/mjrousos/AutodevPlugins/blob/main/samples/factory-review/README.md
 */

import { joinSession, defineFactory } from "@github/copilot-sdk/extension";

/* -------------------------------------------------------------------------------------------
 * Schemas.
 *
 * `schema` is a structural SUBSET of JSON Schema, not a validator. Honoured: type, required,
 * enum, const, recursive properties/items, and anyOf/oneOf/allOf. Silently IGNORED: pattern,
 * format, minLength/maxLength, numeric ranges, and additionalProperties. So `required` earns its
 * keep here and a `minLength: 1` on a title would not — which is why the code below still checks
 * that a title is a non-empty string by hand.
 * ------------------------------------------------------------------------------------------- */

const FINDINGS = {
    type: "object",
    properties: {
        findings: {
            type: "array",
            items: {
                type: "object",
                properties: {
                    title: { type: "string" },
                    where: { type: "string" },
                    why: { type: "string" },
                },
                required: ["title"],
            },
        },
    },
    required: ["findings"],
};

const VERDICT = {
    type: "object",
    properties: {
        refuted: { type: "boolean" },
        reason: { type: "string" },
    },
    required: ["refuted"],
};

/* -------------------------------------------------------------------------------------------
 * Configuration.
 *
 * The caps are the real cost control. `meta.limits` is deliberately left undeclared (see the
 * README): a declared ceiling that is too low ends a legitimate run, so the safety ceiling
 * belongs to whoever invokes the factory, while the factory bounds its own fan-out with counters.
 * ------------------------------------------------------------------------------------------- */

const DEFAULT_TARGET = "the code most recently changed in this repository's working tree";
const DEFAULT_LENSES = ["correctness", "security"];

/**
 * One question per skeptic. These differ on purpose. Identical prompts would memoize into a
 * single subagent (see GOTCHA 1), so "three verifiers" would quietly become one verifier counted
 * three times — and a unanimous vote from one agent is not a vote.
 */
const VERIFIER_ANGLES = [
    "Does this actually reproduce? Walk the specific code path that would trigger it.",
    "Is the cited code really doing what the claim says? Re-read it before you answer.",
    "Would a maintainer of this project call this a defect, or a deliberate trade-off?",
];

const CAPS = { lenses: 5, maxFindings: 5, verifiers: VERIFIER_ANGLES.length };
const DEFAULTS = { maxFindings: 2, verifiers: 2 };

/* -------------------------------------------------------------------------------------------
 * Helpers. Plain JavaScript — no factory API in here.
 * ------------------------------------------------------------------------------------------- */

function clampInt(value, min, max, fallback) {
    if (!Number.isFinite(value)) return fallback;
    return Math.max(min, Math.min(max, Math.trunc(value)));
}

/**
 * clampInt, plus the log line that makes it honest.
 *
 * `ctx.args` arrives from an untyped tool parameter, so a model passing `"4"` instead of `4` is a
 * routine event, not an exotic one — and it lands on the fallback. A caller whose argument was
 * rejected or clamped gets told which value actually took effect, under the same "no silent caps"
 * rule the dropped findings follow.
 */
function clampedArg(ctx, name, value, min, max, fallback) {
    const result = clampInt(value, min, max, fallback);
    if (value !== undefined && value !== result) {
        ctx.log(`\`${name}\`: ${JSON.stringify(value) ?? "undefined"} is not a whole number between ${min} and ${max}; using ${result}.`);
    }
    return result;
}

/** Case-insensitive dedupe. Duplicate lenses would produce duplicate labels — see GOTCHA 1. */
function dedupe(values) {
    const seen = new Set();
    const out = [];
    for (const value of values) {
        const key = value.toLowerCase();
        if (seen.has(key)) continue;
        seen.add(key);
        out.push(value);
    }
    return out;
}

function isPlainObject(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmptyString(value) {
    return typeof value === "string" && value.trim() ? value.trim() : "";
}

function finderPrompt(target, lens, maxFindings) {
    return [
        `Review ${target}.`,
        "",
        `Look ONLY for ${lens} problems. Another reviewer covers every other category, so ignore them.`,
        "Read the relevant code yourself before answering. Do not guess, and do not describe what you would look for.",
        `Report at most ${maxFindings} findings, most serious first. Reporting nothing is a valid and useful answer — do not pad the list.`,
        "",
        'Return JSON: {"findings":[{"title":"one line","where":"file:line or the symbol name","why":"one or two sentences"}]}',
    ].join("\n");
}

function verifierPrompt(target, finding, angle) {
    return [
        `A reviewer of ${target} claims to have found a problem. Your job is to REFUTE it.`,
        "",
        `Claim: ${finding.title}`,
        `Where: ${finding.where || "unspecified"}`,
        `Their reasoning: ${finding.why || "unspecified"}`,
        "",
        `Attack it from this angle: ${angle}`,
        "",
        "Read the code yourself. If you cannot confirm the claim directly from the code, it is refuted.",
        "Default to refuted when you are uncertain. An unrefuted claim should be one you actively verified.",
        "",
        'Return JSON: {"refuted":true|false,"reason":"one sentence"}',
    ].join("\n");
}

/* -------------------------------------------------------------------------------------------
 * The factory.
 * ------------------------------------------------------------------------------------------- */

const sampleReview = defineFactory({
    meta: {
        name: "sample-review",

        // There is no declared schema for ctx.args — `run_factory` forwards them verbatim and its
        // parameter is untyped. This description is therefore the ONLY thing telling a model what
        // to pass, which is why the argument shape is spelled out in it.
        description: [
            "Teaching sample. Reviews a target through several independent lenses in parallel, then has",
            "each finding attacked by independent skeptics before reporting it. Findings a majority of",
            "skeptics fail to refute come back confirmed; the rest come back unconfirmed rather than deleted.",
            "",
            "args: {",
            "  target?: string       — what to review: a file path, a directory, a diff, or a description.",
            `                          Defaults to "${DEFAULT_TARGET}".`,
            "  lenses?: string[]     — review dimensions, one finder subagent each. Case-insensitively",
            `                          deduplicated and capped at ${CAPS.lenses}. Defaults to ["${DEFAULT_LENSES.join('", "')}"].`,
            `  maxFindings?: number  — findings per lens carried into verification, 1-${CAPS.maxFindings}. Defaults to ${DEFAULTS.maxFindings}.`,
            `  verifiers?: number    — independent skeptics per finding, 1-${CAPS.verifiers}. Defaults to ${DEFAULTS.verifiers}.`,
            "}",
            "",
            "Issues up to lenses + (lenses x maxFindings x verifiers) agent calls — 10 at the defaults.",
            "Every call uses a schema, and a schema call may retry once, so budget up to twice that many",
            "subagent admissions against maxTotalSubagents. Pass `limits` to run_factory to set a ceiling;",
            "the factory declares none of its own.",
        ].join("\n"),

        phases: [
            { title: "Intake", detail: "Validate arguments and pin the run's baseline" },
            { title: "Review", detail: "One finder per lens; verify each finding as soon as it lands" },
            { title: "Report", detail: "Tally the votes and summarise" },
        ],
    },

    run: async (ctx) => {
        /* --- Intake ----------------------------------------------------------------------
         * ctx.args is forwarded verbatim from an untyped tool parameter, so it is untrusted
         * input: validate it, never destructure it hopefully.
         */
        ctx.phase("Intake");

        const args = isPlainObject(ctx.args) ? ctx.args : {};
        if (!isPlainObject(ctx.args)) {
            ctx.log(`Ignored \`args\` (${JSON.stringify(ctx.args) ?? "undefined"}): expected a JSON object, so every default is in force.`);
        }

        const target = nonEmptyString(args.target) || DEFAULT_TARGET;
        if (args.target !== undefined && !nonEmptyString(args.target)) {
            ctx.log(`Ignored \`target\` (${JSON.stringify(args.target) ?? "undefined"}): expected a non-empty string, so the default target is in force.`);
        }

        const rawLenses = Array.isArray(args.lenses) ? args.lenses : [];
        const requested = rawLenses.map(nonEmptyString).filter(Boolean);
        const deduped = dedupe(requested.length ? requested : DEFAULT_LENSES);
        const lenses = deduped.slice(0, CAPS.lenses);

        // A rejected argument is a dropped request, so it gets a log line like every other drop.
        // `lenses: "correctness,security"` — a bare string rather than an array — is the mistake a
        // model actually makes, and without this it would be discarded without a word.
        if (args.lenses !== undefined && !requested.length) {
            ctx.log(`Ignored \`lenses\` (${JSON.stringify(args.lenses) ?? "undefined"}): no usable lens names in it, so the defaults are in force.`);
        } else if (rawLenses.length > requested.length) {
            ctx.log(`Dropped ${rawLenses.length - requested.length} \`lenses\` entr(ies) that were not non-empty strings.`);
        }
        if (requested.length > deduped.length) {
            ctx.log(`Dropped ${requested.length - deduped.length} duplicate lens name(s); duplicates would have collapsed into one subagent.`);
        }
        if (deduped.length > lenses.length) {
            ctx.log(`Capped at ${CAPS.lenses} lenses; dropped ${deduped.slice(CAPS.lenses).join(", ")}.`);
        }

        const maxFindings = clampedArg(ctx, "maxFindings", args.maxFindings, 1, CAPS.maxFindings, DEFAULTS.maxFindings);
        const verifiers = clampedArg(ctx, "verifiers", args.verifiers, 1, CAPS.verifiers, DEFAULTS.verifiers);

        // ctx.step journals its producer's JSON result under a stable key, so a resumed run
        // replays the cached value instead of re-running the producer. That is exactly what a
        // clock needs: without this, resuming after a limit breach would silently re-date the
        // run and the report would claim a start time the run did not have.
        //
        // The key is the SOLE identity — not the producer body, not its inputs. Version it
        // ("baseline-v2") whenever its meaning changes, or a resume will replay a stale value
        // from the old meaning. Pass { volatile: true } for a producer that must run every time.
        const baseline = await ctx.step("baseline-v1", () => ({
            startedAt: new Date().toISOString(),
            target,
        }));

        ctx.log(`Reviewing ${target} through ${lenses.length} lens(es): ${lenses.join(", ")}.`);
        ctx.log(`Budget: <=${lenses.length} finder(s) + <=${lenses.length * maxFindings * verifiers} verifier(s).`);

        /* --- Review ----------------------------------------------------------------------
         * ctx.phase sets ONE run-global value, so calling it from inside a concurrent stage is a
         * race. Set it here, at the run-level transition, and tell concurrent work apart by
         * `label` instead.
         */
        ctx.phase("Review");

        // ctx.pipeline, not ctx.parallel: there is no barrier between the stages, so a lens whose
        // finder returns quickly starts verifying while a slower lens is still searching. A
        // barrier here would make every finding wait for the slowest finder for no benefit —
        // nothing in stage 2 needs to see the other lenses' results. (See README for when a
        // barrier *is* the right call.)
        const perLens = await ctx.pipeline(
            lenses,

            // Stage 1 — one finder per lens. A stage receives (previous, item, index); for the
            // first stage `previous` IS the item, which is why this takes a single parameter.
            (lens) => ctx.agent(finderPrompt(target, lens, maxFindings), {
                // GOTCHA 1: identical prompt + options memoize into ONE shared subagent, even
                // when issued concurrently. A unique label is what makes these independent.
                label: `find:${lens}`,
                schema: FINDINGS,
            }),

            // Stage 2 — attack this lens's findings without waiting for any other lens.
            async (review, lens) => {
                // GOTCHA 2: an ordinary subagent failure resolves to `null`; it does not throw.
                // An error, an empty response, or output that still fails the schema after its
                // one automatic retry all arrive here as `null`. Only cancellation, a reached
                // limit, and hard runtime failures reject and abort the run.
                if (!review) {
                    ctx.log(`find:${lens} produced nothing; that lens contributed no findings.`);
                    return [];
                }

                const found = (Array.isArray(review.findings) ? review.findings : [])
                    .filter((f) => isPlainObject(f) && nonEmptyString(f.title));
                const kept = found.slice(0, maxFindings);

                // No silent caps: whenever the factory bounds its own coverage, say so.
                if (found.length > kept.length) {
                    ctx.log(`find:${lens} returned ${found.length} findings; verifying ${kept.length} and dropping ${found.length - kept.length}.`);
                }
                if (!kept.length) {
                    ctx.log(`find:${lens} found nothing to verify.`);
                    return [];
                }

                // A barrier IS correct here: the vote cannot be tallied until every skeptic on
                // this one finding has reported. It is a small barrier, over `verifiers` items,
                // nested inside the pipeline — so it never blocks another lens.
                return ctx.parallel(kept.map((finding, i) => async () => {
                    const verdicts = await ctx.parallel(
                        Array.from({ length: verifiers }, (_, v) => () =>
                            ctx.agent(verifierPrompt(target, finding, VERIFIER_ANGLES[v % VERIFIER_ANGLES.length]), {
                                label: `verify:${lens}:${i}:${v}`,
                                schema: VERDICT,
                            })),
                    );

                    // GOTCHA 3: filter with `v => v !== null`, never with Boolean — Boolean also
                    // discards a legitimate `false`, `0`, or `""`. It costs nothing here and is
                    // a data-loss bug the moment a schema returns a bare boolean.
                    const votes = verdicts.filter((v) => v !== null && isPlainObject(v));

                    // A skeptic that never answered ABSTAINS — it does not acquit. So the quorum
                    // is a strict majority of the skeptics that were *requested*, not of however
                    // many happened to answer. Dividing by `votes.length` instead would quietly
                    // lower the bar exactly when the evidence got weaker: with 3 verifiers and 2
                    // failures, a single unrefuted vote would "win 1-0" and promote the finding.
                    const quorum = Math.floor(verifiers / 2) + 1;
                    const supporting = votes.filter((v) => v.refuted !== true).length;
                    const refuting = votes.filter((v) => v.refuted === true).length;
                    const confirmed = supporting >= quorum;

                    if (votes.length < verifiers) {
                        ctx.log(`verify:${lens}:${i} — ${verifiers - votes.length} of ${verifiers} skeptic(s) returned no verdict; they abstain, and "${finding.title}" still needs ${quorum} supporting vote(s).`);
                    }

                    return {
                        lens,
                        title: nonEmptyString(finding.title),
                        where: nonEmptyString(finding.where) || null,
                        why: nonEmptyString(finding.why) || null,
                        confirmed,
                        votes: { requested: verifiers, responded: votes.length, supporting, refuting, quorum },
                        objections: votes
                            .filter((v) => v.refuted === true && nonEmptyString(v.reason))
                            .map((v) => nonEmptyString(v.reason)),
                    };
                }));
            },
        );

        /* --- Report ---------------------------------------------------------------------- */
        ctx.phase("Report");

        // `perLens` is one entry per lens; an entry is `null` if that lens's stage threw outright.
        const findings = perLens.flat().filter((v) => v !== null && isPlainObject(v));
        const confirmed = findings.filter((f) => f.confirmed);

        ctx.log(`${confirmed.length} of ${findings.length} finding(s) survived verification.`);

        return {
            runId: ctx.runId,
            startedAt: baseline.startedAt,
            target,
            lenses,
            settings: { maxFindings, verifiers },
            confirmed,
            unconfirmed: findings.filter((f) => !f.confirmed),
            summary: findings.length
                ? `${confirmed.length} of ${findings.length} finding(s) survived verification across ${lenses.length} lens(es).`
                : `No findings were reported across ${lenses.length} lens(es).`,
        };
    },
});

await joinSession({ factories: [sampleReview] });
