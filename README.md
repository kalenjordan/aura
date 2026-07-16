# Aura

A small, native macOS Markdown editor inspired by Typora. Aura focuses on the useful core: open Markdown files, write in a calm editor, preview the result, and save with standard Mac document behavior.

The app icon master artwork is stored at `Resources/AuraIcon.png`, with the packaged macOS icon at `Resources/Aura.icns`.

## Install it

Aura requires macOS 14 or newer and the Swift command-line tools.

```sh
./Scripts/install.sh
```

This builds and installs `Aura.app` in `/Applications`. To make it your default Markdown editor, select a `.md` file in Finder, choose **File → Get Info**, select **Aura** under **Open with**, and click **Change All**.

For development, run Aura without installing it using `swift run Aura`.

Open a `.md` file with **File → Open**, or create a new document with **File → New**. Changes participate in native autosave and versioning.

## Current scope

- Open, edit, and save Markdown or plain-text files
- One calm, editable canvas with live Markdown styling
- Styled headings, emphasis, links, quotes, lists, and code
- Reopens the most recently edited file at launch
- `Command-K` palette for switching between recent files
- Opens every file in the same editor window
- Reloads the open document when Git or another app changes it on disk
- Adjustable editor text size
- Standard macOS document windows, undo, autosave, and recent files

The intentionally small first version does not yet include a file browser, image management, themes, or hidden Markdown punctuation.
