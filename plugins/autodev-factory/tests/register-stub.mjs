/**
 * Installs the SDK resolver stub before the test files are loaded.
 *
 * Usage: node --import ./plugins/autodev-factory/tests/register-stub.mjs --test plugins/autodev-factory/tests/factory.tests.mjs
 */

import { register } from "node:module";

register("./resolve-sdk.mjs", import.meta.url);
