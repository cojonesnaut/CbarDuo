CbarDuo 1.4.8 keeps the desktop widget in step with the menu bar.

### What's fixed
- **Widget and menu bar match on a full battery:** when your MacBook is fully charged on power, the menu bar switches to the Adaptive Ring, but the desktop widget kept drawing the green battery ring. The widget's Standard mode now switches with the menu bar, and back again when you unplug.
- **Desktop Macs:** the widget's Standard mode now draws the Adaptive Ring, the same as the menu bar, instead of an empty battery ring.
- The widget's Adaptive Ring follows your **Adaptive Ring colour coding** setting, just like the menu bar.

### Updating
- **From 1.4.4 or later:** CbarDuo offers this update inside the app (or use Check for Updates… in Settings).
- **From 1.4.3:** download the DMG below and install it over the old version once; later versions will update from inside the app.

### Requirements
- macOS 15 Sequoia or later
- Apple Silicon (M-series) Mac

### Installation
1. Download **CbarDuo-1.4.8.dmg** below.
2. Open it and drag **CbarDuo** to **Applications**, replacing the old version if asked.
3. Open CbarDuo from Applications. This build is not notarized by Apple, so macOS will say it can't verify the app: go to **System Settings → Privacy & Security**, click **Open Anyway** next to CbarDuo, and confirm.

   Or skip that step: run this in Terminal after copying CbarDuo to Applications, then open it normally. It clears the download flag from CbarDuo only and needs no `sudo`.

   ```bash
   xattr -dr com.apple.quarantine /Applications/CbarDuo.app
   ```

Build 17 · SHA-256 of CbarDuo-1.4.8.dmg:
`4b3d403fd3b6508c09604a4cfd341dfe32315dc34065f99d7abfc9dcc348b6a1`
