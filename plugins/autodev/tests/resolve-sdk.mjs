/**
 * Module resolver that points `@github/copilot-sdk/extension` at the test stub.
 *
 * Registered with `node --import ./plugins/autodev/tests/register-stub.mjs`. Everything else
 * resolves normally.
 */

export async function resolve(specifier, context, nextResolve) {
    if (specifier === "@github/copilot-sdk/extension" || specifier === "@github/copilot-sdk") {
        return { url: new URL("./sdk-stub.mjs", import.meta.url).href, shortCircuit: true };
    }
    return nextResolve(specifier, context);
}
