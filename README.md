<div align="center">
<img 
  src="https://github.com/user-attachments/assets/50862f8a-7826-4d07-9ecd-5281216e5982" 
  width="2000" 
  style="border-radius: 30px;" 
/>
</div>


### Burrito

A lightweight macOS menu bar app for shrinking files. Drop images, videos, or PDFs onto the notch shelf and Burrito converts them — **PNG**, **WebP**, **MP4**, **WebM**, or **PDF** — no extra steps.

https://github.com/user-attachments/assets/de94b2fd-c711-46d1-b790-6626954f07af

## Download

**Option 1** — Grab the latest build from [GitHub Releases](https://github.com/arj00n/burrito/releases/latest).

**Option 2** — Install via the command line:

```bash
curl -L -o Burrito.zip "$(curl -fsSL \
  https://api.github.com/repos/arj00n/burrito/releases/latest \
  | sed -n 's/.*"browser_download_url": *"\([^"]*\.zip\)".*/\1/p')"
unzip -o Burrito.zip -d /Applications
```

> Requires **macOS 15** or later on **Apple silicon**.

Builds are ad-hoc signed rather than notarized, so the first launch needs manual
approval: right-click **Burrito.app** → **Open**. After that it launches
normally, and Burrito updates itself from then on.

## Using it

Burrito lives in the menu bar and presents itself as a shelf that grows out of
the notch. Click the menu bar icon to open it, or just start dragging files
toward the notch — it opens on approach.

**Dropping decides the format.** The shelf splits into two halves while a drag
is over it. Drop on the **left** for the high-quality target (PNG, MP4, PDF);
drop on the **right** for the web-optimized one (WebP, WebM, PDF). The labels
update to match whatever you are dragging.

**Engine presets.** `Fast`, `Balanced`, and `Smallest` trade encoding time
against output size. The shelf is colour-coded to the active preset — amber,
green, violet — so you can tell which one is live at a glance.

**When it finishes**, drag the converted files straight out of the shelf into
any app, or hit **Copy** to put them on the clipboard. Results carry the
percentage saved.

**Pin** the shelf open with the pin button if you are running several batches.

**Settings** (gear icon) covers where output lands — an `Optimized` folder or
beside the originals — and an optional size ceiling for PDFs. Right-click the
menu bar icon for **Launch on Login**, update checks, and quit.

## Raycast

The included Raycast extension adds `PNG`, `WebP`, `PDF`, `WebM`, `MP4`, and a
general `Convert` command. Select files in Finder, run a command, and Burrito
copies the converted files to the clipboard when the batch succeeds.

```bash
cd raycast-extension
npm install
npm run dev
```

## URL scheme

Burrito registers the `burrito://` scheme, which is how the Raycast extension
drives it. Anything that can open a URL can too:

```bash
open "burrito://convert/webp?file=/path/to/one.png&file=/path/to/two.jpg"
```

The path component is the target format (`png`, `webp`, `mp4`, `webm`, `pdf`).
Each `file` parameter must be an absolute path. Results are copied to the
clipboard automatically.

## Building

```bash
git clone https://github.com/arj00n/burrito.git
cd burrito
open Burrito.xcodeproj
```

Built with **Xcode 26**. Swift Package Manager resolves the two dependencies on
first build — [Sparkle](https://github.com/sparkle-project/Sparkle) for updates
and [OpenNook](https://github.com/twinkling-reality/opennook) for the notch
surface. No other setup.

Publishing an update is a separate flow with its own signing key — see
[UPDATES.md](UPDATES.md).

## Contributing

Contributions are welcome! Here's how to get started:

1. **Fork** the repository.
2. **Clone** your fork:
   ```bash
   git clone https://github.com/<your-username>/burrito.git
   ```
3. Open `Burrito.xcodeproj` in Xcode 26.
4. Create a new branch for your change:
   ```bash
   git checkout -b my-feature
   ```
5. Make your changes and verify the build succeeds (⌘B).
6. **Commit** with a clear message and **push** your branch:
   ```bash
   git push origin my-feature
   ```
7. Open a **Pull Request** against `main`.

### Guidelines

- Keep PRs focused — one feature or fix per PR.
- Match the existing code style (SwiftUI, no storyboards).
- Test on macOS 15 or later before submitting.

## License

MIT License



Built with 💚 by Swish Design
