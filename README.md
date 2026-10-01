# Split Sound

Send each Mac app to its own speaker. Music can play through a Bluetooth speaker while a video in the browser stays on the MacBook.

<p align="center">
  <a href="https://github.com/supergaga/SplitSound/releases/latest"><img src="https://img.shields.io/github/v/release/supergaga/SplitSound?style=for-the-badge&labelColor=1c1c1e&color=0A84FF&logo=github&logoColor=white" alt="Latest Release"></a>
  <a href="https://github.com/supergaga/SplitSound/releases"><img src="https://img.shields.io/github/downloads/supergaga/SplitSound/total?style=for-the-badge&labelColor=1c1c1e&color=3a3a3c" alt="Downloads"></a>
  <a href="https://github.com/supergaga/SplitSound/releases/latest/download/SplitSound-macos.zip"><img src="https://img.shields.io/badge/Download-macOS-0A84FF?style=for-the-badge&labelColor=1c1c1e&logo=apple&logoColor=white" alt="Download for macOS"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-15%2B-3a3a3c?style=for-the-badge&labelColor=1c1c1e&logo=apple&logoColor=white" alt="macOS 15+"></a>
</p>

<p align="center">
  <img src="Packaging/AppIcon.png" width="96" alt="Split Sound app icon">
</p>

Needs macOS 15 or later.

## Features

Split Sound is for when one speaker is wrong for everything playing at once.

- **Music and video at the same time.** Send Spotify or NetEase Cloud Music to a Bluetooth speaker, and leave the browser on the MacBook so a video does not come out of the speaker.
- **One list, only what is playing.** Silent apps stay out of the way. A choice is remembered and comes back the next time that app plays.
- **Volume per speaker.** The slider under System Output changes that device. An app sent to another speaker has a slider for that speaker.
- **EQ when a speaker needs it.** Presets include a Marshall setting for home speakers such as Acton: less muddy bass, clearer guitars and vocals.

## Install

Download [SplitSound-macos.zip](https://github.com/supergaga/SplitSound/releases/latest/download/SplitSound-macos.zip), unzip it, and move **Split Sound** into Applications.

The first time you open it, macOS may block the app because it came from the internet. Control-click **Split Sound**, choose **Open**, then **Open** again.

Click the branch icon in the menu bar. **Launch at Login** is at the bottom of the panel.

## Use

**System Output** is where everything goes unless you say otherwise. Set it to the MacBook speakers if that is what you want for most sound. The slider under it is the same volume as Control Center.

An app shows up only while it is playing. Hover the icon to see its name.

- **Output.** Leave it on **Follow System**, or pick another speaker, such as a Bluetooth speaker.
- **Volume.** The slider under System Output changes that device only. If an app is sent to another speaker, its slider changes that speaker.
- **EQ.** Optional. **Off** leaves the sound alone.

If a Bluetooth speaker disconnects, that app falls back to the system output and returns to the speaker when it reconnects.

The first time you send an app to another speaker, macOS asks to allow system audio. Allow it. While that app is routed, macOS may show a recording indicator. Split Sound is not saving a recording. If you deny access, the routed app goes silent. **Recording Permission** in the panel opens the setting.

## EQ

| Preset | What it does |
| --- | --- |
| Bass | More low end |
| Vocal | Clearer voices |
| Harman | A common listening preference, with a little more bass |
| Marshall | For Marshall home speakers such as Acton: less muddy bass, clearer guitars and vocals |
| Treble | Brighter top end |
| Night | Softer, less harsh |
| Podcast | Voice, with rumble reduced |

## Good to know

A whole app is one route. Two tabs in the same browser cannot go to different speakers.

Safari’s web video sometimes comes from a separate system process. If the page stays on the old speaker after you route Safari, turn on **Show system processes** and set those WebKit rows the same way.

Settings stay on this Mac. Split Sound does not send anything over the network.
