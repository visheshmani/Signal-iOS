//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

@objc
public class MessageProcessing: NSObject {

    // MARK: - Dependencies

    private var databaseStorage: SDSDatabaseStorage {
        return SDSDatabaseStorage.shared
    }

    private var messageReceiver: OWSMessageReceiver {
        return SSKEnvironment.shared.messageReceiver
    }

    private var batchMessageProcessor: OWSBatchMessageProcessor {
        return SSKEnvironment.shared.batchMessageProcessor
    }

    private var socketManager: TSSocketManager {
        return TSSocketManager.shared
    }

    private var messageFetcherJob: MessageFetcherJob {
        return SSKEnvironment.shared.messageFetcherJob
    }

    private var tsAccountManager: TSAccountManager {
        return TSAccountManager.sharedInstance()
    }

    private var signalService: OWSSignalService {
        return OWSSignalService.sharedInstance()
    }

    // MARK: -

    private let serialQueue = DispatchQueue(label: "org.signal.MessageProcessing")

    public override init() {
        super.init()

        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(messageDecryptionDidFlushQueue),
                                               name: .messageDecryptionDidFlushQueue,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(messageProcessingDidFlushQueue),
                                               name: .messageProcessingDidFlushQueue,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(webSocketStateDidChange),
                                               name: .webSocketStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(messageFetcherJobDidChangeState),
                                               name: MessageFetcherJob.didChangeStateNotificationName,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(registrationStateDidChange),
                                               name: .registrationStateDidChange,
                                               object: nil)
    }

    // MARK: - Flush decryption and message processing

    // This promise can be used by the notification extension to
    // block on decryption and processing of any messages
    // received before this promise is created.
    //
    // TODO: MessageManager uses dispatch_async() to finish
    //       handling certain kinds of messages outside of the
    //       "message processing" transaction.  This isn't
    //       reflected in this promise yet.
    @objc
    public func flushMessageDecryptionAndProcessingPromise() -> AnyPromise {
        // GroupsV2 TODO: Make sure the "groups v2" processing queue is flushed as well.
        return AnyPromise(decryptStepPromise().then { _ in
            return self.processingStepPromise()
        })
    }

    // MARK: - Decrypt Step

    // This should only be accessed on serialQueue.
    private var decryptStepResolvers = [Resolver<Void>]()

    private func decryptStepPromise() -> Promise<Void> {
        let (promise, resolver) = Promise<Void>.pending()

        serialQueue.async {
            self.decryptStepResolvers.append(resolver)

            self.tryToResolveDecryptStepPromises()
        }

        return promise
    }

    private func tryToResolveDecryptStepPromises() {
        assertOnQueue(serialQueue)

        let decryptStepResolvers = self.decryptStepResolvers
        guard !decryptStepResolvers.isEmpty else {
            // No pending resolvers to resolve.
            return
        }

        let hasPendingJobs = databaseStorage.read { transaction in
            return self.isDecryptingIncomingMessages(transaction: transaction)
        }
        guard !hasPendingJobs else {
            return
        }

        self.decryptStepResolvers = []

        for resolver in decryptStepResolvers {
            resolver.fulfill(())
        }
    }

    private func isDecryptingIncomingMessages(transaction: SDSAnyReadTransaction) -> Bool {
        return messageReceiver.hasPendingJobs(with: transaction)
    }

    @objc
    fileprivate func messageDecryptionDidFlushQueue() {
        AssertIsOnMainThread()

        serialQueue.async {
            self.tryToResolveDecryptStepPromises()
            self.tryToResolveAllMessageFetchingAndProcessingPromises()
        }
    }

    // MARK: - Processing Step

    // This should only be accessed on serialQueue.
    private var processingStepResolvers = [Resolver<Void>]()

    private func processingStepPromise() -> Promise<Void> {
        let (promise, resolver) = Promise<Void>.pending()

        serialQueue.async {
            self.processingStepResolvers.append(resolver)

            self.tryToResolveProcessingStepPromises()
        }

        return promise
    }

    private func tryToResolveProcessingStepPromises() {
        assertOnQueue(serialQueue)

        let processingStepResolvers = self.processingStepResolvers
        guard !processingStepResolvers.isEmpty else {
            // No pending resolvers to resolve.
            return
        }

        let hasPendingJobs = databaseStorage.read { transaction in
            return self.isProcessingIncomingMessages(transaction: transaction)
        }
        guard !hasPendingJobs else {
            return
        }

        self.processingStepResolvers = []

        for resolver in processingStepResolvers {
            resolver.fulfill(())
        }
    }

    private func isProcessingIncomingMessages(transaction: SDSAnyReadTransaction) -> Bool {
        return batchMessageProcessor.hasPendingJobs(with: transaction)
    }

    @objc
    fileprivate func messageProcessingDidFlushQueue() {
        AssertIsOnMainThread()

        serialQueue.async {
            self.tryToResolveProcessingStepPromises()
            self.tryToResolveAllMessageFetchingAndProcessingPromises()
        }
    }

    // MARK: - WebSocket drained

    // This should only be accessed on serialQueue.
    private var websocketDrainedResolvers = [UUID: Resolver<Void>]()

    // This promise can be used by the notification extension
    // to detect when the websocket has drained its queue.
    //
    // TODO: The notification extension will eventually use
    // REST (not the websocket) to receive messages.  At that
    // time, we'll want to add restMessageFetchingCompletePromiseObjc()
    // to this class.  We'll probably still need this
    // websocketDrainedPromiseObjc() for usage by the main app.
    @objc
    public func websocketDrainedPromiseObjc() -> AnyPromise {
        return AnyPromise(websocketDrainedPromise())
    }

    private func websocketDrainedPromise() -> Promise<Void> {
        let (promise, resolver) = Promise<Void>.pending()

        serialQueue.async {
            self.websocketDrainedResolvers[UUID()] = resolver

            self.tryToResolveWebsocketDrainedPromises()
        }

        return promise
    }

    private func tryToResolveWebsocketDrainedPromises() {
        assertOnQueue(serialQueue)

        // We can only access the resolvers on serialQueue,
        // but we can only check "isWebsocketDrained" on the main
        // thread.  Therefore, we first snapshot the current
        // set of resolvers on the serialQueue:
        let resolverKeys = self.websocketDrainedResolvers.keys
        guard !resolverKeys.isEmpty else {
            // No pending resolvers to resolve.
            return
        }

        DispatchQueue.main.async {
            // Then we check for isWebsocketDrained of the main thread:
            let isWebsocketDrained = (self.socketManager.socketState() == .open &&
                self.socketManager.hasEmptiedInitialQueue())
            guard isWebsocketDrained else {
                return
            }

            self.serialQueue.async {
                // Lastly, if the websocket is drained, on the serialQueue
                // we resolve any resolvers that were present _before_ we
                // checked (to avoid races):
                for key in resolverKeys {
                    guard let resolver = self.websocketDrainedResolvers[key] else {
                        continue
                    }
                    self.websocketDrainedResolvers.removeValue(forKey: key)
                    resolver.fulfill(())
                }
            }
        }
    }

    @objc
    fileprivate func webSocketStateDidChange() {
        AssertIsOnMainThread()

        serialQueue.async {
            self.tryToResolveWebsocketDrainedPromises()
            self.tryToResolveAllMessageFetchingAndProcessingPromises()
        }
    }

    // MARK: - Specific MessageFetchJob completed

    // This should only be accessed on serialQueue.
    private var specificMessageFetchJobResolvers = [MessageFetchCycle: Resolver<Void>]()

    // This promise can be used by the notification extension
    // to detect when the websocket has drained its queue.
    //
    // TODO: Do we need an obj-c flavor of this method? If so, we'll need
    //       to convert MessageFetchCycle to a NSObject.
    private func specificMessageFetchJobPromise(fetchCycle: MessageFetchCycle) -> Promise<Void> {
        let (promise, resolver) = Promise<Void>.pending()

        serialQueue.async {
            self.specificMessageFetchJobResolvers[fetchCycle] = resolver

            self.tryToResolveSpecificMessageFetchJobPromises()
        }

        return promise
    }

    private func tryToResolveSpecificMessageFetchJobPromises() {
        assertOnQueue(serialQueue)

        guard !specificMessageFetchJobResolvers.isEmpty else {
            // No pending resolvers to resolve.
            return
        }
        for (fetchCycle, resolver) in specificMessageFetchJobResolvers {
            let isFetchComplete = messageFetcherJob.isFetchCycleComplete(fetchCycle: fetchCycle)
            guard isFetchComplete else {
                continue
            }

            specificMessageFetchJobResolvers.removeValue(forKey: fetchCycle)
            resolver.fulfill(())
        }
    }

    @objc
    fileprivate func messageFetcherJobDidChangeState() {
        AssertIsOnMainThread()

        serialQueue.async {
            self.tryToResolveSpecificMessageFetchJobPromises()
            self.tryToResolveAllMessageFetchingAndProcessingPromises()
        }
    }

    // MARK: - All message processing

    // This should only be accessed on serialQueue.
    private var allMessageFetchingAndProcessingResolvers = [Resolver<Void>]()

    // This promise can be used by the Groups v2 logic
    // to block until all messages are fetched and processed.
    public func allMessageFetchingAndProcessingPromise() -> Promise<Void> {
        let (promise, resolver) = Promise<Void>.pending()

        serialQueue.async {
            self.allMessageFetchingAndProcessingResolvers.append(resolver)

            self.tryToResolveAllMessageFetchingAndProcessingPromises()
        }

        return promise
    }

    private func tryToResolveAllMessageFetchingAndProcessingPromises() {
        assertOnQueue(serialQueue)

        let resolvers = self.allMessageFetchingAndProcessingResolvers
        guard !resolvers.isEmpty else {
            // No pending resolvers to resolve.
            return
        }
        guard isAllMessageFetchingAndProcessingComplete else {
            // Not complete.
            return
        }

        self.allMessageFetchingAndProcessingResolvers = []

        for resolver in resolvers {
            resolver.fulfill(())
        }
    }

    private var isAllMessageFetchingAndProcessingComplete: Bool {
        guard tsAccountManager.isRegisteredAndReady else {
            owsFailDebug("Not registered.")
            return false
        }
        // Groupsv2 TODO: We don't want to process incoming messages
        // in the share extension, but we need to block on latest
        // groups v2 state when sending messages.
        guard CurrentAppContext().shouldProcessIncomingMessages else {
            owsFailDebug("Should not process incoming messages.")
            return false
        }

        if MessageFetcherJob.shouldUseWebSocket {
            let isWebsocketDrained = (self.socketManager.socketState() == .open &&
                self.socketManager.hasEmptiedInitialQueue())
            guard isWebsocketDrained else {
                return false
            }
        } else {
            guard messageFetcherJob.completedRestFetches > 0 else {
                return false
            }
        }

        guard messageFetcherJob.areAllFetchCyclesComplete else {
            return false
        }

        let hasPendingDecryptionOrProcess = databaseStorage.read { (transaction: SDSAnyReadTransaction) -> Bool in
            guard !self.isDecryptingIncomingMessages(transaction: transaction) else {
                return true
            }
            guard !self.isProcessingIncomingMessages(transaction: transaction) else {
                return true
            }
            return false
        }
        guard !hasPendingDecryptionOrProcess else {
            return false
        }
        return true
    }

    @objc
    fileprivate func registrationStateDidChange() {
        AssertIsOnMainThread()

        serialQueue.async {
            self.tryToResolveAllMessageFetchingAndProcessingPromises()
        }
    }
}
