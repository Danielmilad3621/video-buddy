// vsctl "<command> [arg]": sends one test command to a Video Summarizer launched with VS_TEST_HOOKS=1.
// e.g. vsctl "link https://youtu.be/…", vsctl "start summary", vsctl state, vsctl snapshot
import Foundation

// VS_TEST_CHANNEL=<name> talks to the instance launched with the same channel, and only to it
let command = CommandLine.arguments.dropFirst().joined(separator: " ")
let channel = ProcessInfo.processInfo.environment["VS_TEST_CHANNEL"].map { ".\($0)" } ?? ""
let name = Notification.Name((command == "snapshot-only" ? "local.video-summarizer.snapshot" : "local.video-summarizer.test") + channel)
DistributedNotificationCenter.default().postNotificationName(name, object: command, userInfo: nil, deliverImmediately: true)
