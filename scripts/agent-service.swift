// Unregisters or registers LaunchPad's launchd agent with SMAppService, which asks for both after an
// agent's executable changes (SMAppService.h). Not part of LaunchPad: scripts/reload-app.sh builds
// it and runs it from the bundle's Contents/MacOS, where SMAppService finds the bundle and its agent
// plist, and removes it again.
//
// Usage: agent-service unregister|register

import ServiceManagement

let agent = SMAppService.agent(plistName: "io.github.wljf817.LaunchPad.plist")
switch CommandLine.arguments.dropFirst().first {
case "unregister":
    // Fails when the agent is not registered yet, as after a fresh checkout.
    try? agent.unregister()
case "register":
    try agent.register()
default:
    print("usage: agent-service unregister|register")
    exit(2)
}
