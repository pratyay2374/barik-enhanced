import Foundation

class AerospaceSpacesProvider: SpacesProvider, SwitchableSpacesProvider {
    typealias SpaceType = AeroSpace
    private var executablePath: String { ConfigManager.shared.config.aerospace.path }
    private let commandTimeout: DispatchTimeInterval = .seconds(2)

    func getSpacesWithWindows() -> [AeroSpace]? {
        guard
            let spaces = fetchSpaces(),
            let windows = fetchWindows()
        else {
            return nil
        }

        // `fetchSpaces()` already carries the focus flag, so no extra CLI call.
        let focusedSpace = spaces.first { $0.isFocused }

        let focusedWindow = fetchFocusedWindow()
        var spaceDict = Dictionary(
            uniqueKeysWithValues: spaces.map { ($0.id, $0) })

        for window in windows {
            var mutableWindow = window
            if let focused = focusedWindow, window.id == focused.id {
                mutableWindow.isFocused = true
            }

            if let ws = mutableWindow.workspace, !ws.isEmpty {
                if var space = spaceDict[ws] {
                    space.windows.append(mutableWindow)
                    spaceDict[ws] = space
                }
            } else if let focusedSpace {
                if var space = spaceDict[focusedSpace.id] {
                    space.windows.append(mutableWindow)
                    spaceDict[focusedSpace.id] = space
                }
            }
        }
        var resultSpaces = Array(spaceDict.values)
        for i in 0..<resultSpaces.count {
            resultSpaces[i].windows.sort { $0.id < $1.id }
        }
        return resultSpaces.filter { !$0.windows.isEmpty }
    }

    func focusSpace(spaceId: String, needWindowFocus: Bool) {
        _ = runAerospaceCommand(arguments: ["workspace", spaceId])
    }

    func focusWindow(windowId: String) {
        _ = runAerospaceCommand(arguments: ["focus", "--window-id", windowId])
    }

    private func runAerospaceCommand(arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let exitGroup = DispatchGroup()
        exitGroup.enter()
        process.terminationHandler = { _ in
            exitGroup.leave()
        }

        do {
            try process.run()
        } catch {
            print("Aerospace error: \(error)")
            return nil
        }

        if exitGroup.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            print("Aerospace command timed out: \(arguments.joined(separator: " "))")
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorData, encoding: .utf8) ?? ""
            print("Aerospace command failed (\(process.terminationStatus)): \(stderr)")
            return nil
        }

        return data
    }

    /// Lists every workspace *and* which one is focused in a single invocation.
    ///
    /// The `workspace-is-focused` format field lets us fold what used to be a
    /// separate `list-workspaces --focused` call into this one — each `aerospace`
    /// invocation is a full `posix_spawn` plus a round-trip that wakes
    /// AeroSpace.app, so dropping one is a real saving on every refresh.
    private func fetchSpaces() -> [AeroSpace]? {
        guard
            let data = runAerospaceCommand(arguments: [
                "list-workspaces", "--all", "--json", "--format",
                "%{workspace} %{workspace-is-focused}",
            ])
        else {
            return nil
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([AeroSpace].self, from: data)
        } catch {
            print("Decode spaces error: \(error)")
            return nil
        }
    }

    private func fetchWindows() -> [AeroWindow]? {
        guard
            let data = runAerospaceCommand(arguments: [
                "list-windows", "--all", "--json", "--format",
                "%{window-id} %{app-name} %{window-title} %{workspace}",
            ])
        else {
            return nil
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([AeroWindow].self, from: data)
        } catch {
            print("Decode windows error: \(error)")
            return nil
        }
    }

    /// Note: there is no `window-is-focused` format field (verified against
    /// AeroSpace 0.20.2 — the CLI rejects it), so unlike the focused *workspace*
    /// this one can't be folded into `fetchWindows()` and needs its own call.
    private func fetchFocusedWindow() -> AeroWindow? {
        guard
            let data = runAerospaceCommand(arguments: [
                "list-windows", "--focused", "--json",
            ])
        else {
            return nil
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([AeroWindow].self, from: data).first
        } catch {
            print("Decode focused window error: \(error)")
            return nil
        }
    }
}
