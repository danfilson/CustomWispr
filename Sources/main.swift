import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// A menu-bar app has no visible main menu, but key equivalents like ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z
// are still dispatched through NSApp.mainMenu. Without an Edit menu they do nothing in any
// of our windows (Settings, Feedback), leaving right-click → Paste as the only way in.
let mainMenu = NSMenu()
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
mainMenu.addItem(editItem)
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate

app.run()
