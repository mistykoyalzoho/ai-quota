import Cocoa
import SwiftUI

@MainActor
final class PopoverManager: NSObject, NSPopoverDelegate {
    static let shared = PopoverManager()

    private var popover: NSPopover?
    private let viewModel = UnifiedPopoverViewModel()
    private weak var statusButton: NSStatusBarButton?

    func configure(with button: NSStatusBarButton) {
        self.statusButton = button

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self

        let root = UnifiedPopoverView(
            viewModel: viewModel,
            onOpenAddAccount: {
                AddAccountWindowController.shared.show()
            },
            onOpenManageAccounts: {
                ManageAccountsWindowController.shared.show()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        pop.contentViewController = NSHostingController(rootView: root)
        self.popover = pop
    }

    var isShown: Bool {
        popover?.isShown ?? false
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        guard let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            viewModel.reload()
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func close() {
        popover?.performClose(nil)
    }

    func reload() {
        viewModel.reload()
    }
}
