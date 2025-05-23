//
//  ProvisioningDelegateWrappers.swift
//  AlgorigoBleLibrary
//
//  Created by JuDH on 5/26/25.
//  Copyright © 2025 Jaehong Yoo. All rights reserved.
//

import Foundation
import NordicWiFiProvisioner_BLE

class WiFiScannerDelegateWrapper: WiFiScannerDelegate {
    let onDiscovered: (WifiInfo, Int?) -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    
    init(onDiscovered: @escaping (WifiInfo, Int?) -> Void, onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onDiscovered = onDiscovered
        self.onStart = onStart
        self.onStop = onStop
    }
    
    func deviceManager(_ deviceManager: DeviceManager, discoveredAccessPoint wifi: WifiInfo, rssi: Int?) {
        onDiscovered(wifi, rssi)
    }
    
    func deviceManagerDidStartScan(_ deviceManager: DeviceManager, error: Error?) {
        onStart()
    }
    
    func deviceManagerDidStopScan(_ deviceManager: DeviceManager, error: Error?) {
        onStop()
    }
}

class ProvisionDelegateWrapper: ProvisionDelegate {
    let onProvisionResult: (Result<Void, Error>) -> Void
    let onForgetResult: (Result<Void, Error>) -> Void
    let onStateChange: (NordicWiFiProvisioner_BLE.ConnectionState) -> Void
    
    init(
        onProvisionResult: @escaping (Result<Void, Error>) -> Void,
        onForgetResult: @escaping (Result<Void, Error>) -> Void,
        onStateChange: @escaping (NordicWiFiProvisioner_BLE.ConnectionState) -> Void
    ) {
        self.onProvisionResult = onProvisionResult
        self.onForgetResult = onForgetResult
        self.onStateChange = onStateChange
    }
    
    func deviceManagerDidSetConfig(_ deviceManager: NordicWiFiProvisioner_BLE.DeviceManager, error: Error?) {
        if let error {
            onProvisionResult(.failure(error))
        } else {
            onProvisionResult(.success(()))
        }
    }
    
    func deviceManagerDidForgetConfig(_ deviceManager: NordicWiFiProvisioner_BLE.DeviceManager, error: Error?) {
        if let error {
            onForgetResult(.failure(error))
        } else {
            onForgetResult(.success(()))
        }
    }
    
    func deviceManager(_ provisioner: NordicWiFiProvisioner_BLE.DeviceManager, didChangeState state: NordicWiFiProvisioner_BLE.ConnectionState) {
        onStateChange(state)
    }
}

class DeviceInfoDelegateWrapper: InfoDelegate {
    let onVersionReceived: (Result<Int, ProvisionerInfoError>) -> Void
    let onDeviceStatusReceived: (Result<DeviceStatus, ProvisionerError>) -> Void
    
    init(
        onVersionReceived: @escaping (Result<Int, ProvisionerInfoError>) -> Void,
        onDeviceStatusReceived: @escaping (Result<DeviceStatus, ProvisionerError>) -> Void
    ) {
        self.onVersionReceived = onVersionReceived
        self.onDeviceStatusReceived = onDeviceStatusReceived
    }
    
    func versionReceived(_ version: Result<Int, ProvisionerInfoError>) {
        onVersionReceived(version)
    }
    
    func deviceStatusReceived(_ status: Result<DeviceStatus, ProvisionerError>) {
        onDeviceStatusReceived(status)
    }
}

class ConnectionDelegateWrapper: ConnectionDelegate {
    let onConnected: () -> Void
    let onDisconnected: () -> Void
    let onFailed: (Error) -> Void
    let onStateChange: (DeviceManager.ConnectionState) -> Void
    
    init(onConnected: @escaping () -> Void, onDisconnected: @escaping () -> Void , onFailed: @escaping (Error) -> Void, onStateChange: @escaping (DeviceManager.ConnectionState) -> Void) {
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
        self.onFailed = onFailed
        self.onStateChange = onStateChange
    }
    
    func deviceManagerConnectedDevice(_ deviceManager: DeviceManager) {
        onConnected()
    }
    
    func deviceManagerDidFailToConnect(_ deviceManager: DeviceManager, error: Error) {
        onFailed(error)
    }
    
    func deviceManagerDisconnectedDevice(_ deviceManager: DeviceManager, error: Error?) {
        onDisconnected()
    }
    
    func deviceManager(_ deviceManager: DeviceManager, changedConnectionState newState: DeviceManager.ConnectionState) {
        onStateChange(newState)
    }
}

class ScannerDelegateWrapper: ScannerDelegate {
    let onDeviceDiscovered: (ScanResult) -> Void
    let onScanComplete: () -> Void
    
    init(onDeviceDiscovered: @escaping (ScanResult) -> Void, onScanComplete: @escaping () -> Void) {
        self.onDeviceDiscovered = onDeviceDiscovered
        self.onScanComplete = onScanComplete
    }
    
    func scannerDidUpdateState(_ state: NordicWiFiProvisioner_BLE.Scanner.State) {}
    
    func scannerStartedScanning() {}
    
    func scannerStoppedScanning() { onScanComplete() }
    
    func scannerDidDiscover(_ scanResult: ScanResult) {
        onDeviceDiscovered(scanResult)
    }
}
