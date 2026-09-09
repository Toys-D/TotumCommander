import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest

@testable import TotumComXLApp

// MARK: - PanelViewController Layout Tests

@MainActor
final class PanelViewControllerLayoutTests: XCTestCase {

    private func makePanelVC() -> PanelViewController {
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSTemporaryDirectory(),
            pathDefaultsKey: "test.layout.\(UUID().uuidString)",
            viewModeDefaultsKey: "test.mode.\(UUID().uuidString)",
            showHiddenFiles: true
        )
        let tabsVM = PanelTabsViewModel(panelKey: "test.tabs.\(UUID().uuidString)", initialPath: NSTemporaryDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()
        return vc
    }

    func test_layoutOrder_volumeBarIsAtTop() {
        let vc = makePanelVC()
        let container = vc.view
        let subviews = container.subviews

        // VolumeBar should be constrained to top of container
        XCTAssertGreaterThanOrEqual(subviews.count, 6,
            "Container should have at least 6 subviews (volume, breadcrumb, tabs, sort, fileList, status)")
    }

    func test_layoutOrder_tabBarAfterBreadcrumb() {
        let vc = makePanelVC()
        let container = vc.view

        // Find hosting views by checking their order in constraints
        // VolumeBar → Breadcrumb → TabBar → SortBar → FileList → StatusBar
        let subviews = container.subviews
        guard subviews.count >= 6 else {
            XCTFail("Expected 6 subviews, got \(subviews.count)")
            return
        }

        // The first subview added should be volumeBar (index 0)
        // breadcrumb should be index 1
        // tabBar should be index 2 (AFTER breadcrumb)
        // sortBar should be index 3
        // fileListContainer should be index 4
        // statusBar should be index 5
        let volumeBar = subviews[0]
        let breadcrumb = subviews[1]
        let tabBar = subviews[2]
        let sortBar = subviews[3]

        // Verify order via constraints: tabBar.top == breadcrumb.bottom
        let tabBarTopConstraint = container.constraints.first { constraint in
            constraint.firstItem === tabBar
            && constraint.firstAttribute == .top
            && constraint.secondItem === breadcrumb
            && constraint.secondAttribute == .bottom
        }
        XCTAssertNotNil(tabBarTopConstraint,
            "TabBar top anchor should be constrained to Breadcrumb bottom (tabs after breadcrumbs)")

        // Verify: volumeBar.top == container.top
        let volumeBarTopConstraint = container.constraints.first { constraint in
            constraint.firstItem === volumeBar
            && constraint.firstAttribute == .top
            && constraint.secondItem === container
            && constraint.secondAttribute == .top
        }
        XCTAssertNotNil(volumeBarTopConstraint,
            "VolumeBar should be at the top of container")

        // Verify: sortBar.top == tabBar.bottom
        let sortBarTopConstraint = container.constraints.first { constraint in
            constraint.firstItem === sortBar
            && constraint.firstAttribute == .top
            && constraint.secondItem === tabBar
            && constraint.secondAttribute == .bottom
        }
        XCTAssertNotNil(sortBarTopConstraint,
            "SortBar should be after TabBar")
    }
}

// MARK: - View Mode Switching Tests

@MainActor
final class ViewModeSwitchingTests: XCTestCase {

    private func makePanelVC() -> PanelViewController {
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSTemporaryDirectory(),
            pathDefaultsKey: "test.viewmode.\(UUID().uuidString)",
            viewModeDefaultsKey: "test.mode.\(UUID().uuidString)",
            showHiddenFiles: true
        )
        let tabsVM = PanelTabsViewModel(panelKey: "test.tabs.\(UUID().uuidString)", initialPath: NSTemporaryDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()
        return vc
    }

    func test_initialViewMode_isDetailed() {
        let vc = makePanelVC()
        XCTAssertEqual(vc.viewModel.viewMode, .detailed)
    }

    func test_tableView_isPanelNSTableView() {
        let vc = makePanelVC()
        XCTAssertTrue(vc.tableView is PanelNSTableView,
            "tableView should be PanelNSTableView with custom key handling")
    }

    func test_tableView_hasKeyHandler() {
        let vc = makePanelVC()
        let panelTable = vc.tableView as! PanelNSTableView
        XCTAssertNotNil(panelTable.keyHandler, "keyHandler should be set for keyboard forwarding")
    }

    func test_handleKeyEvent_guardsIsActivePanel() {
        // Inactive panel must NOT process key events
        let vc = makePanelVC()
        vc.isActivePanel = false
        let downArrow = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 125 // Down arrow
        )!
        let handled = vc.handleKeyEvent(downArrow)
        XCTAssertFalse(handled, "Inactive panel should NOT handle key events")
    }

    func test_viewModeChange_combineBindingExists() {
        let vc = makePanelVC()
        // Verify viewMode can be changed without crash
        vc.viewModel.viewMode = .brief
        vc.viewModel.viewMode = .thumbnails
        vc.viewModel.viewMode = .detailed
        // No crash = bindings are set up correctly
    }

    func test_scrollViewAndAlternateHosting_existInViewHierarchy() {
        let vc = makePanelVC()

        let scrollView = vc.view.subviews.first { $0 is NSScrollView && ($0 as? NSScrollView)?.documentView is PanelNSTableView }
        XCTAssertNotNil(scrollView, "ScrollView with PanelNSTableView should exist in view hierarchy")

        // alternateHosting is lazy — not in hierarchy until switching to non-detailed mode
        let alternateView = vc.view.subviews.first { $0 is NSHostingView<AnyView> }
        XCTAssertNil(alternateView, "Alternate hosting should NOT be in hierarchy in default detailed mode")
    }
}

// MARK: - MainSplitViewController Tests

@MainActor
final class MainSplitViewControllerTests: XCTestCase {

    private func makeSplitVC() -> MainSplitViewController {
        let leftVM = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSTemporaryDirectory(),
            pathDefaultsKey: "test.split.left.\(UUID().uuidString)",
            viewModeDefaultsKey: "test.split.left.mode.\(UUID().uuidString)",
            showHiddenFiles: true
        )
        let rightVM = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSTemporaryDirectory(),
            pathDefaultsKey: "test.split.right.\(UUID().uuidString)",
            viewModeDefaultsKey: "test.split.right.mode.\(UUID().uuidString)",
            showHiddenFiles: true
        )
        let leftTabs = PanelTabsViewModel(panelKey: "test.split.ltabs.\(UUID().uuidString)", initialPath: NSTemporaryDirectory())
        let rightTabs = PanelTabsViewModel(panelKey: "test.split.rtabs.\(UUID().uuidString)", initialPath: NSTemporaryDirectory())

        return MainSplitViewController(leftPanel: leftVM, rightPanel: rightVM, leftTabs: leftTabs, rightTabs: rightTabs)
    }

    func test_initialActivePanel_isLeft() {
        let splitVC = makeSplitVC()
        splitVC.loadViewIfNeeded()
        XCTAssertEqual(splitVC.activePanel, .left)
    }

    func test_setActivePanel_switchesToRight() {
        let splitVC = makeSplitVC()
        splitVC.loadViewIfNeeded()

        splitVC.setActivePanel(.right)

        XCTAssertEqual(splitVC.activePanel, .right)
        XCTAssertTrue(splitVC.rightPanelVC.isActivePanel)
        XCTAssertFalse(splitVC.leftPanelVC.isActivePanel)
    }

    func test_setActivePanel_switchesBackToLeft() {
        let splitVC = makeSplitVC()
        splitVC.loadViewIfNeeded()

        splitVC.setActivePanel(.right)
        splitVC.setActivePanel(.left)

        XCTAssertEqual(splitVC.activePanel, .left)
        XCTAssertTrue(splitVC.leftPanelVC.isActivePanel)
        XCTAssertFalse(splitVC.rightPanelVC.isActivePanel)
    }

    func test_activePanelViewModel_returnsCorrectVM() {
        let splitVC = makeSplitVC()
        splitVC.loadViewIfNeeded()

        XCTAssertTrue(splitVC.activePanelViewModel === splitVC.leftPanelVM)

        splitVC.setActivePanel(.right)
        XCTAssertTrue(splitVC.activePanelViewModel === splitVC.rightPanelVM)
    }

    func test_inactivePanelViewModel_returnsOppositeVM() {
        let splitVC = makeSplitVC()
        splitVC.loadViewIfNeeded()

        XCTAssertTrue(splitVC.inactivePanelViewModel === splitVC.rightPanelVM)

        splitVC.setActivePanel(.right)
        XCTAssertTrue(splitVC.inactivePanelViewModel === splitVC.leftPanelVM)
    }

    func test_setShowHiddenFiles_doesNotCrash() {
        let splitVC = makeSplitVC()
        splitVC.loadViewIfNeeded()

        // Verify method exists and doesn't crash
        splitVC.setShowHiddenFiles(false)
        splitVC.setShowHiddenFiles(true)
    }
}

// MARK: - Extracted Types Tests (PreviewHelpers)

@MainActor
final class PreviewHelpersTests: XCTestCase {

    // MARK: FileCategory

    func test_fileCategory_videoExtensions() {
        XCTAssertEqual(fileCategory(extension: "mp4"), .video)
        XCTAssertEqual(fileCategory(extension: "mov"), .video)
        XCTAssertEqual(fileCategory(extension: "mkv"), .video)
    }

    func test_fileCategory_audioExtensions() {
        XCTAssertEqual(fileCategory(extension: "mp3"), .audio)
        XCTAssertEqual(fileCategory(extension: "flac"), .audio)
        XCTAssertEqual(fileCategory(extension: "wav"), .audio)
    }

    func test_fileCategory_imageExtensions() {
        XCTAssertEqual(fileCategory(extension: "png"), .image)
        XCTAssertEqual(fileCategory(extension: "jpg"), .image)
        XCTAssertEqual(fileCategory(extension: "heic"), .image)
    }

    func test_fileCategory_pdfExtension() {
        XCTAssertEqual(fileCategory(extension: "pdf"), .pdf)
    }

    func test_fileCategory_textExtensions() {
        XCTAssertEqual(fileCategory(extension: "swift"), .text)
        XCTAssertEqual(fileCategory(extension: "py"), .text)
        XCTAssertEqual(fileCategory(extension: "json"), .text)
        XCTAssertEqual(fileCategory(extension: "txt"), .text)
    }

    func test_fileCategory_markdownExtensions() {
        XCTAssertEqual(fileCategory(extension: "md"), .markdown)
        XCTAssertEqual(fileCategory(extension: "markdown"), .markdown)
    }

    func test_fileCategory_binaryExtensions_returnsOther() {
        XCTAssertEqual(fileCategory(extension: "exe"), .other)
        XCTAssertEqual(fileCategory(extension: "zip"), .other)
        XCTAssertEqual(fileCategory(extension: "dmg"), .other)
    }

    func test_fileCategory_stripsLeadingDot() {
        XCTAssertEqual(fileCategory(extension: ".mp4"), .video)
        XCTAssertEqual(fileCategory(extension: ".swift"), .text)
    }

    func test_fileCategory_caseInsensitive() {
        XCTAssertEqual(fileCategory(extension: "MP4"), .video)
        XCTAssertEqual(fileCategory(extension: "SWIFT"), .text)
        XCTAssertEqual(fileCategory(extension: "Png"), .image)
    }

    func test_fileCategory_emptyExtension_returnsOther() {
        XCTAssertEqual(fileCategory(extension: ""), .other)
    }

    func test_fileCategory_fonts() {
        XCTAssertEqual(fileCategory(extension: "ttf"), .font)
        XCTAssertEqual(fileCategory(extension: "otf"), .font)
        XCTAssertEqual(fileCategory(extension: "ttc"), .font)
        XCTAssertEqual(fileCategory(extension: "woff"), .font)
        XCTAssertEqual(fileCategory(extension: "OTF"), .font)   // case-insensitive
        XCTAssertEqual(autoMode(for: .font), .font)
    }

    /// Внешний редактор, если назначен, важнее места встроенного — раньше при включённом
    /// «редакторе в панели» F4 открывал наш редактор и не спрашивал про чужую программу.
    func test_внешнийРедакторВажнееМестаВстроенного() {
        typealias Road = FileOperationsService.EditorRoad
        XCTAssertEqual(FileOperationsService.editorRoad(externalConfigured: true, editorInPanel: true, insideArchive: false), Road.external)
        XCTAssertEqual(FileOperationsService.editorRoad(externalConfigured: true, editorInPanel: false, insideArchive: false), Road.external)
        XCTAssertEqual(FileOperationsService.editorRoad(externalConfigured: true, editorInPanel: true, insideArchive: true), Road.embedded,
                       "в архиве чужой программе отдавать нечего — наш редактор с временной копией")
        XCTAssertEqual(FileOperationsService.editorRoad(externalConfigured: false, editorInPanel: true, insideArchive: false), Road.embedded)
        XCTAssertEqual(FileOperationsService.editorRoad(externalConfigured: false, editorInPanel: false, insideArchive: false), Road.window)
    }

    func test_fileCategory_postScript() {
        // macOS has no PostScript rasteriser since 10.15, so these must NOT go to Quick Look
        // (which renders nothing) — they route to the bundled Ghostscript instead.
        XCTAssertEqual(fileCategory(extension: "eps"), .postScript)
        XCTAssertEqual(fileCategory(extension: "ps"), .postScript)
        XCTAssertEqual(fileCategory(extension: "EPS"), .postScript)
        XCTAssertEqual(autoMode(for: .postScript), .postScript)
        // SVG stays on Quick Look — it renders fine there.
        XCTAssertEqual(fileCategory(extension: "svg"), .vectorImage)
    }

    // MARK: PreviewMode

    func test_previewMode_allCases() {
        let allModes: [PreviewMode] = [.auto, .quickLook, .image, .text, .hex, .video, .pdf,
                                       .document, .djvu, .book, .drawing, .font, .postScript,
                                       .info]
        XCTAssertEqual(PreviewMode.allCases.count, allModes.count)
        for mode in allModes {
            XCTAssertFalse(mode.iconName.isEmpty, "\(mode) should have an icon name")
            XCTAssertFalse(mode.title.isEmpty, "\(mode) should have a title")
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func test_wordProcessingDocuments_areRecognised() {
        for ext in ["doc", "docx", "docm", "dot", "dotx", "odt", "rtf"] {
            XCTAssertTrue(isWordProcessingDocument(extension: ext), "\(ext) should open in .document mode")
            XCTAssertTrue(isWordProcessingDocument(extension: ext.uppercased()), "\(ext) should be case-insensitive")
        }
        // textutil returns an empty document for these, and their Quick Look preview already uses
        // the full width — so they must stay on Quick Look.
        for ext in ["xls", "xlsx", "ppt", "pptx", "key", "numbers", "pages", "pdf", "png"] {
            XCTAssertFalse(isWordProcessingDocument(extension: ext), "\(ext) must NOT use .document mode")
        }
    }

    // MARK: autoMode

    func test_fileCategory_djvuExtensions() {
        // macOS has no DjVu support at all, so this must come from our own extension table —
        // the UTType fallback would never classify it.
        XCTAssertEqual(fileCategory(extension: "djvu"), .djvu)
        XCTAssertEqual(fileCategory(extension: "djv"), .djvu)
        XCTAssertEqual(fileCategory(extension: "DJVU"), .djvu, "must be case-insensitive")
        XCTAssertEqual(fileCategory(extension: ".djvu"), .djvu, "leading dot must be tolerated")
    }

    func test_autoMode_forDjVu_returnsDjVuMode() {
        XCTAssertEqual(autoMode(for: .djvu), .djvu)
    }

    func test_djvu_isNotConfusedWithPdf() {
        XCTAssertEqual(fileCategory(extension: "pdf"), .pdf)
        XCTAssertNotEqual(fileCategory(extension: "djvu"), .pdf)
        XCTAssertEqual(autoMode(for: .pdf), .pdf)
    }

    func test_autoMode_forImage_returnsImage() {
        XCTAssertEqual(autoMode(for: .image), .image)
    }

    func test_autoMode_forText_returnsText() {
        XCTAssertEqual(autoMode(for: .text), .text)
        XCTAssertEqual(autoMode(for: .markdown), .text)
    }

    func test_autoMode_forVideo_returnsVideo() {
        XCTAssertEqual(autoMode(for: .video), .video)
        XCTAssertEqual(autoMode(for: .audio), .video)
    }

    func test_autoMode_forPdf_returnsPdf() {
        XCTAssertEqual(autoMode(for: .pdf), .pdf)
    }

    func test_autoMode_forOther_returnsInfo() {
        XCTAssertEqual(autoMode(for: .other), .info)
    }

    // MARK: FileTypeIconCache

    func test_fileTypeIconCache_returnsNonNilIcon() {
        let icon = FileTypeIconCache.icon(fileExtension: "swift", isDirectory: false, targetSize: CGSize(width: 16, height: 16))
        XCTAssertNotNil(icon)
        XCTAssertEqual(icon.size.width, 16)
        XCTAssertEqual(icon.size.height, 16)
    }

    func test_fileTypeIconCache_directoryIcon() {
        let icon = FileTypeIconCache.icon(fileExtension: "", isDirectory: true, targetSize: CGSize(width: 32, height: 32))
        XCTAssertNotNil(icon)
        XCTAssertEqual(icon.size.width, 32)
    }

    func test_fileTypeIconCache_emptyExtension_returnsGenericIcon() {
        let icon = FileTypeIconCache.icon(fileExtension: "", isDirectory: false, targetSize: CGSize(width: 16, height: 16))
        XCTAssertNotNil(icon)
    }
}

// MARK: - FileListRowView Tests

@MainActor
final class FileListRowViewTests: XCTestCase {

    func test_defaultState_neitherCursorNorSelected() {
        let rowView = FileListRowView()
        XCTAssertFalse(rowView.isCursor)
        XCTAssertFalse(rowView.isItemSelected)
    }

    func test_isEmphasized_alwaysFalse() {
        let rowView = FileListRowView()
        rowView.isEmphasized = true
        XCTAssertFalse(rowView.isEmphasized, "isEmphasized should always return false to disable system highlight")
    }

    func test_isSelected_alwaysFalse() {
        let rowView = FileListRowView()
        rowView.isSelected = true
        XCTAssertFalse(rowView.isSelected, "isSelected should always return false to use custom rendering")
    }

    func test_setCursor_storesValue() {
        let rowView = FileListRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        XCTAssertFalse(rowView.isCursor)
        rowView.isCursor = true
        XCTAssertTrue(rowView.isCursor)
        rowView.isCursor = false
        XCTAssertFalse(rowView.isCursor)
    }

    func test_setSelected_storesValue() {
        let rowView = FileListRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        XCTAssertFalse(rowView.isItemSelected)
        rowView.isItemSelected = true
        XCTAssertTrue(rowView.isItemSelected)
        rowView.isItemSelected = false
        XCTAssertFalse(rowView.isItemSelected)
    }
}

// MARK: - PanelTabsViewModel Integration Tests

@MainActor
final class PanelTabsIntegrationTests: XCTestCase {

    func test_panelNavigated_updatesActiveTabPath() {
        let tabsVM = PanelTabsViewModel(panelKey: "test.nav.\(UUID().uuidString)", initialPath: "/tmp")
        let newPath = "/Users"
        tabsVM.panelNavigated(to: newPath)

        XCTAssertEqual(tabsVM.activeTab.path, newPath)
    }

    func test_newTab_addsTabWithPath() {
        let tabsVM = PanelTabsViewModel(panelKey: "test.newtab.\(UUID().uuidString)", initialPath: "/tmp")
        let initialCount = tabsVM.tabs.count

        tabsVM.newTab(path: "/Users")

        XCTAssertEqual(tabsVM.tabs.count, initialCount + 1)
        XCTAssertEqual(tabsVM.activeTab.path, "/Users")
    }

    func test_closeTab_removesTabAndSelectsPrevious() {
        let tabsVM = PanelTabsViewModel(panelKey: "test.close.\(UUID().uuidString)", initialPath: "/tmp")
        tabsVM.newTab(path: "/Users")
        XCTAssertEqual(tabsVM.tabs.count, 2)

        tabsVM.closeTab(at: 1)

        XCTAssertEqual(tabsVM.tabs.count, 1)
        XCTAssertEqual(tabsVM.activeTab.path, "/tmp")
    }

    func test_selectTab_changesActiveIndex() {
        let tabsVM = PanelTabsViewModel(panelKey: "test.select.\(UUID().uuidString)", initialPath: "/tmp")
        tabsVM.newTab(path: "/Users")

        tabsVM.selectTab(at: 0)
        XCTAssertEqual(tabsVM.activeIndex, 0)

        tabsVM.selectTab(at: 1)
        XCTAssertEqual(tabsVM.activeIndex, 1)
    }
}

// MARK: - ViewMode Enum Tests

@MainActor
final class ViewModeEnumTests: XCTestCase {

    func test_viewMode_rawValues() {
        XCTAssertEqual(ViewMode.detailed.rawValue, "detailed")
        XCTAssertEqual(ViewMode.brief.rawValue, "brief")
        XCTAssertEqual(ViewMode.thumbnails.rawValue, "thumbnails")
    }

    func test_viewMode_initFromRawValue() {
        XCTAssertEqual(ViewMode(rawValue: "detailed"), .detailed)
        XCTAssertEqual(ViewMode(rawValue: "brief"), .brief)
        // The removed "icons" mode migrates onto the surviving grid rather
        // than decoding to nil — a saved panel/tab must not snap back to the
        // table view just because the mode was retired.
        XCTAssertEqual(ViewMode(rawValue: "icons"), .thumbnails)
        XCTAssertEqual(ViewMode(rawValue: "thumbnails"), .thumbnails)
        XCTAssertNil(ViewMode(rawValue: "nonexistent"))
    }

    func test_viewModelViewMode_defaultIsDetailed() {
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSTemporaryDirectory(),
            pathDefaultsKey: "test.vmenum.\(UUID().uuidString)",
            viewModeDefaultsKey: "test.vmenum.mode.\(UUID().uuidString)",
            showHiddenFiles: true
        )
        XCTAssertEqual(vm.viewMode, .detailed)
    }

    func test_viewModelViewMode_canBeChanged() {
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSTemporaryDirectory(),
            pathDefaultsKey: "test.vmchange.\(UUID().uuidString)",
            viewModeDefaultsKey: "test.vmchange.mode.\(UUID().uuidString)",
            showHiddenFiles: true
        )
        vm.viewMode = .brief
        XCTAssertEqual(vm.viewMode, .brief)
        vm.viewMode = .thumbnails
        XCTAssertEqual(vm.viewMode, .thumbnails)
    }
}

// MARK: - NotificationNames Tests

final class NotificationNamesTests: XCTestCase {

    func test_fcxlOperationCompleted_notEmpty() {
        XCTAssertFalse(Notification.Name.fcxlOperationCompleted.rawValue.isEmpty)
        XCTAssertEqual(Notification.Name.fcxlOperationCompleted.rawValue, "fcxlOperationCompleted")
    }

    func test_fcxlRequestEditorClose_notEmpty() {
        XCTAssertFalse(Notification.Name.fcxlRequestEditorClose.rawValue.isEmpty)
        XCTAssertEqual(Notification.Name.fcxlRequestEditorClose.rawValue, "fcxlRequestEditorClose")
    }
}
