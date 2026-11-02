# deploy-ipa

A Claude Code plugin that puts debug builds of your iOS apps on your iPhone
without TestFlight or a cable, and lets Claude read their console output
wherever the phone is.

Ask Claude to "deploy MyApp to my phone". It archives the scheme, uploads a
development-signed .ipa to your own private S3 bucket, and replies with a
link to a page with an Install button. It is made for driving Claude Code
from the phone you test on, through Remote Control or Claude Code on the web,
so you tap the link right there, and it stays in the conversation. Ask for
"a build that uploads its logging" instead, and the build also streams its
`print` and `NSLog` output to the bucket, where Claude reads it while you
reproduce a bug.

Nothing is added to your Xcode projects, and nothing runs on anyone's server
but your own bucket.

## What you need

- A Mac with Xcode, using automatic signing, with an Xcode account signed in
  for the team. The phone must be registered with that team, with Developer
  Mode on (Settings > Privacy & Security).
- An AWS account with an S3 bucket that blocks public access (the default),
  and an IAM user limited to it.
- The `aws` CLI 2.9 or later (`brew install awscli`), `jq`, `python3` and
  `curl`. Recent macOS has all but the `aws` CLI; `setup` checks.

## Install

In Claude Code:

```
/plugin marketplace add palmin/deploy-ipa
/plugin install deploy-ipa@deploy-ipa
```

Or copy `skills/deploy-ipa` to `~/.claude/skills/deploy-ipa` to use it as a
personal skill.

## Set up

1. **Bucket.** Create an S3 bucket in a region near you. Its name must not
   contain dots, as the links use `https://<bucket>.s3.<region>.amazonaws.com`.
   Keep Block Public Access on.
2. **IAM user.** Create a user with only the policy in
   [iam-policy.json](iam-policy.json), with `YOUR-BUCKET` replaced (and
   `deploy-ipa` too, if you pick another prefix). Create an access key for it.
3. **Run setup in your own Terminal.** Ask Claude to "set up deploy-ipa" to
   get the exact path, which depends on how you installed it, then run it
   yourself:

   ```bash
   <skill folder>/setup
   ```

   It stores the keys in your login Keychain (service `deploy-ipa`), typed
   into macOS's own prompt, so they never pass through Claude. It writes
   `~/.config/deploy-ipa.env`, copies a small Keychain helper to
   `~/.config/deploy-ipa/aws-credentials`, and adds a profile to
   `~/.aws/config`. Then it checks everything: the AWS login, the bucket's
   region, a signed download, that the same link without its signature is
   refused, and a console upload.

Run `setup --check` at any time to repeat the checks without changing
anything; Claude runs it too when something fails.

## Use

- "Deploy MyApp to my phone", or `/deploy-ipa:deploy-ipa MyApp`
- "Send a Release build of MyApp to my iPhone"
- "Show me the install link again"
- "Make a build of MyApp that uploads its logging"
- "I reproduced it, what did MyApp log?"
- "Watch the MyApp console live while I try this"
- "I'm on the same Wi-Fi, install it directly and watch the console"

Links last 7 days. Console output arrives 2 to 5 seconds late, with the time
and process name on each line, and the app and each of its extensions upload
their own. From a device, only `print` and `NSLog` come through, because
reading the log store for `Logger` lines takes seconds there; so add
temporary debug lines as `NSLog` or `print`.

## What leaves your Mac

- The secret key never does. Install links are presigned URLs, which carry
  the access key id and a signature, and give anyone holding them the .ipa
  for 7 days. They appear in the conversation, so anyone who can read the
  transcript can download the build until then. A development-signed .ipa
  installs only on devices registered with your team.
- A console build contains a signed upload policy instead of a key. Anyone
  holding the binary can upload files of up to 10 MB under that build's own
  console folder until the policy expires with the links, but cannot read,
  list or delete anything.
- Each deploy deletes everything under the prefix older than the link
  lifetime, so keep the prefix for deploy-ipa alone. In a versioned bucket,
  the deleted versions stay until a lifecycle rule removes them.

## Limits

- AWS S3 only. Other S3-compatible services need a configurable endpoint,
  and console builds rely on presigned POST uploads, which not all of them
  support (Cloudflare R2 does not).
- iOS apps only, and console builds need iOS 15 or later.
- Builds run one at a time, since schemes share DerivedData.

## Files

| File | Purpose |
|---|---|
| `skills/deploy-ipa/SKILL.md` | tells Claude how to deploy, show the link and read console output |
| `skills/deploy-ipa/deploy-ipa` | archives, packages, uploads and prints the links |
| `skills/deploy-ipa/deploy-ipa-console` | prints or follows what a console build uploaded |
| `skills/deploy-ipa/build-console-object` | compiles `RemoteConsole.m` with an upload policy |
| `skills/deploy-ipa/upload-policy` | signs the S3 POST policy for console uploads |
| `skills/deploy-ipa/RemoteConsole.m` | captures stdout, stderr, `NSLog` and `Logger` lines and uploads them |
| `skills/deploy-ipa/aws-credentials` | reads the AWS keys from the Keychain for the `aws` CLI |
| `skills/deploy-ipa/setup` | sets everything up and checks it |
| `iam-policy.json` | the permissions the IAM user needs |

## About me

I'm [Anders Borum](https://mastodon.social/@palmin), making developer
tools for iOS and Mac, most notably [Working Copy](https://workingcopy.app),
the full-featured Git client for iOS putting your
side-projects in your side pocket where they belong.
