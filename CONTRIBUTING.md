# Contributing

Thanks for taking a look. GameMetrik is a personal project shared as is. Issues and pull requests are welcome, in English or in French, with no promise on how fast they are handled.

## Before you open a pull request

1. Run the tests: `swift test --package-path NativeApp`.
2. If you touched the app itself, build the demonstration and check the screens you changed:
   `GAMEMETRIK_DEMO_BUILD=1 ./NativeApp/scripts/build.sh`
3. Keep `NativeApp` free of dependencies outside the Apple SDKs.

## Rules that are not negotiable

- No credential, token, key file or real player data in a commit, a test or a fixture. Fixtures are synthetic.
- Raw game sessions and player profiles are never written to disk.
- A missing or failed source is shown as unavailable. It is never replaced by zero or by demonstration data.
- The interface is written in French. Keep new interface text consistent with it.

## Reporting a security problem

See [SECURITY.md](SECURITY.md). Do not use a public issue.
