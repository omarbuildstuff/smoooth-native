import Foundation
import os

enum Log {
    private static let subsystem = "com.cursorful.app"
    static let app      = Logger(subsystem: subsystem, category: "app")
    static let capture  = Logger(subsystem: subsystem, category: "capture")
    static let events   = Logger(subsystem: subsystem, category: "events")
    static let effects  = Logger(subsystem: subsystem, category: "effects")
    static let render   = Logger(subsystem: subsystem, category: "render")
    static let timeline = Logger(subsystem: subsystem, category: "timeline")
    static let export   = Logger(subsystem: subsystem, category: "export")
    static let ui       = Logger(subsystem: subsystem, category: "ui")
    static let storage  = Logger(subsystem: subsystem, category: "storage")
}
