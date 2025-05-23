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
import NordicWiFiProvisioner_BLE

public protocol BleDeviceDelegate {
    func createBleDevice(peripheral: CBPeripheral) -> BleDevice?
    func createBleDeviceWithProvisioing(peripheral: CBPeripheral, scanResult: ScanResult) -> BleDevice?
}
extension BleDeviceDelegate {
    func createBleDeviceOuter(peripheral: CBPeripheral) -> BleDevice? {
        return createBleDevice(peripheral: peripheral)
    }
    
    func createBleDeviceWithProvisioingOuter(peripheral: CBPeripheral, scanResult: ScanResult) -> BleDevice? {
        return createBleDeviceWithProvisioing(peripheral: peripheral, scanResult: scanResult)
    }
}

public class BluetoothManager : NSObject, CBCentralManagerDelegate {
    
    class RxBluetoothError : Error {
        let error: Error?
        init(_ error: Error?) {
            self.error = error
        }
    }
    
    enum BluetoothCentralManagerError : Error {
        case BluetoothUnknownError
        case BluetoothResettingError
        case BluetoothUnsupportedError
        case BluetoothUnauthorizedError
        case BluetoothPowerOffError
    }
    
    public class DefaultBleDeviceDelegate : BleDeviceDelegate {
        public func createBleDevice(peripheral: CBPeripheral) -> BleDevice? {
            BleDevice(peripheral)
        }
        
        public func createBleDeviceWithProvisioing(peripheral: CBPeripheral, scanResult: ScanResult) -> BleDevice? {
            BleDevice(peripheral: peripheral, scanResult: scanResult)
        }
    }
    
    public static let instance = BluetoothManager()
    
    fileprivate var manager: CBCentralManager! = nil
    fileprivate var deviceDic = [CBPeripheral: BleDevice]()
    public var bleDeviceDelegate: BleDeviceDelegate = DefaultBleDeviceDelegate()
    fileprivate let initializedSubject = ReplaySubject<CBManagerState>.create(bufferSize: 1)
    fileprivate let connectionStateSubject = PublishSubject<(bleDevice: BleDevice, connectionState: BleDevice.ConnectionState)>()
    fileprivate var scanSubjects = [([String]?, PublishSubject<CBPeripheral>)]()
    fileprivate var connectSubjects = [CBPeripheral: PublishSubject<Bool>]()
    fileprivate var disconnectSubjects = [CBPeripheral: PublishSubject<Bool>]()
    fileprivate var reconnectUUIDs = [UUID]()
    fileprivate var disposeBag = DisposeBag()
    fileprivate var provisioningScanDelegateWrapper: ScannerDelegateWrapper?
    
    override private init() {
        super.init()
        self.manager = CBCentralManager(delegate: self, queue: nil)
    }
    
    public func initialize(bleDeviceDelegate: BleDeviceDelegate) {
        self.bleDeviceDelegate = bleDeviceDelegate
    }
    
    public func scanAndMatchProvisioningDevices(withServices services: [String]? = nil) -> Observable<[BleDevice]> {
        let scanResultsStream = scanDeviceWithProvisioning()
            .scan(into: [UUID: ScanResult]()) { map, scanResult in
                map[scanResult.id] = scanResult
            }
            .startWith([:])
        
        let peripheralsStream = scanDeviceInner(withServices: services)
            .scan(into: [UUID: CBPeripheral]()) { map, peripheral in
                map[peripheral.identifier] = peripheral
            }
            .startWith([:])
            
        
        return Observable.combineLatest(peripheralsStream, scanResultsStream)
            .map { peripheralMap, scanResultMap in
                var matchedDevicesMap = [UUID: BleDevice]()
                
                for (uuid, peripheral) in peripheralMap {
                    if let scan = scanResultMap[uuid] {
                        matchedDevicesMap[uuid] = self.onBluetoothDeviceFoundWithProvisioning(peripheral: peripheral, scanResult: scan)
                    }
                }
                
                return Array(matchedDevicesMap.values)
            }
    }

    public func scanDevice(withServices services: [String]? = nil) -> Observable<[BleDevice]> {
        var bleDeviceList = [BleDevice]()
        var lastCount = 0
        return scanDeviceInner(withServices: services)
            .map { (peripheral) -> [BleDevice] in
                let device = self.onBluetoothDeviceFound(peripheral)
                if let _device = device {
                    if !bleDeviceList.contains(where: { (a) -> Bool in _device == a }) {
                        bleDeviceList.append(_device)
                    }
                }
                return bleDeviceList
            }
            .filter { (bleDevices) -> Bool in
                if lastCount < bleDevices.count {
                    lastCount = bleDevices.count
                    return true
                } else {
                    return false
                }
            }
    }
    
    public func scanDevice(withServices services: [String]? = nil, intervalSec: Int) -> Observable<[BleDevice]> {
        return scanDevice(withServices: services)
            .take(until: Observable<Int>.timer(DispatchTimeInterval.seconds(intervalSec), scheduler: ConcurrentDispatchQueueScheduler(qos: .background)))
    }
    
    private func scanDeviceInner(withServices services: [String]? = nil) -> Observable<CBPeripheral> {
        return checkBluetoothStatus()
            .andThen(Observable.deferred({ [unowned self] () -> Observable<CBPeripheral> in
                let publishSubject = PublishSubject<CBPeripheral>()
                self.scanSubjects.append((services, publishSubject))
                let services = services?.map({ (uuidStr) -> CBUUID? in
                    CBUUID(string: uuidStr)
                }).compactMap({ $0 })
                self.manager.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey : true])
                return publishSubject
                    .do(onDispose: { [unowned self] in
                        if !publishSubject.hasObservers {
                            let index = self.scanSubjects.firstIndex(where: { (tuple) -> Bool in
                                tuple.1 === publishSubject
                            })!
                            self.scanSubjects.remove(at: index)
                            if scanSubjects.count == index {
                                if scanSubjects.count > 0 {
                                    let lastServices = self.scanSubjects.last?.0?.map({ (uuidStr) -> CBUUID? in
                                        CBUUID(string: uuidStr)
                                    }).compactMap({ $0 })
                                    self.manager.scanForPeripherals(withServices: lastServices, options: [CBCentralManagerScanOptionAllowDuplicatesKey : true])
                                } else {
                                    self.manager.stopScan()
                                }
                            }
                        }
                    })
            }))
    }
    
    private func scanDeviceWithProvisioning(withServices services: [String]? = nil) -> Observable<ScanResult> {
        return Observable.create { observer in
            self.provisioningScanDelegateWrapper = ScannerDelegateWrapper(
                onDeviceDiscovered: { scanResult in
                    print("Scanned: \(scanResult)")
                    observer.onNext(scanResult)
                },
                onScanComplete: {
                    observer.onCompleted()
                }
            )

            let bleScanner = Scanner(delegate: self.provisioningScanDelegateWrapper)
            bleScanner.startScan()

            return Disposables.create {
                bleScanner.stopScan()
            }
        }
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
                    throw BluetoothCentralManagerError.BluetoothUnknownError
                case .resetting:
                    throw BluetoothCentralManagerError.BluetoothResettingError
                case .unsupported:
                    throw BluetoothCentralManagerError.BluetoothUnsupportedError
                case .unauthorized:
                    throw BluetoothCentralManagerError.BluetoothUnauthorizedError
                case .poweredOff:
                    throw BluetoothCentralManagerError.BluetoothPowerOffError
                case .poweredOn:
                    break
                @unknown default:
                    throw BluetoothCentralManagerError.BluetoothUnknownError
                }
            })
            .first()
            .asCompletable()
    }
    
    fileprivate func onBluetoothDeviceFound(_ peripheral: CBPeripheral) -> BleDevice? {
        return deviceDic[peripheral] ?? createBleDevice(peripheral)
    }
    
    fileprivate func onBluetoothDeviceFoundWithProvisioning(peripheral: CBPeripheral, scanResult: ScanResult) -> BleDevice? {
        return deviceDic[peripheral] ?? createBleDevcieWithProvisioning(peripheral: peripheral, scanResult: scanResult)
    }
    
    fileprivate func createBleDevcieWithProvisioning(peripheral: CBPeripheral, scanResult: ScanResult) -> BleDevice? {
        let device = bleDeviceDelegate.createBleDeviceWithProvisioingOuter(peripheral: peripheral, scanResult: scanResult)
        if let _device = device {
            deviceDic[peripheral] = _device
            _device.connectionStateObservable
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
    
    fileprivate func createBleDevice(_ peripheral: CBPeripheral) -> BleDevice? {
        let device = bleDeviceDelegate.createBleDeviceOuter(peripheral: peripheral)
        if let _device = device {
            deviceDic[peripheral] = _device
            _device.connectionStateObservable
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
            bleDevice.connectionState == .CONNECTED
        }
    }
    
    public func getConnectionStateObservable() -> Observable<(bleDevice: BleDevice, connectionState: BleDevice.ConnectionState)> {
        return connectionStateSubject
    }
    
    func connectDevice(peripheral: CBPeripheral, autoConnect: Bool = false) -> Completable {
        return checkBluetoothStatus()
            .andThen(Completable.deferred({ () -> PrimitiveSequence<CompletableTrait, Never> in
                if let subject = self.connectSubjects[peripheral] {
                    return subject
                        .ignoreElements()
                        .asCompletable()
                } else {
                    let subject = PublishSubject<Bool>()
                    self.connectSubjects[peripheral] = subject
                    return subject
                        .ignoreElements()
                        .asCompletable()
                        .do(onCompleted: {
                            if autoConnect,
                               !self.reconnectUUIDs.contains(peripheral.identifier) {
                                self.reconnectUUIDs.append(peripheral.identifier)
                            }
                        }, onSubscribe: {
                            self.manager.connect(peripheral, options: nil)
                        }, onDispose: {
                            self.connectSubjects.removeValue(forKey: peripheral)
                        })
                }
            }))
    }
    
    func getReconnectFlag(peripheral: CBPeripheral) -> Bool {
        return reconnectUUIDs.contains { uuid in
            peripheral.identifier == uuid
        }
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
                        if let index = self.reconnectUUIDs.firstIndex(where: { (uuid) -> Bool in
                            peripheral.identifier == uuid
                        }) {
                            self.reconnectUUIDs.remove(at: index)
                        }
                        self.manager.cancelPeripheralConnection(peripheral)
                    }, onDispose: {
                        self.disconnectSubjects.removeValue(forKey: peripheral)
                    })
            }
        }
    }
    
    //CBCentralManagerDelegate Override Methods
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        initializedSubject.onNext(central.state)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        scanSubjects.last?.1.onNext(peripheral)
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
            if reconnectUUIDs.contains(peripheral.identifier) {
                manager.connect(peripheral, options: nil)
            }
        }
    }
}
