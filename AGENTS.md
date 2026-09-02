# Repository Guidelines

## Project Structure & Module Organization

Masume is a Swift Package Manager project for a native macOS 15+ app. Keep code within its existing target boundary:

- `Sources/AnnotationModel/` contains platform-light value types and geometry.
- `Sources/AnnotationRender/` handles Core Graphics rendering and WebP encoding.
- `Sources/Masume/` contains the SwiftUI application, AppKit canvas bridge, controllers, and export services.
- `Tests/<Target>Tests/` mirrors the three source targets.
- `Resources/` holds the app plist and icons; `scripts/` assembles the app and regenerates icons; `docs/` records design and investigation notes.

Do not commit generated `.build/` or `build/` content.

## Build, Test, and Development Commands

- `swift build` compiles all package targets for local development.
- `swift test` runs the complete XCTest suite.
- `swift test --filter ZoomMathTests` runs a focused test class while iterating.
- `swiftlint --strict` applies the repository's `.swiftlint.yml` checks. `aqua install` installs the pinned SwiftLint version when Aqua is available.
- `./scripts/build-app.sh release` creates and ad-hoc-signs `build/Masume.app`; use `open build/Masume.app` for a manual smoke test.
- `./scripts/generate-icon.sh` regenerates `Resources/AppIcon.icns` from the PNG source.

Development requires Apple Silicon macOS with the Xcode/Swift toolchain specified by `.swift-version`.

## Coding Style & Naming Conventions

Use four-space indentation and follow existing Swift formatting, including trailing commas in multiline declarations. Name types in `UpperCamelCase`, members in `lowerCamelCase`, and test methods as descriptive `test...` phrases. Prefer `struct`, `let`, `guard` early exits, and structured concurrency. UI state owners should use `@MainActor` and `@Observable`; avoid `ObservableObject` and `@Published`. Prefer SwiftUI and confine AppKit to interactions that require `NSView`. SwiftLint checks `Sources/` and `Tests/`; its line-length warning begins at 150 characters.

## Testing Guidelines

Use XCTest and place regressions in the test target matching the changed module. Test observable behavior, boundary conditions, rendering dimensions or pixels, and failure paths where relevant. There is no stated numeric coverage threshold, but every bug fix should include a focused regression test. Run the full suite before opening a pull request.

## Commit & Pull Request Guidelines

Recent history favors concise Conventional Commit subjects such as `feat:`, `fix:`, `docs:`, `refactor:`, and `chore:`. Keep each commit and pull request to one logical change. PRs should explain what changed and why, link related issues, and include screenshots or a short recording for visible UI changes. Before requesting review, run `swift test`, SwiftLint, and `./scripts/build-app.sh release`.
