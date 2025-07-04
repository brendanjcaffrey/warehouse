struct AppArguments {
    var headless = false
    var fast = false
    var logPath: String? = nil

    init(arguments: [String]) {
        var iterator = arguments.makeIterator()
        _ = iterator.next() // skip the first arg (executable name)

        while let arg = iterator.next() {
            switch arg {
            case "--headless":
                headless = true
            case "--fast":
                fast = true
            case "--log":
                logPath = iterator.next()
            default:
                continue
            }
        }
    }
}
