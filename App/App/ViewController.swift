//
//  ViewController.swift
//  TestApp
//
//  Created by Jaehong Yoo on 2020/08/28.
//  Copyright © 2020 Algorigo. All rights reserved.
//

import UIKit
import AlgorigoBleLibrary
import RxSwift

class ViewController: UIViewController {

    static let UUID_SERVICE = "F000AA20-0451-4000-B000-000000000000"
    
    private var disposableAll: Disposable? = nil
    private var disposableDevice: Disposable? = nil
    private var disposableBag = DisposeBag()
    private var devicesAll = [BleDevice]()
    private var devicesDevice = [BleDevice]()
    
    @IBOutlet weak var allTableView: UITableView!
    @IBOutlet weak var deviceTableView: UITableView!
    
    deinit {
        disposableAll?.dispose()
        disposableDevice?.dispose()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        let nibName = UINib(nibName: "DeviceTableViewCell", bundle: nil)
        self.allTableView.register(nibName, forCellReuseIdentifier: "deviceCell")
        self.deviceTableView.register(nibName, forCellReuseIdentifier: "deviceCell")
        
        BluetoothManager.instance.getConnectionStateObservable()
            .observeOn(MainScheduler.instance)
            .subscribe { [weak self] (event) in
                switch event {
                case .next(let status):
//                    print("next:\(status.bleDevice):\(status.connectionState)")
                    self?.allTableView.reloadData()
                    self?.deviceTableView.reloadData()
                default:
                    break
                }
            }
            .disposed(by: disposableBag)
    }

    @IBAction func handleScanBtn() {
        if disposableAll != nil {
            disposableAll?.dispose()
        } else {
            startScan()
        }
    }
    
    @IBAction func handleScanSpecificBtn(_ sender: Any) {
        if disposableDevice != nil {
            disposableDevice?.dispose()
        } else {
            startScanWithServices()
        }
    }
    
    private func startScan() {
        if disposableAll == nil {
            disposableAll = BluetoothManager.instance.scanDevice()
                .subscribeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                .observeOn(MainScheduler.instance)
                .do(onSubscribe: { [weak self] in
                    self?.devicesAll = []
                    self?.allTableView.reloadData()
                })
                .subscribe(onNext: { [weak self] (devices) in
//                    print("scanDevice onNextAll:\(devices.map { $0.getName() ?? $0.getIdentifier()})")
                    self?.devicesAll = devices
                    self?.allTableView.reloadData()
                }, onError: { (error) in
                    print("scanDevice onError:\(error)")
                }, onCompleted: {
                    print("scanDevice onCompleted")
                }, onDisposed: { [weak self] in
                    print("scanDevice onDisposed")
                    self?.disposableAll = nil
                })
        }
    }
    
    private func startScanWithServices() {
        if disposableDevice == nil {
            disposableDevice = BluetoothManager.instance.scanDevice(withServices: [ViewController.UUID_SERVICE])
                .subscribeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                .observeOn(MainScheduler.instance)
                .do(onSubscribe: { [weak self] in
                    self?.devicesDevice = []
                    self?.deviceTableView.reloadData()
                })
                .subscribe(onNext: { [weak self] (devices) in
//                    print("scanDevice onNext:\(devices.map { $0.getName() ?? $0.getIdentifier()})")
                    self?.devicesDevice = devices
                    self?.deviceTableView.reloadData()
                }, onError: { (error) in
                    print("scanDevice onError:\(error)")
                }, onCompleted: {
                    print("scanDevice onCompleted")
                }, onDisposed: { [weak self] in
                    print("scanDevice onDisposed")
                    self?.disposableDevice = nil
                })
        }
    }
}

extension ViewController : UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch tableView.restorationIdentifier {
        case "all":
            return devicesAll.count
        case "device":
            return devicesDevice.count
        default:
            return 0
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "deviceCell", for: indexPath) as? DeviceTableViewCell ?? DeviceTableViewCell()
        cell.delegate = self
        switch tableView.restorationIdentifier {
        case "all":
            cell.device = devicesAll[indexPath.row]
        case "device":
            cell.device = devicesDevice[indexPath.row]
        default:
            break
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let addAction = UIContextualAction(style: .normal, title: "추가", handler: { [weak self] (ac:UIContextualAction, view:UIView, success:(Bool) -> Void) in
            switch tableView.restorationIdentifier {
            case "all":
                if let uuidStr = self?.devicesAll[indexPath.row].getIdentifier(),
                   let uuid = UUID(uuidString: uuidStr) {
                    _ = RetrieveViewController.appendToUserDefault(uuid: uuid)
                }
            case "device":
                if let uuidStr = self?.devicesDevice[indexPath.row].getIdentifier(),
                   let uuid = UUID(uuidString: uuidStr) {
                    _ = RetrieveViewController.appendToUserDefault(uuid: uuid)
                }
            default:
                break
            }
            success(true)
        })
        return UISwipeActionsConfiguration(actions: [addAction])
    }
}

extension ViewController : DeviceTableViewCellDelegate {
    func handleConncectBtn(device: BleDevice) {
        switch device.connectionState {
        case .CONNECTED:
            device.disconnect()
            self.allTableView.reloadData()
        case .DISCONNECTED:
            _ = device.connect()
                .subscribeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                .observeOn(MainScheduler.instance)
                .subscribe(onCompleted: {
                    print("connect onCompleted")
                }, onError: { (error) in
                    print("connect onError:\(error)")
                })
        default:
            break
        }
    }
}
