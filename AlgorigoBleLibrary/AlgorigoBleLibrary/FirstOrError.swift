//
//  FirstOrError.swift
//  TestBleApp
//
//  Created by Jaehong Yoo on 2020/06/18.
//  Copyright © 2020 Jaehong Yoo. All rights reserved.
//

import Foundation
import RxSwift

public extension Observable {
    func firstOrError() -> Single<Element> {
        return first()
            .map { (value) -> Element in
                if let _value = value {
                    return _value
                } else {
                    throw RxError.noElements
                }
            }
    }
}
