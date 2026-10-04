import Foundation
@testable import Warehouse

// these helpers wait for externally observable completion of asynchronous content work.
extension PhoneWatchContentQueue {
    func settledReconcile(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?) async throws {
        try reconcile(head: head, snapshot: snapshot)
        await waitForWork()
    }

    func settledReceive(_ receipt: WatchContentReceipt) async throws {
        try receive(receipt)
        await waitForWork()
    }

    func settledReceive(_ report: WatchInventoryReport) async throws {
        try receive(report)
        await waitForWork()
    }

    func settledFinished(_ file: WatchContentFile, error: Error?) async throws {
        try finished(file, error: error)
        await waitForWork()
    }

    func settledResume() async {
        resume()
        await waitForWork()
    }

    func settledRequestInventory() async {
        requestInventory()
        await waitForWork()
    }

    func settledInvalidate(identity: String?, playlistIDs: [String]) async throws {
        try invalidate(identity: identity, playlistIDs: playlistIDs)
        await waitForWork()
    }
}

extension WatchContentReceiver {
    func settledReconcile(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?) async throws {
        try reconcile(head: head, snapshot: snapshot)
        await waitForWork()
    }

    func settledQuery(_ file: WatchContentFile) async throws {
        try query(file)
        await waitForWork()
    }

    func settledQuery(_ request: WatchInventoryRequest) async throws {
        try query(request)
        await waitForWork()
    }

    func settledResume() async {
        resume()
        await waitForWork()
    }

    func settledStaged(_ file: WatchContentFile) async {
        staged(file)
        await waitForWork()
    }

    func settledStagingFailed(_ file: WatchContentFile, error: Error) async {
        stagingFailed(file, error: error)
        await waitForWork()
    }
}
