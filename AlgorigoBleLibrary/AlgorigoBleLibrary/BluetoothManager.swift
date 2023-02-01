//
//  RxBluetoothManager.swift
//  TestBleApp
//
//  Created by Jaehong Yoo on 2020/06/09.
//  Copyright © 2020 Jaehong Yoo. All rights reserved.
//

import Foundation
import CoreBluetooth
import RxSwift
import RxRelay


public protocol BleDeviceDelegate {
    func createBleDevice(peripheral: CBPeripheral) -> BleDevice?
}
extension BleDeviceDelegate {
    func createBleDeviceOuter(peripheral: CBPeripheral) -> BleDevice? {
        return createBleDevice(peripheral: peripheral)
    }
}

public class BluetoothManager : NSObject {
    
    class RxBluetoothError : Error {
        let error: Error?
        init(_ error: Error?) {
            self.error = error
        }
    }
    
    enum BluetoothManagerError : Error {
        case unknownError
        case resettingError
        case unsupportedError
        case unauthorizedError
        case powerOffError
    }
    
    public class DefaultBleDeviceDelegate : BleDeviceDelegate {
        public func createBleDevice(peripheral: CBPeripheral) -> BleDevice? {
            BleDevice(peripheral)
        }
    }
    
    public static let instance = BluetoothManager()
    
    fileprivate var manager: CBCentralManager! = nil
    fileprivate var deviceDic = [CBPeripheral: BleDevice]()
    public var bleDeviceDelegate: BleDeviceDelegate = DefaultBleDeviceDelegate()
    fileprivate let initializedSubject = ReplaySubject<CBManagerState>.create(bufferSize: 1)
    fileprivate let connectionStateSubject = PublishSubject<(bleDevice: BleDevice, connectionState: BleDevice.ConnectionState)>()
    fileprivate var scanRelay = PublishRelay<(CBPeripheral, ScanInfo)>()
    fileprivate var connectSubjects = [CBPeripheral: PublishSubject<Any>]()
    fileprivate var disconnectSubjects = [CBPeripheral: PublishSubject<Bool>]()
    fileprivate var disposeBag = DisposeBag()
    
    override private init() {
        super.init()
        self.manager = CBCentralManager(delegate: self, queue: nil)
    }
    
    public func initialize(bleDeviceDelegate: BleDeviceDelegate) {
        self.bleDeviceDelegate = bleDeviceDelegate
    }
    
    public func scanDevice(withServices services: [String]? = nil) -> Observable<[(device: BleDevice, scanInfo: ScanInfo)]> {
        var count = 0
        return scanDeviceInner(withServices: services)
            .compactMap({ tuple -> [(device: BleDevice, scanInfo: ScanInfo)]? in
                guard let device = self.onBluetoothDeviceFound(tuple.0) else {
                    return nil
                }
                return [(device: device, scanInfo: tuple.1)]
            })
            .scan([], accumulator: { prev, next -> [(device: BleDevice, scanInfo: ScanInfo)] in
                prev + next.filter({ (device, scanInfo) in
                    !prev.contains { tuple in
                        tuple.device.getIdentifier() == device.getIdentifier()
                    }
                })
            })
            .filter({ list in
                let newExist = list.count != count
                count = list.count
                return newExist
            })
            .subscribe(on: ConcurrentDispatchQueueScheduler(qos: .background))
    }
    
    private func scanDeviceInner(withServices services: [String]? = nil) -> Observable<(CBPeripheral, ScanInfo)> {
        return checkBluetoothStatus()
            .andThen(Observable.deferred({ [unowned self] () -> Observable<(CBPeripheral, ScanInfo)> in
                let services = services?.map({ (uuidStr) -> CBUUID? in
                    CBUUID(string: uuidStr)
                }).compactMap({ $0 })
                self.manager.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey : true])
                return self.scanRelay
                    .asObservable()
            }))
            .do(onDispose: { [unowned self] in
                self.manager.stopScan()
            })
    }
    
    public func retrieveDevice(identifiers: [UUID]) -> Single<[BleDevice]> {
        return retrieveDeviceInner(identifiers: identifiers)
                .map { [unowned self] (peripherals) -> [BleDevice] in
                    return peripherals
                        .compactMap { [unowned self] (peripheral) -> BleDevice? in
                            self.onBluetoothDeviceFound(peripheral)
                        }
                }
    }
    
    private func retrieveDeviceInner(identifiers: [UUID]) -> Single<[CBPeripheral]> {
        return checkBluetoothStatus()
            .andThen(Single<[CBPeripheral]>.deferred { [unowned self] () -> Single<[CBPeripheral]> in
                let devices = self.manager.retrievePeripherals(withIdentifiers: identifiers)
                return Single.just(devices)
            })
    }
    
    fileprivate func checkBluetoothStatus() -> Completable {
        return initializedSubject
            .do(onNext: { (state) in
                switch (state) {
                case .unknown:
                    throw BluetoothManagerError.unknownError
                case .resetting:
                    throw BluetoothManagerError.resettingError
                case .unsupported:
                    throw BluetoothManagerError.unsupportedError
                case .unauthorized:
                    throw BluetoothManagerError.unauthorizedError
                case .poweredOff:
                    throw BluetoothManagerError.powerOffError
                case .poweredOn:
                    break
                @unknown default:
                    throw BluetoothManagerError.unknownError
                }
            })
            .first()
            .asCompletable()
    }
    
    fileprivate func onBluetoothDeviceFound(_ peripheral: CBPeripheral) -> BleDevice? {
        return deviceDic[peripheral] ?? createBleDevice(peripheral)
    }
    
    fileprivate func createBleDevice(_ peripheral: CBPeripheral) -> BleDevice? {
        let device = bleDeviceDelegate.createBleDeviceOuter(peripheral: peripheral)
        if let _device = device {
            deviceDic[peripheral] = _device
            _device.connectionStateObservable
                .skip(1)
                .subscribe { [weak self] (event) in
                    switch event {
                    case .next(let state):
                        self?.connectionStateSubject.onNext((bleDevice: _device, connectionState: state))
                    default:
                        break
                    }
                }
                .disposed(by: disposeBag)
        }
        return device
    }
    
    public func getDevices() -> [BleDevice] {
        return Array(deviceDic.values)
    }
    
    public func getConnectedDevices() -> [BleDevice] {
        return deviceDic.values.filter { (bleDevice) -> Bool in
            bleDevice.connectionState == .connected
        }
    }
    
    public func getConnectionStateObservable() -> Observable<(bleDevice: BleDevice, connectionState: BleDevice.ConnectionState)> {
        return connectionStateSubject
    }
    
    internal func connectDevice(peripheral: CBPeripheral) -> Completable {
        return checkBluetoothStatus()
            .andThen(Completable.deferred({ () -> PrimitiveSequence<CompletableTrait, Never> in
                if let subject = self.connectSubjects[peripheral] {
                    return subject
                        .ignoreElements()
                        .asCompletable()
                } else {
                    let subject = PublishSubject<Any>()
                    self.connectSubjects[peripheral] = subject
                    return subject
                        .ignoreElements()
                        .asCompletable()
                        .do(onSubscribe: {
                            self.manager.connect(peripheral, options: nil)
                        }, onDispose: {
                            self.connectSubjects.removeValue(forKey: peripheral)
                        })
                }
            }))
    }
    
    func disconnectDevice(peripheral: CBPeripheral) -> Completable {
        return Completable.deferred { () -> PrimitiveSequence<CompletableTrait, Never> in
            if let subject = self.disconnectSubjects[peripheral] {
                return subject
                    .ignoreElements()
                    .asCompletable()
            } else {
                let subject = PublishSubject<Bool>()
                self.disconnectSubjects[peripheral] = subject
                return subject
                    .ignoreElements()
                    .asCompletable()
                    .do(onSubscribe: {
                        self.manager.cancelPeripheralConnection(peripheral)
                    }, onDispose: {
                        self.disconnectSubjects.removeValue(forKey: peripheral)
                    })
            }
        }
    }
}

extension BluetoothManager : CBCentralManagerDelegate {
    //CBCentralManagerDelegate Override Methods
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        initializedSubject.onNext(central.state)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        scanRelay.accept((peripheral, ScanInfo(advertisementData: advertisementData, rssi: RSSI)))
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let subject = connectSubjects[peripheral] {
            subject.on(.completed)
        } else if let device = deviceDic[peripheral] {
            device.onReconnected()
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let subject = connectSubjects[peripheral] {
            subject.on(.error(RxBluetoothError(error)))
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let subject = disconnectSubjects[peripheral] {
            subject.on(.completed)
        } else if let device = deviceDic[peripheral] {
            device.onDisconnected()
        }
    }
}
