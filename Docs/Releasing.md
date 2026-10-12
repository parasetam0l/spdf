# Building a signed release

The GitHub Actions Release workflow builds the application, signs it with Developer ID, notarizes and staples the app and DMG, and creates a draft release. It calls Appcast to sign the final DMG, verify the signature against the packaged public key, and attach `appcast.xml` and a release manifest before publication.

## Repository secrets

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | Original `.p12` password |
| `NOTARY_APPLE_ID` | Apple ID email used for notarization |
| `NOTARY_PASSWORD` | Apple app-specific password |
| `SPARKLE_PRIVATE_KEY` | Exported Sparkle EdDSA private seed; already base64-encoded |

No VPN provisioning profiles are required. The workflows use their built-in GitHub token with `contents: write` for release uploads.

To upload secrets without saving a GitHub CLI login, install `gh` and create a fine-grained token restricted to this repository with **Secrets: Read and write**. From an interactive terminal:

```sh
bash Scripts/setup-ci-secrets.sh /path/to/developer-id.p12
```

The setup prompts privately, encodes the certificate automatically, validates the identity, uploads the five secrets through stdin, and verifies their names. Passwords and the Apple ID are entered normally. The setup token is not saved or placed in CI.

The setup expects an exported Sparkle key under the ignored `Work/SparkleKeys/spdf-update-key`, matching `SUPublicEDKey` in both `project.yml` and `App/Info.plist`. Keep a private backup. Never generate a replacement key for an existing release without planning a compatible rotation.

The application bundle identifier, Developer ID team, update feed, and public key must agree with the release workflow and build configuration. If maintaining a fork, configure your own identity and update feed before distributing a build.

## Prepare and publish

1. Push a tested source revision; the Build and test workflow must pass.
2. Start Actions → Release → Run workflow with a version such as `0.1.0`.
3. Review the resulting draft, DMG, checksums, appcast, and manifest. Verify notarization and installation.
4. Publish the reviewed draft manually. Published assets and feed URLs must remain publicly reachable.
5. Verify the latest-feed redirect and a real version-to-version update on an installed copy, including unsaved work and relaunch behavior.

Appcast also supports manual dispatch with a tag for trusted feed repair. Keep published binary bytes immutable; a corrected binary receives a new version. Update the pinned Sparkle package and tools together after verifying the tools archive checksum.

Local ad-hoc builds and automated policy tests do not replace a quarantined installation, Gatekeeper validation, and a real Sparkle update test.
