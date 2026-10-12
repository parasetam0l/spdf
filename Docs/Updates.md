# Application updates

Release builds use Sparkle 2.10.0 and the public GitHub Releases feed:

`https://github.com/parasetam0l/spdf/releases/latest/download/appcast.xml`

Debug builds do not check for updates. Release builds ask whether to check automatically; when allowed, checks run daily. Check for Updates is also available from the application menu. Automatic installation is disabled, so an update asks for confirmation.

## Update verification

Each published update archive carries a Sparkle EdDSA signature checked against the public key embedded in the app. Developer ID signing provides a separate trust check. No GitHub credential is embedded in the application.

The release workflow prepares a signed, notarized DMG and attaches its appcast before the draft is published. Draft releases are not served by the latest-release feed. Version-specific asset URLs identify the actual download.

## Installation and recovery

Install published builds by dragging the application from the DMG into Applications. Resolve unsaved work before installing a development preview update. Live testing of every save, cancellation, background-job, restoration, and installation-location path is still being completed.

To return to an older build, download its published DMG, quit the app, replace it, and reopen. The updater does not perform downgrades. Back up preferences and recovery state before rollback; replacing the application does not change document files.

Delta updates, beta channels, and App Sandbox distribution are not currently offered.
