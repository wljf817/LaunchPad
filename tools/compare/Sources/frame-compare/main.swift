// Compares two recordings frame by frame, or inspects one.
// See CompareCommand.usage for the command line.

import FrameCompare
import Foundation

let status = await CompareCommand.run(Array(CommandLine.arguments.dropFirst()))
exit(status.rawValue)
