// vsctl "<command> [arg]": sends one test command to a Video Summarizer launched with VS_TEST_HOOKS=1.
// e.g. vsctl "link https://youtu.be/…", vsctl "start summary", vsctl state, vsctl snapshot
import Foundation

let command = CommandLine.arguments.dropFirst().joined(separator: " ")
let name = Notification.Name(command == "snapshot-only" ? "local.video-summarizer.snapshot" : "local.video-summarizer.test")
DistributedNotificationCenter.default().postNotificationName(name, object: command, userInfo: nil, deliverImmediately: true)
