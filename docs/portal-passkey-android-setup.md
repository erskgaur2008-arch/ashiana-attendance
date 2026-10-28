# Android passkey setup

The Android app now uses Credential Manager through `@capgo/capacitor-passkey`.
The native authenticator verifies a real passkey with the server; a local
fingerprint prompt by itself is not treated as a sign-in.

## Required relying-party setup

The relying-party ID is `erskgaur2008-arch.github.io`, and the web origin is
`https://erskgaur2008-arch.github.io`. Keep both stable after users enroll
passkeys: changing the RP ID invalidates existing credentials.

For each Android certificate that signs an APK users install:

1. Publish `/.well-known/assetlinks.json` at the root of
   `https://erskgaur2008-arch.github.io/`. Include the exact Android package
   name and the signing certificate's SHA-256 fingerprint. Android package
   variants are defined in `capacitor.config.ts`.
2. In Supabase Authentication → Passkeys, add the certificate origin
   `android:apk-key-hash:<base64url SHA-256 of the signing certificate>` to
   Relying Party Origins. Keep the web origin too. Supabase allows up to five
   origins, so use one stable signing certificate for the distributed app
   variants where possible.
3. Set the Supabase Edge Function secret `ANDROID_PASSKEY_ORIGINS` to the
   comma-separated exact certificate origins. The function accepts only
   `android:apk-key-hash:` origins with a 43-character base64url SHA-256 hash;
   it does not accept wildcards.

The GitHub Pages project site in this repository is served under
`/ashiana-attendance/`; it cannot itself publish a file at the hostname root.
The asset links file must therefore be published by the GitHub Pages root site
or another hosting setup serving that same relying-party hostname. Do not
register a fingerprint until the production signing certificate is known.

The local `supabase/config.toml` contains the web origin only because the
production Android signing certificate is not stored in this repository. The
GitHub Actions APK workflow builds debug APKs; their signing certificate is
not the production signing certificate. A successful Gradle build confirms
the native plugin compiles, but does not by itself confirm passkey enrollment
on a device. Device sign-in becomes available after the Digital Asset Links,
Supabase Auth origins, and Edge Function secret are configured with the actual
release signing certificate.
