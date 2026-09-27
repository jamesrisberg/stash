import Foundation
import HUDKit

// `stash <command> [key=value ...]`: talks to Stash's MacHUD control socket.
//
//   stash hello
//   stash state
//   stash panel show id=history
//   stash panel mode id=history compact
//   stash action copy text=hello
//   echo hi | stash copy          # copy stdin
//   stash list                     # newest first, with indexes
//   stash paste 2                  # copy clip 2 and paste it into the frontmost app
//   stash action search q=invoice
//   stash watch                    # print pushed events until interrupted
//   stash quit

let usage = """
usage: stash <command> [key=value ...]
  hello | state | help | quit
  copy [text]                  copy text (or stdin when no text is given)
  list [limit=20]              history, newest first
  paste [index]                copy clip <index> (1 = newest) and paste it
  search <query>               matching clips
  panel show|hide|toggle id=history
  panel frame id=history x= y= w= h=
  panel mode id=history full|compact|parked
  action copy text= | copy-clip index= | paste index= | search q= | list | pin index= | delete index= | clear [all=1]
  settings get [key=]  |  settings set key=value ...
  watch [events=state]         stream events (Ctrl-C to stop)

Env: STASH_SOCKET=<name or /path> talks to a different instance.

"""

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "ctl" { arguments.removeFirst() }
guard let command = arguments.first, !["-h", "--help"].contains(command) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 2 : 0)
}

let socket = ProcessInfo.processInfo.environment["STASH_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "stash"
let path = socket.hasPrefix("/") ? socket : HUDSocket.path(for: socket)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("stash: \(message)\n".utf8))
    exit(1)
}

// Shorthands for the common actions.
let rest = Array(arguments.dropFirst())
switch command {
case "copy":
    // `stash copy some words` or `... | stash copy` (stdin, trailing newline kept as is).
    var text = rest.filter { !$0.hasPrefix("text=") }.joined(separator: " ")
    if let explicit = rest.first(where: { $0.hasPrefix("text=") }) { text = String(explicit.dropFirst(5)) }
    if text.isEmpty {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        text = String(decoding: data, as: UTF8.self)
    }
    guard !text.isEmpty else { fail("nothing to copy (pass text or pipe it on stdin)") }
    do {
        let r = try HUDSocketClient(path: path).request("action", args: ["name": "copy", "text": text])
        guard r["ok"] as? Bool == true else { fail(r["error"] as? String ?? "copy failed") }
        exit(0)
    } catch {
        fail("Stash is not running (\(error))")
    }
case "paste", "list", "search", "pin", "delete", "clear":
    var mapped = ["action", "name=\(command)"]
    for arg in rest {
        if arg.contains("=") { mapped.append(arg) }
        else if command == "search" { mapped.append("q=\(rest.filter { !$0.contains("=") }.joined(separator: " "))"); break }
        else if Int(arg) != nil { mapped.append("index=\(arg)") }
        else { mapped.append(arg) }
    }
    arguments = mapped
default:
    // `action copy ...` is shorthand for `action name=copy ...`.
    if command == "action", arguments.count > 1, !arguments[1].contains("=") {
        arguments[1] = "name=\(arguments[1])"
    }
}

if command == "watch" {
    let args = HUDSocketClient.parseArguments(Array(arguments.dropFirst()))
    do {
        _ = try HUDSocketClient(path: path).subscribe(
            events: args["events"].map { $0.split(separator: ",").map(String.init) },
            onEvent: { event in
                if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                    fflush(stdout)
                }
            },
            onClose: { exit(0) }
        )
    } catch {
        fail("Stash is not running (\(error))")
    }
    dispatchMain()
}

exit(HUDSocketClient.runCLI(path: path, arguments: arguments, appName: "stash"))
