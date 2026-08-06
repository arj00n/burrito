# Publishing Burrito updates

Burrito uses Sparkle 2 with EdDSA verification. The private update key is stored
in the macOS Keychain that generated it; only the public key is committed to the
application.

1. Increment both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the
   Burrito target. The build number must increase for every published update.
2. Export the Release build using one of these paths:
   - Preferred: Developer ID-sign and notarize it with Apple.
   - Free distribution: ad-hoc sign it with
     `scripts/adhoc-sign.sh /path/to/Burrito.app`. This does not remove
     Gatekeeper's first-launch warning; users must approve the app manually.
3. Export `Burrito.app`, then run:

   ```sh
   scripts/prepare-update.sh 1.1 /path/to/Burrito.app
   ```

4. Create the GitHub Release using the exact command printed by the script.
5. Commit and push the generated `appcast.xml` to `main` only after the release
   asset is available.

Installed OTA-enabled builds check the HTTPS appcast once every 24 hours. Users
can also right-click Burrito's menu-bar icon and choose **Check for Updates…**.
Builds distributed before Sparkle was integrated require one final manual update.

## Unsigned first installation

There is no distributor-controlled way to suppress Gatekeeper for an app that
does not have an Apple-issued Developer ID signature. Tell users to Control-click
the app, choose **Open**, and confirm, or use **System Settings → Privacy &
Security → Open Anyway** after the first blocked launch. Do not ask users to
disable Gatekeeper globally.
