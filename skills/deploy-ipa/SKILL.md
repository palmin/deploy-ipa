---
name: deploy-ipa
description: Build a development-signed .ipa of an iOS app, upload it to the user's S3 bucket and show them an install link to tap on their phone, optionally linking in RemoteConsole so the build uploads its print/NSLog output for reading here. Use when the user says /deploy-ipa or asks to deploy, send or push a debug build to their phone, to get a build onto a device without TestFlight or a cable, for a build that uploads its logging or console output, to read what such a build logged, or to set up or check deploy-ipa.
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/deploy-ipa *), Bash(${CLAUDE_SKILL_DIR}/deploy-ipa-console *), Bash(${CLAUDE_SKILL_DIR}/build-console-object *), Bash(${CLAUDE_SKILL_DIR}/setup --check), Bash(xcodebuild -list *)
---

# deploy-ipa

Archive an iOS scheme, sign it for development, upload it to a private S3
bucket and show the user a link that installs it on their phone.

## Setup

Settings live in `~/.config/deploy-ipa.env`; the AWS keys are in the login
Keychain. When a script says the settings are missing, or the user asks to
set this up, tell them to run this in their own Terminal, since it asks for
the keys there:

```bash
${CLAUDE_SKILL_DIR}/setup
```

Never ask for keys in the conversation. To find out what is wrong with an
existing setup, run `${CLAUDE_SKILL_DIR}/setup --check`; it asks nothing
and tests the AWS profile, bucket, signed links and console uploads.

## Steps

1. **Pick the scheme.** Use the one the user named. Otherwise run
   `xcodebuild -list` in the project folder; if more than one scheme builds
   an app, ask which. The configuration defaults to `Debug`; pass another
   only when the user asks for it.

2. **Run the script** from the folder holding the `.xcodeproj` or
   `.xcworkspace` (usually the repo root), with `run_in_background: true`,
   since an archive can outlast the Bash timeout:

   ```bash
   ${CLAUDE_SKILL_DIR}/deploy-ipa [--console] <scheme> [configuration]
   ```

   Pass `--console` when the user wants the build to upload its logging
   (see Console builds below). Wait for the completion notice rather than
   polling. For several schemes, run them one after another, never in
   parallel: they share DerivedData.

3. **Show the link.** The script ends with `KEY=value` lines. Put the
   install page in the reply as a markdown link on its own line, followed
   by when it expires (`EXPIRES`):

   ```markdown
   [Install <TITLE> <VERSION> (<BUILD>)](<PAGE_URL>)
   ```

   The skill is made for sessions driven from the phone being tested, such
   as Remote Control or Claude Code on the web: the user taps the link in
   the Claude app, and it stays in the conversation. `PAGE_URL` is an https
   page whose Install button holds the direct `INSTALL_URL`
   (itms-services) link. Link to the page, never to `INSTALL_URL`: the
   Claude app does not make itms-services links tappable, whether written
   as a markdown link, an autolink or a bare URL. A page left open in
   Safari also makes it easy to retry.
   Show the link again whenever the user asks for it.

## Console builds

When the phone is on the Mac's network, its console can be read directly
(see the last bullet). When it is not, a `--console` build uploads its
console to the same bucket instead. Check which case applies before choosing.

- **Reading it:** once the user has reproduced the problem, print everything
  the newest console build of a scheme uploaded:

  ```bash
  ${CLAUDE_SKILL_DIR}/deploy-ipa-console <scheme>
  ```

  Or pass the `CONSOLE=` prefix from the deploy output. To watch live, add
  `--follow` and run it with `run_in_background: true`. Lines arrive about
  2 to 5 seconds late, prefixed by time and process name, and the app and
  each extension upload their own.
- **What is captured:** `print`, `NSLog`, anything else written to stdout or
  stderr, and `Logger`/`os_log` lines from the process's own code or from
  subsystems sharing the bundle id's first two components. Apple framework
  logging is left out. The last 2 seconds before a crash are lost. On an
  iPhone one read of the log store took about 9 s, and RemoteConsole stops
  reading after a read over 5 s and says so in the console, so from a device
  expect only `print` and `NSLog`; suggest those for remote debugging.
- **How:** `build-console-object` compiles `RemoteConsole.m` with a POST
  policy from `upload-policy` compiled in. The policy allows uploads only
  under that build's prefix, expires with the install link and holds no
  secret. `deploy-ipa` links the object into every target through
  `xcodebuild -xcconfig` (`OTHER_LDFLAGS[sdk=iphoneos*] = $(inherited) …`),
  and a constructor starts it. Nothing in the project changes, and builds
  without `--console` relink without it.
- **Simulator or Mac:** `build-console-object iphonesimulator|macosx <out.o>
  <prefix>` makes the same object; link it the same way with
  `OTHER_LDFLAGS[sdk=iphonesimulator*]` and read it by its `s3://` prefix.
- **When the phone is on the Mac's network:** `xcrun devicectl device
  install app --device <udid> <Payload/App.app>` (unzip the uploaded .ipa)
  and `xcrun devicectl device process launch --console --terminate-existing
  --device <udid> <bundle id>` in the background show the app's console
  directly; a console build streams to S3 at the same time.

## How it works

- iOS installs only through `itms-services://?action=download-manifest&url=…`
  pointing at a `manifest.plist` served over https, which points at the .ipa.
  The page, manifest and .ipa are all presigned S3 links lasting
  `DEPLOY_IPA_EXPIRES` (604800 s, the SigV4 maximum). Uploads land in
  `<prefix>/<scheme>/<version>-<build>-<timestamp>/`, and each run deletes
  everything under the prefix older than the link lifetime.
- With automatic signing the archive is already signed for development, so
  the script zips the app into an .ipa itself. Only an archive without a
  device profile goes through `xcodebuild -exportArchive`, which spends
  about a minute checking profiles with Apple.
- The `aws` CLI already uploads in parallel parts, so upload time is set by
  the uplink.
- It never touches the project's own archive scripts or build numbers.

## When it fails

- `error: the following command failed with exit code 0` lines come from
  `xcodebuild -quiet` on files with warnings; trust the script's exit code.
- **AWS errors:** run `${CLAUDE_SKILL_DIR}/setup --check` and pass on what
  fails.
- **Signing errors during export:** the device or capability is missing
  from the team's development profile. Xcode's automatic signing must be
  able to create it, so an Xcode account for the team must be signed in.
- **"Unable to install" on the phone:** the phone is not registered with
  the team, or Developer Mode is off (Settings > Privacy & Security).
- Installing replaces the App Store or TestFlight copy with the same bundle
  id, just like running from Xcode. Installing from TestFlight puts it back.
