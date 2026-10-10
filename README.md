# TT

A clean-room iOS terminal-app prototype with a GitHub Actions IPA build pipeline.

## First milestone

This first milestone validates the cloud build and creates a minimal terminal-style UI. It is **not yet a real shell** and does not claim root access. The input area currently provides an observable local echo/command transcript so keyboard and UI behavior can be tested before adding process execution.

## Build

Open **Actions → Build TT IPA → Run workflow**, or push a change to `main`.

On success, download the **TT-IPA** artifact. It contains a single `TT.ipa` file.

## Compatibility

- Deployment target: iOS 15.0
- UI: SwiftUI
- Xcode project generated from `project.yml` by XcodeGen
- No signing certificate or provisioning profile is configured by this workflow; the IPA is packaged for testing with TrollStore. Actual installation and device behavior still need on-device verification.

## Planned stages

1. Prove cloud compilation and IPA packaging.
2. Verify keyboard input and terminal UI on the device.
3. Add a real command-session backend only after defining and testing its permission model.
4. Evaluate root-session support separately; TrollStore alone is not assumed to grant a root shell.
