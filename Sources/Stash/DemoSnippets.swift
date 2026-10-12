import Foundation
import StashKit

/// Sample snippets for `--demo` (pictures and docs). Synthetic text only.
@MainActor
enum DemoSnippets {
    static func seed(_ snippets: SnippetsController) {
        let samples = [
            Snippet(id: "demo-sig", name: "Email signature", keyword: "sig",
                    text: "Kind regards,\nAlex Example\nexample.com", collection: "Default Collection"),
            Snippet(id: "demo-addr", name: "Office address", keyword: "addr",
                    text: "1 Example Way, Springfield", collection: "Default Collection"),
            Snippet(id: "demo-date", name: "Today's date", keyword: "tdy", text: "{date}", collection: "Default Collection"),
            Snippet(id: "demo-review", name: "Code review prompt", keyword: "crv",
                    text: "Review this change for correctness first, then clarity:\n\n{clipboard}", collection: "Prompts"),
            Snippet(id: "demo-sum", name: "Summarise", keyword: "sumz",
                    text: "Summarise the following in three bullet points.", collection: "Prompts", autoExpand: false),
            Snippet(id: "demo-standup", name: "Stand-up notes", keyword: "stnd",
                    text: "Yesterday:\nToday:\nBlocked on:", collection: "Work"),
        ]
        for snippet in samples { try? snippets.save(snippet) }
        try? snippets.addCollection("Archive")
    }
}
