//
//  RetrieveViewController.swift
//  App
//
//  Created by Jaehong Yoo on 2021/02/09.
//  Copyright © 2021 Jaehong Yoo. All rights reserved.
//

import UIKit
import RxSwift
import AlgorigoBleLibrary

class RetrieveViewController: UIViewController {

    static let RetrievePoolKey = "RetrievePool"
    
    static func appendToUserDefault(uuid: UUID) -> [UUID] {
        if var retrievePool = UserDefaults.standard.array(forKey: RetrieveViewController.RetrievePoolKey) as? [String] {
            if !retrievePool.contains(uuid.uuidString) {
                retrievePool.append(uuid.uuidString)
                UserDefaults.standard.set(retrievePool, forKey: RetrieveViewController.RetrievePoolKey)
            }
            return retrievePool.toUuid()
        } else {
            UserDefaults.standard.set([uuid], forKey: RetrieveViewController.RetrievePoolKey)
            return [uuid]
        }
    }
    
    static func removeFromUserDefault(uuid: UUID) -> [UUID] {
        if var retrievePool = UserDefaults.standard.array(forKey: RetrieveViewController.RetrievePoolKey) as? [String] {
            if let index = retrievePool.firstIndex(where: { (uuidString) -> Bool in
                uuidString == uuid.uuidString
            }) {
                retrievePool.remove(at: index)
                UserDefaults.standard.set(retrievePool, forKey: RetrieveViewController.RetrievePoolKey)
            }
            return retrievePool.toUuid()
        } else {
            return []
        }
    }
    
    @IBOutlet weak var identifierTextField: UITextField!
    @IBOutlet weak var identifierTableView: UITableView!
    @IBOutlet weak var deviceTableView: UITableView!
    
    private var retrievePool = [UUID]()
    private var devicesDevice = [BleDevice]()
    
    private let disposeBag = DisposeBag()
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        deviceTableView.register(UINib(nibName: "DeviceTableViewCell", bundle: nil), forCellReuseIdentifier: "deviceCell")
        
        if let stringArray = UserDefaults.standard.array(forKey: RetrieveViewController.RetrievePoolKey) as? [String] {
            retrievePool = stringArray.toUuid()
        }
        
        BluetoothManager.instance.getConnectionStateObservable()
            .observe(on: MainScheduler.instance)
            .subscribe { [weak self] (event) in
                switch event {
                case .next(let status):
//                    print("111 next:\(status.bleDevice):\(status.connectionState)")
                    self?.deviceTableView.reloadData()
                default:
                    break
                }
            }
            .disposed(by: disposeBag)
    }
    

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destination.
        // Pass the selected object to the new view controller.
    }
    */

    @IBAction func handleIdentifierAdd(_ sender: Any) {
        if let text = identifierTextField.text,
           let uuid = UUID(uuidString: text) {
            retrievePool = RetrieveViewController.appendToUserDefault(uuid: uuid)
            identifierTableView.reloadData()
        }
    }
    
    @IBAction func handleRetrieve(_ sender: Any) {
        BluetoothManager.instance.retrieveDevice(identifiers: retrievePool)
            .observe(on: MainScheduler.instance)
            .subscribe { [weak self] (event) in
                switch event {
                case .success(let devices):
                    print("next:\(devices)")
                    self?.devicesDevice = devices
                    self?.deviceTableView.reloadData()
                case .failure(let error):
                    print("error:\(error)")
                }
            }
            .disposed(by: disposeBag)
    }
}

extension RetrieveViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
    }
}

extension RetrieveViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch tableView.restorationIdentifier {
        case "identifiers":
            return retrievePool.count
        case "devices":
            return devicesDevice.count
        default:
            return 0
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch tableView.restorationIdentifier {
        case "identifiers":
            let cell = tableView.dequeueReusableCell(withIdentifier: "identifierCell", for: indexPath)
            if let label = cell.contentView.subviews.first as? UILabel {
                label.text = retrievePool[indexPath.row].uuidString
            }
            return cell
        case "devices":
            let cell = tableView.dequeueReusableCell(withIdentifier: "deviceCell", for: indexPath) as? DeviceTableViewCell ?? DeviceTableViewCell()
            cell.delegate = self
            cell.device = devicesDevice[indexPath.row]
            return cell
        default:
            return UITableViewCell()
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return tableView.restorationIdentifier == "identifiers"
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if tableView.restorationIdentifier == "identifiers",
           editingStyle == .delete {
            let uuid = retrievePool[indexPath.row]
            retrievePool = RetrieveViewController.removeFromUserDefault(uuid: uuid)
            identifierTableView.reloadData()
        }
    }
}

extension RetrieveViewController: DeviceTableViewCellDelegate {
    func handleCellClick(device: BleDevice) {
        
    }
    
    func handleConncectBtn(device: BleDevice) {
        switch device.connectionState {
        case .CONNECTED:
            device.disconnect()
            self.deviceTableView.reloadData()
        case .DISCONNECTED:
            _ = device.connect(autoConnect: true)
                .subscribe(on: ConcurrentDispatchQueueScheduler(qos: .background))
                .observe(on: MainScheduler.instance)
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

extension Array where Element == String {
    func toUuid() -> [UUID] {
        compactMap({ (string) -> UUID? in
            UUID(uuidString: string)
        })
    }
}
