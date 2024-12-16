/// Define your environment
public protocol Scribe {
    init()
    var config: Config { get }
}

extension Scribe {
    public static func main() {
        let scribe = self.init()
        print(scribe.config.hello)
    }
}
