# DroidLink contributor guidance

- Keep this a small native macOS utility; avoid unrelated refactors and new runtime dependencies.
- Do not add unit tests unless explicitly requested.
- Use codebase-memory-mcp for code discovery when available; index this repository first when needed. Fall back to file searches for literals, configuration, or insufficient graph results.
- Build with `./build.command`; output is `dist/DroidLink.app` (Apple Silicon, macOS 13+).
- Verify actual command results. A pairing request is not an online connection.
- Never commit pairing codes, real device identifiers/addresses, local notes, ADB keys, logs, screenshots of personal devices, or generated app bundles.
- Device names live outside the repository; preserve the existing `Application Support/AndroidWireless` path when adjusting branding.
- Requirements, decisions, and final acceptance stay in the primary thread. Delegate bounded independent work when useful; never edit the same region concurrently. Review delegated diffs and command outcomes before accepting.
