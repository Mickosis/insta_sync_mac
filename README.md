# Insta Sync for Mac

A native macOS app that sets your Mac Contacts' photos from their Instagram profile pictures, keeps every contact that has an Instagram handle in your **iCloud** account, and syncs to your iPhone through iCloud. It replaces the old "Insta Sync" iPhone shortcut and the earlier Python/browser version.

Insta Sync has its own built-in browser. You log in to Instagram once in its **Instagram** window; after that, every lookup (profile pictures, the accounts you follow) runs in a hidden browser inside the app, so nothing pops up while it syncs or links contacts in a batch. It doesn't use Chrome or Safari, and doesn't need any browser settings changed.

The window has four sections:

- **Contacts**: every contact with an Instagram handle, with its photo, account (iCloud or Google) and when its photo was last synced. **Sync all**, **Sync selected**, or per contact **Sync**, **Edit** (change the handle) and **Remove** (delete the Instagram link). Syncing moves contacts that aren't in iCloud yet, then sets the HD photo.
- **Find matches**: each contact appears with the accounts you follow that might be them, with photos. Click the right account in as many rows as you like (or **Select strong matches**), then **Link N**. They're all linked in one go: Instagram link saved, the contact moved to iCloud, and the HD photo set. If the right account isn't shown, **Search…** in that row searches the accounts you follow by name or username. You can also type any `@username` (or paste a profile link) and pick it the same way. **Search on Instagram ↗** opens a Google search of Instagram for that name in your normal browser. **None** means don't ask about this contact again. **Skip** asks again next time.
- **Add**: lists every contact without an Instagram handle, with a filter (name, phone or email). Tick the box to include contacts that already have one, to change it. Click a contact, type a username or paste a profile link, then **Link**. It saves the profile link in an **Instagram** URL field, moves the contact to iCloud and sets the photo. To keep a contact off Instagram, leave the handle empty and click **Move to iCloud** instead. You can drop a photo on the row or paste an `https` image link, or skip the photo. Sync leaves these contacts alone, and they stay in **Add** rather than **Contacts**.
- **Cleanup & backups**:
  - **Phone numbers**: formats iCloud contacts' numbers as `+63 917 123 4567` (landlines `+63 2 8123 4567`, US `+1 212 555 0123`) and removes a number that appears twice on the same contact. You see every change before confirming. Numbers it can't safely recognize, such as `1-800-MY-APPLE`, short codes and other countries, are left as they are. Every sync does this too.
  - **Backups**: lists every backup with **Show in Finder** and **Restore**. Each contact keeps its oldest backup and its 2 latest different versions. Older versions are deleted automatically, on launch and after each job, and a card that hasn't changed isn't backed up again.

Long tasks show their progress in a panel at the bottom of the window, with **Stop**. If one needs a decision, such as whether to merge with a card that's already in iCloud, the question appears there. Tasks run one at a time; more wait their turn.

Photos are full size (usually up to 1080×1080). If someone uploaded a small profile picture, Insta Sync uses it only when Instagram confirms it's the biggest version it has; the result says "the biggest Instagram has". If it can't get a confirmed full-size picture, that contact is skipped and listed. It never uses a reduced copy of a bigger picture.

## Logging in to Instagram

Open **Instagram → Log In…** (or the toolbar button). The Instagram window shows instagram.com; log in there as usual, including any two-factor step. When the login completes the window closes by itself and the toolbar shows **Instagram: logged in**.

The login (cookies) is kept in Insta Sync's own browser storage, separate from Safari and Chrome, and stays after you quit. Insta Sync never sees or stores your password. **Instagram → Log Out** forgets it.

**Log in with your browser instead.** Insta Sync's own browser can't use passkeys (macOS only allows them in apps Apple approves as web browsers), so if Instagram asks for a passkey the login gets stuck. Use the bar at the top of the Instagram window instead:
1. Pick Safari or Chrome (or Brave, Edge, Arc) and click **Open Instagram in …**. Log in there as usual; passkeys and every two-factor method work.
2. Click **Import Login**. Insta Sync copies that browser's instagram.com cookies (and nothing else) into its own browser storage.

For Chrome-family browsers, macOS asks once to let Insta Sync use the browser's "Safe Storage" key; click Allow. For Safari, Insta Sync needs Full Disk Access (System Settings → Privacy & Security → Full Disk Access). After a rebuild, macOS asks again.

If Instagram asks for a security check during a task, the task stops and offers **Open Instagram window**, where you can complete it. **Instagram → Show Instagram Window** opens it any time.

## Where the Instagram link is kept

Each contact's Instagram is a URL field labelled **Instagram**, e.g. `https://www.instagram.com/juan.delacruz/`. It's tappable on your iPhone and syncs through iCloud.

Handles typed into a contact's Notes are not read. Use **Add**, **Find matches** or **Edit** to set the link.

## Moving contacts to iCloud

Contacts with an Instagram handle are moved automatically, from any other account (e.g. Google, On My Mac). A contact without a handle moves only when you click **Move to iCloud** in **Add**. Everything else stays where it is, and your default account doesn't change.

Each move:
1. saves a backup `.vcf` (with the photo and Notes);
2. copies the contact into iCloud;
3. deletes the original.

If iCloud already has a card with the same name, you're asked (in the progress panel) whether to merge into it or keep a separate card.

Limits: a moved contact leaves any groups it was in, and if a card is linked to cards in other accounts, only that card moves. To undo, use **Restore** on the backup (or double-click the `.vcf`).

## Finding matches

Matches come from **the accounts you follow**, fetched in the hidden browser with your Instagram login and cached for 7 days. **Refresh following** on the Find matches page fetches it again.

A contact appears only if at least one followed account plausibly matches: first and last name in the account's name or username, or the same surname. Same-surname matches are labelled **Possible**, because they're often relatives.

## How it works

- **Instagram**: a hidden WebKit browser view, in an invisible window that never appears on screen, in the Window menu, Mission Control or Cmd-Tab. For photos, it loads each profile page, the same as you visiting it, and takes the full-size picture the page shows (or, if the page only shows a small one, the profile's HD picture URL from the same logged-in page). The following list comes from the same endpoint instagram.com's own page uses. It pauses between requests.
- **Contacts**: Apple's Contacts framework for reading cards, accounts, photos, phone numbers, the Instagram URL field, moving cards between accounts and making backups. Contacts.app isn't needed to list contacts. When a task changes a card, Insta Sync reads that card's Notes through Contacts.app (Apple doesn't let ordinary apps read Notes through the framework), so the backup includes them and a card moved to iCloud keeps them. That's why macOS asks to let Insta Sync control Contacts, and why Contacts.app may open during a sync.
- **Data**: `~/Library/Application Support/Insta Sync/` holds `backups/<date_time>/`, `following.json`, `none.json` (contacts you answered None for), `sync_state.json` (when each photo was synced) and Instagram thumbnails.

## Privacy

- Everything stays on your Mac. Insta Sync talks only to instagram.com and Instagram's picture servers (to look up profiles and download pictures), to any image link you paste in **Add**, and to Apple's Contacts on your Mac. It has no server and sends no analytics.
- Your Instagram login lives in Insta Sync's own browser storage. **Import Login** reads only the instagram.com cookies of the browser you pick, once, when you click it. It never reads other sites' cookies, and never sees your password.
- Before changing a contact it saves a `.vcf` backup. Backups, the following list, sync history and a troubleshooting log (`browser.log`, capped at about 1 MB, without passwords, cookies or what you type) are in `~/Library/Application Support/Insta Sync/`. Delete that folder to remove them.

## Build and run

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.

```sh
scripts/build_app.sh               # builds "Insta Sync.app" in this folder (git-ignored)
scripts/build_app.sh /Applications # or somewhere else
scripts/test.sh                    # unit tests
swift scripts/make_icon.swift      # redraws Resources/AppIcon.icns and AppIcon.png
```

Open **Insta Sync.app**. On the first run, macOS asks for Contacts access and to let Insta Sync control Contacts; allow both. Each rebuild has a new ad-hoc signature, so macOS asks again after rebuilding.

If the old Python version's `data/` folder is in this project folder, the first launch offers to import its following list, photo sync history, None answers and backups.

## Files

- `Sources/InstaSyncCore/`: handle parsing, phone formatting, matching, cleanup rules, data files. No UI; covered by `Tests/`.
- `Sources/InstaSync/`: the app. `Instagram/` (hidden browser, login window, lookups), `Contacts/` (framework + Notes), `Jobs/` (task queue and the sync/link/cleanup steps), `UI/` (SwiftUI views).
- `Resources/`: `Info.plist` and the app icon. `scripts/`: build, test and icon drawing.

## Notes

- This reads Instagram's web pages with a script, which is unofficial and against Instagram's terms, and it can break whenever Instagram changes its site.
- If Instagram shows "Please wait a few minutes" or a security check, the task stops, tells you how far it got, and you can run it again later.
