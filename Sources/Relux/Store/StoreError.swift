import Foundation

enum StoreError: Error {
    case cannotOpen
    case query
    case exec(String)
}
