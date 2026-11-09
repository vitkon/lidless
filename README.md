# lidsomnia

Keep your MacBook awake, **even with the lid closed on battery**, while a job runs. It's built for Claude Code Remote Control sessions you drive from your phone, and supports Codex too.

```sh
brew install vitkon/tap/lidsomnia   # or: git clone … && make install (→ ~/.local/bin)
lidsomnia setup                     # once: sudoers rule for pmset + launchd watchdog (asks for your password)

lidsomnia claude --remote-control     # close the lid, keep working from your phone
lidsomnia codex                       # Codex works too
lidsomnia --sleep-after npm run build # sleep the Mac when the build finishes
lidsomnia status
lidsomnia doctor                      # something off? it tells you the fix
lidsomnia release                     # panic button
```

- Any command keeps the Mac awake for as long as it runs.
- `claude` sessions also get idle detection through per-run hooks. After 30 minutes without activity the hold is dropped, but the session keeps running. A new prompt takes the hold back.
- Safety limits: the hold is dropped when the battery is ≤10% on battery or the chip's thermal state is `serious` or worse.
- A watchdog resets `pmset disablesleep` within 60s if a wrapper dies without cleaning up.

Config is in `~/.lidsomnia/config.json`. Every key is optional:

```json
{ "idleTimeoutMinutes": 30, "batteryFloorPercent": 10, "thermalLimit": "serious", "notify": true }
```

### Sessions you forgot to wrap

Add `"autoDetect": true` to the config and the watchdog also keeps the Mac awake for Claude Code and Codex sessions started without lidsomnia, including `claude --bg`, `codex remote-control` and Codex in VS Code. Idle time is judged from the session's transcript writes, with the same 30-minute timeout.

### Phone alerts

Install the [ntfy](https://ntfy.sh) app, subscribe to a long random topic, then:

```sh
echo '{"alerts": {"ntfyTopic": "your-random-topic"}}' > ~/.lidsomnia/config.json
lidsomnia test-alert
```

You'll get a push when the battery runs low, the Mac gets hot, Claude goes idle, or a job of 5+ minutes finishes. A generic `webhookURL` is supported too. See the spec for all options.

See [docs/spec.md](docs/spec.md) for the design and [docs/roadmap.md](docs/roadmap.md) for what's next.

Project page: https://vitkon.github.io/lidsomnia/

## Releasing

```sh
# bump Sources/lidsomnia/Version.swift, commit, then:
scripts/release.sh 1.1.0   # tests, tags, pushes, publishes Formula/lidsomnia.rb to vitkon/homebrew-tap
```

MIT licensed.
