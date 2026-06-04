# Azure DevOps extension — build & publish

This folder is the source for the **UnitAutogen Coverage** Azure Pipelines task,
published to the **Visual Studio Marketplace** (the Azure DevOps tab) — *not* the
Azure (cloud) Marketplace.

```
azure-devops-extension/
├─ vss-extension.json              # extension manifest (publisher, version, contributions)
├─ overview.md                     # the Marketplace listing page
├─ images/icon.png                 # extension icon (replace with a real 128x128 PNG)
└─ UnitAutogenCoverage/
   ├─ task.json                    # pipeline task definition (id GUID is permanent)
   ├─ run.ps1                      # installs the module + runs Invoke-UnitAutogen
   └─ icon.png                     # task icon (replace with a real 32x32 PNG)
```

## One-time setup
1. **Create a publisher** at https://marketplace.visualstudio.com/manage → set its ID
   in `vss-extension.json` → `publisher` (replace `YOUR_PUBLISHER_ID`).
2. Install the packaging CLI: `npm install -g tfx-cli`
3. **Replace the placeholder icons** in `images/icon.png` (128×128) and
   `UnitAutogenCoverage/icon.png` (32×32) — they're currently a copy of the social
   card and the wrong dimensions.

## Package
```bash
cd azure-devops-extension
tfx extension create --manifest-globs vss-extension.json
# -> produces YOUR_PUBLISHER_ID.unitautogen-coverage-0.9.9.vsix
```

## Publish
- **Easiest:** at https://marketplace.visualstudio.com/manage, select your publisher →
  **New extension → Azure DevOps** → upload the `.vsix`. Microsoft runs a virus scan
  before it goes live.
- **Or CLI:** `tfx extension publish --manifest-globs vss-extension.json --token <PAT>`
  (a Marketplace-scoped PAT).

## Test before going public
- Keep `"public": false` in the manifest (it already is) and **Share** the extension
  with your own Azure DevOps org from the manage portal, install it there, and run the
  task in a throwaway pipeline against a test database. Flip `"public": true` only once
  it works end to end.

## Versioning rules (important)
- Bump **`version`** in `vss-extension.json` AND the **`version`** in `task.json` on
  every publish (Marketplace rejects a re-publish of the same version). Keep them in
  step with the module/release version.
- **Never change** the task `id` GUID in `task.json` (`1699bdbe-…`) once published —
  it's the task's permanent identity; changing it breaks every pipeline that uses it
  (same rule as the module GUID).

## How it works at runtime
The task is a thin wrapper: on a Windows agent it installs the `UnitAutogen` module
from PSGallery (if absent), then runs `Invoke-UnitAutogen` with the step inputs,
writing `coverage.xml` / `test-results.xml` / `coverage-report.html` to the output
path for the native publish tasks. All the real work lives in the module + the
in-database parser — the extension just makes it a first-class, discoverable pipeline
step (and a Marketplace listing with an install count).
