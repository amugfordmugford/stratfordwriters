# MessengerBar

A tiny macOS menu bar app for Facebook Messenger (macOS 14+).

- **Left-click** the bubble icon to open Messenger in a popover; click away to hide it.
- **Right-click** for options: Inbox, Reload, Open in Browser, load from messenger.com or facebook.com/messages, window size, Launch at Login, Quit.
- The number of unread chats shows next to the icon.
- New messages show as macOS notifications while the popover is closed.

It runs the real Messenger web client in a WebKit view, so you can send, read, edit, unsend and delete messages, react and attach files the same way you do on messenger.com. You stay signed in between launches. Links to other sites open in your default browser, and files you save land in ~/Downloads.

Personal Messenger accounts have no public API (Meta's Messenger Platform API only works for business Pages), so this app uses the web client instead of an API.

## Build

```bash
./build.sh            # builds build/MessengerBar.app
./build.sh --run      # build and launch
./build.sh --install --run   # copy to /Applications (or ~/Applications if you're not an admin) and launch
```

You need Xcode installed. The app has an ad-hoc signature, so if you copy it to another Mac, the first time you open it there, right-click it and choose Open.

Shortcuts while the popover is open: ⌘R reload, ⌘[ / ⌘] back/forward, ⌘W close, plus the usual ⌘C / ⌘V / ⌘Z.
