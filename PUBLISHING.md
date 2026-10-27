# Publishing omni_ai to pub.dev

## Before the first release

1. **Pick the final name.** `omni_ai` was free on pub.dev when this was written. Check again at `https://pub.dev/packages/<name>`; if taken, change `name:` in `pubspec.yaml`, the `library` import in `example/pubspec.yaml`, and `package:omni_ai/...` imports.
2. **Fix the links** in `pubspec.yaml` (`homepage`, `repository`, `issue_tracker`, `documentation`) to your real GitHub repository, and push the code there. pub.dev shows these and scores them.
3. **Check the LICENSE** copyright line.
4. **(Recommended) Make a verified publisher** at https://pub.dev/create-publisher (you need a domain you own, verified in Google Search Console). Packages under a verified publisher show a ✓ badge. You can transfer the package to it later.

## Every release

1. Bump `version:` in `pubspec.yaml` ([semver](https://dart.dev/tools/pub/versioning): `0.1.1` for fixes, `0.2.0` for new features or breaking changes while below 1.0).
2. Add a section to `CHANGELOG.md` with the same version.
3. Check everything:

   ```bash
   dart format lib test example/lib
   flutter analyze
   flutter test
   flutter pub publish --dry-run
   ```

   The dry run lists the files that will be uploaded and any warnings (missing fields, too-large package — the limit is 100 MB compressed, files in `.gitignore`/`.pubignore` are left out).

4. Optional: preview the pub.dev score locally:

   ```bash
   dart pub global activate pana
   pana .
   ```

   Points come from: following Dart conventions (pubspec fields, README, CHANGELOG, example), documentation (`///` comments on public API), platform support, passing static analysis, and up-to-date dependencies.

5. Publish:

   ```bash
   flutter pub publish
   ```

   The first time, it opens a browser to sign in with the Google account that will own the package. **Publishing is permanent**: a version can't be deleted, only retracted within 7 days or the package marked discontinued.

## Automated publishing from GitHub (after the first release)

`.github/workflows/publish.yml` publishes when you push a tag like `v0.1.1`, with no secrets (GitHub's OIDC token proves the request).

1. Publish the first version by hand (above).
2. On `https://pub.dev/packages/omni_ai/admin` → **Automated publishing** → enable **GitHub Actions**, set the repository (`owner/repo`) and tag pattern `v{{version}}`.
3. Release:

   ```bash
   git tag v0.1.1
   git push origin v0.1.1
   ```

   The tag's version must equal `version:` in `pubspec.yaml`.

`.github/workflows/ci.yml` runs analyze, tests and a publish dry run on every push and pull request.

References: [Publishing packages](https://dart.dev/tools/pub/publishing) · [Automated publishing](https://dart.dev/tools/pub/automated-publishing) · [Verified publishers](https://dart.dev/tools/pub/verified-publishers) · [Package scores](https://pub.dev/help/scoring)
