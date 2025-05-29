//
//  BleDevice.swift
//  TestBleApp
//
//  Created by Jaehong Yoo on 2020/06/12.
//  Copyright © 2020 Jaehong Yoo. All rights reserved.
//

import Foundation
import CoreBluetooth
import RxSwift
import RxRelay
import NordicWiFiProvisioner_BLE

open class BleDevice: NSObject {
    
    public struct ProvisioningStatus {
        public let version: Int
        public let state: NordicWiFiProvisioner_BLE.ConnectionState?
        public let ssid: String?
        public let bssid: String?
        public let auth: String?
        public let channel: UInt?
    }
    
    public class ProvisioningWifiInfo {
        internal let wifiInfo: WifiInfo
        
        public init(_ wifiInfo: WifiInfo) {
            self.wifiInfo = wifiInfo
        }
        
        public var ssid: String {
            return wifiInfo.ssid
        }
        
        public var bssid: String {
            return wifiInfo.bssid.description
        }
        
        public var bandId: String? {
            return wifiInfo.band?.description
        }
        
        public var channel: UInt {
            return wifiInfo.channel
        }
        
        public var auth: String? {
            return wifiInfo.auth?.description
        }
    }
    
    public enum ConnectionState : String {
        case CONNECTING = "CONNECTING"
        case DISCOVERING = "DISCONVERING"
        case CONNECTED = "CONNECTED"
        case DISCONNECTED = "DISCONNECTED"
        case DISCONNECTING = "DISCONNECTING"
    }
    
    class DisconnectedError : Error {}
    class CommunicationError : Error {}
    class DeviceManagerNotInitializedError: Error {}
    class UnsupportedProvisioningError: Error {}
    
    enum PushData {
        case ReadCharacteristicData(bleDevice: BleDevice, subject: ReplaySubject<Data>, characteristicUuid: String)
        case WriteCharacteristicData(bleDevice: BleDevice, subject: ReplaySubject<Data>, characteristicUuid: String, data: Data)
    }
    
    class AtomicValue<T> {
        let queue = DispatchQueue(label: "queue")

        private(set) var storedValue: T

        init(_ storedValue: T) {
            self.storedValue = storedValue
        }

        var value: T {
            get {
                return queue.sync {
                    self.storedValue
                }
            }
            set { // read, write 접근 자체는 atomic하지만,
                  // 다른 쓰레드에서 데이터 변경 도중(read, write 사이)에 접근이 가능하여, 완벽한 atomic이 아닙니다.
                queue.sync {
                    self.storedValue = newValue
                }
            }
        }
        
        func acquire<S>(_ transform: (inout T) -> S) -> S {
            return queue.sync {
                return transform(&self.storedValue)
            }
        }

        // 올바른 방법
        func mutate(_ transform: (inout T) -> ()) {
            queue.sync {
                transform(&self.storedValue)
            }
        }
    }
    
    static var pushQueue = AtomicValue<[PushData]>([PushData]())
    static var pushing = AtomicValue<Bool>(false)
    static let dispatchQueue = DispatchQueue(label: "BleDevice")
    static func pushStart() {
        if !pushing.value {
            doPush()
        }
    }
    static func doPush() {
        if let pushData = pushQueue.acquire({ pushs -> PushData? in
            if (pushs.count > 0) {
                return pushs.removeFirst()
            } else {
                return nil
            }
        }) {
            pushing.value = true
            switch pushData {
            case .ReadCharacteristicData(let bleDevice, let subject, let uuid):
                bleDevice.processReadCharacteristicData(subject: subject, characteristicUuid: uuid)
            case .WriteCharacteristicData(let bleDevice, let subject, let uuid, let data):
                bleDevice.processWriteCharacteristicData(subject: subject, characteristicUuid: uuid, data: data)
            }
        } else {
            pushing.value = false
        }
    }
    
    var connectionStateSubject = ReplaySubject<ConnectionState>.create(bufferSize: 1)
    public var connectionStateObservable: Observable<ConnectionState> {
        connectionStateSubject.asObserver()
    }
    public internal(set) var connectionState: ConnectionState = .DISCONNECTED {
        didSet {
            if (connectionState == .DISCONNECTED) {
                discoverSubject = PublishSubject<Any>()
                notificationObservableDic.values.forEach { (tuple) in
                    tuple.subject.onError(DisconnectedError())
                }
            }
            connectionStateSubject.onNext(connectionState)
        }
    }
    public var connected: Bool {
        return connectionState == ConnectionState.CONNECTED || connectionState == ConnectionState.DISCOVERING
    }
    fileprivate var disposable: Disposable! = nil
    fileprivate var peripheral: CBPeripheral! = nil
    fileprivate let characteristicSubject = ReplaySubject<CBCharacteristic>.createUnbounded()
    fileprivate var characteristicDic = AtomicValue([String: (subject: ReplaySubject<Data>, data: Data)]())
    fileprivate var notificationObservableDic: [String: (observable: Observable<Observable<Data>>, subject: ReplaySubject<Observable<Data>>)] = [:]
    fileprivate var notificationDic: [String: PublishSubject<Data>] = [:]
    fileprivate var discoverSubject = PublishSubject<Any>()
    fileprivate var discoverCompletable: Completable {
        return discoverSubject.ignoreElements().asCompletable()
    }
    fileprivate(set) var deviceManager: DeviceManager?
    fileprivate var discoveredWifiList: [WifiInfo] = []
    fileprivate var connectionDelegateWrapper: ConnectionDelegateWrapper?
    fileprivate var wiFiScannerDelegateWrapper: WiFiScannerDelegateWrapper?
    fileprivate var provisionDelegateWrapper: ProvisionDelegateWrapper?
    fileprivate var infoDelegateWrapper: DeviceInfoDelegateWrapper?
    
    fileprivate var scanResult: ScanResult?

    public required init(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        
        peripheral.delegate = self
    }
    
    public init(peripheral: CBPeripheral, scanResult: ScanResult) {
        self.scanResult = scanResult
        self.peripheral = peripheral
        super.init()
        
        peripheral.delegate = self
    }
    
    public func connect(autoConnect: Bool = false) -> Completable {
        var dispose = true
        return BluetoothManager.instance.connectDevice(peripheral: peripheral, autoConnect: autoConnect)
            .concat(discoverCompletable.do(onSubscribe: {
                self.discover()
            }))
            .do(onError: { (error) in
                dispose = false
                self.connectionState = .DISCONNECTED
            }, onCompleted: {
                dispose = false
                self.connectionState = .CONNECTED
            }, onSubscribe: {
                self.connectionState = .CONNECTING
            }, onSubscribed: {
            }, onDispose: {
                if dispose {
                    self.disconnect()
                }
            })
    }
    
    public func reconnect() -> Completable {
        return Single<Bool>.deferred { [weak self] in
            if let this = self {
                return Single.just(BluetoothManager.instance.getReconnectFlag(peripheral: this.peripheral))
            } else {
                return Single.error(RxError.noElements)
            }
        }.flatMapCompletable { [weak self] autoConnect in
            if let this = self {
                return this.disconnectCompletable()
                    .andThen(this.connect(autoConnect: autoConnect))
            } else {
                return Completable.error(RxError.noElements)
            }
        }
    }
    
    public func disconnect() {
        _ = disconnectCompletable()
            .subscribe(onCompleted: {
                
            }, onError: { (error) in
                debugPrint("disconnectDevice onError:\(error)")
            })
    }
    
    fileprivate func disconnectCompletable() -> Completable {
        return BluetoothManager.instance.disconnectDevice(peripheral: peripheral)
            .do(onSubscribe: {
                self.connectionState = .DISCONNECTING
            })
            .do(onCompleted: {
                self.onDisconnected()
            })
    }
    
    fileprivate func discover() {
        connectionState = .DISCOVERING
        peripheral.discoverServices(nil)
    }
    
    func onReconnected() {
        _ = reconnectCompletable()
            .subscribe { (event) in
//                print("onReconnected \(event)")
            }
    }
    
    func reconnectCompletable() -> Completable {
        var dispose = true
        return discoverCompletable.do(onSubscribe: {
            self.discover()
        })
        .do(onError: { (error) in
            dispose = false
            self.connectionState = .DISCONNECTED
        }, onCompleted: {
            dispose = false
            self.connectionState = .CONNECTED
        }, onSubscribe: {
            self.connectionState = .CONNECTING
        }, onSubscribed: {
        }, onDispose: {
            if dispose {
                self.disconnect()
            }
        })
    }
    
    open func onDisconnected() {
        discoverSubject = PublishSubject<Any>()
        connectionState = .DISCONNECTED
    }
    
    public func getName() -> String? {
        return peripheral.name
    }
    
    public func getIdentifier() -> String {
        return peripheral.identifier.uuidString
    }
    
    public func readCharacteristic(uuid: String) -> Single<Data> {
        let subject = ReplaySubject<Data>.create(bufferSize: 1)
        return subject
            .do(onSubscribe: {
                BleDevice.pushQueue.mutate({ pushData in
                    pushData.append(.ReadCharacteristicData(bleDevice: self, subject: subject, characteristicUuid: uuid))
                })
                BleDevice.pushStart()
            }, onDispose: {
                BleDevice.doPush()
            })
            .firstOrError()
    }
    
    public func writeCharacteristic(uuid: String, data: Data) -> Single<Data> {
        let subject = ReplaySubject<Data>.create(bufferSize: 1)
        return subject
            .do(onSubscribe: {
                BleDevice.pushQueue.mutate({ pushData in
                    pushData.append(.WriteCharacteristicData(bleDevice: self, subject: subject, characteristicUuid: uuid, data: data))
                })
                BleDevice.pushStart()
            }, onDispose: {
                BleDevice.doPush()
            })
            .firstOrError()
    }
    
    public func setupNotification(uuid: String) -> Observable<Observable<Data>> {
        if notificationObservableDic[uuid] == nil {
            var isFirst = true
            let subject = ReplaySubject<Observable<Data>>.create(bufferSize: 1)
            notificationObservableDic[uuid] = (
                observable: subject.do(onSubscribe: {
                    if (isFirst) {
                        isFirst = false
                        self.processNotificationEnableData(subject: subject, characteristicUuid: uuid)
                    }
                }, onDispose: {
                    if (!subject.hasObservers) {
                        self.disableNotification(uuid: uuid)
                    }
                }), subject: subject)
        }
        return notificationObservableDic[uuid]!.observable
    }
    
    public func initializeProvisioning() -> Completable {
        guard let scanResult = self.scanResult else {
            return Completable.error(UnsupportedProvisioningError())
        }
        self.deviceManager = DeviceManager(scanResult: scanResult)
        
        return Completable.create { completable in
            self.connectionDelegateWrapper = ConnectionDelegateWrapper(
                onConnected: {
                    //                    completable(.completed)
                    // 연결 성공 시 상태값 읽기 시도
                    _ = self.getProvisioningStatus()
                        .subscribe(onSuccess: { _ in
                            completable(.completed)
                        }, onFailure: { error in
                            completable(.error(error))
                        })
                },
                onDisconnected: {
                    completable(.error(DisconnectedError()))
                },
                onFailed: { error in
                    completable(.error(error))
                },
                onStateChange: { state in }
            )
            
            self.deviceManager?.connectionDelegate = self.connectionDelegateWrapper
            self.deviceManager?.connect()
            
            return Disposables.create()
        }
    }
    
    public func scanWifiList() -> Single<[ProvisioningWifiInfo]> {
        guard let deviceManager = self.deviceManager else {
            return Single.error(DeviceManagerNotInitializedError())
        }
        
        let discoveredSsids = AtomicValue(Set<String>())
        
        return Observable<ProvisioningWifiInfo>.create { observer in
            self.wiFiScannerDelegateWrapper = WiFiScannerDelegateWrapper(
                onDiscovered: { wifi, _ in
                    guard !wifi.ssid.isEmpty else { return }
                    
                    let inserted = discoveredSsids.acquire { set -> Bool in
                        return set.insert(wifi.ssid).inserted
                    }
                    
                    if inserted {
                        let result = ProvisioningWifiInfo(wifi)
                        observer.onNext(result)
                    }
                },
                onStart: {},
                onStop: {
                    observer.onCompleted()
                }
            )
            
            do {
                deviceManager.wifiScannerDelegate = self.wiFiScannerDelegateWrapper
                try deviceManager.startScan()
            } catch {
                observer.onError(error)
            }
            
            return Disposables.create {
                do {
                    try deviceManager.stopScan()
                } catch {
                    debugPrint("Failed to stop scan: \(error)")
                }
            }
        }
        .scan(into: [ProvisioningWifiInfo]()) { acc, wifi in
            if acc.first(where: { $0.ssid == wifi.ssid }) == nil {
                acc.append(wifi)
            }
        }
        .filter { !$0.isEmpty }
        .debounce(.milliseconds(500), scheduler: MainScheduler.instance)
        .take(1)
        .asSingle()
        .do(onDispose: { [weak self] in
            guard let self = self, let deviceManager = self.deviceManager else { return }
            do {
                try deviceManager.stopScan()
                debugPrint("Scan stopped successfully")
            } catch {
                debugPrint("Failed to stop scan: \(error)")
            }
        })
    }
    
    public func startProvisioning(provisioningWifiInfo: ProvisioningWifiInfo, password: String) -> Completable {
        guard let deviceManager = self.deviceManager else {
            return Completable.error(DeviceManagerNotInitializedError())
        }
        
        return Completable.create { completable in
            self.provisionDelegateWrapper = ProvisionDelegateWrapper(
                onProvisionResult: { _ in },
                onForgetResult: { _ in },
                onStateChange: { state in
                    switch state {
                    case .connected:
                        completable(.completed)
                    case .connectionFailed(let error):
                        completable(.error(error))
                    case .disconnected:
                        _ = self.getProvisioningStatus()
                            .retry(when: { (errors: Observable<Error>) in
                                errors.enumerated().flatMap { attempt, error -> Observable<Int> in
                                    if attempt >= 9 {
                                        return Observable.error(error)
                                    }
                                    return Observable<Int>.just(attempt).delay(.seconds(1), scheduler: MainScheduler.instance)
                                }
                            })
                            .subscribe(onSuccess: { provisioningStatus in
                                guard
                                    let state = provisioningStatus.state,
                                    let ssid = provisioningStatus.ssid
                                else {
                                    completable(.error(DisconnectedError()))
                                    return
                                }
                                
                                if state == .connected && ssid == provisioningWifiInfo.wifiInfo.ssid {
                                    completable(.completed)
                                } else {
                                    completable(.error(DisconnectedError()))
                                }
                            }, onFailure: { error in
                                completable(.error(error))
                            })
                    default:
                        break
                    }
                }
            )
            
            deviceManager.provisionerDelegate = self.provisionDelegateWrapper
            
            do {
                try deviceManager.setConfig(wifi: provisioningWifiInfo.wifiInfo, passphrase: password, volatileMemory: false)
            } catch {
                completable(.error(error))
            }
            
            return Disposables.create()
        }
    }
    
    public func cleanProvisioning() -> Completable {
        guard let deviceManager = self.deviceManager else {
            return Completable.error(DeviceManagerNotInitializedError())
        }
        
        return Completable.create { completable in
            self.provisionDelegateWrapper = ProvisionDelegateWrapper(
                onProvisionResult: { _ in },
                onForgetResult: { result in
                    switch result {
                    case .success:
                        completable(.completed)
                    case .failure(let error):
                        completable(.error(error))
                    }
                },
                onStateChange: { _ in }
            )
            
            deviceManager.provisionerDelegate = self.provisionDelegateWrapper
            
            do {
                try deviceManager.forgetConfig()
            } catch {
                completable(.error(error))
            }
            
            return Disposables.create()
        }
    }
    
    public func getProvisioningStatus() -> Single<ProvisioningStatus> {
        guard let deviceManager = self.deviceManager else {
            return Single.error(DeviceManagerNotInitializedError())
        }
        
        return Single.create { single in
            var versionValue: Int?
            var statusValue: DeviceStatus?
            
            func tryEmit() {
                guard let version = versionValue, let status = statusValue else { return }
                
                let state = status.state
                let ssid = status.provisioningInfo?.ssid
                let bssid = status.provisioningInfo?.bssid.description
                let auth = status.provisioningInfo?.auth?.description
                let channel = status.provisioningInfo?.channel
                
                let result = ProvisioningStatus(
                    version: version,
                    state: state,
                    ssid: ssid,
                    bssid: bssid,
                    auth: auth,
                    channel: channel
                )
                
                single(.success(result))
            }
            
            self.infoDelegateWrapper = DeviceInfoDelegateWrapper(
                onVersionReceived: { result in
                    if case .success(let value) = result {
                        versionValue = value
                        tryEmit()
                    } else if case .failure(let error) = result {
                        single(.failure(error))
                    }
                },
                onDeviceStatusReceived: { result in
                    if case .success(let value) = result {
                        statusValue = value
                        tryEmit()
                    } else if case .failure(let error) = result {
                        single(.failure(error))
                    }
                }
            )
            
            deviceManager.infoDelegate = self.infoDelegateWrapper
            
            do {
                try deviceManager.readVersion()
                try deviceManager.readDeviceStatus()
            } catch {
                single(.failure(error))
            }
            
            return Disposables.create()
        }
    }
    
    fileprivate func disableNotification(uuid: String) {
        notificationObservableDic.removeValue(forKey: uuid)
        notificationDic.removeValue(forKey: uuid)
        processNotificationDisableData(characteristicUuid: uuid)
    }
    
    fileprivate func processReadCharacteristicData(subject: ReplaySubject<Data>, characteristicUuid: String) {
        _ = getConnectedCompletable()
            .andThen(getCharacteristic(uuid: characteristicUuid))
            .flatMap { (characteristic) -> Single<Data> in
                let dataSubject = ReplaySubject<Data>.create(bufferSize: 1)
                self.characteristicDic.mutate({ dict in
                    dict[characteristicUuid] = (subject: dataSubject, data: Data())
                })
                return Completable.create { (observer) -> Disposable in
                    self.readCharacteristicInner(characteristic: characteristic)
                    observer(.completed)
                    return Disposables.create()
                }
                .andThen(dataSubject.firstOrError())
                .timeout(DispatchTimeInterval.seconds(3), scheduler: ConcurrentDispatchQueueScheduler(qos: .background))
                .do(onError: { (error) in
                    self.characteristicDic.mutate({ dict in
                        dict.removeValue(forKey: characteristicUuid)
                    })
                })
            }
            .subscribe(onSuccess: { (data) in
                subject.on(.next(data))
            }, onFailure: { (error) in
                subject.on(.error(error))
            })
    }
    
    fileprivate func processWriteCharacteristicData(subject: ReplaySubject<Data>, characteristicUuid: String, data: Data) {
        _ = getConnectedCompletable()
            .andThen(getCharacteristic(uuid: characteristicUuid))
            .flatMap { (characteristic) -> Single<Data> in
                let dataSubject = ReplaySubject<Data>.create(bufferSize: 1)
                self.characteristicDic.mutate { dict in
                    dict[characteristicUuid] = (subject: dataSubject, data: data)
                }
                return Completable.create { (observer) -> Disposable in
                    self.writeCharacteristicInner(characteristic: characteristic, data: data)
                    observer(.completed)
                    return Disposables.create()
                }
                .andThen(dataSubject.firstOrError())
                .timeout(DispatchTimeInterval.seconds(3), scheduler: ConcurrentDispatchQueueScheduler(qos: .background))
                .do(onError: { (error) in
                    self.characteristicDic.mutate { dict in
                        dict.removeValue(forKey: characteristicUuid)
                    }
                })
            }
            .subscribe(onSuccess: { (data) in
                subject.on(.next(data))
            }, onFailure: { (error) in
                subject.on(.error(error))
            })
    }
    
    fileprivate func processNotificationEnableData(subject: ReplaySubject<Observable<Data>>, characteristicUuid: String) {
        _ = getConnectedCompletable()
            .andThen(getCharacteristic(uuid: characteristicUuid))
            .flatMapCompletable({ (characteristic) -> Completable in
                Completable.create { (observer) -> Disposable in
                    self.setCharacteristicNotificationInner(characteristic: characteristic, data: true)
                    observer(.completed)
                    return Disposables.create()
                }
            })
            .subscribe(onCompleted: {
                let dataSubject = PublishSubject<Data>()
                self.notificationDic[characteristicUuid] = dataSubject
                subject.on(.next(dataSubject))
            }, onError: { (error) in
                subject.on(.error(error))
            })
    }
    
    fileprivate func processNotificationDisableData(characteristicUuid: String) {
        _ = getCharacteristic(uuid: characteristicUuid)
            .flatMapCompletable({ (characteristic) -> Completable in
                return Completable.create { (observer) -> Disposable in
                    self.setCharacteristicNotificationInner(characteristic: characteristic, data: false)
                    observer(.completed)
                    return Disposables.create()
                }
            })
            .subscribe(onCompleted: {
            }, onError: { (error) in
                debugPrint("getCharacteristic onError \(error)")
            })
    }
    
    fileprivate func getConnectedCompletable() -> Completable {
        return connectionStateSubject
            .filter { (connectionState) -> Bool in
                connectionState != .CONNECTING && connectionState != .DISCOVERING
            }
            .do(onNext: { (connectionState) in
                if (connectionState != .CONNECTED) {
                    throw DisconnectedError()
                }
            })
            .firstOrError()
            .asCompletable()
    }
    
    fileprivate func getCharacteristic(uuid: String) -> Single<CBCharacteristic> {
        return characteristicSubject
            .filter({ (characteristic) -> Bool in
                characteristic.uuid.uuidString == uuid
            })
            .take(for: DispatchTimeInterval.seconds(1), scheduler: ConcurrentDispatchQueueScheduler(qos: .background))
            .firstOrError()
    }
    
    fileprivate func readCharacteristicInner(characteristic: CBCharacteristic) {
        peripheral.readValue(for: characteristic)
    }
    
    fileprivate func writeCharacteristicInner(characteristic: CBCharacteristic, data: Data) {
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }
    
    fileprivate func setCharacteristicNotificationInner(characteristic: CBCharacteristic, data: Bool) {
        peripheral.setNotifyValue(data, for: characteristic)
    }
}

extension BleDevice: CBPeripheralDelegate {
    //CBPeripheralDelegate Override Methods
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        discoverSubject.onCompleted()
        if let error = error {
            debugPrint("error : peripheral didDiscoverServices: \(peripheral.name ?? peripheral.identifier.uuidString), error: \(error.localizedDescription)")
        } else {
            self.peripheral = peripheral
            for service in peripheral.services! {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics! {
            characteristicSubject.on(.next(characteristic))
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let subjectAndData = characteristicDic.value[characteristic.uuid.uuidString] {
            characteristicDic.mutate({ dict in
                dict.removeValue(forKey: characteristic.uuid.uuidString)
            })
            subjectAndData.subject.on(.next(characteristic.value ?? subjectAndData.data))
        } else if let subject = notificationDic[characteristic.uuid.uuidString], let _value = characteristic.value {
            subject.on(.next(_value))
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let subjectAndData = characteristicDic.value[characteristic.uuid.uuidString] {
            characteristicDic.mutate { dict in
                dict.removeValue(forKey: characteristic.uuid.uuidString)
            }
            subjectAndData.subject.on(.next(characteristic.value ?? subjectAndData.data))
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
    }
}
