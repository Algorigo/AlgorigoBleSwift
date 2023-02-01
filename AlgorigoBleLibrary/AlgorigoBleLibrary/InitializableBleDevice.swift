//
//  InitializableBleDevice.swift
//  AlgorigoBleLibrary
//
//  Created by rouddy on 2020/09/24.
//  Copyright © 2020 Jaehong Yoo. All rights reserved.
//

import Foundation
import RxSwift
import RxRelay
import CoreBluetooth

open class InitializableBleDevice: BleDevice {
    
    private let initialzeRelay = PublishRelay<ConnectionState>()
    
    required public init(_ peripheral: CBPeripheral) {
        super.init(peripheral)
    }
    
    private let initializeRelay = BehaviorRelay<Bool>(value: false)
    public override var connectionStateObservable: Observable<BleDevice.ConnectionState> {
        return Observable.combineLatest(super.connectionStateObservable, initializeRelay)
            .map({ (connectionState, initialize) in
                connectionState == .connected && !initialize ? .discovering : connectionState
            })
    }
    
    public override func connect() -> Completable {
        super.connect()
            .delay(RxTimeInterval.milliseconds(100), scheduler: ConcurrentDispatchQueueScheduler.init(qos: .background))
            .concat(getInitialize())
    }
    
    private func getInitialize() -> Completable {
        Completable.deferred { [weak self] () -> PrimitiveSequence<CompletableTrait, Never> in
            self?.initialzeCompletable() ?? Completable.error(RxError.unknown)
        }
        .do(onError: { [weak self] error in
            self?.disconnect()
        }, onCompleted: { [weak self] in
            self?.initializeRelay.accept(true)
            self?.connectionStateRelay.accept(.connected)
        })
    }
    
    //Abstract
    open func initialzeCompletable() -> Completable {
        fatalError("Subsclasses need to implement the 'scannedIdentifier' method.")
    }
    
    override func reconnectCompletable() -> Completable {
        super.reconnectCompletable()
            .delay(RxTimeInterval.milliseconds(100), scheduler: ConcurrentDispatchQueueScheduler.init(qos: .background))
            .andThen(getInitialize())
    }
    
    open override func onDisconnected() {
        super.onDisconnected()
        initializeRelay.accept(false)
    }
}
