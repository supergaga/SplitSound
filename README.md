# Split Sound

Send each Mac app to its own audio output. A music app can play through a Bluetooth speaker while the browser stays on the MacBook speakers.

<p align="center">
  <a href="https://github.com/supergaga/SplitSound/releases/latest"><img src="https://img.shields.io/github/v/release/supergaga/SplitSound?style=for-the-badge&labelColor=1c1c1e&color=0A84FF&logo=github&logoColor=white" alt="Latest Release"></a>
  <a href="https://github.com/supergaga/SplitSound/releases"><img src="https://img.shields.io/github/downloads/supergaga/SplitSound/total?style=for-the-badge&labelColor=1c1c1e&color=3a3a3c" alt="Downloads"></a>
  <a href="https://github.com/supergaga/SplitSound/releases/latest/download/SplitSound-macos.zip"><img src="https://img.shields.io/badge/Download-macOS-0A84FF?style=for-the-badge&labelColor=1c1c1e&logo=apple&logoColor=white" alt="Download for macOS"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-15%2B-3a3a3c?style=for-the-badge&labelColor=1c1c1e&logo=apple&logoColor=white" alt="macOS 15+"></a>
</p>

<p align="center">
  <img src="Packaging/AppIcon.png" width="96" alt="Split Sound app icon">
</p>

## Features

- Choose an output device per app, or leave the app on the system output.
- Set a separate volume after an app is routed.
- Apps show up when they play audio. Nothing is added by hand, and the choice stays after the app quits.
- If the chosen device disconnects, that audio falls back to the system output and returns when the device reconnects.
- No virtual audio driver and no kernel extension.

## Requirements

macOS 15 or later.

## Install

Download `SplitSound-macos.zip` from the [latest release](releases/latest), unzip it, and move **Split Sound** into `/Applications`.

```bash
open /Applications/SplitSound.app
```

The menu-bar icon is a branch. Click it to open the panel.

macOS may say the app is from an unidentified developer, because this release is not signed with a paid Apple Developer ID. You do not need your own certificate. Right-click the app, choose **Open**, then **Open** again. That approval is kept for this download.

Launch at Login works after the app is in `/Applications`.

## Build from source

Only needed if you want to change the app. The build script signs it automatically.

```bash
./Packaging/build-app.sh
open build/SplitSound.app
```

A release is published when a `v*` tag is pushed. GitHub Actions builds the zip and attaches it to the release.

## Usage

1. Set **System Output** to the device everything else should use, such as the MacBook speakers.
2. Play audio in a music app. Its icon appears in the list. Hover the icon to see the name.
3. Change that app from **Follow System** to the other device, such as a Bluetooth speaker.
4. Leave the browser on **Follow System** if web video should stay on the system output.

The first time an app is routed, macOS asks to record system audio. Allow Split Sound. If access is denied, the routed app stays silent instead of reporting an error. Allow it later in **System Settings → Privacy & Security → Screen & System Audio Recording**. **Recording Permission** in the panel opens that pane.

## Limitations

Routing applies to a whole app, not to one browser tab.

Safari web audio sometimes comes from a separate WebKit process. If those pages stay on the old device after Safari is routed, turn on **Show system processes** and set the WebKit rows to the same device.

## Privacy

Choices are stored only on this Mac, in `~/Library/Application Support/SplitSound/routes.json`, so a route can be restored. Split Sound does not use the network and does not collect analytics.
