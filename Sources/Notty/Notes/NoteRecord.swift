import Foundation

struct NoteRecord: Sendable {
    let id: String
    let title: String
    let plainText: String
    let folder: String
    let modifiedDate: Date
}
