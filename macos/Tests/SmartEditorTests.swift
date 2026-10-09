import Foundation
import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct SmartEditorTests {
    private func cond(_ property: String, _ op: String, _ left: String, right: String = "", unit: String = "") -> SmartCondition {
        SmartCondition(property: property, operator: op, left: left, right: right, unit: unit)
    }

    private func editor(_ rule: SmartRule = SmartRule(logic: .all, conditions: []), name: String = "List", mode: SmartEditorModel.Mode = .create(parent: "root"))
        -> SmartEditorModel
    {
        SmartEditorModel(mode: mode, name: name, rule: rule)
    }

    @Test func aNewListStartsWithArtistEqualsNothing() {
        let e = editor(name: "Untitled Intelligent List")
        #expect(e.rows.count == 1)
        #expect(e.rows[0].property == "artist" && e.rows[0].op == "1" && e.rows[0].left.isEmpty)
        #expect(e.title == "Create New Intelligent Playlist")
        #expect(!e.canSave, "a row without a value cannot be saved")
        e.rows[0].left = "  Moby "
        #expect(e.canSave)
        #expect(e.rule.conditions[0].left == "Moby", "values are trimmed on save")
        e.name = "   "
        #expect(!e.canSave)
    }

    @Test func theVocabularyIsRekordboxsInItsOrder() {
        #expect(SmartCatalogue.properties.count == 23)
        #expect(SmartCatalogue.properties.first?.label == "Album" && SmartCatalogue.properties.last?.label == "Year")
        #expect(SmartCatalogue.operators.map(\.value) == ["1", "2", "3", "4", "6", "7", "5", "8", "9", "10", "11"])
        #expect(SmartCatalogue.operators(for: .tag).map(\.label) == ["contains", "does not contain"])
        #expect(SmartCatalogue.operators(for: .date).count == 7)
    }

    @Test func changingThePropertyKeepsAnOperatorItStillTakes() {
        let e = editor(SmartRule(logic: .all, conditions: [cond("bpm", "3", "126")]))
        let id = e.rows[0].id
        e.changeProperty(id, to: "rating")  // number to number: > stays
        #expect(e.rows[0].op == "3" && e.rows[0].left == "126")
        e.changeProperty(id, to: "artist")  // text takes no ">": falls back to the first
        #expect(e.rows[0].op == "1")
        e.changeProperty(id, to: "name")
        #expect(e.rows[0].op == "1")
    }

    @Test func crossingMyTagClearsTheValues() {
        let e = editor(SmartRule(logic: .all, conditions: [cond("artist", "8", "daft")]))
        let id = e.rows[0].id
        e.changeProperty(id, to: "myTag")
        #expect(e.rows[0].left.isEmpty && e.rows[0].op == "8")
        e.rows[0].left = "7"
        e.changeProperty(id, to: "genre")
        #expect(e.rows[0].left.isEmpty)
        // Not crossing it keeps the text.
        e.rows[0].left = "House"
        e.changeProperty(id, to: "label")
        #expect(e.rows[0].left == "House")
    }

    @Test func relativeOperatorsGetAUnitAndRangesKeepTheirUpperValue() {
        let e = editor(SmartRule(logic: .all, conditions: [cond("stockDate", "1", "")]))
        let id = e.rows[0].id
        e.changeOperator(id, to: "6")
        #expect(e.rows[0].unit == "day")
        e.rows[0].unit = "week"
        e.changeOperator(id, to: "7")
        #expect(e.rows[0].unit == "week", "a unit already chosen stays")
        e.changeOperator(id, to: "5")
        #expect(e.rows[0].unit.isEmpty)
        e.rows[0].right = "2026-01-01"
        e.changeOperator(id, to: "5")
        #expect(e.rows[0].right == "2026-01-01")
        e.changeOperator(id, to: "3")
        #expect(e.rows[0].right.isEmpty)
        e.changeProperty(id, to: "bpm")  // a range carried to another number property keeps nothing stale
        #expect(e.rows[0].op == "3")
    }

    @Test func rowsAddAndRemoveButNeverBelowOne() {
        let e = editor()
        e.addRow()
        #expect(e.rows.count == 2)
        e.removeRow(e.rows[0].id)
        e.removeRow(e.rows[0].id)
        #expect(e.rows.count == 1)
    }

    @Test func matchAnyIsCarriedToTheRule() {
        let e = editor(SmartRule(logic: .any, conditions: [cond("artist", "1", "a"), cond("genre", "8", "house")]))
        #expect(e.logic == .any && e.rule.logic == .any && e.rule.conditions.count == 2)
        #expect(e.title == "Create New Intelligent Playlist")
        #expect(editor(mode: .edit(id: "3")).title == "Edit the Intelligent Playlist")
    }

    @Test func aRuleWithAnUnsupportedPropertyIsShownReadOnly() {
        let rule = SmartRule(logic: .all, conditions: [cond("", "1", "x"), cond("artist", "8", "a")])
        let e = editor(rule, name: "Odd", mode: .edit(id: "3"))
        #expect(e.readOnlyRules)
        let before = e.rows
        e.addRow()
        e.removeRow(e.rows[0].id)
        e.changeProperty(e.rows[0].id, to: "genre")
        e.changeOperator(e.rows[1].id, to: "9")
        #expect(e.rows == before, "no edit reaches the rows")
        #expect(e.rule == rule, "the rule goes back exactly as it came")
        #expect(e.canSave && e.saveTitle == "Rename")
        e.name = ""
        #expect(!e.canSave)
        #expect(!editor(SmartRule(logic: .all, conditions: [cond("artist", "1", "a")])).readOnlyRules)
    }

    // MARK: Saving through the model

    private func ready() async -> (AppModel, MockBackend) {
        let backend = MockBackend(trackCount: 10, nodes: [
            TreeNode(id: "all", name: "All Tracks", kind: .allTracks, depth: 0, expanded: nil, childCount: 10),
            TreeNode(id: "playlists", name: "Playlists", kind: .collection, depth: 0, expanded: true, childCount: 1),
            TreeNode(id: "3", name: "Peak", kind: .smartPlaylist, depth: 1, expanded: nil, childCount: nil),
        ])
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.protectLibrary = false
        model.start()
        #expect(await eventually { model.opened != nil && !model.isReadOnly })
        return (model, backend)
    }

    @Test func savingANewListCreatesItClosesTheSheetAndSelectsIt() async {
        let (model, backend) = await ready()
        model.newSmartPlaylist(near: nil)
        let e = model.smartEditor!
        e.name = "Four Stars"
        e.rows[0] = SmartRow(property: "rating", op: "3", left: "3", right: "", unit: "")
        await model.saveSmartEditor(e)
        #expect(model.smartEditor == nil)
        #expect(await backend.editLog == ["createSmartPlaylist(Four Stars,root)"])
        #expect(model.selectedNodeID == "pl:100")
        #expect(model.sidebar.node(withID: "pl:100")?.kind == .smartPlaylist)
        let rule = try? await backend.smartRule(playlistID: "100")
        #expect(rule?.conditions.first?.property == "rating")
    }

    @Test func aRefusedSaveKeepsTheSheetOpenWithTheMessage() async {
        let (model, backend) = await ready()
        model.newSmartPlaylist(near: nil)
        let e = model.smartEditor!
        e.rows[0].left = "x"
        await backend.setFailure(.Malformed(message: "\"\" is not a property a rule can use here.", detail: nil))
        await model.saveSmartEditor(e)
        #expect(model.smartEditor === e)
        #expect(e.error == "\"\" is not a property a rule can use here.")
        #expect(model.notice == e.error)
    }

    @Test func editingASmartListLoadsItsRuleAndSavesRuleAndNameTogether() async {
        let (model, backend) = await ready()
        await backend.setSmartRule(SmartRule(logic: .any, conditions: [SmartCondition(property: "artist", operator: "8", left: "a", right: "", unit: "")]), for: "3")
        await model.editSmartPlaylist(model.sidebar.node(withID: "pl:3")!)
        let e = model.smartEditor!
        #expect(e.name == "Peak" && e.logic == .any && e.rows.count == 1)
        e.name = "Peakier"
        e.rows[0].left = "b"
        await model.saveSmartEditor(e)
        #expect(model.smartEditor == nil)
        #expect(await backend.editLog == ["saveSmartPlaylist(3,Peakier)"])
        #expect(await eventually { model.sidebar.node(withID: "pl:3")?.name == "Peakier" })
        // The history arrives as an event of its own, after the save returns.
        #expect(await eventually { model.editHistory.undoLabel == "Rename Playlist" })
    }

    @Test func aReadOnlyRuleOnlyRenames() async {
        let (model, backend) = await ready()
        await backend.setSmartRule(SmartRule(logic: .all, conditions: [SmartCondition(property: "", operator: "1", left: "x", right: "", unit: "")]), for: "3")
        await model.editSmartPlaylist(model.sidebar.node(withID: "pl:3")!)
        let e = model.smartEditor!
        #expect(e.readOnlyRules)
        await model.saveSmartEditor(e)  // unchanged name: nothing to do
        #expect(model.smartEditor == nil)
        #expect(await backend.editLog.isEmpty)
        await model.editSmartPlaylist(model.sidebar.node(withID: "pl:3")!)
        model.smartEditor!.name = "Renamed"
        await model.saveSmartEditor(model.smartEditor!)
        #expect(await backend.editLog == ["renamePlaylist(3,Renamed)"])
    }
}
