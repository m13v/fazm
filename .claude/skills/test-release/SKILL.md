# test-release: Smoke Test a Fazm Release

Smoke test a Fazm release. Use when the user says "test the release", "smoke test", or "verify the build works".

**This skill does NOT build anything.** It tests the shipped product via Sparkle auto-update.

## Channel → Machine Mapping

| Channel | Test machine | `update_channel` | Sparkle sees |
|---------|-------------|-------------------|-------------|
| **staging** | MacStadium remote | `staging` | staging + beta |
| **beta** | Local (`/Applications/Fazm.app`) | default (beta) | beta |
| **stable** | Both | — | all |

**NEVER change the remote machine's `update_channel`.** It must stay `staging`. The local machine defaults to `beta` (no override needed).

**NEVER promote to the next channel yourself.** Each promotion (staging→beta→stable) requires explicit user approval. Only test the channel that was just promoted.

## Prerequisites

- The release must be registered in Firestore on the channel being tested
- For staging tests: MacStadium remote must be reachable (`./scripts/macstadium/ssh.sh`)
- For beta tests: production Fazm app must be installed locally (`/Applications/Fazm.app`)

## Test Queries

Send each query via distributed notification. Wait 15 seconds between queries. After each, check logs for errors.

```bash
# Query 1: Basic chat
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "What is 2+2?"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'

# Query 2: Memory recall
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "What do you remember about me?"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'

# Query 3: Tool use / Google Workspace
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "What events do I have on my calendar today?"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'

# Query 4: File system
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "List the files on my Desktop"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
```

For remote queries, wrap in: `./scripts/macstadium/ssh.sh "xcrun swift -e '...'"` (escape inner quotes).

After each query:
- Errors: `grep -i "error\|fail\|crash\|unauthorized\|401" /private/tmp/fazm.log | tail -5`
- Response: `grep -i "Prompt completed\|Chat response complete" /private/tmp/fazm.log | tail -5`

## Flow: Staging Test (remote)

1. Verify remote channel: `./scripts/macstadium/ssh.sh "defaults read com.fazm.app update_channel"` — must be `staging`
2. Check Fazm is running: `./scripts/macstadium/ssh.sh "pgrep -la Fazm"` (launch if needed)
3. Use `macos-use-remote` MCP to navigate to Settings > About > "Check for Updates"
4. Sparkle shows update dialog — verify correct version. **Do NOT check "Automatically download and install updates"**
5. Click "Install Update", wait for restart, verify new version
6. Send 4 test queries via SSH, check remote logs after each
7. Check Sentry: `./scripts/sentry-release.sh --version X.Y.Z`

## Flow: Beta Test (local)

1. Open production app: `open -a "Fazm"`
2. Navigate to Settings > About > "Check for Updates" via `macos-use` MCP
3. Sparkle shows update dialog — verify correct version. **Do NOT check "Automatically download and install updates"**
4. Click "Install Update", wait for restart, verify new version
5. Send 4 test queries locally, check `/private/tmp/fazm.log` after each
6. Check Sentry: `./scripts/sentry-release.sh --version X.Y.Z`

## Report Results

| Test | Machine | Result |
|------|---------|--------|
| App updated to vX.Y.Z | local/remote | pass/fail |
| Basic chat ("2+2") | local/remote | pass/fail |
| Memory recall | local/remote | pass/fail |
| Tool use (calendar) | local/remote | pass/fail |
| File system (Desktop) | local/remote | pass/fail |
| Sentry errors | — | 0 new / N new |

**pass** = AI responded without errors in logs
**fail** = no response, error in logs, or crash

## What Counts as a Failure

- **Sparkle update fails** — hard failure. Do NOT work around with manual ZIP install. Common cause: broken code signature from `__pycache__` files written inside the app bundle.
- App doesn't update (Sparkle error, appcast not serving correct version)
- Query gets no AI response within 60 seconds
- Logs show `error`, `crash`, `unauthorized`, `401`, or `failed` during the query
- App crashes or becomes unresponsive
- Sentry shows new issues for this release version
