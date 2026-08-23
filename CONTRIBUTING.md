# Contributing to Mnemos

Thanks for helping build a private, user-owned memory layer for AI agents.

## Development setup

1. Install Xcode 26 or later.
2. Install XcodeGen with `brew install xcodegen`.
3. Run `make build` from the repository root.
4. Run the app with `make run` or open it in Xcode with `make open`.

## Pull requests

- Keep changes focused and explain the user-facing behavior.
- Add tests when introducing capture, privacy, storage, or retrieval logic.
- Do not add telemetry, cloud services, or new capture sources without an explicit design discussion.
- Never commit captured user data, database files, credentials, signing material, or build artifacts.
- Update the README or architecture notes when changing a public boundary.

## Privacy and security expectations

Privacy failures are product failures. Capture code must fail closed, honor explicit allowlists, reject secure fields, and treat observed content as untrusted. New data collection requires a visible user control and a documented retention policy.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
