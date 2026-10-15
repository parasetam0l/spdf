# Application updates

Release builds use Sparkle 2.10.0 and the public GitHub Releases feed:

`https://github.com/parasetam0l/spdf/releases/latest/download/appcast.xml`

Debug builds do not check for updates. Release builds ask whether to check automatically; when allowed, checks run daily. Check for Updates is also available from the application menu. Automatic installation is disabled, so an update asks for confirmation.

The application menu has one Settings command (Command-comma) for document defaults and updates. In releases through 0.1.2, this window was named Update Settings.

## Update verification

Each published update archive carries a Sparkle EdDSA signature checked against the public key embedded in the app. Developer ID signing provides a separate trust check. No GitHub credential is embedded in the application.

The release workflow prepares a signed, notarized DMG and attaches its appcast before the draft is published. Draft releases are not served by the latest-release feed. Version-specific asset URLs identify the actual download.

## Installation and recovery

Install published builds by dragging the application from the DMG into Applications. In-place updates require a writable installation outside Desktop. Desktop, read-only and macOS translocated copies provide installation guidance before checking for an update; the app and unsaved work stay open. Save your work, quit, move the app to Applications or another writable folder outside Desktop, and reopen it.

On a read-only copy, Check for Updates and Settings remain available to show these instructions even when Sparkle cannot start. A quarantined build must also pass Gatekeeper before the application can display guidance.

Before Quit or an update restarts the app, pending text and form input is committed and each modified document gets its native save decision. Canceling a save or Save As, a rejected edit, or a failed write keeps the app open. Windows close only after every document is ready.

When updating from 0.1.0 or 0.1.1, save your changes before choosing Install and Relaunch. Those versions may close an earlier window when a later save prompt is canceled, or fail to reopen document windows automatically after updating. Use File → Open to reopen the saved PDFs.

If OCR, an export, font preparation, or a save is active, choose to wait, cancel background jobs and wait, or keep working. Cancellation waits for the actual worker to finish; atomic saves finish their verified write. Completed export files remain in the destination folder. A deferred update can be resumed from Settings.

An update restart records saved file bookmarks and view metadata after all save decisions succeed. Relaunch reopens those files once and restores page/zoom/sidebar/window state and Settings. Protected PDFs follow your existing password and Keychain preferences; when no remembered credential is available, they reopen locked and resume their saved view after you unlock them. Missing files or access failures leave the files unchanged and provide File → Open guidance. Compatible metadata is retained for rollback; document contents and passwords are never part of this record.

Update settings and recovery records are stored outside the application bundle. The current formats remain compatible across updates: older recovery indexes and view records load optional fields with defaults. Compatible relaunch metadata is retained for rollback. Notarized, quarantined distribution is verified separately from local signed updates.

To return to an older build, download its published DMG, quit the app, replace it, and reopen. The updater does not perform downgrades. Back up preferences and recovery state before rollback; replacing the application does not change document files.

Delta updates, beta channels, and App Sandbox distribution are not currently offered.
