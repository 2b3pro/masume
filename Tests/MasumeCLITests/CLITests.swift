import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AnnotationModel
import MasumeCommands
@testable import MasumeCLI

/// The CLI without an app: argument parsing, the request each live
/// subcommand builds (the mirror the MCP server must match), exit codes,
/// the default document lookup, and the offline commands on fixtures.
final class CLITests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        OfflineCommands.recoveryDirectory = scratch.appendingPathComponent("recovery")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Fixtures

    private func png(width: Int, height: Int) -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func pdf(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(red: CGFloat(i) * 0.3, green: 0.2, blue: 0.8, alpha: 1)
            ctx.fill(box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// A fake app: records requests and answers from a script.
    private final class FakeApp {
        var requests: [[String: Any]] = []
        var replies: [Data]
        init(replies: [String]) { self.replies = replies.map { Data($0.utf8) } }
        func transport(_ data: Data) throws -> Data {
            requests.append(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
            return replies.isEmpty ? Data(#"{"ok":true,"result":{}}"#.utf8) : replies.removeFirst()
        }
    }

    private func run(_ args: [String], app: FakeApp) -> (code: Int32, out: String, err: String) {
        var out = "", err = ""
        let code = MasumeCLI.run(args, output: { out += $0 }, error: { err += $0 + "\n" }, transport: app.transport)
        return (code, out, err)
    }

    // MARK: Parsing and the mirror table

    func testEveryLiveSubcommandBuildsItsCommand() throws {
        let options = CLIRequest.Options(documentId: "D", expectedRevision: 3, actorId: "nova", reason: "why")
        let table: [(args: [String], command: String, params: [String: Any])] = [
            (["doc"], "get_active_document", [:]),
            (["elements"], "list_elements", [:]),
            (["element", "abc"], "get_element", ["id": "abc"]),
            (["resolve", "d5:f7"], "resolve_grid", ["address": "d5:f7"]),
            (["view", "B2:C3", "--margin", "8"], "view_base_image", ["range": "B2:C3", "margin": 8]),
            (["history", "--limit", "5"], "get_history", ["limit": 5]),
            (["add", "arrow", "from=B3", "to=D6", "color=blue", "width=12"], "create_element",
             ["type": "arrow", "from": "B3", "to": "D6", "color": "blue", "width": 12]),
            (["add", "rectangle", "rect=10,20,30,40", "fill=#FF0000"], "create_element",
             ["type": "rectangle", "rect": ["x": 10.0, "y": 20.0, "width": 30.0, "height": 40.0], "fill": "#FF0000"]),
            (["add", "pen", "points=1,2;3,4"], "create_element",
             ["type": "pen", "points": [["x": 1.0, "y": 2.0], ["x": 3.0, "y": 4.0]]]),
            (["add", "text", "at=C3", "text=Hello world", "bold=false"], "create_element",
             ["type": "text", "at": "C3", "text": "Hello world", "bold": false]),
            (["update", "abc", "color=red", "zOrder=front", "start=5,5"], "update_element",
             ["id": "abc", "color": "red", "zOrder": "front", "start": ["x": 5.0, "y": 5.0]]),
            (["delete", "a", "b"], "delete_elements", ["ids": ["a", "b"]]),
            (["crop", "B2:E5"], "set_crop", ["crop": "B2:E5"]),
            (["crop", "1,2,3,4"], "set_crop", ["crop": ["x": 1.0, "y": 2.0, "width": 3.0, "height": 4.0]]),
            (["crop", "none"], "set_crop", ["crop": NSNull()]),
            (["zone", "C3:E6", "--shape", "ellipse"], "set_zone", ["zone": "C3:E6", "shape": "ellipse"]),
            (["zone", "none"], "set_zone", ["zone": NSNull()]),
            (["view", "zone", "--out", "/tmp/x.png"], "view_base_image", ["range": "zone"]),
            (["density", "24"], "set_grid_density", ["cellsAcrossLongSide": 24]),
            (["undo"], "undo", [:]),
            (["redo"], "redo", [:]),
            (["save", "/tmp/x.masume"], "save_project", ["path": "/tmp/x.masume"]),
            (["export", "/tmp/out.png", "--format", "png", "--bounds", "clipToImage"], "export",
             ["path": "/tmp/out.png", "format": "png", "bounds": "clipToImage"]),
        ]
        for row in table {
            let invocation = try MasumeCLI.parse(row.args)
            let request = try CLIRequest.build(invocation.subcommand, arguments: invocation.arguments,
                                               flags: invocation.flags, options: options)
            XCTAssertEqual(request["command"] as? String, row.command, "\(row.args)")
            XCTAssertEqual(request["params"] as? NSDictionary, row.params as NSDictionary, "\(row.args)")
            XCTAssertEqual(request["documentId"] as? String, "D")
            XCTAssertEqual(request["expectedRevision"] as? Int, 3)
            XCTAssertEqual(request["actorId"] as? String, "nova")
            XCTAssertEqual(request["reason"] as? String, "why")
        }
    }

    func testGlobalOptionsAndUsageErrors() throws {
        let inv = try MasumeCLI.parse(["add", "arrow", "from=A1", "to=B2", "--doc", "X", "--revision", "4",
                                       "--actor", "nova", "--actor-name", "Nova", "--reason", "because", "--pretty"])
        XCTAssertEqual(inv.subcommand, "add")
        XCTAssertEqual(inv.arguments, ["arrow", "from=A1", "to=B2"])
        XCTAssertEqual(inv.options, CLIRequest.Options(documentId: "X", expectedRevision: 4, actorId: "nova",
                                                       actorName: "Nova", reason: "because"))
        XCTAssertTrue(inv.pretty)
        XCTAssertThrowsError(try MasumeCLI.parse([]))
        XCTAssertThrowsError(try MasumeCLI.parse(["--help"]))
        XCTAssertEqual(MasumeCLI.run([], output: { _ in }, error: { _ in }, transport: { $0 }), 64, "no subcommand is a mistake")
        XCTAssertThrowsError(try MasumeCLI.parse(["doc", "--revision", "x"]))
        XCTAssertThrowsError(try MasumeCLI.parse(["doc", "--bogus", "1"]))
        XCTAssertEqual(MasumeCLI.run(["frobnicate"], output: { _ in }, error: { _ in }, transport: { $0 }), 64)
        XCTAssertEqual(MasumeCLI.run(["add"], output: { _ in }, error: { _ in }, transport: { $0 }), 64)
    }

    func testHelpPrintsToStdoutAndExitsZero() {
        var out: [String] = [], err: [String] = []
        let transport: (Data) throws -> Data = { _ in XCTFail("help never talks to the app"); return Data() }
        XCTAssertEqual(MasumeCLI.run(["--help"], output: { out.append($0) }, error: { err.append($0) }, transport: transport), 0)
        XCTAssertTrue(out.joined().hasPrefix("usage: masume"))
        XCTAssertTrue(out.joined().contains("help add"), "the usage screen points at the topics")
        XCTAssertTrue(err.isEmpty)

        for arguments in [["help", "add"], ["add", "--help"], ["add", "stamp", "-h"], ["HELP", "ADD"]] {
            out = []
            let status = MasumeCLI.run(arguments, output: { out.append($0) }, error: { _ in }, transport: transport)
            XCTAssertEqual(status, 0, "\(arguments)")
            let text = out.joined()
            for key in ["from=B3", "over=", "tail=", "points=", "kind=", "ordinal=", "emoji=", "zoom=", "amount=", "D5.3"] {
                XCTAssertTrue(text.contains(key), "help add lists \(key)")
            }
        }
        out = []
        XCTAssertEqual(MasumeCLI.run(["help", "resolve"], output: { out.append($0) }, error: { _ in }, transport: transport), 0)
        XCTAssertTrue(out.joined().contains("clockwise"), "the quadrant grammar is explained")
        XCTAssertEqual(MasumeCLI.run(["help", "frobnicate"], output: { _ in }, error: { err.append($0) }, transport: transport), 64)
        XCTAssertTrue(err.joined().contains("no help for frobnicate"))
    }

    func testEveryUsageSubcommandHasAHelpTopic() {
        let listed = MasumeCLI.usage.split(separator: "\n")
            .filter { $0.hasPrefix("  ") && !$0.hasPrefix("   ") }
            .compactMap { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first }
            .flatMap { String($0).split(separator: "|").map(String.init) }
        XCTAssertFalse(listed.isEmpty)
        for name in listed where !name.hasPrefix("<") {
            XCTAssertNotNil(MasumeCLI.help(for: name), "help for \(name)")
        }
    }

    // MARK: Live behaviour through a fake app

    func testMutationDefaultsToTheActiveDocumentAndSaysSo() throws {
        let app = FakeApp(replies: [
            #"{"ok":true,"result":{"id":"DOC-1","revision":7}}"#,
            #"{"ok":true,"result":{"revision":8,"element":{"id":"E"}}}"#,
        ])
        let result = run(["add", "arrow", "from=B3", "to=D6"], app: app)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(app.requests.count, 2)
        XCTAssertEqual(app.requests[0]["command"] as? String, "get_active_document")
        XCTAssertEqual(app.requests[1]["documentId"] as? String, "DOC-1")
        XCTAssertEqual(app.requests[1]["expectedRevision"] as? Int, 7)
        XCTAssertTrue(result.err.contains("using document DOC-1 at revision 7"))
        XCTAssertTrue(result.out.contains(#""revision":8"#))
    }

    func testExplicitDocumentSkipsTheLookupAndReadsNeverNeedIt() throws {
        let app = FakeApp(replies: [])
        XCTAssertEqual(run(["delete", "x", "--doc", "D", "--revision", "2"], app: app).code, 0)
        XCTAssertEqual(app.requests.count, 1)
        XCTAssertEqual(run(["doc"], app: app).code, 0)
        XCTAssertEqual(app.requests.count, 2)
        XCTAssertNil(app.requests[1]["documentId"])
    }

    func testExitCodesMirrorTheEnvelope() {
        let cases: [(String, Int32)] = [
            ("conflict", 2), ("not_found", 3), ("invalid_address", 4), ("invalid_argument", 5), ("unsupported", 6), ("io", 7),
        ]
        for (code, expected) in cases {
            let app = FakeApp(replies: [#"{"ok":false,"error":{"code":"\#(code)","message":"m"}}"#])
            let result = run(["doc"], app: app)
            XCTAssertEqual(result.code, expected, code)
            XCTAssertTrue(result.out.contains(code))
        }
        let notRunning = MasumeCLI.run(["doc"], output: { _ in }, error: { _ in }, transport: { _ in throw CLIError.notRunning })
        XCTAssertEqual(notRunning, 10)
    }

    func testExecPassesJSONThroughWithOptionsInjected() throws {
        let app = FakeApp(replies: [])
        let result = run(["exec", #"{"command":"resolve_grid","params":{"address":"A1"}}"#, "--doc", "D", "--actor", "nova"], app: app)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(app.requests[0]["command"] as? String, "resolve_grid")
        XCTAssertEqual(app.requests[0]["documentId"] as? String, "D")
        XCTAssertEqual(app.requests[0]["actorId"] as? String, "nova")
        XCTAssertEqual(MasumeCLI.run(["exec", "{nope"], output: { _ in }, error: { _ in }, transport: app.transport), 64)
    }

    func testViewMovesTheCropToOut() throws {
        let cropped = scratch.appendingPathComponent("crop.png")
        try png(width: 4, height: 4).write(to: cropped)
        let app = FakeApp(replies: [#"{"ok":true,"result":{"path":"\#(cropped.path)","width":4,"height":4}}"#])
        let out = scratch.appendingPathComponent("here.png")
        let result = run(["view", "A1", "--out", out.path], app: app)
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cropped.path))
        XCTAssertTrue(result.out.contains(out.path))
    }

    // MARK: Offline

    private func makeProject(name: String = "Fixture") throws -> URL {
        let image = scratch.appendingPathComponent("shot.png")
        try png(width: 1200, height: 800).write(to: image)
        let project = scratch.appendingPathComponent("\(name).masume")
        XCTAssertEqual(MasumeCLI.run(["new", image.path, project.path], output: { _ in }, error: { _ in }, transport: { $0 }), 0)
        return project
    }

    func testNewInfoResolveAndExportOffline() throws {
        let project = try makeProject()
        let contents = try ProjectPackage.read(at: project)
        XCTAssertEqual(contents.manifest.canvasSize, CGSize(width: 1200, height: 800))
        XCTAssertEqual(contents.manifest.grid, GridDefinition(columns: 12, rows: 8))

        var out = ""
        XCTAssertEqual(MasumeCLI.run(["info", project.path], output: { out += $0 }, error: { _ in }, transport: { $0 }), 0)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let result = try XCTUnwrap(info["result"] as? [String: Any])
        XCTAssertEqual(result["name"] as? String, "Fixture")
        XCTAssertEqual((result["grid"] as? [String: Any])?["columns"] as? Int, 12)
        XCTAssertEqual(result["openInMasume"] as? Bool, false)

        out = ""
        XCTAssertEqual(MasumeCLI.run(["resolve", "--file", project.path, "D5"], output: { out += $0 }, error: { _ in }, transport: { $0 }), 0)
        XCTAssertTrue(out.contains(#""x":300"#))
        XCTAssertEqual(MasumeCLI.run(["resolve", "--file", project.path, "Z9"], output: { _ in }, error: { _ in }, transport: { $0 }), 4)

        let exported = scratch.appendingPathComponent("flat.png")
        out = ""
        XCTAssertEqual(MasumeCLI.run(["export", project.path, exported.path, "--bounds", "clipToImage"],
                                     output: { out += $0 }, error: { _ in }, transport: { $0 }), 0)
        XCTAssertEqual(ProjectPackage.pngPixelSize(try Data(contentsOf: exported))?.width, 1200)
        XCTAssertEqual(MasumeCLI.run(["export", project.path, scratch.appendingPathComponent("x.gif").path],
                                     output: { _ in }, error: { _ in }, transport: { $0 }), 5)
        XCTAssertEqual(MasumeCLI.run(["info", scratch.appendingPathComponent("missing.masume").path],
                                     output: { _ in }, error: { _ in }, transport: { $0 }), 7)
    }

    func testNewFromAPDFPage() throws {
        let file = scratch.appendingPathComponent("doc.pdf")
        try pdf(pages: 2).write(to: file)
        let project = scratch.appendingPathComponent("FromPDF.masume")
        XCTAssertEqual(MasumeCLI.run(["new", file.path, project.path, "--page", "2"], output: { _ in }, error: { _ in }, transport: { $0 }), 0)
        XCTAssertEqual(try ProjectPackage.read(at: project).manifest.canvasSize, CGSize(width: 400, height: 200), "2× the 200×100pt page")
        XCTAssertEqual(MasumeCLI.run(["new", file.path, scratch.appendingPathComponent("Bad.masume").path, "--page", "9"],
                                     output: { _ in }, error: { _ in }, transport: { $0 }), 5)
        XCTAssertEqual(MasumeCLI.run(["new", file.path, scratch.appendingPathComponent("wrong.png").path],
                                     output: { _ in }, error: { _ in }, transport: { $0 }), 5)
    }

    func testInfoReportsWhenTheAppHasTheProjectOpen() throws {
        let project = try makeProject(name: "Open")
        // A recovery package that binds it, as the app would write.
        var contents = try ProjectPackage.read(at: project)
        contents.manifest.boundProjectPath = project.path
        let recovery = OfflineCommands.recoveryDirectory.appendingPathComponent("\(UUID().uuidString).masume")
        try FileManager.default.createDirectory(at: OfflineCommands.recoveryDirectory, withIntermediateDirectories: true)
        try ProjectPackage.create(at: recovery, manifest: contents.manifest, baseImagePNG: contents.baseImagePNG,
                                  preview: nil, history: [])
        XCTAssertTrue(OfflineCommands.isOpenInApp(project))
        var out = ""
        XCTAssertEqual(MasumeCLI.run(["info", project.path], output: { out += $0 }, error: { _ in }, transport: { $0 }), 0)
        XCTAssertTrue(out.contains(#""openInMasume":true"#))
    }
}
