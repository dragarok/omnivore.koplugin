# omnivore.koplugin

Two-way sync between [KOReader](https://koreader.rocks) and [Omnivore](https://github.com/omnivore-app/omnivore),
self-hosted or hosted.

- **Sync** downloads the newest articles from your inbox, or from a label or search you choose. It shows
  progress as it goes, and you can tap to stop.
- **Highlights and notes go back to Omnivore**, and they appear *in place* in the article in the Omnivore
  apps, not just in a list. Edited notes are updated too.
- **Reading progress goes back to Omnivore.** Freshly downloaded articles open where you left off in the
  Omnivore app.
- **Finish an article and it's archived** in Omnivore. Mark it as finished, or use *This article →
  Archive*. The local copy is deleted, moved to an `archive` subfolder, or kept, as you prefer.
- **Changes made elsewhere are followed.** Articles you archive or delete in the Omnivore app are removed
  from the device. Ones you move back to the inbox are downloaded again.
- **Browse your library** without leaving KOReader: Inbox, Continue reading, Unread, With highlights,
  Archive, labels and search. From there you can download, open, archive, restore or delete articles.
- **Save links** from KOReader: tap a link in any book and choose *Save to Omnivore*, select a URL, or type
  one in. Links saved while offline are sent at the next sync.
- **Articles read offline with their images.** Images are stored as files beside the article, not inlined,
  so even image-heavy pages open in about a second.
- **Gestures** (Dispatcher actions): sync, browse library, open download folder, archive this article.

Based on [fairlygood/omnivore.koplugin](https://github.com/fairlygood/omnivore.koplugin) by Jamie (MIT),
which downloaded articles from hosted Omnivore. This version is a rewrite around two-way sync.

## Install

1. Download this repository, as a release zip or with `git clone`, and put the `omnivore.koplugin` folder
   into KOReader's `plugins` folder. On Android that's `/sdcard/koreader/plugins/`, on Kobo
   `.adds/koreader/plugins/`, and on Kindle `koreader/plugins/`.
2. Restart KOReader. **Omnivore** appears in the Tools menu (🛠), next to Wallabag, both in the file
   browser and while reading.
3. Choose *Omnivore → Set up Omnivore…*:
   - **Server address**: your Omnivore API, e.g. `https://omnivore.example.com:4000` for a self-hosted
     install. You can paste the full `…/api/graphql` URL; it's trimmed for you.
   - **API key**: create one in Omnivore's web app under *Settings → API Keys*.

   *Test* checks the connection and shows who you're signed in as. *Save* checks it again.
4. Choose *Sync now*.

If typing a 36-character key is painful on your device, set `api_key` in `koreader/settings/omnivore.lua`
instead.

## Using it

| Where | What |
|---|---|
| *Omnivore → Sync now* | Sends saved links, highlights, notes and progress; archives finished articles; removes articles archived elsewhere; downloads new ones. Shows a summary at the end. |
| *Omnivore → Browse library* | Your Omnivore library, page by page. The ☰ button switches views. Tap an article for Download / Open / Archive / Move to inbox / Delete. |
| *Omnivore → Save a link…* | Type or paste a URL (`https://` is added if you leave it out). |
| *Omnivore → This article* (while reading) | Archive in Omnivore and close · Send highlights and progress now · Delete from Omnivore. |
| Tapping a link in a document | *Save to Omnivore* in the link dialog. |
| Gestures | *Omnivore: sync*, *browse library*, *open download folder*, *archive this article*. |

Some details:

- A downloaded article that you delete yourself is **not** downloaded again by sync. Use *Browse library*
  to get it back.
- Progress only moves forward. Omnivore keeps the furthest position, so opening a fresh copy at the top
  never winds it back.
- Highlights are matched to the article text with the same diff-match-patch "patch" that Omnivore's web
  reader writes (see `highlightlocator.lua`). If a highlight can't be placed, it's still sent and appears in
  the article's notebook.
- Deleting a highlight in KOReader doesn't delete it in Omnivore. That's deliberate, so a lost sidecar file
  can never wipe your highlights there.

## Settings

*Omnivore → Settings*:

- **Server / API key** and the **download folder** (default: `<home folder>/Omnivore`).
- **What to download**: newest in the inbox, inbox items with one label, or a custom Omnivore search such
  as `in:inbox label:news -label:long sort:saved-desc`. Useful filters include `in:inbox|archive|all`,
  `is:unread|reading|read`, `label:NAME`, `has:highlights`, `type:article` and
  `sort:saved-desc|read-desc|published-asc`. Also how many **articles per sync**, and whether to
  **download images**.
- **When you finish an article**: archive it in Omnivore when marked as finished, and optionally when read
  to the end. Then delete the local copy, move it to an `archive` subfolder, or keep it.
- **Send to Omnivore**: highlights and notes, reading progress, and whether to send them right after
  closing an article or only at sync.

## Files

- `koreader/settings/omnivore.lua`: settings, including server and API key. It's compatible with the
  original plugin's file; add `server_url` if you're upgrading.
- `koreader/settings/omnivore_state.lua`: which articles are on the device, and what has been sent.
- `<download folder>/Title.html`: the articles. Each carries `<meta name="omnivore-id">`, so moved or
  renamed files are still recognised.
- `<download folder>/.images/<article id>/`: their images. The folder is hidden in KOReader's file browser,
  and orphaned image folders are cleaned up at sync.

## Development

`highlightlocator.lua` has no KOReader dependencies. `test/run.sh` builds patches for sample quotes with
LuaJIT and checks them against Google's diff-match-patch, the library Omnivore uses. Each patch must be
byte-identical to the one `patch_make` produces, and must apply to the text.

```sh
python3 -m venv .venv && .venv/bin/pip install diff-match-patch
PYTHON=.venv/bin/python test/run.sh
```

## Licence

MIT. See [LICENSE](LICENSE).
