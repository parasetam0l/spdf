import Foundation
import PDFEditing

// AUT-05: minimal executable entry point. All parsing, capabilities, exit codes
// and structured output live in the shared PDFEditing automation profile so the
// CLI, Shortcuts and AppleScript surfaces cannot drift apart.
exit(AutomationCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
