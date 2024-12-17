import MyConfig
import Scribe

/// MyScribe Entry point
@main
struct MyScribe: Scribe {
    var config: any Config = MyConfig()
    var commands: [String: Command] = ["format": format]
}
