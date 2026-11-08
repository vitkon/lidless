# lidless

Keep your MacBook awake, **even with the lid closed on battery**, while a job runs. It's built for `claude` Remote Control sessions you drive from your phone.

```sh
brew install vitkon/tap/lidless   # or: git clone … && make install (→ ~/.local/bin)
lidless setup                     # once: sudoers rule for pmset + launchd watchdog (asks for your password)

lidless claude --remote-control     # close the lid, keep working from your phone
lidless --sleep-after npm run build # sleep the Mac when the build finishes
lidless status
lidless release                     # panic button
```

- Any command keeps the Mac awake for as long as it runs.
- `claude` sessions also get idle detection through per-run hooks. After 30 minutes without activity the hold is dropped, but the session keeps running. A new prompt takes the hold back.
- Safety limits: the hold is dropped when the battery is ≤10% on battery or the chip's thermal state is `serious` or worse.
- A watchdog resets `pmset disablesleep` within 60s if a wrapper dies without cleaning up.

Config is in `~/.lidless/config.json`. Every key is optional:

```json
{ "idleTimeoutMinutes": 30, "batteryFloorPercent": 10, "thermalLimit": "serious", "notify": true }
```

### Phone alerts

Install the [ntfy](https://ntfy.sh) app, subscribe to a long random topic, then:

```sh
echo '{"alerts": {"ntfyTopic": "your-random-topic"}}' > ~/.lidless/config.json
lidless test-alert
```

You'll get a push when the battery runs low, the Mac gets hot, Claude goes idle, or a job of 5+ minutes finishes. A generic `webhookURL` is supported too. See the spec for all options.

See [docs/spec.md](docs/spec.md) for the design and [docs/roadmap.md](docs/roadmap.md) for what's next.

Project page: https://vitkon.github.io/lidless/

## Releasing

```sh
# bump Sources/lidless/Version.swift, commit, then:
scripts/release.sh 1.1.0   # tests, tags, pushes, publishes Formula/lidless.rb to vitkon/homebrew-tap
```

MIT licensed.
