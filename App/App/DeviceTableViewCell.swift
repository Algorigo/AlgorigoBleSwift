//
//  DeviceTableViewCell.swift
//  TestApp
//
//  Created by Jaehong Yoo on 2020/08/28.
//  Copyright © 2020 Algorigo. All rights reserved.
//

import UIKit
import AlgorigoBleLibrary

protocol DeviceTableViewCellDelegate {
    func handleConncectBtn(device: BleDevice)
    func handleCellClick(device: BleDevice)
}

class DeviceTableViewCell: UITableViewCell {

    @IBOutlet weak var titleView: UILabel!
    @IBOutlet weak var connectBtn: UIButton!
    
    var delegate: DeviceTableViewCellDelegate!

    var device: BleDevice? {
        didSet {
            titleView.text = "\(device?.getName() ?? ""):\(device?.getIdentifier() ?? "Unknown")"
//            print("connectionState:\(device?.connectionState)")
            switch device?.connectionState {
            case .CONNECTED:
                connectBtn.setTitle("Disconnect", for: .normal)
                connectBtn.isEnabled = true
            case .DISCONNECTED, .DISCONNECTING:
                connectBtn.setTitle("Connect", for: .normal)
                connectBtn.isEnabled = true
            case .CONNECTING, .DISCOVERING:
                connectBtn.setTitle("Connecting...", for: .normal)
                connectBtn.isEnabled = false
            default:
                break
            }
        }
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleCellClick))
          self.addGestureRecognizer(tapGesture)
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        
    }
    
    @objc private func handleCellClick() {
        guard let device = device else { return }
        
        if device.connectionState == .CONNECTED {
            print("handleCellClick:\(device.getName() ?? device.getIdentifier())")
            delegate.handleCellClick(device: device)
        }
    }
    
    @IBAction func handleConnectBtn() {
        if let device = device {
            print("handleConnectBtn:\(device.getName() ?? device.getIdentifier())")
            delegate.handleConncectBtn(device: device)
        }
    }
}
