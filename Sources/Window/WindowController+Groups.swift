import AppKit

/// Named groups keep related ordinary tabs together and expose group actions through a native menu.
extension WindowController {
    @objc func showTabGroups(_ sender: Any?) {
        let menu = NSMenu(title: "Tab Groups")
        let create = menu.addItem(withTitle: "New Group for Current Tab…", action: #selector(nameTabGroup(_:)), keyEquivalent: "")
        create.target = self
        create.isEnabled = active != nil && active?.isPinned == false
        for name in Set(tabs.compactMap(\.groupName)).sorted() {
            let group = NSMenu()
            for tab in tabs where tab.groupName == name {
                let item = group.addItem(
                    withTitle: tab.title.isEmpty ? "New Tab" : tab.title, action: #selector(selectGroupedTab(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tab
            }
            group.addItem(.separator())
            let collapse = group.addItem(
                withTitle: collapsedGroups.contains(name) ? "Expand Group" : "Collapse Group", action: #selector(toggleGroupFromMenu(_:)),
                keyEquivalent: "")
            collapse.target = self
            collapse.representedObject = name
            for (title, action) in [
                ("Move Current Tab Here", #selector(moveToGroup(_:))), ("Ungroup Tabs", #selector(ungroupTabs(_:))),
                ("Close Group", #selector(closeGroup(_:))),
            ] {
                let item = group.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = name
            }
            menu.addItem(withTitle: name, action: nil, keyEquivalent: "").submenu = group
        }
        menu.popUp(positioning: nil, at: NSPoint(x: strip.bounds.maxX - 14, y: strip.bounds.maxY + 4), in: strip)
    }

    @objc private func nameTabGroup(_ sender: Any?) {
        guard let window, let active, !active.isPinned else { return }
        let alert = NSAlert()
        alert.messageText = "Name this tab group"
        let field = NSTextField(string: active.groupName ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create Group")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            self.setGroup(name, for: active)
        }
    }

    func setGroup(_ name: String?, for tab: Tab) {
        guard !tab.isPinned else { return }
        tab.groupName = name
        if let name { collapsedGroups.remove(name) }
        if let name, let index = tabs.lastIndex(where: { $0 !== tab && $0.groupName == name }) { move(tab, to: index + 1) }
        updateStrip()
    }

    @objc private func selectGroupedTab(_ sender: NSMenuItem) { if let tab = sender.representedObject as? Tab { select(tab) } }
    @objc private func toggleGroupFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        toggleGroup(name)
    }
    func toggleGroup(_ name: String) {
        if collapsedGroups.contains(name) { collapsedGroups.remove(name) } else { collapsedGroups.insert(name) }
        updateStrip()
    }
    func closeGroup(named name: String) { tabs.filter { $0.groupName == name }.forEach(close) }
    @objc private func moveToGroup(_ sender: NSMenuItem) {
        if let tab = active, let name = sender.representedObject as? String { setGroup(name, for: tab) }
    }
    @objc private func ungroupTabs(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        tabs.filter { $0.groupName == name }.forEach { $0.groupName = nil }
        updateStrip()
    }
    @objc private func closeGroup(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        closeGroup(named: name)
    }
}
