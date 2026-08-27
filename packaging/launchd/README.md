# Supervised wax-mcp HTTP LaunchAgent

Product-owned wrapper + plist for `127.0.0.1:3000`. KeepAlive is the point: launchd must respawn the wrapper after SIGTERM.

Agents must not run `launchctl`, bind `:3000`, or kill a live listener.

Static check (safe for CI / agents):

```
bash packaging/launchd/test.sh
```

Install locations (after a human copies them):

- wrapper → `~/.local/share/waxmcp/bin/start-wax-mcp-http.sh`
- plist → `~/Library/LaunchAgents/ai.wax.mcp-http.plist`
- logs → `~/.local/share/waxmcp/logs/`

The runtime binary stays `$HOME/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp`. Never Homebrew `waxmcp`.

```
# Chris, from a real Terminal — agents must not run this:
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.wax.mcp-http.plist  # ok if not loaded
cp packaging/launchd/ai.wax.mcp-http.plist.template ~/Library/LaunchAgents/ai.wax.mcp-http.plist
# substitute $HOME if the template uses it
cp packaging/launchd/start-wax-mcp-http.sh ~/.local/share/waxmcp/bin/start-wax-mcp-http.sh
chmod +x ~/.local/share/waxmcp/bin/start-wax-mcp-http.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.wax.mcp-http.plist
launchctl kickstart -k gui/$(id -u)/ai.wax.mcp-http
lsof -nP -iTCP:3000 -sTCP:LISTEN
```

Pass after Chris runs it: listener is launchd’s child of the wrapper, not an Ishi shell pid.
