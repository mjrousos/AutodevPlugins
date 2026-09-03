/**
 * Test-only stub for `@github/copilot-sdk/extension`.
 *
 * The real module is not installable: the CLI injects a resolver hook into the extension host
 * process, so `@github/copilot-sdk` exists only inside a running CLI. The unit tests import
 * `extension.mjs` for its pure helpers, which means the import has to resolve to something.
 *
 * `defineFactory` mirrors the real contract closely enough for the registration tests: it
 * returns a handle carrying deep-frozen metadata. `joinSession` throws, because
 * `extension.mjs` guards its call behind AUTODEV_FACTORY_TEST and a test that reaches this
 * would be testing a guard that had stopped working.
 */

export function defineFactory(definition) {
    return { meta: Object.freeze({ ...definition.meta }), run: definition.run };
}

export async function joinSession() {
    throw new Error("joinSession must not be called under test — the AUTODEV_FACTORY_TEST guard failed");
}
