# Autodev

Autodev is the consolidated planning + implementation plugin.

- Planning entry point: `autodev:autodev-plan`
- Implementation entry point: `autodev:autodev-implement`
- The same `autodev:` namespace also includes architecture/security/privacy planning reviewers and tasking/implementation/code-review/code-fix implementation workers.
- Hook enforcement stays split between dedicated gate (`autodev-gates.*`) and stage (`autodev-stages.*`) routers.
- The plugin contributes the `autodev-workflow` canvas extension.

## Installation

```text
/plugin marketplace add mjrousos/AutodevPlugins
/plugin install autodev@autodev-plugins
```

If `autodev-plan` or `autodev-implement` are installed from earlier releases, uninstall those before installing this merged plugin.

## Tests

```bash
bash plugins/autodev/tests/gates.tests.sh
bash plugins/autodev/tests/stages.tests.sh
node --test plugins/autodev/tests/workflow-canvas.tests.mjs
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\autodev\tests\gates.tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\autodev\tests\stages.tests.ps1
```
