import Foundation

// `masume help <subcommand>` and `masume <subcommand> --help`: what each
// subcommand takes, with the element keys `add` and `update` accept,
// which the one-screen usage has no room for.

extension MasumeCLI {
    static let elementKeys = """
        Element keys for add <type> and update <id> (key=value; numbers, true/false, x,y points,
        x,y,w,h rects, and x,y;x,y;... point lists are typed, everything else is a string):

          Geometry by grid address     from=B3 to=D6 (arrow, line) | over=D5:F14 (rectangle, ellipse,
                                       pixelate, magnifier) | at=C3 (text origin, stamp center) |
                                       tail=E7 (callout tail). Cells D5, quadrants D5.3, ranges D5:F14.
          Geometry by pixels           start=x,y end=x,y | rect=x,y,w,h | center=x,y | tailTip=x,y |
                                       points=x,y;x,y;... (pen)
          Style (most types)           color=red|#RRGGBB width=6 fill=#RRGGBB opacity=0.5 (pen: below 1
                                       is a highlighter)
          text, callout                text=... fontSize=24 bold=true alignment=left|center|right
                                       style=shadow|outline|plain outlineColor=white|black
                                       callout: shape=speech|thought
          stamp                        kind=check|cross|exclaim|question|heart|number|letter|emoji
                                       radius=30 pointerAngle=1.57 ordinal=3 (number, letter; default:
                                       next of that kind) emoji=🔥 (one character)
          pixelate                     amount=12 (block size)
          magnifier                    zoom=2.5 (1.5 to 8) shape=circle|square
          update only                  zOrder=front|back

        Types: arrow line rectangle ellipse pen text callout stamp pixelate magnifier
        """

    static let topics: [String: String] = [
        "add": """
            masume add <type> key=value ... [--reason text]
            Create one annotation and print it with the new revision.
              masume add arrow from=B3 to=D6 --reason "point at the button"
              masume add stamp at=D5.3 kind=number
              masume add callout tail=E7 at=G4 text="Click here" shape=thought

            """ + "\n" + elementKeys,
        "update": """
            masume update <id> key=value ...
            Change only the given keys of one annotation; others keep their values.
              masume update 3F2A... end=600,600
              masume update 3F2A... kind=letter ordinal=2
              masume update 3F2A... zOrder=front

            """ + "\n" + elementKeys,
        "delete": "masume delete <id> ...\nRemove annotations. An unknown id fails the whole call and nothing changes.",
        "doc": """
            masume doc
            The active document: id, revision, canvas size, grid, crop, selection, dirty state, and counts.
            Mutations need its id and revision; the CLI reads both from here when --doc and --revision are omitted.
            """,
        "elements": "masume elements\nEvery annotation in draw order, as JSON with stable ids.",
        "element": "masume element <id>\nOne annotation by id.",
        "resolve": """
            masume resolve <address>                    (live: the open document's grid)
            masume resolve --file <file.masume> <address>   (offline: the saved project's grid)
            Turns a grid address into pixels: rect, center, corners, and normalized coordinates.
              D5        one cell (column D, row 5)
              D5.3      a quadrant of it: 1 to 4 clockwise from the upper left, so 3 is lower right;
                        quadrants nest (D5.3.1), four levels deep
              D5:F14    a range, from D5's upper-left edge to F14's lower-right edge; either end
                        may be a quadrant (D5.3:F14)
            Case-insensitive. Nothing is clamped: a cell off the grid or a reversed range is an error.
            """,
        "view": """
            masume view [range] --out <png> [--margin px]
            Writes a crop of the untouched base image (annotations never appear in it) to --out;
            no range means the whole image. --margin adds context around the range.
            """,
        "history": "masume history [--limit n]\nCommitted actions, oldest first, with actor, revisions, summary, reason, and affected ids.",
        "crop": """
            masume crop <range|x,y,w,h|none>
            Sets the non-destructive crop to a grid range or a pixel rect, or clears it with none.
            Export honors it; the base image is untouched.
            """,
        "density": "masume density <n>\nGrid preset: 8, 12, 16, 24, or 32 cells across the long side. Every address changes; resolve again.",
        "undo": "masume undo\nUndo the latest committed action, whoever made it.",
        "redo": "masume redo\nRedo the last undone action.",
        "save": """
            masume save [path]
            Writes the editable .masume project. The path (absolute, ending in .masume) is required the
            first time; after that the project saves in place. The package holds the original,
            unredacted image.
            """,
        "export": """
            masume export <path> [--format png|jpeg|webp] [--bounds expandToFit|clipToImage]       (live)
            masume export <file.masume> <out> [--format ...] [--bounds ...]                         (offline)
            Writes the flattened image; the format defaults to the extension. expandToFit (default)
            grows the canvas to include annotations outside the image; clipToImage does not.
            """,
        "info": """
            masume info <file.masume>
            The saved project's manifest: id, revision, canvas, grid, crop, elements, and whether Masume has it open.
            """,
        "new": """
            masume new <image-or-pdf> <file.masume> [--page n]
            A fresh project from an image or one PDF page, with the default grid. No app needed.
            """,
        "exec": """
            masume exec '<json>'
            Any command by name, as the JSON the app's command service takes:
              {"command": "create_element", "params": {"type": "arrow", "from": "B3", "to": "D6"}}
            --doc, --revision, --actor, --actor-name, and --reason are merged in.
            Commands: get_active_document list_elements get_element resolve_grid view_base_image get_history
            create_element update_element delete_elements set_crop set_grid_density undo redo save_project
            export batch.
            """,
        "options": """
            Global options, accepted after any live subcommand:
              --doc <id>            the document to act on (default: the active one)
              --revision <n>        the revision you expect (default: the active document's; the CLI
                                    says which it used on stderr). A mismatch fails with conflict.
              --actor <id>          who is editing, for the history (default: cli)
              --actor-name <name>   the name the history shows
              --reason <text>       why, shown in the history
              --pretty              indent the JSON
            """,
    ]

    /// The help text for a subcommand, or nil for one that has none.
    public static func help(for topic: String) -> String? {
        let key = topic.lowercased()
        return topics[key].map { $0.trimmingCharacters(in: .newlines) }
    }
}
